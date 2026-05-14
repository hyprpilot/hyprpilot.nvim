--- Pinned permission strip between the chat and the composer.
---
--- This is the SOLE interaction surface for permission prompts —
--- chat-buffer rendering for permissions was dropped on purpose.
--- The row renders the request title + tool details + button group;
--- the window auto-resizes to fit (clamped to 40% of `vim.o.lines`)
--- so a Bash command with a multi-line description grows the row
--- without the captain having to scroll.
---
--- Default focus is ALWAYS the Allow-shaped option (`^allow`,
--- `^accept`, `^proceed`); a bare `<CR>` answers Allow. `<Tab>` /
--- `<S-Tab>` cycle through other options when the captain wants
--- something more cautious; `g` jumps focus to Allow, `d` to deny.
--- Auto-shows on the first pending request, auto-hides when the
--- queue drains.

local buffer = require("hyprpilot.chat.buffer")
local config = require("hyprpilot.config")
local log = require("hyprpilot.log")
local window = require("hyprpilot.chat.window")

local M = {}

local BUFFER_NAME = "hyprpilot://permission_row"
local NS = vim.api.nvim_create_namespace("hyprpilot.chat.permission_row")

---@class hyprpilot.chat.permission_row.Entry
---@field instance_id string
---@field request_id string
---@field tool string
---@field tool_kind? string
---@field options table[]
---@field formatted? table
---@field focused_idx integer
---@field raw_input? table  -- agent's structured tool input (path / old_string / new_string / content / edits[] for the edit family). Diff preview reads from here.

---@type hyprpilot.chat.permission_row.Entry[]
M._queue = {}

---@type integer?
M._winid = nil

---@type integer?
M._bufnr = nil

---@type table<integer, integer>  -- line index → entry button col offsets registry (set on render; reserved)
M._button_rows = {}

---True when the row window exists + is valid.
---@return boolean
function M.is_visible()
  if M._winid == nil then
    return false
  end
  if not vim.api.nvim_win_is_valid(M._winid) then
    M._winid = nil
    return false
  end
  return true
end

---Get-or-create the shared row buffer. Adopts an existing buffer
---with the same name when `M._bufnr` was reset but Neovim still
---holds the buffer alive (post-`shutdown()` hot-reload, etc.) —
---otherwise `nvim_buf_set_name` raises `E95: Buffer with this name
---already exists`.
---@return integer
local function ensure_buffer()
  if M._bufnr ~= nil and vim.api.nvim_buf_is_valid(M._bufnr) then
    return M._bufnr
  end

  local existing = require("hyprpilot.chat.buffer").find_by_name(BUFFER_NAME)
  if existing ~= nil then
    M._bufnr = existing
    return existing
  end

  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_name(bufnr, BUFFER_NAME)
  vim.bo[bufnr].filetype = "hyprpilot_permission_row"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].modifiable = false

  M._bufnr = bufnr
  return bufnr
end

---Pick the "default" option index for a fresh permission prompt:
---first option whose id or name matches `^allow|^accept|^proceed`.
---Falls back to 1 when nothing matches (the daemon should never ship
---a permission prompt without an allow-shaped option, but defending
---against it keeps the captain from being keymap-stuck).
---
---Primary signal is `option.kind` — the daemon wire-normalises every
---vendor's option shape to `allow_*` / `reject_*` (see
---`PermissionOptionView` in the daemon's `permission.rs`). Matching
---on `kind:find("^allow")` is the same contract `is_allow_kind`
---enforces server-side, so we stay in lockstep with new vendor
---variants (`allow_session` / `allow_workspace` / …) without code
---changes. The id / name suffix match is a defensive fallback for
---adapters that don't (yet) populate `kind`.
---@param options table[]
---@return integer
local function default_focused_idx(options)
  for i, opt in ipairs(options) do
    local kind = string.lower(tostring(opt.kind or ""))
    if kind:match("^allow") then
      return i
    end
    local id = string.lower(tostring(opt.optionId or ""))
    local name = string.lower(tostring(opt.name or ""))
    if id:match("^allow") or id:match("^accept") or id:match("^proceed") or name:match("^allow") or name:match("^accept") or name:match("^proceed") then
      return i
    end
  end
  return 1
end

---Find the first option whose kind (preferred) or id / name (fallback)
---matches a `^prefix` pattern. Same `kind`-first rationale as
---`default_focused_idx`.
---@param options table[]
---@param patterns string[]
---@return table?
---@return integer?
local function smart_match(options, patterns)
  for i, opt in ipairs(options) do
    local kind = string.lower(tostring(opt.kind or ""))
    local id = string.lower(tostring(opt.optionId or ""))
    local name = string.lower(tostring(opt.name or ""))
    for _, pattern in ipairs(patterns) do
      if kind:match(pattern) ~= nil or id:match(pattern) ~= nil or name:match(pattern) ~= nil then
        return opt, i
      end
    end
  end
  return nil, nil
end

---Resolve the active entry (head of queue).
---@return hyprpilot.chat.permission_row.Entry?
local function head()
  return M._queue[1]
end

---Compose the button line for the head entry, marking the focused
---option with `[> Label <]` and others with `[ Label ]`.
---@param entry hyprpilot.chat.permission_row.Entry
---@return string
local function button_line(entry)
  local parts = {}
  for i, opt in ipairs(entry.options) do
    local label = tostring(opt.name or opt.optionId or "?")
    if i == entry.focused_idx then
      table.insert(parts, "[> " .. label .. " <]")
    else
      table.insert(parts, "[ " .. label .. " ]")
    end
  end
  return "  " .. table.concat(parts, "  ")
end

---Build the full content for the row's buffer from the head entry.
---The button line lives at the TOP so it's the first thing the
---captain sees the moment the row pops in — header + tool details
---follow below for context. Returns the lines + the row index
---(0-indexed) of the button line + the row index of the header
---line so the caller can apply the corresponding highlights.
---@return string[] lines
---@return integer? button_row
---@return integer? header_row
local function compose()
  local entry = head()
  if entry == nil then
    return { "" }, nil, nil
  end

  local lines = {}

  table.insert(lines, button_line(entry))
  local btn_row = 0

  table.insert(lines, "")

  local extra = #M._queue > 1 and string.format(" (+%d more)", #M._queue - 1) or ""
  -- `[diff]` affordance hint for edit-shaped tools so the captain
  -- knows the inline diff preview is available before pressing the
  -- keymap. Tool kind discriminator + raw_input path-presence check
  -- matches what `diff_preview.is_previewable` does.
  local diff_hint = ""
  if entry.tool_kind == "edit" and type(entry.raw_input) == "table" then
    local raw = entry.raw_input
    if raw.notebook_path == nil and (type(raw.path) == "string" or type(raw.file_path) == "string") then
      local show_diff = ((config.options.permission_row or {}).keymaps or {}).show_diff
      local key_label = type(show_diff) == "string" and show_diff or "<C-o>"
      diff_hint = string.format(" [diff %s]", key_label)
    end
  end
  table.insert(lines, string.format(" permission · %s%s%s", entry.tool or "tool", extra, diff_hint))
  local header_row = #lines - 1

  -- Body lines from the daemon's `formatted` payload (diff /
  -- description / fields) — same shape as the inline tool-call
  -- body. Prefer `diff` over `description` for Edit / Write /
  -- MultiEdit so the captain sees a clean unified patch (with
  -- diff syntax highlight) rather than the Shiki-marker source
  -- the desktop overlay consumes.
  local formatted = entry.formatted
  if type(formatted) == "table" then
    if type(formatted.fields) == "table" then
      for _, field in ipairs(formatted.fields) do
        if type(field) == "table" and field.label and field.value then
          local value = tostring(field.value):gsub("\n", " ")
          table.insert(lines, string.format("  %s: %s", field.label, value))
        end
      end
    end
    if type(formatted.diff) == "string" and formatted.diff ~= "" then
      table.insert(lines, "  ````diff")
      for _, l in ipairs(vim.split(formatted.diff, "\n", { plain = true })) do
        table.insert(lines, "  " .. l)
      end
      table.insert(lines, "  ````")
    elseif type(formatted.description) == "string" and formatted.description ~= "" then
      for _, l in ipairs(vim.split(formatted.description, "\n", { plain = true })) do
        table.insert(lines, "  " .. l)
      end
    end
  end

  return lines, btn_row, header_row
end

---Resolve the row's max height from config (40% of `vim.o.lines` by
---default), with a sane floor.
---@return integer
local function resolve_max_height()
  local raw = (config.options.permission_row or {}).max_height
  if type(raw) == "function" then
    local ok, value = pcall(raw, vim.o.lines)
    if ok and type(value) == "number" then
      return math.max(1, math.floor(value))
    end
    log.warn("permission_row: max_height function returned %s; falling back", vim.inspect(value))
  end
  if type(raw) == "number" then
    return math.max(1, math.floor(raw))
  end
  return math.max(3, math.floor(vim.o.lines * 0.4))
end

---Re-paint the row buffer + resize the window to fit content.
function M.refresh()
  -- Ensure the buffer exists so refresh-without-window (test path,
  -- early enqueue before open) can still populate the row.
  ensure_buffer()

  local lines, btn_row, header_row = compose()

  buffer.with_buffer(M._bufnr, function()
    vim.api.nvim_buf_set_lines(M._bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(M._bufnr, NS, 0, -1)

    if head() ~= nil then
      if btn_row ~= nil then
        vim.api.nvim_buf_set_extmark(M._bufnr, NS, btn_row, 0, { line_hl_group = "HyprpilotPermissionButton" })
      end
      if header_row ~= nil then
        vim.api.nvim_buf_set_extmark(M._bufnr, NS, header_row, 0, { line_hl_group = "HyprpilotPermissionHeader" })
      end
    end
  end)

  if M.is_visible() then
    local target = math.min(#lines, resolve_max_height())
    if target < 1 then
      target = 1
    end
    if vim.api.nvim_win_get_height(M._winid) ~= target then
      pcall(vim.api.nvim_win_set_height, M._winid, target)
    end
  end
end

---Submit the focused option (or one matching `patterns`) for the
---head request.
---@param patterns? string[]
local function submit(patterns)
  local entry = head()
  if entry == nil then
    return
  end

  local opt, idx
  if patterns ~= nil then
    opt, idx = smart_match(entry.options, patterns)
    if opt == nil then
      log.debug("permission_row: no option matching %s", vim.inspect(patterns))
      return
    end
    entry.focused_idx = idx
  else
    opt = entry.options[entry.focused_idx]
    if opt == nil then
      return
    end
  end

  require("hyprpilot.permissions").respond(entry.request_id, opt.optionId, function(err)
    if err ~= nil then
      log.warn("permission_row.respond: %s (%s/%s)", err.message, entry.request_id, opt.optionId)
    else
      log.debug("permission_row.respond: ok %s/%s", entry.request_id, opt.optionId)
    end
  end)
end

local function cycle_focus(delta)
  local entry = head()
  if entry == nil then
    return
  end
  local count = #entry.options
  if count == 0 then
    return
  end
  local current = entry.focused_idx or 1
  entry.focused_idx = ((current - 1 + delta) % count) + 1
  M.refresh()
end

---Bind one action's configured keys onto `bufnr`. `keys` is `false`
---(disabled), a single key string, or a list of strings. Each key
---gets a buffer-local normal-mode mapping firing `handler`.
---@param bufnr integer
---@param keys string | string[] | false | nil
---@param handler fun(): nil
---@param desc string
local function apply_action(bufnr, keys, handler, desc)
  if keys == false or keys == nil then
    return
  end
  if type(keys) == "string" then
    keys = { keys }
  end
  for _, key in ipairs(keys) do
    vim.keymap.set("n", key, handler, { buffer = bufnr, silent = true, desc = "hyprpilot: " .. desc })
  end
end

---Install the row keymaps once per buffer. Bindings are
---configurable via `config.permission_row.keymaps`; each action
---accepts a single key, list of keys, or `false` to disable.
---@param bufnr integer
local function install_keymaps(bufnr)
  local keymaps = (require("hyprpilot.config").options.permission_row or {}).keymaps or {}

  apply_action(bufnr, keymaps.submit, function()
    -- `submit` always commits the focused option (default = Allow
    -- on fresh prompts), so a captain who lands on the row and
    -- fires submit gets the safe-path answer.
    submit()
  end, "submit focused permission option")

  apply_action(bufnr, keymaps.accept, function()
    submit({ "^allow", "^accept", "^proceed" })
  end, "allow pending permission")

  apply_action(bufnr, keymaps.reject, function()
    submit({ "^reject", "^deny", "^abort", "^cancel" })
  end, "deny pending permission")

  apply_action(bufnr, keymaps.cycle_next, function()
    cycle_focus(1)
  end, "cycle permission options")

  apply_action(bufnr, keymaps.cycle_prev, function()
    cycle_focus(-1)
  end, "cycle permission options (back)")

  apply_action(bufnr, keymaps.show_diff, function()
    local entry = head()
    if entry == nil then
      return
    end
    local diff_preview = require("hyprpilot.ui.diff_preview")
    if not diff_preview.is_previewable(entry) then
      log.debug("permission_row.show_diff: head entry isn't edit-previewable (tool_kind=%s)", tostring(entry.tool_kind))
      return
    end
    diff_preview.toggle(entry)
  end, "toggle inline diff preview for the head edit request")
end

-- Test-only affordance: open_window is the public path that
-- installs keymaps, but it requires a visible chat split which the
-- unit test suite doesn't have. Expose a direct entry so the
-- keymap tests can drive the install against a mint buffer.
---@param bufnr integer
function M._install_keymaps_for_tests(bufnr)
  install_keymaps(bufnr)
end

---Look up the live row entry by request_id. Used by the diff
---preview module (which holds onto a request_id, not the entry
---table) to refresh against the row's authoritative state at
---accept / reject time.
---@param request_id string
---@return hyprpilot.chat.permission_row.Entry?
function M._entry_by_request_id(request_id)
  for _, entry in ipairs(M._queue) do
    if entry.request_id == request_id then
      return entry
    end
  end
  return nil
end

---Open the row window below the chat split, sized to fit content.
local function open_window()
  if not window.is_visible() or head() == nil then
    return
  end

  if M.is_visible() then
    M.refresh()
    return
  end

  local previous_win = vim.api.nvim_get_current_win()

  -- `window.focus()` wraps the BufEnter-firing `nvim_set_current_win`
  -- in pcall. Third-party autocmds (markview, render-markdown) that
  -- bind on BufEnter and call `vim.treesitter.start()` will throw when
  -- the captain's environment lacks the markdown parser; absorbing
  -- the throw here keeps that environment problem from killing our
  -- event dispatch loop.
  if not window.focus() then
    return
  end
  local ok_split = pcall(vim.cmd, "belowright 1split")
  if not ok_split then
    log.warn("permission_row.open_window: belowright 1split failed")
    if vim.api.nvim_win_is_valid(previous_win) then
      pcall(vim.api.nvim_set_current_win, previous_win)
    end
    return
  end

  M._winid = vim.api.nvim_get_current_win()
  local bufnr = ensure_buffer()
  vim.api.nvim_win_set_buf(M._winid, bufnr)
  install_keymaps(bufnr)

  vim.wo[M._winid].number = false
  vim.wo[M._winid].relativenumber = false
  vim.wo[M._winid].signcolumn = "no"
  vim.wo[M._winid].foldcolumn = "0"
  vim.wo[M._winid].wrap = true
  vim.wo[M._winid].linebreak = true
  vim.wo[M._winid].winfixheight = true
  vim.wo[M._winid].winfixwidth = true
  vim.wo[M._winid].cursorline = false

  -- Sized properly inside refresh() based on content + max_height.
  if vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end

  M.refresh()
end

---Close the row window (queue stays — re-opens on next request).
function M.close()
  if not M.is_visible() then
    return
  end

  pcall(vim.api.nvim_win_close, M._winid, true)
  M._winid = nil
end

---Enqueue a permission request. Auto-opens the row if not already
---visible and pre-focuses the Allow-shaped option.
---@param instance_id string
---@param record { request_id: string, tool: string, tool_kind?: string, options: table[], formatted?: table }
function M.enqueue(instance_id, record)
  for _, entry in ipairs(M._queue) do
    if entry.request_id == record.request_id then
      return
    end
  end

  local options = record.options or {}
  table.insert(M._queue, {
    instance_id = instance_id,
    request_id = record.request_id,
    tool = record.tool,
    tool_kind = record.tool_kind,
    options = options,
    formatted = record.formatted,
    focused_idx = default_focused_idx(options),
    raw_input = record.raw_input,
  })

  if M.is_visible() then
    M.refresh()
  else
    open_window()
  end
end

---Drop a resolved permission from the queue. Auto-closes the row
---when the queue drains.
---@param request_id string
---@param resolved_label? string
function M.resolve(request_id, resolved_label)
  for i, entry in ipairs(M._queue) do
    if entry.request_id == request_id then
      log.debug("permission_row.resolve: request_id=%s resolved=%s", request_id, tostring(resolved_label))
      table.remove(M._queue, i)
      break
    end
  end

  if #M._queue == 0 then
    M.close()
  elseif M.is_visible() then
    M.refresh()
  end
end

---Re-open the row when there's at least one queued entry but no
---visible window. Called by `chat.window.show()` so a captain who
---closed the chat (manually with `:q` or via `hp.hide()`) and
---re-opens it gets the still-pending permission prompts back on
---screen automatically — without it, the row stays hidden until
---the daemon emits a fresh `permission_request` event.
function M.refresh_if_queued()
  if #M._queue == 0 then
    return
  end
  if M.is_visible() then
    M.refresh()
    return
  end
  open_window()
end

---Wipe state (used on full hide / hydrate).
function M.reset()
  M._queue = {}
  M.close()
end

---Drop queue entries belonging to `instance_id`. Used by
---`chat.window.close` to keep stale permissions from an
---instance-being-shut-down out of the active row. The daemon-side
---resolution slot lives until something resolves it; the captain
---can spawn the instance again and replay via `permissions/pending`
---if they need the prompt back.
---@param instance_id string
function M.drop_for_instance(instance_id)
  local kept = {}
  for _, entry in ipairs(M._queue) do
    if entry.instance_id ~= instance_id then
      table.insert(kept, entry)
    end
  end
  M._queue = kept

  if #M._queue == 0 then
    M.close()
  elseif M.is_visible() then
    M.refresh()
  end
end

return M
