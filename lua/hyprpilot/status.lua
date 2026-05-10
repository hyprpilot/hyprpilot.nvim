--- Status aggregate — single source of truth for statusline components.
---
--- Pull (`get()`) returns a snapshot. Push (`User Hyprpilot*` autocmds)
--- fires on state transitions so consumers (lualine extension,
--- heirline, plain `&statusline`) refresh without polling.
---
--- Sources:
--- - Connection state via `client.on_state_change`.
--- - Active instance via `chat.window.active_instance()` (sync read).
--- - Activity (idle / streaming / tool / awaiting_permission) is a
---   stub for now — Phase 4+ rendering will plumb the live signals.

local client = require("hyprpilot.client")
local window = require("hyprpilot.chat.window")

local M = {}

---@class hyprpilot.Status
---@field connection hyprpilot.client.State
---@field active_instance? string
---@field activity hyprpilot.Activity

---@class hyprpilot.Activity
---@field kind "idle" | "thinking" | "streaming" | "tool" | "awaiting_permission"
---@field tool_name? string
---@field permission_request_id? string
---@field started_at_ms? integer

---@type hyprpilot.Activity
local activity = { kind = "idle" }

local wired = false

---@param event string
---@param data table?
local function emit(event, data)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "Hyprpilot" .. event,
    data = data,
  })
end

---Wire the client state-change listener exactly once.
local function ensure_wired()
  if wired then
    return
  end

  client.on_state_change(function(state, err)
    if state == "connected" then
      emit("Connected")
    elseif state == "disconnected" then
      emit("Disconnected", { err = err })
    end
  end)

  wired = true
end

---Snapshot of the current status. Statusline components call this on
---refresh and re-paint whatever they need from the result.
---@return hyprpilot.Status
function M.get()
  ensure_wired()

  return {
    connection = client.state(),
    active_instance = window.active_instance(),
    activity = activity,
  }
end

---Update the activity hint. Called by Phase 4+ render layers as turns
---start, tools fire, permissions request — fires the autocmd when the
---kind actually changes so statuslines don't redraw on every chunk.
---@param next hyprpilot.Activity
function M.set_activity(next)
  if next.kind == activity.kind and next.tool_name == activity.tool_name and next.permission_request_id == activity.permission_request_id then
    return
  end

  activity = next

  emit("ActivityChanged", activity)
end

---Force a reconnect. Convenience wrapper around `client.reconnect()`.
function M.reconnect()
  client.reconnect()
end

---Close the daemon connection without auto-reconnect.
function M.disconnect()
  client.disconnect()
end

---Return the daemon socket path the client is configured to use.
---@return string?
function M.socket_address()
  local cfg = require("hyprpilot.config").options.socket

  if type(cfg) == "string" and cfg ~= "" then
    return cfg
  end

  local runtime = vim.env.XDG_RUNTIME_DIR

  if runtime == nil or runtime == "" then
    return nil
  end

  return runtime .. "/hyprpilot.sock"
end

---Test-only — reset wired flag + clear local state.
function M._reset()
  wired = false
  activity = { kind = "idle" }
end

return M
