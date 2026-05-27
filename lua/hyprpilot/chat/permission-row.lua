--- Pinned permission strip between the chat and the composer.
---
--- This is the SOLE interaction surface for permission prompts —
--- chat-buffer rendering for permissions was dropped on purpose.
--- The row renders the request title + tool details + button group;
--- the window auto-resizes to fit (clamped to 50% of `vim.o.lines`)
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
local tool_kind = require("hyprpilot.tool_kind")
local window = require("hyprpilot.chat.window")

local M = {}

local BUFFER_NAME = "hyprpilot://permission_row"
local NS = vim.api.nvim_create_namespace("hyprpilot.chat.permission-row")
local MAX_BUTTON_LABEL_CHARS = 32

---@class hyprpilot.chat.permission-row.Entry
---@field instance_id string
---@field request_id string
---@field tool string
---@field tool_kind? string
---@field options table[]
---@field formatted? table
---@field focused_idx integer?    -- nil when the daemon shipped no default-option id; <Tab> / <S-Tab> seed focus on the first cycle keypress
---@field allow_option_id? string -- daemon's pick for the allow-shaped option; consumed by the accept keymap (no plugin-side pattern matching)
---@field reject_option_id? string -- daemon's pick for the reject-shaped option; consumed by the reject keymap
---@field raw_input? table  -- agent's structured tool input (path / old_string / new_string / content / edits[] for the edit family). Diff preview reads from here.

---@type hyprpilot.chat.permission-row.Entry[]
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
  vim.bo[bufnr].filetype = "hyprpilot_permission_row.markdown"
  vim.bo[bufnr].undolevels = -1 -- render-from-source; no captain edits = no undo tree
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].modifiable = false
  buffer.suppress_external_ui(bufnr)

  M._bufnr = bufnr
  return bufnr
end

---Pick the focus index for a fresh permission prompt. Honour the
---daemon's `default_option_id` verbatim — it's the source of truth
---(see `pick_allow_once_id` in
---`src-tauri/src/adapters/permission.rs`). Returns nil when the
---daemon shipped no id OR the shipped id doesn't match any offered
---option: the captain navigates with `<Tab>` / `<S-Tab>` and
---commits with `<CR>` on an explicit pick.
---
---No local fallback to `allow_always` (would be "allow forever"
---by accident) or to the first option (whatever it happens to
---be). The daemon now strictly ships `default_option_id` ONLY when
---the agent offered `allow_once` exactly; nvim mirrors that
---contract — see `pick_allow_once_id` in the daemon for the
---strict-allow-once rationale.
---@param options table[]
---@param default_option_id? string
---@return integer?
local function default_focused_idx(options, default_option_id)
  if type(default_option_id) ~= "string" or default_option_id == "" then
    return nil
  end
  for i, opt in ipairs(options) do
    if tostring(opt.optionId or "") == default_option_id then
      return i
    end
  end
  log.debug("permission_row: daemon default_option_id=%q not in option list; rendering no focused default", default_option_id)
  return nil
end

---Find the option whose `optionId` matches `target_id` (and the
---index it lives at). Returns nil, nil when not found. Used by the
---accept / reject keymap path to translate the daemon-supplied
---`allow_option_id` / `reject_option_id` into the local `options[]`
---index for the wire reply.
---@param options table[]
---@param target_id string?
---@return table?
---@return integer?
local function option_by_id(options, target_id)
  if type(target_id) ~= "string" or target_id == "" then
    return nil, nil
  end
  for i, opt in ipairs(options) do
    if tostring(opt.optionId or "") == target_id then
      return opt, i
    end
  end
  return nil, nil
end

---Resolve the head entry FOR a specific instance. The row only ever
---renders one instance's pending permissions at a time — entries
---belonging to other instances stay in `_queue` (their daemon-side
---resolution slot is still live) so a switch back surfaces them
---intact.
---@param instance_id? string
---@return hyprpilot.chat.permission-row.Entry?
local function head_for(instance_id)
  if type(instance_id) ~= "string" or instance_id == "" then
    return nil
  end
  for _, entry in ipairs(M._queue) do
    if entry.instance_id == instance_id then
      return entry
    end
  end
  return nil
end

---Resolve the head entry for the currently-active instance. Wrapper
---around `head_for(window.active_instance())` for the internal call
---sites that fire from an autocmd / keymap context where the active
---id is the implicit operating instance.
---@return hyprpilot.chat.permission-row.Entry?
local function head()
  return head_for(window.active_instance())
end

---Count pending entries belonging to other instances (i.e., not the
---one currently being rendered). Used in the "+N more" suffix so the
---captain knows other-instance permissions are silently waiting.
---@param instance_id? string
---@return integer
local function other_count(instance_id)
  if instance_id == nil then
    return #M._queue
  end
  local n = 0
  for _, entry in ipairs(M._queue) do
    if entry.instance_id ~= instance_id then
      n = n + 1
    end
  end
  return n
end

---Count entries belonging to `instance_id`.
---@param instance_id string
---@return integer
local function count_for(instance_id)
  local n = 0
  for _, entry in ipairs(M._queue) do
    if entry.instance_id == instance_id then
      n = n + 1
    end
  end
  return n
end

---True when the head entry is edit-shaped and a diff preview can
---be opened against its `raw_input.path` / `raw_input.file_path`.
---Mirrors `diff_preview.is_previewable` without the require cycle —
---compose() needs the answer before keymaps fire, and we don't
---want the heavier module loaded just to build a button label.
---@param entry hyprpilot.chat.permission-row.Entry
---@return boolean
local function diff_previewable(entry)
  if entry.tool_kind ~= "edit" or type(entry.raw_input) ~= "table" then
    return false
  end
  local raw = entry.raw_input
  if raw.notebook_path ~= nil then
    return false
  end
  return type(raw.path) == "string" or type(raw.file_path) == "string"
end

---Strip embedded newlines from a label so a multi-line agent-
---supplied string (tool name, option label, daemon error message)
---doesn't break `nvim_buf_set_lines` later with `'replacement
---string' item contains newlines`. Returns a single-line string —
---tabs / CR / LF / vertical-tabs all collapse to a single space so
---the resulting row is exactly one buffer line.
---@param s any
---@return string
local function single_line(s)
  if type(s) ~= "string" then
    return ""
  end

  return (s:gsub("[\r\n\t\v]+", " "))
end

---@param label string
---@return string
local function truncate_label(label)
  if vim.fn.strchars(label) <= MAX_BUTTON_LABEL_CHARS then
    return label
  end

  return vim.fn.strcharpart(label, 0, MAX_BUTTON_LABEL_CHARS) .. "..."
end

---Compose the button line for the head entry, marking the focused
---option with `[> Label <]` and others with `[ Label ]`. Appends a
---`[ Diff ]` button at the tail when the entry is edit-previewable
---so the captain sees the affordance instead of having to remember
---the `show_diff` keymap.
---@param entry hyprpilot.chat.permission-row.Entry
---@return string
local function button_line(entry)
  local parts = {}
  for i, opt in ipairs(entry.options) do
    local label = truncate_label(single_line(opt.name or opt.optionId or "?"))
    if i == entry.focused_idx then
      table.insert(parts, "[> " .. label .. " <]")
    else
      table.insert(parts, "[ " .. label .. " ]")
    end
  end
  if diff_previewable(entry) then
    table.insert(parts, "[ Diff ]")
  end
  return "  " .. table.concat(parts, "  ")
end

---Resolve the status icon for the row header. The row only ever
---exists for `awaiting_permission`, so we surface that single
---glyph; captains who want a different color / shape override
---`config.icons.tool_status.awaiting_permission`.
---@return string
local function status_icon()
  local map = (config.options.icons or {}).tool_status or {}
  return map.awaiting_permission or map.pending or "?"
end

---Build the full content for the row's buffer from the head entry.
---The button line lives at the TOP so it's the first thing the
---captain sees the moment the row pops in — header + tool details
---follow below for context. Header is markdown `#` so the chat
---buffer's markdown highlighter colours it without a custom
---highlight group; status icon comes first so the captain reads
---"waiting on me" before parsing the tool name. Returns the lines
---plus the row indexes the caller uses to anchor highlights.
---@return string[] lines
---@return integer? button_row
---@return integer? header_row
local function compose()
  local active_id = window.active_instance()
  local entry = head_for(active_id)
  if entry == nil then
    return { "" }, nil, nil
  end

  local lines = {}

  table.insert(lines, button_line(entry))
  local btn_row = 0

  table.insert(lines, "")

  -- Count same-instance pending (after the head) plus other-instance
  -- pending separately so the captain reads "this instance has 2
  -- more, plus 1 from another instance" — actionable context vs the
  -- old `(+N more)` that lumped everything together.
  local same_extra_count = count_for(active_id) - 1
  local others = other_count(active_id)
  local extra_parts = {}
  if same_extra_count > 0 then
    table.insert(extra_parts, string.format("+%d more", same_extra_count))
  end
  if others > 0 then
    table.insert(extra_parts, string.format("+%d on other instance%s", others, others == 1 and "" or "s"))
  end
  local extra = #extra_parts > 0 and (" (" .. table.concat(extra_parts, ", ") .. ")") or ""

  local kind_icons = (config.options.icons or {}).tool_kind or {}
  local kind_glyph = kind_icons[entry.tool_kind or ""] or kind_icons.default or ""
  local prefix_glyph = kind_glyph ~= "" and (kind_glyph .. " ") or ""
  -- Newline-strip `entry.tool`: some tool names are agent-supplied
  -- (e.g., the daemon stamps the tool call's first input line as
  -- the title), and a multi-line value here would break
  -- `nvim_buf_set_lines` later in `M.refresh`.
  table.insert(lines, string.format("# %s %s%s%s", status_icon(), prefix_glyph, single_line(entry.tool or "tool"), extra))
  local header_row = #lines - 1

  -- Stamp the daemon-side respond failure (if any) directly under
  -- the header so the captain can see why their last submit didn't
  -- take. Cleared automatically when they retry against a fresh
  -- daemon-emitted entry (different request_id). Daemon error
  -- messages can carry stack traces / multi-line context — strip
  -- to keep this as a single buffer row.
  if type(entry._respond_error) == "string" and entry._respond_error ~= "" then
    table.insert(lines, "  daemon rejected: " .. single_line(entry._respond_error))
  end

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
      vim.list_extend(
        lines,
        vim.tbl_map(function(l)
          return "  " .. l
        end, vim.split(formatted.diff, "\n", { plain = true }))
      )
      table.insert(lines, "  ````")
    elseif type(formatted.description) == "string" and formatted.description ~= "" then
      vim.list_extend(
        lines,
        vim.tbl_map(function(l)
          return "  " .. l
        end, vim.split(formatted.description, "\n", { plain = true }))
      )
    end
  end

  return lines, btn_row, header_row
end

---Resolve the row's max height from config (50% of `vim.o.lines` by
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
  return math.max(5, math.floor(vim.o.lines * 0.5))
end

---@param lines string[]
---@return integer
local function target_height(lines)
  local target = math.min(#lines, resolve_max_height())
  if target < 1 then
    return 1
  end
  return target
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
    local target = target_height(lines)
    if buffer.layout_manager_active() then
      if not buffer.layout_manager_auto_resize_enabled() then
        return
      end
      -- Cooperate with edgy: set its dynamic-sizing hook + nudge
      -- a layout pass so the change takes effect immediately.
      pcall(function()
        vim.w[M._winid].edgy_height = target
      end)
      -- Debounced — shared with composer / queue-strip so burst
      -- events collapse to one layout pass per 100ms.
      require("hyprpilot.chat.buffer").nudge_edgy_layout()
    elseif vim.api.nvim_win_get_height(M._winid) ~= target then
      pcall(vim.api.nvim_win_set_height, M._winid, target)
    end
  end
end

---Submit a permission option for the head request. `target_id`
---resolves the option via daemon-supplied id (typically
---`entry.allow_option_id` / `entry.reject_option_id`); when nil, the
---focused option is used. Returns silently when no head entry exists
---or the target id doesn't map to an offered option.
---@param target_id? string
local function submit(target_id)
  local entry = head()
  if entry == nil then
    return
  end

  local opt, idx
  if target_id ~= nil then
    opt, idx = option_by_id(entry.options, target_id)
    if opt == nil then
      log.debug("permission_row: no option with optionId=%q", tostring(target_id))
      return
    end
    entry.focused_idx = idx
  else
    opt = entry.options[entry.focused_idx]
    if opt == nil then
      return
    end
  end

  require("hyprpilot.rpc.permissions").respond(entry.request_id, opt.optionId, function(err)
    if err ~= nil then
      log.warn("permission_row.respond: %s (%s/%s)", err.message, entry.request_id, opt.optionId)
      -- Surface respond failures via vim.notify (which routes through
      -- the captain's notification backend). Without a visible signal
      -- the row stays interactive on a still-pending entry but the
      -- captain has no idea the daemon rejected the response — they'd
      -- mash submit thinking nothing happened. Stamp the entry with
      -- the err so a future render can paint a "✗ daemon rejected"
      -- pill (cheap state stash; Compose reads if present).
      entry._respond_error = err.message or "respond failed"
      pcall(vim.notify, "hyprpilot: permission respond failed — " .. tostring(err.message), vim.log.levels.WARN)
      M.refresh()
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

local apply_action = require("hyprpilot.ui.keymaps").apply_action

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
    local entry = head()
    if entry == nil then
      return
    end
    if type(entry.allow_option_id) ~= "string" or entry.allow_option_id == "" then
      log.warn("permission_row: daemon shipped no allow_option_id for %s — pick explicitly with <Tab> + <CR>", entry.request_id)
      return
    end
    submit(entry.allow_option_id)
  end, "allow pending permission")

  apply_action(bufnr, keymaps.reject, function()
    local entry = head()
    if entry == nil then
      return
    end
    if type(entry.reject_option_id) ~= "string" or entry.reject_option_id == "" then
      log.warn("permission_row: daemon shipped no reject_option_id for %s — pick explicitly with <Tab> + <CR>", entry.request_id)
      return
    end
    submit(entry.reject_option_id)
  end, "deny pending permission")

  apply_action(bufnr, keymaps.cycle_next, function()
    cycle_focus(1)
  end, "focus next permission option")

  apply_action(bufnr, keymaps.cycle_prev, function()
    cycle_focus(-1)
  end, "focus previous permission option")

  apply_action(bufnr, keymaps.show_diff, function()
    local entry = head()
    if entry == nil then
      return
    end
    local diff_preview = require("hyprpilot.ui.diff-preview")
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
---@return hyprpilot.chat.permission-row.Entry?
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

  local bufnr = ensure_buffer()
  local lines = compose()
  local initial_height = target_height(lines)
  local winid, err = buffer.open_aux_split({
    direction = string.format("belowright %dsplit", initial_height),
    bufnr = bufnr,
    after = function(w)
      install_keymaps(bufnr)
      vim.wo[w].wrap = true
      vim.wo[w].linebreak = true
      -- `winfixheight` protects against `equalalways` redistributing
      -- height when sibling splits open. Direct
      -- `nvim_win_set_height` still works through the pin.
      if not buffer.layout_manager_active() then
        vim.wo[w].winfixheight = true
        vim.wo[w].winfixwidth = true
      end
    end,
  })
  if winid == nil then
    log.warn("permission_row.open_window: %s", err)
    return
  end

  M._winid = winid
  -- Sized properly inside refresh() based on content + max_height.
  M.refresh()

  -- The split + buffer attach + extmark paint above all happen in
  -- the same event-loop tick. Without an explicit redraw the
  -- captain has to give the row a moment of focus before the
  -- buttons composite — `vim.schedule` lets Neovim's UI thread
  -- process the new layout before the next user keystroke.
  vim.schedule(function()
    if M.is_visible() then
      pcall(vim.cmd, "redraw")
    end
  end)
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
---visible and pre-focuses the daemon-supplied (or Allow-shaped)
---option.
---@param instance_id string
---@param record { request_id: string, tool: string, tool_kind?: string|table, options: table[], formatted?: table, default_option_id?: string, allow_option_id?: string, reject_option_id?: string, raw_input?: table }
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
    tool_kind = tool_kind.classify(record.tool_kind),
    options = options,
    formatted = record.formatted,
    focused_idx = default_focused_idx(options, record.default_option_id),
    allow_option_id = record.allow_option_id,
    reject_option_id = record.reject_option_id,
    raw_input = record.raw_input,
  })

  -- Auto-pop the row only when the new request belongs to the active
  -- instance — a permission landing on a background instance stays
  -- queued silently and surfaces when the captain switches there
  -- (refresh runs from window.switch). This keeps a tool call on
  -- background instance B from blocking the captain's read of A.
  local active_id = window.active_instance()
  if instance_id ~= active_id then
    -- Refresh the visible row anyway so the same-instance "+N more"
    -- count updates if the active row is currently displayed.
    if M.is_visible() then
      M.refresh()
    end
    return
  end

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

  -- Close only when the ACTIVE instance's queue drained — entries
  -- still pending on other instances stay in the queue, the row
  -- stays hidden, and a future switch surfaces them.
  if head_for(window.active_instance()) == nil then
    M.close()
  elseif M.is_visible() then
    M.refresh()
  end
end

---Re-open the row when the active instance has at least one queued
---entry but no visible window. Called by `chat.window.show()` /
---`chat.window.switch()` so a captain who closed the chat (manually
---with `:q` or via `hp.hide()`) or peeked at a different instance
---and came back gets the still-pending permission prompts back on
---screen automatically — without it, the row stays hidden until the
---daemon emits a fresh `permission_request` event.
function M.refresh_if_queued()
  if head_for(window.active_instance()) == nil then
    -- No pending for active instance — close the row even if other
    -- instances still have queued entries (we don't surface them on
    -- the captain's current screen).
    if M.is_visible() then
      M.close()
    end
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
  M._queue = vim.tbl_filter(function(entry)
    return entry.instance_id ~= instance_id
  end, M._queue)

  if #M._queue == 0 then
    M.close()
  elseif M.is_visible() then
    M.refresh()
  end
end

return M
