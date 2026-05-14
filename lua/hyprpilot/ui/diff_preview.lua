--- Inline diff preview for file-edit permission requests.
---
--- When the captain hits `<C-o>` on a permission row for an edit
--- tool (Edit / Write / MultiEdit / similar), we render the proposed
--- changes as virt_lines + line highlights on the actual target
--- buffer. The buffer itself is NEVER mutated — mcphub.nvim does
--- this and inherits a save/undo state machine that's hard to keep
--- correct. We stay purely visual; the daemon owns the write on
--- accept.
---
--- Captain experience:
---   - `<C-o>` on the row opens the preview in the prior window
---     (or a vsplit if none is stashed). Cursor moves there.
---   - `<C-g>` / `<C-r>` from the preview buffer resolve the
---     permission; `<Esc>` closes the preview without resolving.
---   - Editing the buffer auto-closes the preview (stale).
---   - Permission resolution from anywhere closes the preview too.

local config = require("hyprpilot.config")
local log = require("hyprpilot.log")
local permissions = require("hyprpilot.permissions")

local M = {}

local NS = vim.api.nvim_create_namespace("hyprpilot.ui.diff_preview")
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

---Extract `path / file_path` from `raw_input` regardless of which
---field the agent populated. Returns nil when neither is present
---(the caller logs + falls back to "no preview").
---@param raw any
---@return string?
local function resolve_path(raw)
  if type(raw) ~= "table" then
    return nil
  end
  if type(raw.path) == "string" and raw.path ~= "" then
    return raw.path
  end
  if type(raw.file_path) == "string" and raw.file_path ~= "" then
    return raw.file_path
  end
  if type(raw.notebook_path) == "string" and raw.notebook_path ~= "" then
    -- NotebookEdit — handled separately by the caller (no preview in v1).
    return raw.notebook_path
  end
  return nil
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
---the first occurrence of `old_string` in the joined text is replaced
---with `new_string`. Used for MultiEdit so hunks reflect the
---compound result, not parallel edits against the original.
---@param lines string[]
---@param edits table[]
---@return string[], string?   -- second return is an error reason when an edit's old_string was missing
local function apply_edits_sequentially(lines, edits)
  local text = table.concat(lines, "\n")
  for i, edit in ipairs(edits) do
    local old = edit.old_string
    local new = edit.new_string
    if type(old) ~= "string" or type(new) ~= "string" then
      return lines, string.format("edit %d has non-string old/new", i)
    end
    local idx = text:find(old, 1, true)
    if idx == nil then
      return lines, string.format("edit %d: old_string not found in buffer", i)
    end
    text = text:sub(1, idx - 1) .. new .. text:sub(idx + #old)
  end
  return vim.split(text, "\n", { plain = true }), nil
end

---Build the proposed-result line list for a given entry. Returns
---`(new_lines, reason)`; reason is set when we can't compute (e.g.
---old_string not in buffer). When reason is set, new_lines is the
---unchanged original — caller renders an "out of sync" pill.
---@param entry hyprpilot.chat.permission_row.Entry
---@param current_lines string[]   -- buffer's current content
---@return string[], string?
local function compute_new_lines(entry, current_lines)
  local raw = entry.raw_input or {}

  -- Plain `Write` (full-content replacement).
  if type(raw.content) == "string" then
    return to_lines(raw.content), nil
  end

  -- Single-edit `Edit`.
  if type(raw.old_string) == "string" and type(raw.new_string) == "string" then
    return apply_edits_sequentially(current_lines, { { old_string = raw.old_string, new_string = raw.new_string } })
  end

  -- `MultiEdit` (list of edits applied sequentially).
  if type(raw.edits) == "table" and #raw.edits > 0 then
    return apply_edits_sequentially(current_lines, raw.edits)
  end

  return current_lines, "no diff-able fields on raw_input (need content / old_string+new_string / edits)"
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

---Pick a window to host the preview. Ladder:
---   1. `ui.window._prev_winid` if valid AND not a hyprpilot chrome window
---   2. First non-chrome window in the current tabpage
---   3. Fresh vsplit
---@return integer winid
local function resolve_host_window()
  local ui_window = package.loaded["hyprpilot.ui.window"]
  local prev = ui_window and ui_window._prev_winid or nil
  if prev ~= nil and vim.api.nvim_win_is_valid(prev) then
    -- Don't drive the diff preview back into a hyprpilot chrome
    -- window (chat / composer / header / etc.) — those use
    -- `hyprpilot*` filetypes which we filter against.
    local prev_buf = vim.api.nvim_win_get_buf(prev)
    local prev_ft = vim.bo[prev_buf].filetype
    if not vim.startswith(prev_ft, "hyprpilot") then
      return prev
    end
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local ft = vim.bo[bufnr].filetype
      if not vim.startswith(ft, "hyprpilot") then
        return winid
      end
    end
  end

  vim.cmd("vsplit")
  return vim.api.nvim_get_current_win()
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
      local virt_lines = {}
      for _, line in ipairs(hunk.new_lines) do
        table.insert(virt_lines, { { line, hl_add } })
      end
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
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, 0, 0, {
    virt_lines_above = true,
    virt_lines = {
      { { string.format("⚠ diff-preview: %s", reason), "WarningMsg" } },
      { { "  accept / reject from the row; reopen <C-o> after editing", "Comment" } },
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

  local function apply(spec, handler)
    if spec == false or spec == nil then
      return
    end
    if type(spec) == "string" then
      spec = { spec }
    end
    for _, key in ipairs(spec) do
      vim.keymap.set("n", key, handler, { buffer = bufnr, silent = true, nowait = true })
    end
  end

  apply(keymaps.accept or "<C-g>", function()
    local opt = nil
    for _, candidate in ipairs(state and {} or {}) do
      local _ = candidate
    end
    -- Find the first "allow"-shaped option on the entry. The row's
    -- own accept path uses the same patterns; mirroring keeps the
    -- two surfaces in sync. We look the entry up fresh in case it
    -- mutated under us (focus change etc.).
    local row = require("hyprpilot.chat.permission_row")
    local entry = row._entry_by_request_id and row._entry_by_request_id(state.request_id)
    if entry == nil then
      log.debug("diff_preview.accept: entry vanished, closing")
      M.close()
      return
    end
    for _, candidate in ipairs(entry.options) do
      local id = tostring(candidate.optionId or ""):lower()
      local name = tostring(candidate.name or ""):lower()
      if id:match("^allow") or id:match("^accept") or id:match("^proceed") or name:match("^allow") or name:match("^accept") or name:match("^proceed") then
        opt = candidate
        break
      end
    end
    opt = opt or entry.options[1]
    if opt == nil then
      log.warn("diff_preview.accept: no allow-shaped option available")
      return
    end
    permissions.respond(state.request_id, opt.optionId)
    M.close()
  end)

  apply(keymaps.reject or "<C-r>", function()
    local row = require("hyprpilot.chat.permission_row")
    local entry = row._entry_by_request_id and row._entry_by_request_id(state.request_id)
    if entry == nil then
      log.debug("diff_preview.reject: entry vanished, closing")
      M.close()
      return
    end
    local opt = nil
    for _, candidate in ipairs(entry.options) do
      local id = tostring(candidate.optionId or ""):lower()
      local name = tostring(candidate.name or ""):lower()
      if
        id:match("^reject")
        or id:match("^deny")
        or id:match("^abort")
        or id:match("^cancel")
        or name:match("^reject")
        or name:match("^deny")
        or name:match("^abort")
        or name:match("^cancel")
      then
        opt = candidate
        break
      end
    end
    opt = opt or entry.options[#entry.options]
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
  end)

  apply(keymaps.close or "<Esc>", function()
    M.close()
  end)

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
  end)

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
  end)

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
---@param entry hyprpilot.chat.permission_row.Entry
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
  if entry.raw_input and entry.raw_input.notebook_path ~= nil then
    log.info("diff_preview.open: notebook edits aren't previewable in v1; accept/reject from the row")
    return
  end

  local path = resolve_path(entry.raw_input)
  if path == nil then
    log.info("diff_preview.open: no path field on raw_input — accept/reject from the row")
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

  local new_lines, reason = compute_new_lines(entry, current_lines)

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
  end

  local host_win = resolve_host_window()
  vim.api.nvim_set_current_win(host_win)
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
    path = path,
    is_scratch = is_scratch,
    hunks = hunks,
  }
  local unwire_keymaps = install_keymaps(target_bufnr, state)
  local unwire_autocmds = install_autocmds(target_bufnr)
  state.unwire = function()
    pcall(vim.api.nvim_buf_clear_namespace, target_bufnr, NS, 0, -1)
    if is_scratch and vim.api.nvim_buf_is_valid(target_bufnr) then
      pcall(vim.api.nvim_buf_delete, target_bufnr, { force = true })
    end
    unwire_keymaps()
    unwire_autocmds()
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

---Toggle the preview for `entry`. Closes if currently open for the
---same request; opens otherwise.
---@param entry hyprpilot.chat.permission_row.Entry
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
---render (tool_kind == "edit" AND raw_input carries a path-like
---field). Excludes notebook edits (no preview in v1).
---@param entry hyprpilot.chat.permission_row.Entry?
---@return boolean
function M.is_previewable(entry)
  if entry == nil then
    return false
  end
  if entry.tool_kind ~= "edit" then
    return false
  end
  local raw = entry.raw_input
  if type(raw) ~= "table" then
    return false
  end
  if raw.notebook_path ~= nil then
    return false
  end
  return resolve_path(raw) ~= nil
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

return M
