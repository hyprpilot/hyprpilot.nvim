--- Inline diff preview for file-edit permission requests.
---
--- When the captain hits `permission_row.keymaps.show_diff` on a
--- permission row for an edit
--- tool (Edit / Write / MultiEdit / similar), we render the proposed
--- changes as virt_lines + line highlights on the actual target
--- buffer. The buffer itself is NEVER mutated — mcphub.nvim does
--- this and inherits a save/undo state machine that's hard to keep
--- correct. We stay purely visual; the daemon owns the write on
--- accept.
---
--- Captain experience:
---   - `<localleader>o` by default opens the preview in the prior
---     window (or a vsplit if none is stashed). Cursor moves there.
---   - `<localleader>a` / `<localleader>d` from the preview buffer resolve the
---     permission; `<Esc>` closes the preview without resolving.
---   - Editing the buffer auto-closes the preview (stale).
---   - Permission resolution from anywhere closes the preview too.

local chat_buffer = require("hyprpilot.chat.buffer")
local config = require("hyprpilot.config")
local log = require("hyprpilot.log")
local permissions = require("hyprpilot.rpc.permissions")
local tool_kind = require("hyprpilot.tool_kind")

local M = {}

local NS = vim.api.nvim_create_namespace("hyprpilot.ui.diff-preview")
local AUGROUP = vim.api.nvim_create_augroup("HyprpilotDiffPreview", { clear = true })

---@class hyprpilot.diff_preview.Hunk
---@field old_start integer     -- 1-indexed line in the original where the hunk starts
---@field old_count integer     -- number of original lines this hunk replaces
---@field new_lines string[]    -- replacement lines (may be empty for pure deletion)

---@class hyprpilot.diff_preview.State
---@field request_id string
---@field instance_id string
---@field bufnr integer
---@field winid? integer            -- captain-visible window we drove the cursor into
---@field path string               -- resolved absolute path (or `hyprpilot://...` scratch name)
---@field is_scratch boolean        -- true when the file didn't exist + we minted a scratch buffer
---@field hunks hyprpilot.diff_preview.Hunk[]
---@field unwire fun()              -- composite cleanup closure (autocmds + keymaps + extmarks)

---@type hyprpilot.diff_preview.State?
M._state = nil

local listeners_wired = false

---True when a preview is currently open.
---@return boolean, string?
function M.is_open()
  if M._state == nil then
    return false, nil
  end
  return true, M._state.request_id
end

---@param value any
---@return string?
local function nonempty_string(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

---@param raw table
---@param keys string[]
---@return string?
local function pick_string(raw, keys)
  for _, key in ipairs(keys) do
    local value = nonempty_string(raw[key])
    if value ~= nil then
      return value
    end
  end
  return nil
end

---@param path string?
---@return string?
local function clean_diff_path(path)
  path = nonempty_string(path)
  if path == nil or path == "/dev/null" then
    return nil
  end
  path = path:gsub("\r$", "")
  path = path:gsub('^"(.*)"$', "%1")
  path = path:gsub("^[ab]/", "")
  return nonempty_string(path)
end

---@param raw any
---@return string?
local function first_change_path(raw)
  if type(raw) ~= "table" or type(raw.changes) ~= "table" then
    return nil
  end
  for path, _ in pairs(raw.changes) do
    local cleaned = clean_diff_path(path)
    if cleaned ~= nil then
      return cleaned
    end
  end
  return nil
end

---Extract `path / file_path` from `raw_input` regardless of which
---field the agent populated. Returns nil when neither is present
---(the caller logs + falls back to "no preview").
---@param raw any
---@return string?
local function resolve_path(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local path = pick_string(raw, { "path", "file_path", "filePath", "filepath" })
  if path ~= nil then
    return path
  end
  path = first_change_path(raw)
  if path ~= nil then
    return path
  end
  path = pick_string(raw, { "notebook_path", "notebookPath" })
  if path ~= nil then
    -- NotebookEdit — handled separately by the caller (no preview in v1).
    return path
  end
  return nil
end

---@param raw any
---@return boolean
local function is_notebook(raw)
  return type(raw) == "table" and (raw.notebook_path ~= nil or raw.notebookPath ~= nil)
end

---@param formatted any
---@return string?
local function formatted_diff(formatted)
  if type(formatted) ~= "table" then
    return nil
  end
  return nonempty_string(formatted.diff)
end

---@param diff string?
---@return string?
local function path_from_unified_diff(diff)
  diff = nonempty_string(diff)
  if diff == nil then
    return nil
  end
  for line in diff:gmatch("[^\n]+") do
    local git_path = line:match("^diff %-%-git%s+a/.-%s+b/(.+)$")
    local cleaned = clean_diff_path(git_path)
    if cleaned ~= nil then
      return cleaned
    end

    local new_path = line:match("^%+%+%+%s+(.+)$")
    cleaned = clean_diff_path(new_path)
    if cleaned ~= nil then
      return cleaned
    end

    local old_path = line:match("^%-%-%-%s+(.+)$")
    cleaned = clean_diff_path(old_path)
    if cleaned ~= nil then
      return cleaned
    end
  end
  return nil
end

---@param formatted any
---@return string?
local function path_from_formatted_fields(formatted)
  if type(formatted) ~= "table" or type(formatted.fields) ~= "table" then
    return nil
  end
  for _, field in ipairs(formatted.fields) do
    if type(field) == "table" then
      local label = tostring(field.label or ""):lower()
      if label == "path" or label == "file" or label == "add" or label == "update" or label == "delete" or label == "change" then
        local value = nonempty_string(field.value)
        if value ~= nil then
          return value
        end
      end
    end
  end
  return nil
end

---@param content any
---@return string?
local function path_from_content_blocks(content)
  if type(content) ~= "table" then
    return nil
  end
  for _, block in ipairs(content) do
    if type(block) == "table" and block.type == "diff" then
      local path = clean_diff_path(block.path or block.file_path or block.filePath)
      if path ~= nil then
        return path
      end
    end
  end
  return nil
end

---@param entry hyprpilot.chat.permission-row.Entry
---@return string?
local function resolve_entry_path(entry)
  local path = resolve_path(entry.raw_input)
  if path ~= nil then
    return path
  end
  path = path_from_content_blocks(entry.content)
  if path ~= nil then
    return path
  end
  path = path_from_formatted_fields(entry.formatted)
  if path ~= nil then
    return path
  end
  return path_from_unified_diff(formatted_diff(entry.formatted))
end

---@param candidate string?
---@param target string?
---@return boolean
local function path_matches(candidate, target)
  candidate = clean_diff_path(candidate)
  target = nonempty_string(target)
  if candidate == nil or target == nil then
    return false
  end
  local normalized_candidate = vim.fs.normalize(candidate)
  local normalized_target = vim.fs.normalize(target)
  if normalized_candidate == normalized_target then
    return true
  end
  local prefix_index = #normalized_target - #normalized_candidate
  return normalized_target:sub(-#normalized_candidate) == normalized_candidate
    and (#normalized_target == #normalized_candidate or normalized_target:sub(prefix_index, prefix_index) == "/")
end

---Normalise CRLF / mixed line endings on a string into a list of LF
---lines. `vim.diff` is byte-oriented; if we leave `\r` in we'll see
---phantom "every line changed" diffs.
---@param text string
---@return string[]
local function to_lines(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  return vim.split(text, "\n", { plain = true })
end

---Apply N edits sequentially to `lines` (1-indexed list), returning
---the resulting lines. Each edit is `{ old_string, new_string }`;
---OpenCode's camelCase `{ oldString, newString }` is accepted too.
---the first occurrence of `old_string` in the joined text is replaced
---with `new_string`. Used for MultiEdit so hunks reflect the
---compound result, not parallel edits against the original.
---@param lines string[]
---@param edits table[]
---@return string[], string?, "unsupported"|"out_of_sync"?   -- second return is an error reason
local function apply_edits_sequentially(lines, edits)
  local text = table.concat(lines, "\n")
  for i, edit in ipairs(edits) do
    local old = pick_string(edit, { "old_string", "oldString" })
    local new = edit.new_string
    if new == nil and type(edit.newString) == "string" then
      new = edit.newString
    end
    if type(old) ~= "string" or type(new) ~= "string" then
      return lines, string.format("edit %d has non-string old/new", i), "unsupported"
    end
    local idx = text:find(old, 1, true)
    if idx == nil then
      return lines, string.format("edit %d: old_string not found in buffer", i), "out_of_sync"
    end
    text = text:sub(1, idx - 1) .. new .. text:sub(idx + #old)
  end
  return vim.split(text, "\n", { plain = true }), nil
end

---@param raw table
---@param path string?
---@return table?
local function change_for_path(raw, path)
  if type(raw.changes) ~= "table" then
    return nil
  end
  if path ~= nil then
    for candidate, change in pairs(raw.changes) do
      if path_matches(candidate, path) then
        return change
      end
    end
  end
  for _, change in pairs(raw.changes) do
    if type(change) == "table" then
      return change
    end
  end
  return nil
end

---@param raw table
---@param path string?
---@return table[]?
local function edits_from_content_blocks(raw, path)
  if type(raw) ~= "table" then
    return nil
  end

  local edits = {}
  for _, block in ipairs(raw) do
    if type(block) == "table" and block.type == "diff" then
      local block_path = block.path or block.file_path or block.filePath
      if path == nil or block_path == nil or path_matches(block_path, path) then
        local old = block.oldText
        if old == nil then
          old = block.old_text
        end
        local new = block.newText
        if new == nil then
          new = block.new_text
        end
        if type(old) == "string" and type(new) == "string" then
          table.insert(edits, { old_string = old, new_string = new })
        end
      end
    end
  end

  if #edits == 0 then
    return nil
  end
  return edits
end

---@param raw any
---@return boolean
local function raw_has_diff_fields(raw)
  if type(raw) ~= "table" then
    return false
  end
  if type(raw.content) == "string" then
    return true
  end
  if (type(raw.old_string) == "string" or type(raw.oldString) == "string") and (type(raw.new_string) == "string" or type(raw.newString) == "string") then
    return true
  end
  if type(raw.edits) == "table" and #raw.edits > 0 then
    return true
  end
  if type(raw.changes) == "table" then
    return true
  end
  if type(raw.diff) == "string" and raw.diff ~= "" then
    return true
  end
  return false
end

---@param entry hyprpilot.chat.permission-row.Entry
---@return boolean
local function content_has_diff_blocks(entry)
  return edits_from_content_blocks(entry.content, resolve_entry_path(entry)) ~= nil
end

---Build the proposed-result line list for a given entry. Returns
---`(new_lines, reason)`; reason is set when we can't compute (e.g.
---old_string not in buffer). When reason is set, new_lines is the
---unchanged original — caller renders an "out of sync" pill.
---@param entry hyprpilot.chat.permission-row.Entry
---@param current_lines string[]   -- buffer's current content
---@return string[], string?, "unsupported"|"out_of_sync"?
local function compute_new_lines(entry, current_lines)
  local raw = entry.raw_input or {}
  local path = resolve_entry_path(entry)

  -- Plain `Write` (full-content replacement).
  if type(raw.content) == "string" then
    return to_lines(raw.content), nil
  end

  -- Single-edit `Edit`.
  local old = raw.old_string
  if old == nil then
    old = raw.oldString
  end
  local new = raw.new_string
  if new == nil then
    new = raw.newString
  end
  if type(old) == "string" and type(new) == "string" then
    return apply_edits_sequentially(current_lines, { { old_string = old, new_string = new } })
  end

  -- `MultiEdit` (list of edits applied sequentially).
  if type(raw.edits) == "table" and #raw.edits > 0 then
    return apply_edits_sequentially(current_lines, raw.edits)
  end

  -- Codex patch approvals expose a `changes` map keyed by file path.
  local change = change_for_path(raw, path)
  if type(change) == "table" then
    local add = change.Add or change.add
    if type(add) == "table" and type(add.content) == "string" then
      return to_lines(add.content), nil
    end
    local delete = change.Delete or change.delete
    if type(delete) == "table" and type(delete.content) == "string" then
      return {}, nil
    end
    local update = change.Update or change.update
    if type(update) == "table" and type(update.unified_diff) == "string" and update.unified_diff ~= "" then
      return current_lines, "raw_input.changes carries unified_diff; falling back to daemon diff", "unsupported"
    end
  end

  local content_edits = edits_from_content_blocks(entry.content, path)
  if content_edits ~= nil then
    return apply_edits_sequentially(current_lines, content_edits)
  end

  return current_lines, "no diff-able fields on raw_input (need content / old_string+new_string / edits)", "unsupported"
end

---`vim.diff` is byte-string only — feed it joined lines, take the
---unified-shape output back as `{ start_a, count_a, start_b, count_b }`
---tuples, translate to our Hunk struct.
---@param old_lines string[]
---@param new_lines string[]
---@return hyprpilot.diff_preview.Hunk[]
local function compute_hunks(old_lines, new_lines)
  local old_text = table.concat(old_lines, "\n") .. "\n"
  local new_text = table.concat(new_lines, "\n") .. "\n"

  local raw_hunks = vim.diff(old_text, new_text, {
    result_type = "indices",
    algorithm = "histogram",
    ctxlen = 0,
  })

  local out = {}
  if type(raw_hunks) ~= "table" then
    return out
  end

  for _, h in ipairs(raw_hunks) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
    -- `vim.diff` returns 0 for `start_*` when the count is 0 (pure
    -- insertion / pure deletion adjacent to a line). Translate to a
    -- valid 1-indexed anchor so downstream extmark math doesn't trip.
    if count_a == 0 then
      start_a = math.max(start_a, 1)
    end

    local new_section = {}
    if count_b > 0 then
      for i = start_b, start_b + count_b - 1 do
        table.insert(new_section, new_lines[i] or "")
      end
    end

    table.insert(out, {
      old_start = start_a,
      old_count = count_a,
      new_lines = new_section,
    })
  end
  return out
end

---@param diff string
---@param target_path string?
---@return hyprpilot.diff_preview.Hunk[]
local function parse_unified_hunks(diff, target_path)
  local hunks = {}
  local file_active = target_path == nil
  local saw_file_header = false
  local old_line = 1
  local segment = nil

  local function flush_segment()
    if segment ~= nil and (segment.old_count > 0 or #segment.new_lines > 0) then
      table.insert(hunks, segment)
    end
    segment = nil
  end

  local function start_segment()
    if segment == nil then
      segment = {
        old_start = math.max(1, old_line),
        old_count = 0,
        new_lines = {},
      }
    end
  end

  for line in (diff .. "\n"):gmatch("(.-)\n") do
    local git_path = line:match("^diff %-%-git%s+a/.-%s+b/(.+)$")
    if git_path ~= nil then
      flush_segment()
      saw_file_header = true
      file_active = target_path == nil or path_matches(git_path, target_path)
    else
      local new_path = line:match("^%+%+%+%s+(.+)$")
      if new_path ~= nil and new_path ~= "/dev/null" then
        saw_file_header = true
        if target_path ~= nil then
          file_active = path_matches(new_path, target_path)
        end
      end
    end

    local hunk_old_start = line:match("^@@ %-(%d+),?%d* %+%d+,?%d* @@")
    if hunk_old_start ~= nil then
      flush_segment()
      if not saw_file_header and target_path ~= nil then
        file_active = true
      end
      old_line = tonumber(hunk_old_start) or 1
    elseif file_active and line:sub(1, 1) == "-" and not line:match("^%-%-%-") then
      start_segment()
      segment.old_count = segment.old_count + 1
      old_line = old_line + 1
    elseif file_active and line:sub(1, 1) == "+" and not line:match("^%+%+%+") then
      start_segment()
      table.insert(segment.new_lines, line:sub(2))
    elseif file_active and line:sub(1, 1) == " " then
      flush_segment()
      old_line = old_line + 1
    elseif line:match("^@@ ") == nil and (line:match("^diff %-%-git") or line:match("^%-%-%-") or line:match("^%+%+%+")) then
      flush_segment()
    end
  end
  flush_segment()

  return hunks
end

---@param entry hyprpilot.chat.permission-row.Entry
---@param path string?
---@return hyprpilot.diff_preview.Hunk[]
local function fallback_hunks(entry, path)
  local raw = entry.raw_input
  if type(raw) == "table" then
    local change = change_for_path(raw, path)
    local update = type(change) == "table" and (change.Update or change.update) or nil
    if type(update) == "table" and type(update.unified_diff) == "string" and update.unified_diff ~= "" then
      local hunks = parse_unified_hunks(update.unified_diff, path)
      if #hunks > 0 then
        return hunks
      end
    end
    if type(raw.diff) == "string" and raw.diff ~= "" then
      local hunks = parse_unified_hunks(raw.diff, path)
      if #hunks > 0 then
        return hunks
      end
    end
  end

  local diff = formatted_diff(entry.formatted)
  if diff == nil then
    return {}
  end
  return parse_unified_hunks(diff, path)
end

---Pick a window to host the preview. Returns `(winid, owned)` where
---`owned = true` means we created the window fresh — the close path
---uses that to tear it down again instead of leaving an empty
---surface behind.
---
---Ladder:
---   1. `ui.window._prev_winid` if valid AND not a plugin-owned window
---   2. First non-plugin, non-floating window via the shared
---      `chat_buffer.find_editor_winid` helper (same routing logic
---      `mcp/editor.lua` uses for `editor_file_open` / `jump`)
---   3. Fresh `topleft new` split — flagged `owned = true` so close
---      can wipe it once the captain accepts / rejects
---@return integer winid, boolean owned
local function resolve_host_window()
  local ui_window = package.loaded["hyprpilot.ui.window"]
  local prev = ui_window and ui_window._prev_winid or nil
  if prev ~= nil and vim.api.nvim_win_is_valid(prev) and not chat_buffer.is_plugin_window(prev) then
    return prev, false
  end

  local found = chat_buffer.find_editor_winid()
  if found ~= nil then
    return found, false
  end

  vim.cmd("topleft new")
  return vim.api.nvim_get_current_win(), true
end

---Load `path` into a buffer (using the existing one if loaded;
---reading from disk otherwise). New files (Write to nonexistent
---path) get a scratch buffer named `hyprpilot://diff-preview/<path>`
---which the agent's accept later turns into a real file.
---@param path string
---@return integer bufnr, boolean is_scratch
local function load_target_buffer(path)
  if vim.fn.filereadable(path) == 1 then
    local bufnr = vim.fn.bufadd(path)
    pcall(vim.fn.bufload, bufnr)
    return bufnr, false
  end

  -- New-file path: mint a scratch buffer so we have somewhere to
  -- render the all-additions hunk.
  local name = "hyprpilot://diff-preview/" .. path
  local existing = require("hyprpilot.chat.buffer").find_by_name(name)
  if existing ~= nil then
    return existing, true
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  return bufnr, true
end

---Paint hunks into the target buffer:
---   - removed rows get a `DiffDelete` line highlight + a `-` sign
---   - added rows render as `virt_lines` below the hunk anchor with
---     `DiffAdd` highlight
---   - replace = delete + add, one extmark per kind, adjacent
---@param bufnr integer
---@param hunks hyprpilot.diff_preview.Hunk[]
local function paint_hunks(bufnr, hunks)
  local hl = (config.options.diff_preview or {}).highlights or {}
  local hl_add = hl.add or "DiffAdd"
  local hl_delete = hl.delete or "DiffDelete"

  for _, hunk in ipairs(hunks) do
    -- Anchor row is `old_start - 1` (0-indexed). For pure-insertion
    -- hunks (`old_count == 0`) the anchor is the line AFTER which
    -- the addition lands; we render virt_lines as "below" that line.
    local anchor_row = math.max(0, hunk.old_start - 1)

    -- Strikethrough / removed-line highlight for each replaced row.
    if hunk.old_count > 0 then
      local end_row = math.min(anchor_row + hunk.old_count - 1, vim.api.nvim_buf_line_count(bufnr) - 1)
      for row = anchor_row, end_row do
        pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
          end_row = row + 1,
          hl_eol = true,
          hl_group = hl_delete,
          sign_text = "-",
          sign_hl_group = hl_delete,
          priority = 200,
        })
      end
    end

    -- Added rows as virt_lines below the anchor (or at the anchor
    -- when count_a == 0 → pure insertion). We don't try treesitter
    -- highlighting in v1; single hl group per row keeps the path
    -- straightforward and survives every agent's content.
    if #hunk.new_lines > 0 then
      local virt_lines = vim.tbl_map(function(line)
        return { { line, hl_add } }
      end, hunk.new_lines)
      local anchor = anchor_row
      if hunk.old_count > 0 then
        anchor = math.min(anchor_row + hunk.old_count - 1, vim.api.nvim_buf_line_count(bufnr) - 1)
      end
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, math.max(0, anchor), 0, {
        virt_lines = virt_lines,
        virt_lines_above = false,
        priority = 200,
      })
    end
  end
end

---Drop an `out-of-sync` virt_text marker at the top of the buffer
---so the captain knows preview couldn't compute. They can still
---accept / reject from the row.
---@param bufnr integer
---@param reason string
local function paint_out_of_sync(bufnr, reason)
  local row_key = require("hyprpilot.ui.keymaps").first_display_key(((config.options.permission_row or {}).keymaps or {}).show_diff)
  local reopen = row_key ~= nil and ("; reopen " .. row_key .. " after editing") or ""
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, 0, 0, {
    virt_lines_above = true,
    virt_lines = {
      { { string.format("⚠ diff-preview: %s", reason), "WarningMsg" } },
      { { "  accept / reject from the row" .. reopen, "Comment" } },
    },
    priority = 200,
  })
end

---Install buffer-local keymaps. Each binding wraps the closure
---resolution so the cleanup path can drop them.
---@param bufnr integer
---@param state hyprpilot.diff_preview.State
---@return fun()  unwire closure
local function install_keymaps(bufnr, state)
  local keymaps = (config.options.diff_preview or {}).keymaps or {}

  local function apply(spec, handler, desc)
    if spec == false or spec == nil then
      return
    end
    if type(spec) == "string" then
      spec = { spec }
    end
    for _, key in ipairs(spec) do
      vim.keymap.set("n", key, handler, {
        buffer = bufnr,
        silent = true,
        nowait = true,
        desc = "hyprpilot: " .. desc,
      })
    end
  end

  local function option_by_id(entry, target_id)
    if type(target_id) ~= "string" or target_id == "" then
      return nil
    end
    for _, candidate in ipairs(entry.options or {}) do
      if tostring(candidate.optionId or "") == target_id then
        return candidate
      end
    end
    return nil
  end

  local function option_by_patterns(entry, patterns, fallback)
    for _, candidate in ipairs(entry.options or {}) do
      local id = tostring(candidate.optionId or ""):lower()
      local name = tostring(candidate.name or ""):lower()
      for _, pattern in ipairs(patterns) do
        if id:match(pattern) or name:match(pattern) then
          return candidate
        end
      end
    end
    return fallback
  end

  apply(keymaps.accept or "<C-g>", function()
    -- Prefer daemon-picked exact ids, then fall back to the older
    -- local shape matcher so older daemons remain usable.
    local row = require("hyprpilot.chat.permission-row")
    local entry = row._entry_by_request_id and row._entry_by_request_id(state.request_id)
    if entry == nil then
      log.debug("diff_preview.accept: entry vanished, closing")
      M.close()
      return
    end
    local opt = option_by_id(entry, entry.allow_option_id) or option_by_patterns(entry, { "^allow", "^accept", "^proceed" }, entry.options and entry.options[1])
    if opt == nil then
      log.warn("diff_preview.accept: no allow-shaped option available")
      return
    end
    permissions.respond(state.request_id, opt.optionId)
    M.close()
  end, "diff preview: allow + close")

  apply(keymaps.reject or "<C-r>", function()
    local row = require("hyprpilot.chat.permission-row")
    local entry = row._entry_by_request_id and row._entry_by_request_id(state.request_id)
    if entry == nil then
      log.debug("diff_preview.reject: entry vanished, closing")
      M.close()
      return
    end
    local opt = option_by_id(entry, entry.reject_option_id)
      or option_by_patterns(entry, { "^reject", "^deny", "^abort", "^cancel" }, entry.options and entry.options[#entry.options])
    if opt == nil then
      log.warn("diff_preview.reject: no reject-shaped option available")
      return
    end

    local function respond(feedback)
      local respond_opts = nil
      local diff_cfg = config.options.diff_preview or {}
      if diff_cfg.send_reject_feedback == true and type(feedback) == "string" and feedback ~= "" then
        respond_opts = { feedback = feedback }
      end
      permissions.respond(state.request_id, opt.optionId, respond_opts)
      M.close()
    end

    if (config.options.diff_preview or {}).reject_prompt ~= false then
      vim.ui.input({ prompt = "Reject reason (optional): " }, function(text)
        respond(text or "")
      end)
    else
      respond(nil)
    end
  end, "diff preview: reject (with optional feedback prompt)")

  apply(keymaps.close or "<Esc>", function()
    M.close()
  end, "diff preview: close without resolving")

  apply(keymaps.next_hunk or "]h", function()
    if M._state == nil then
      return
    end
    local row = vim.api.nvim_win_get_cursor(0)[1]
    for _, hunk in ipairs(M._state.hunks) do
      if hunk.old_start > row then
        pcall(vim.api.nvim_win_set_cursor, 0, { hunk.old_start, 0 })
        vim.cmd("normal! zz")
        return
      end
    end
  end, "diff preview: jump to next hunk")

  apply(keymaps.prev_hunk or "[h", function()
    if M._state == nil then
      return
    end
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local last_before = nil
    for _, hunk in ipairs(M._state.hunks) do
      if hunk.old_start < row then
        last_before = hunk
      else
        break
      end
    end
    if last_before ~= nil then
      pcall(vim.api.nvim_win_set_cursor, 0, { last_before.old_start, 0 })
      vim.cmd("normal! zz")
    end
  end, "diff preview: jump to previous hunk")

  local keys = {}
  for _, name in ipairs({ "accept", "reject", "close", "next_hunk", "prev_hunk" }) do
    local spec = keymaps[name] or ({ accept = "<C-g>", reject = "<C-r>", close = "<Esc>", next_hunk = "]h", prev_hunk = "[h" })[name]
    if spec ~= false and spec ~= nil then
      if type(spec) == "string" then
        spec = { spec }
      end
      for _, key in ipairs(spec) do
        table.insert(keys, key)
      end
    end
  end
  return function()
    for _, key in ipairs(keys) do
      pcall(vim.keymap.del, "n", key, { buffer = bufnr })
    end
  end
end

---Install lifecycle autocmds (stale-on-edit + wipe → close).
---@param bufnr integer
---@return fun()  unwire closure
local function install_autocmds(bufnr)
  local edit_id = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = AUGROUP,
    buffer = bufnr,
    callback = function()
      if M._state == nil then
        return
      end
      log.debug("diff_preview: buffer edit detected, closing as stale")
      M.close()
    end,
  })

  local wipe_id = vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = AUGROUP,
    buffer = bufnr,
    callback = function()
      if M._state == nil then
        return
      end
      log.debug("diff_preview: target buffer wiped, closing")
      M.close()
    end,
  })

  return function()
    pcall(vim.api.nvim_del_autocmd, edit_id)
    pcall(vim.api.nvim_del_autocmd, wipe_id)
  end
end

---Open a preview for `entry`. Idempotent: re-opening for the same
---request id is a no-op; re-opening for a different request closes
---the previous preview first.
---@param entry hyprpilot.chat.permission-row.Entry
function M.open(entry)
  if entry == nil or type(entry.request_id) ~= "string" then
    log.warn("diff_preview.open: missing entry / request_id")
    return
  end

  if M._state ~= nil then
    if M._state.request_id == entry.request_id then
      log.debug("diff_preview.open: same request already open, no-op")
      return
    end
    M.close()
  end

  -- `notebook_path` short-circuits to no-preview — v1 doesn't try
  -- to render notebook cell diffs.
  if is_notebook(entry.raw_input) then
    log.info("diff_preview.open: notebook edits aren't previewable in v1; accept/reject from the row")
    return
  end

  local path = resolve_entry_path(entry)
  if path == nil then
    log.info("diff_preview.open: no path field on raw_input/formatted.diff — accept/reject from the row")
    return
  end

  path = vim.fs.normalize(path)
  if path:sub(1, 1) ~= "/" and not path:match("^hyprpilot://") then
    path = vim.fs.normalize(vim.fn.getcwd() .. "/" .. path)
  end

  local target_bufnr, is_scratch = load_target_buffer(path)

  local current_lines
  if is_scratch then
    current_lines = {}
  else
    current_lines = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
  end

  local new_lines, reason, reason_kind = compute_new_lines(entry, current_lines)

  -- For new-file Writes the captain expects to see the proposed
  -- content rather than an empty buffer + virt_lines below row 0.
  -- Lay the proposed content into the scratch buffer (it's a nofile
  -- buftype; no risk of accidental save) and compute the diff as a
  -- single all-additions hunk against empty.
  if is_scratch then
    vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, new_lines)
    local ext = path:match("%.([%w]+)$")
    if ext ~= nil then
      pcall(vim.filetype.match, { filename = path })
    end
  end

  local hunks = {}
  if reason == nil then
    hunks = compute_hunks(current_lines, new_lines)
  elseif reason_kind == "unsupported" then
    local parsed = fallback_hunks(entry, path)
    if #parsed > 0 then
      hunks = parsed
      reason = nil
    end
  end

  local host_win, host_owned = resolve_host_window()
  -- pcall around the BufEnter-firing focus call: a third-party plugin
  -- that throws on its `BufEnter` (third-party markdown decorator
  -- without a markdown parser, etc.) should not abort the
  -- diff-preview flow. The window itself
  -- can also be stale if `resolve_host_window` raced with an external
  -- layout change.
  if not vim.api.nvim_win_is_valid(host_win) then
    log.warn("diff_preview.open: host window invalid; aborting preview")
    return
  end
  local ok_focus, focus_err = pcall(vim.api.nvim_set_current_win, host_win)
  if not ok_focus then
    log.warn("diff_preview.open: nvim_set_current_win failed: %s", focus_err)
    return
  end
  vim.api.nvim_win_set_buf(host_win, target_bufnr)

  if reason ~= nil then
    paint_out_of_sync(target_bufnr, reason)
  else
    paint_hunks(target_bufnr, hunks)
    if #hunks > 0 then
      -- Land the cursor on the first hunk so the captain sees the
      -- change immediately.
      pcall(vim.api.nvim_win_set_cursor, host_win, { hunks[1].old_start, 0 })
      vim.cmd("normal! zz")
    end
  end

  local state = {
    request_id = entry.request_id,
    instance_id = entry.instance_id,
    bufnr = target_bufnr,
    winid = host_win,
    host_owned = host_owned,
    path = path,
    is_scratch = is_scratch,
    hunks = hunks,
  }
  local unwire_keymaps = install_keymaps(target_bufnr, state)
  local unwire_autocmds = install_autocmds(target_bufnr)
  state.unwire = function()
    pcall(vim.api.nvim_buf_clear_namespace, target_bufnr, NS, 0, -1)
    -- Tear-down order: unwire keymaps + autocmds FIRST so the
    -- BufWipeout autocmd we install on the target buffer can't
    -- fire a re-entrant `M.close` while we delete the scratch.
    unwire_keymaps()
    unwire_autocmds()
    if is_scratch and vim.api.nvim_buf_is_valid(target_bufnr) then
      pcall(vim.api.nvim_buf_delete, target_bufnr, { force = true })
    end
    -- We created the host window fresh because no editor surface
    -- was visible at open time — close it again so the captain
    -- doesn't end up with an empty `[No Name]` split sitting where
    -- the preview was. Skip when the window was an existing
    -- editor surface (the captain's working file lives there).
    if host_owned and vim.api.nvim_win_is_valid(host_win) and #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, host_win, true)
    end
  end
  M._state = state
  log.debug("diff_preview.open: request_id=%s path=%s hunks=%d", entry.request_id, path, #hunks)
end

---Close the active preview. Idempotent.
function M.close()
  if M._state == nil then
    return
  end
  local state = M._state
  M._state = nil
  pcall(state.unwire)
  log.debug("diff_preview.close: request_id=%s", state.request_id)
end

---Close the preview iff it belongs to `instance_id`. Called from
---`chat/window.lua::M.close` so closing the instance whose diff is
---open doesn't strand `M._state` with a dead instance reference.
---The natural auto-close paths (`HyprpilotPermissionResolved`,
---`HyprpilotInstanceStateChanged`) don't fire on captain-driven
---instance close; this is the missing teardown step.
---@param instance_id string
function M.forget(instance_id)
  if M._state == nil then
    return
  end
  if M._state.instance_id == instance_id then
    M.close()
  end
end

---Toggle the preview for `entry`. Closes if currently open for the
---same request; opens otherwise.
---@param entry hyprpilot.chat.permission-row.Entry
function M.toggle(entry)
  if entry == nil then
    return
  end
  if M._state ~= nil and M._state.request_id == entry.request_id then
    M.close()
  else
    M.open(entry)
  end
end

---True when the entry is an edit-shaped request the preview can
---render. The daemon's normalized signal is `formatted.diff`; raw
---input/content shapes are kept as compatibility and better anchoring
---sources. Excludes notebook edits (no preview in v1).
---@param entry hyprpilot.chat.permission-row.Entry?
---@return boolean
function M.is_previewable(entry)
  if entry == nil then
    return false
  end
  local kind = tool_kind.classify(entry.tool_kind)
  if kind ~= "edit" and kind ~= "write" then
    return false
  end
  local raw = entry.raw_input
  if is_notebook(raw) then
    return false
  end
  if resolve_entry_path(entry) == nil then
    return false
  end
  if formatted_diff(entry.formatted) ~= nil then
    return true
  end
  if raw_has_diff_fields(raw) then
    return true
  end
  return content_has_diff_blocks(entry)
end

---Wire the cross-module autocmd subscriptions (close on permission
---resolution + instance state going terminal). Called once from
---`setup()`. Idempotent.
function M.ensure_listeners()
  if listeners_wired then
    return
  end
  listeners_wired = true

  vim.api.nvim_create_autocmd("User", {
    group = AUGROUP,
    pattern = "HyprpilotPermissionResolved",
    callback = function(args)
      local data = args.data or {}
      if M._state ~= nil and type(data.request_id) == "string" and data.request_id == M._state.request_id then
        M.close()
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = AUGROUP,
    pattern = "HyprpilotInstanceStateChanged",
    callback = function(args)
      local data = args.data or {}
      local terminal = { crashed = true, error = true, disconnected = true }
      if M._state ~= nil and type(data.instance_id) == "string" and data.instance_id == M._state.instance_id and terminal[data.state] then
        M.close()
      end
    end,
  })

  -- Close the preview when the captain switches away from the
  -- instance that owns it. Without this, A's diff stayed visible
  -- while the captain was reading B's chat — confusing, and the
  -- preview's accept/reject still routes to A's request_id which
  -- the captain may have forgotten about.
  vim.api.nvim_create_autocmd("User", {
    group = AUGROUP,
    pattern = "HyprpilotInstanceChanged",
    callback = function(args)
      local data = args.data or {}
      if M._state ~= nil and type(data.instance_id) == "string" and data.instance_id ~= M._state.instance_id then
        M.close()
      end
    end,
  })
end

---Test-only reset hook. Drops state + clears the wired flag so the
---autocmd group can be rebuilt cleanly between cases.
function M._reset()
  if M._state ~= nil then
    M.close()
  end
  pcall(vim.api.nvim_clear_autocmds, { group = AUGROUP })
  AUGROUP = vim.api.nvim_create_augroup("HyprpilotDiffPreview", { clear = true })
  listeners_wired = false
end

M._compute_hunks = compute_hunks
M._compute_new_lines = compute_new_lines
M._resolve_path = resolve_path
M._parse_unified_hunks = parse_unified_hunks
M._resolve_entry_path = resolve_entry_path

return M
