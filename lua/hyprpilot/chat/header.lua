--- Pinned single-line header buffer above the chat split.
---
--- Replaces the per-window `winbar` (which only painted while the
--- chat window held focus — the moment the captain dropped into the
--- composer below, the bar disappeared). The header lives in its own
--- 1-row split sized via `winfixheight` and shows the same meta the
--- winbar used to: instance state · mode · model · usage · mcps ·
--- activity.
---
--- Public surface:
---   `open()`       — open the header above the chat window
---   `close()`      — tear down the header window (buffer persists)
---   `is_visible()` — split is open + valid
---   `refresh()`    — re-render the header line for the active instance

local buffer = require("hyprpilot.chat.buffer")
local log = require("hyprpilot.log")
local winbar = require("hyprpilot.chat.winbar")
local window = require("hyprpilot.chat.window")

local M = {}

local BUFFER_NAME = "hyprpilot://header"
local NS = vim.api.nvim_create_namespace("hyprpilot.chat.header")

---@type integer?
M._winid = nil

---@type integer?
M._bufnr = nil

---Get-or-create the shared header buffer (one buffer reused across
---instance switches; content is just a single-line string).
---@return integer
local function ensure_buffer()
  if M._bufnr ~= nil and vim.api.nvim_buf_is_valid(M._bufnr) then
    return M._bufnr
  end

  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_name(bufnr, BUFFER_NAME)
  vim.bo[bufnr].filetype = "hyprpilot_header"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].modifiable = false

  M._bufnr = bufnr
  return bufnr
end

---True when the header window exists + is valid.
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

---Resolve a mode / model id against the `available_*` list. Falls
---back to the id when no entry matches.
---@param id? string
---@param available? table[]
---@return string?
local function display_name(id, available)
  if id == nil or id == "" then
    return nil
  end
  if type(available) == "table" then
    for _, entry in ipairs(available) do
      if type(entry) == "table" and entry.id == id then
        return tostring(entry.name or entry.id)
      end
    end
  end
  return id
end

--- Reuse the shared token formatter (`chat/stats.format_tokens`) so
--- usage pills here line up with the in-buffer `[Nk/Mk]` chips on the
--- pilot turn header. Returns "0" instead of nil for missing values
--- so the formatter call site stays terse.
---@param n? number
---@return string
local function compact(n)
  return require("hyprpilot.chat.stats").format_tokens(n or 0) or "0"
end

---@param activity? hyprpilot.Activity
---@return string?, string  -- text, hl_group
local function activity_pill(activity)
  if activity == nil or activity.kind == nil or activity.kind == "idle" then
    return nil, "HyprpilotHeaderActivity"
  end
  if activity.kind == "tool" then
    local text = activity.tool_name ~= nil and ("tool · " .. activity.tool_name) or "tool"
    return text, "HyprpilotHeaderActivityTool"
  elseif activity.kind == "awaiting_permission" then
    return "permission?", "HyprpilotHeaderActivityPermission"
  elseif activity.kind == "streaming" then
    return "streaming", "HyprpilotHeaderActivityStreaming"
  elseif activity.kind == "thinking" then
    return "thinking", "HyprpilotHeaderActivityThinking"
  end
  return activity.kind, "HyprpilotHeaderActivity"
end

---Track which instances we've already kicked an `instances/info`
---round-trip for. One-shot per instance so `compose()` doesn't fire
---an RPC on every refresh — the cached name lands on `_meta` and
---subsequent renders pick it up there.
local _name_fetched = {}

---Lazy-hydrate `meta.name` for `instance_id` when the daemon hasn't
---published it on any meta event yet. Fire-and-forget — the `info`
---callback updates `winbar._meta` which triggers a re-render via the
---nudge path.
---@param instance_id string
local function ensure_name(instance_id)
  if _name_fetched[instance_id] then
    return
  end
  _name_fetched[instance_id] = true
  require("hyprpilot.instances").info(instance_id, function(err, info)
    if err ~= nil or info == nil then
      log.debug("header.ensure_name: instance=%s info failed: %s", instance_id, err and err.message or "no info")
      return
    end
    if info.name ~= nil and info.name ~= "" then
      winbar.update_meta(instance_id, { name = info.name })
      M.refresh()
    end
  end)
end

---@class hyprpilot.chat.header.Segment
---@field text string                 -- segment label (without surrounding · separators)
---@field hl string                   -- highlight group applied to the segment span

---Compose the header line as a list of segments. Each segment has its
---own highlight group so the rendered line picks up per-pill colours
---from `HyprpilotHeader*` (registered in `highlights.lua`).
---Mirrors the UI's `Frame.vue` row-1 layout, minus the cwd / git /
---title (captain explicitly dropped cwd; title isn't plumbed; git
---would need a separate composable). The `hyprpilot` brand stays
---leftmost as the constant anchor.
---@return hyprpilot.chat.header.Segment[]
local function compose_segments()
  local segments = { { text = "hyprpilot", hl = "HyprpilotHeaderBrand" } }

  local instance_id = window.active_instance()
  if instance_id == nil then
    table.insert(segments, { text = "(no instance)", hl = "HyprpilotHeaderEmpty" })
    return segments
  end

  local meta = winbar._meta[instance_id]
  local activity = require("hyprpilot.status").get().activity

  if meta ~= nil and meta.instance_state ~= nil and meta.instance_state ~= "running" then
    table.insert(segments, { text = meta.instance_state, hl = "HyprpilotHeaderState" })
  end

  if meta ~= nil then
    if meta.name ~= nil and meta.name ~= "" then
      table.insert(segments, { text = meta.name, hl = "HyprpilotHeaderName" })
    else
      ensure_name(instance_id)
    end
    if meta.profile_id ~= nil and meta.profile_id ~= "" then
      table.insert(segments, { text = meta.profile_id, hl = "HyprpilotHeaderProfile" })
    end
    if meta.agent_id ~= nil and meta.agent_id ~= "" then
      table.insert(segments, { text = meta.agent_id, hl = "HyprpilotHeaderProvider" })
    end

    local model = display_name(meta.current_model_id, meta.available_models)
    if model ~= nil then
      table.insert(segments, { text = model, hl = "HyprpilotHeaderModel" })
    end

    local mode = display_name(meta.current_mode_id, meta.available_modes)
    if mode ~= nil then
      table.insert(segments, { text = mode, hl = "HyprpilotHeaderMode" })
    end

    if meta.usage ~= nil and (meta.usage.size or 0) > 0 then
      table.insert(segments, {
        text = string.format("%s/%s tok", compact(meta.usage.used), compact(meta.usage.size)),
        hl = "HyprpilotHeaderUsage",
      })
    end

    if (meta.mcps_count or 0) > 0 then
      table.insert(segments, { text = string.format("+%d mcps", meta.mcps_count), hl = "HyprpilotHeaderCount" })
    end
  end

  local activity_text, activity_hl = activity_pill(activity)
  if activity_text ~= nil then
    table.insert(segments, { text = activity_text, hl = activity_hl })
  end

  return segments
end

---Stitch `segments` into the rendered line + a parallel list of
---`{ start_col, end_col, hl }` ranges so the caller can paint each
---segment with its own highlight group. Separator `·` glyphs get
---their own range with `HyprpilotHeaderSeparator` so the captain can
---dim them or theme them apart from the segments themselves.
---@param segments hyprpilot.chat.header.Segment[]
---@return string, { start_col: integer, end_col: integer, hl: string }[]
local function render_line(segments)
  local SEP = " · "
  local pieces = { " " }
  local ranges = {}
  local col = 1 -- leading space at col 0

  for i, seg in ipairs(segments) do
    if i > 1 then
      table.insert(pieces, SEP)
      table.insert(ranges, { start_col = col + 1, end_col = col + 2, hl = "HyprpilotHeaderSeparator" })
      col = col + #SEP
    end
    table.insert(pieces, seg.text)
    table.insert(ranges, { start_col = col, end_col = col + #seg.text, hl = seg.hl })
    col = col + #seg.text
  end

  return table.concat(pieces), ranges
end

---Re-render the header line. Cheap; called whenever meta / activity /
---active instance changes. Paints per-segment highlights so each pill
---(brand / name / profile / provider / model / mode / usage / count /
---activity) gets its own colour via the `HyprpilotHeader*` groups.
---No-op when the header isn't visible.
function M.refresh()
  if M._bufnr == nil or not vim.api.nvim_buf_is_valid(M._bufnr) then
    return
  end

  local segments = compose_segments()
  local line, ranges = render_line(segments)

  buffer.with_buffer(M._bufnr, function()
    vim.api.nvim_buf_set_lines(M._bufnr, 0, -1, false, { line })
    vim.api.nvim_buf_clear_namespace(M._bufnr, NS, 0, -1)
    -- Background fill for the whole row + per-segment highlights on
    -- top. `line_hl_group` sets the trailing background so the bar
    -- reads as a cohesive band instead of segment-shaped islands.
    vim.api.nvim_buf_set_extmark(M._bufnr, NS, 0, 0, { line_hl_group = "HyprpilotHeader" })
    for _, range in ipairs(ranges) do
      vim.api.nvim_buf_set_extmark(M._bufnr, NS, 0, range.start_col, {
        end_col = range.end_col,
        hl_group = range.hl,
      })
    end
  end)
end

---Open the header window above the chat split. Idempotent: if already
---visible, just refreshes the line.
function M.open()
  if not window.is_visible() then
    log.debug("header.open: chat window not visible, skipping")
    return
  end

  local bufnr = ensure_buffer()

  if M.is_visible() then
    if vim.api.nvim_win_get_buf(M._winid) ~= bufnr then
      vim.api.nvim_win_set_buf(M._winid, bufnr)
    end
    M.refresh()
    return
  end

  local previous_win = vim.api.nvim_get_current_win()

  vim.api.nvim_set_current_win(window._winid)
  vim.cmd("aboveleft 1split")

  M._winid = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(M._winid, bufnr)
  vim.wo[M._winid].number = false
  vim.wo[M._winid].relativenumber = false
  vim.wo[M._winid].signcolumn = "no"
  vim.wo[M._winid].foldcolumn = "0"
  vim.wo[M._winid].wrap = false
  vim.wo[M._winid].winfixheight = true
  vim.wo[M._winid].cursorline = false
  vim.wo[M._winid].winhighlight = "Normal:HyprpilotHeader"

  -- Lock the height to one row; `winfixheight` keeps `<C-W>=` from
  -- redistributing space onto it.
  vim.api.nvim_win_set_height(M._winid, 1)

  -- Drop back to wherever the captain was — the header is a pinned
  -- display, never a focus target.
  if vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end

  M.refresh()
end

---Close the header window. Buffer persists for next open.
function M.close()
  if not M.is_visible() then
    return
  end

  pcall(vim.api.nvim_win_close, M._winid, true)
  M._winid = nil
end

local listeners_wired = false

---Wire the autocmds that drive `refresh()` (idempotent).
function M.ensure_listeners()
  if listeners_wired then
    return
  end
  listeners_wired = true

  local group = vim.api.nvim_create_augroup("HyprpilotHeader", { clear = true })

  for _, pattern in ipairs({
    "HyprpilotInstanceChanged",
    "HyprpilotInstanceMetaChanged",
    "HyprpilotActivityChanged",
  }) do
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = pattern,
      callback = function()
        M.refresh()
      end,
    })
  end
end

return M
