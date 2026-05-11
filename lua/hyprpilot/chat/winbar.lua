--- Per-instance winbar driver.
---
--- The chat window's `winbar` option calls `render()` on every
--- redraw; we look up which instance the window currently shows (via
--- the buffer's `hyprpilot://<id>` name) and stitch together the
--- mode / model / usage chips from a state table the events layer
--- keeps fresh.
---
--- All updates are partial: the daemon emits `InstanceMeta` after
--- every spawn-time refresh, then drips `CurrentModeUpdate` /
--- `UsageUpdate` / `SessionInfoUpdate` between turns. Each handler
--- merges into `_meta[id]` and lazily forces a winbar redraw on every
--- window currently showing the buffer (cheap; just sets `winbar`
--- to its existing value to nudge Neovim's eval).

local log = require("hyprpilot.log")

local M = {}

---@class hyprpilot.winbar.Usage
---@field used? integer
---@field size? integer
---@field cost? table

---@class hyprpilot.winbar.Meta
---@field profile_id? string
---@field session_id? string
---@field cwd? string
---@field current_mode_id? string
---@field current_model_id? string
---@field available_modes? table[]
---@field available_models? table[]
---@field mcps_count? integer
---@field usage? hyprpilot.winbar.Usage
---@field session_title? string
---@field instance_state? string  -- "starting" | "running" | "ended" | "error"

---@type table<string, hyprpilot.winbar.Meta>
M._meta = {}

local BUFFER_PREFIX = "hyprpilot://"

---Resolve the instance id rendered by the buffer in window `winid`.
---Returns nil for the placeholder buffer or any non-chat buffer.
---@param winid integer
---@return string?
local function instance_id_for_win(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return nil
  end

  local bufnr = vim.api.nvim_win_get_buf(winid)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name:sub(1, #BUFFER_PREFIX) ~= BUFFER_PREFIX then
    return nil
  end

  local id = name:sub(#BUFFER_PREFIX + 1)
  if id == "" or id == "placeholder" or id:find("/", 1, true) ~= nil then
    return nil
  end

  return id
end

---Display name for a mode/model id by looking up the matching entry
---in `available_*`. Falls back to the id itself.
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

---Compact `1234` → `1.2k`. Returns the original string when it's
---under the threshold.
---@param n? integer
---@return string?
local function compact_num(n)
  if type(n) ~= "number" or n < 1000 then
    return n ~= nil and tostring(n) or nil
  end

  if n < 1000000 then
    return string.format("%.1fk", n / 1000)
  end

  return string.format("%.1fM", n / 1000000)
end

---@param activity? hyprpilot.Activity
---@return string?
local function activity_label(activity)
  if activity == nil or activity.kind == nil or activity.kind == "idle" then
    return nil
  end

  if activity.kind == "tool" then
    return activity.tool_name ~= nil and ("tool · " .. activity.tool_name) or "tool"
  elseif activity.kind == "awaiting_permission" then
    return "permission?"
  end

  return activity.kind
end

---@param meta? hyprpilot.winbar.Meta
---@param activity? hyprpilot.Activity
---@return string
local function format_meta(meta, activity)
  if meta == nil then
    meta = {}
  end

  local parts = { "hyprpilot" }

  if meta.instance_state ~= nil and meta.instance_state ~= "running" then
    table.insert(parts, meta.instance_state)
  end

  local mode = display_name(meta.current_mode_id, meta.available_modes)
  if mode ~= nil then
    table.insert(parts, mode)
  end

  local model = display_name(meta.current_model_id, meta.available_models)
  if model ~= nil then
    table.insert(parts, model)
  end

  if meta.usage ~= nil and (meta.usage.size or 0) > 0 then
    local used = compact_num(meta.usage.used) or "0"
    local size = compact_num(meta.usage.size) or "?"
    table.insert(parts, string.format("%s/%s tok", used, size))
  end

  if (meta.mcps_count or 0) > 0 then
    table.insert(parts, string.format("+%d mcps", meta.mcps_count))
  end

  local label = activity_label(activity)
  if label ~= nil then
    table.insert(parts, label)
  end

  return " " .. table.concat(parts, " · ")
end

---Render the winbar string for the current window. Returns an empty
---string for the placeholder / unknown buffers so the bar collapses.
---@return string
function M.render()
  local id = instance_id_for_win(vim.api.nvim_get_current_win())
  if id == nil then
    return ""
  end

  -- Activity is global (singleton status surface), but we only show it
  -- when this winbar belongs to the active instance — otherwise a
  -- spawned-but-backgrounded buffer would also pulse `streaming`.
  local active_id = require("hyprpilot.chat.window").active_instance()
  local activity = nil
  if active_id == id then
    activity = require("hyprpilot.status").get().activity
  end

  return format_meta(M._meta[id], activity)
end

---Force a redraw on every window currently showing the chat buffer
---for `instance_id`. Cheap — just resets the winbar option to its
---current value, nudging Neovim to re-evaluate.
---@param instance_id string
---Force a redraw on every window matching `predicate(bufnr) → bool`.
---Cheap — sets `winbar` to its current value to nudge re-evaluation.
---@param predicate fun(bufnr: integer): boolean
local function nudge_windows(predicate)
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.api.nvim_buf_is_valid(bufnr) and predicate(bufnr) then
        pcall(function()
          vim.wo[winid].winbar = vim.wo[winid].winbar
        end)
      end
    end
  end
end

local function nudge(instance_id)
  local target_name = BUFFER_PREFIX .. instance_id
  nudge_windows(function(bufnr)
    return vim.api.nvim_buf_get_name(bufnr) == target_name
  end)
end

---Force every chat-buffer winbar to re-render. Used when the global
---activity flips so all open chat windows pick up the change.
function M.nudge_all()
  nudge_windows(function(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    return name:sub(1, #BUFFER_PREFIX) == BUFFER_PREFIX
  end)
end

local activity_listener_wired = false

---Wire the `User HyprpilotActivityChanged` autocmd to repaint every
---chat winbar. Idempotent.
function M.ensure_activity_listener()
  if activity_listener_wired then
    return
  end
  activity_listener_wired = true

  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("HyprpilotWinbarActivity", { clear = true }),
    pattern = "HyprpilotActivityChanged",
    callback = function()
      M.nudge_all()
    end,
  })
end

---Merge `fields` into the per-instance meta, emit the
---`HyprpilotInstanceMetaChanged` autocmd, then nudge the winbar.
---@param instance_id string
---@param fields hyprpilot.winbar.Meta
function M.update_meta(instance_id, fields)
  if instance_id == nil or instance_id == "" then
    log.warn("winbar.update_meta: missing instance_id")
    return
  end

  local current = M._meta[instance_id] or {}
  M._meta[instance_id] = vim.tbl_extend("force", current, fields)

  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "HyprpilotInstanceMetaChanged",
    data = { instance_id = instance_id },
  })

  nudge(instance_id)
end

---Update the current mode for an instance.
---@param instance_id string
---@param mode_id string
function M.update_mode(instance_id, mode_id)
  M.update_meta(instance_id, { current_mode_id = mode_id })
end

---Replace the usage tally for an instance.
---@param instance_id string
---@param used integer
---@param size integer
---@param cost? table
function M.update_usage(instance_id, used, size, cost)
  M.update_meta(instance_id, {
    usage = { used = used, size = size, cost = cost },
  })
end

---Update the session title (currently surfaced in autocmds; not in
---the winbar string itself).
---@param instance_id string
---@param title? string
function M.update_session(instance_id, title)
  M.update_meta(instance_id, { session_title = title })
end

---Hydrate from `instance/snapshot/meta`. Carries the full meta shape
---in one shot so the bar fills out the moment the chat window opens.
---@param instance_id string
---@param snapshot table
function M.hydrate(instance_id, snapshot)
  if type(snapshot) ~= "table" then
    log.debug("winbar.hydrate: instance=%s snapshot is not a table", tostring(instance_id))
    return
  end

  M.update_meta(instance_id, {
    profile_id = snapshot.profileId,
    session_id = snapshot.sessionId,
    cwd = snapshot.cwd,
    current_mode_id = snapshot.currentModeId,
    current_model_id = snapshot.currentModelId,
    available_modes = snapshot.availableModes,
    available_models = snapshot.availableModels,
    mcps_count = snapshot.mcpsCount,
    usage = snapshot.usage,
  })
end

---Drop all state for `instance_id`. Called when the chat buffer is
---wiped (instance closed).
---@param instance_id string
function M.forget(instance_id)
  if M._meta[instance_id] == nil then
    return
  end

  log.debug("winbar.forget: instance=%s", instance_id)
  M._meta[instance_id] = nil
end

---Test-only: drop the activity-listener wire flag so a fresh autocmd
---install can be exercised across cases.
function M._reset()
  activity_listener_wired = false
  M._meta = {}
end

return M
