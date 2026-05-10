--- Status aggregate — single source of truth for statusline components.
---
--- Pull (`get()`) returns a snapshot. Push (`User Hyprpilot*` autocmds)
--- fires on state transitions so consumers (lualine extension,
--- heirline, plain `&statusline`) refresh without polling.
---
--- Sources:
--- - Connection state via `client.transport.on_state_change`.
--- - Active instance via `chat.window.active_instance()` (sync read).
--- - Activity (idle / streaming / tool / awaiting_permission) is a
---   stub for now — Phase 4+ rendering will plumb the live signals.

local transport = require("hyprpilot.client.transport")
local window = require("hyprpilot.chat.window")

local M = {}

---@class hyprpilot.Status
---@field connection hyprpilot.ConnectionState
---@field active_instance? string
---@field activity hyprpilot.Activity
---@field last_error? hyprpilot.Error

---@class hyprpilot.ConnectionState
---@field state hyprpilot.client.TransportState
---@field last_error? string

---@class hyprpilot.Activity
---@field kind "idle" | "thinking" | "streaming" | "tool" | "awaiting_permission"
---@field tool_name? string
---@field permission_request_id? string
---@field started_at_ms? integer

---@class hyprpilot.Error
---@field source "transport" | "rpc" | "render" | "lua_tool"
---@field message string
---@field at_ms integer

---@type hyprpilot.Activity
local activity = { kind = "idle" }

---@type hyprpilot.Error?
local last_error = nil

local wired = false

---Fire a `User Hyprpilot<event>` autocmd, best-effort.
---@param event string
---@param data table?
local function emit(event, data)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "Hyprpilot" .. event,
    data = data,
  })
end

---Wire transport listener exactly once.
local function ensure_wired()
  if wired then
    return
  end

  transport.on_state_change(function(state, err)
    if state == "connected" then
      emit("Connected")
    elseif state == "disconnected" or state == "reconnecting" then
      emit("Disconnected", { state = state, err = err })
    end

    if err ~= nil then
      last_error = {
        source = "transport",
        message = err,
        at_ms = math.floor(vim.uv.now()),
      }

      emit("Error", last_error)
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
    connection = {
      state = transport.state(),
      last_error = transport.last_error(),
    },
    active_instance = window.active_instance(),
    activity = activity,
    last_error = last_error,
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

---Note an internal error so the statusline can surface it. Used by
---render / lua-tool error paths.
---@param source "transport" | "rpc" | "render" | "lua_tool"
---@param message string
function M.note_error(source, message)
  last_error = {
    source = source,
    message = message,
    at_ms = math.floor(vim.uv.now()),
  }

  emit("Error", last_error)
end

---Force a reconnect. Helper around `transport.reconnect()`.
function M.reconnect()
  transport.reconnect()
end

---Close the daemon connection without auto-reconnect. Mostly for tests.
function M.disconnect()
  transport.disconnect()
end

---Return the daemon socket path the transport is configured to use.
---Reads `vim.v.servername` is for nvim's listen socket, not ours —
---this is the *daemon* socket the plugin connects to.
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
  last_error = nil
end

return M
