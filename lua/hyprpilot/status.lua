--- Status aggregate — single source of truth for statusline components.
---
--- Pull (`get(instance_id?)`) returns a snapshot. Push (`User Hyprpilot*`
--- autocmds) fires on state transitions so any statusline backend the
--- captain runs (or a plain `&statusline`) refreshes without polling.
---
--- Activity is keyed PER-INSTANCE: every transcript / turn / tool /
--- permission event the daemon emits carries an `instance_id`, and the
--- composer / queue / header / pickers all need to see "is THIS
--- instance busy?" rather than "is ANY instance busy?". A global flag
--- meant a long-running turn on instance A would route prompts in
--- idle-instance B's composer into B's local queue (because the global
--- flag was non-idle), and the header on B would mis-render A's tool
--- name. Per-instance scoping fixes both.

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
local IDLE = { kind = "idle" }

---@type table<string, hyprpilot.Activity>
local activity_by_instance = {}

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

---Snapshot of the current status. With no `instance_id` the snapshot's
---`activity` reads from the active instance (or idle); pass an explicit
---id to read another instance's activity (e.g. the composer of B
---reading B's activity even while A is focused).
---@param instance_id? string
---@return hyprpilot.Status
function M.get(instance_id)
  ensure_wired()

  local id = instance_id or window.active_instance()

  return {
    connection = client.state(),
    active_instance = window.active_instance(),
    activity = (id ~= nil and activity_by_instance[id]) or IDLE,
  }
end

---Return the per-instance activity directly. Returns the IDLE sentinel
---when nothing is tracked — never nil — so callers can read `.kind`
---without a guard.
---@param instance_id string
---@return hyprpilot.Activity
function M.activity(instance_id)
  return activity_by_instance[instance_id] or IDLE
end

---Update the activity hint for `instance_id`. Fires
---`HyprpilotActivityChanged` (with `{ instance_id, kind, ... }`) when
---the kind / tool / request actually changes so statuslines don't
---redraw on every chunk. Drops silently when `instance_id` is missing
---— callers that genuinely have no instance bound (rare; only the
---disconnect path) should pass nothing.
---@param instance_id string?
---@param next hyprpilot.Activity
function M.set_activity(instance_id, next)
  if type(instance_id) ~= "string" or instance_id == "" then
    require("hyprpilot.log").debug("status.set_activity: ignoring call with empty/invalid instance_id (got %s)", vim.inspect(instance_id))
    return
  end
  if type(next) ~= "table" or type(next.kind) ~= "string" then
    require("hyprpilot.log").debug("status.set_activity: instance=%s got invalid activity payload %s", instance_id, vim.inspect(next))
    return
  end

  local current = activity_by_instance[instance_id] or IDLE
  if next.kind == current.kind and next.tool_name == current.tool_name and next.permission_request_id == current.permission_request_id then
    return
  end

  if next.kind == "idle" then
    activity_by_instance[instance_id] = nil
  else
    activity_by_instance[instance_id] = next
  end

  emit("ActivityChanged", {
    instance_id = instance_id,
    kind = next.kind,
    tool_name = next.tool_name,
    permission_request_id = next.permission_request_id,
    started_at_ms = next.started_at_ms,
  })
end

---Drop tracked activity for `instance_id`. Called from `window.close`
---so a shutdown / closed instance doesn't keep its last activity
---around to confuse statuslines that read from a stale `get(id)`.
---@param instance_id string
function M.forget(instance_id)
  if activity_by_instance[instance_id] ~= nil then
    activity_by_instance[instance_id] = nil
    emit("ActivityChanged", { instance_id = instance_id, kind = "idle" })
  end
end

---Fire `User HyprpilotInstanceChanged` with `{ instance_id }` data.
---Called by `chat.window` whenever the active-instance pointer
---moves (spawn / register / switch / show).
---@param instance_id? string
function M.emit_instance_changed(instance_id)
  emit("InstanceChanged", { instance_id = instance_id })
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
  activity_by_instance = {}
end

return M
