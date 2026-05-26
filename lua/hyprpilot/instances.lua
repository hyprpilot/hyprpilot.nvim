--- Daemon instances registered in this Neovim frontend.
---
--- The daemon owns the global instance set; this registry tracks the
--- subset this Neovim client has attached to and can control locally.

local log = require("hyprpilot.log")

local M = {}

---@type table<string, hyprpilot.InstanceState>
local items = {}

---Register a daemon instance this Neovim frontend controls locally.
---@param state hyprpilot.InstanceState
function M.register(state)
  if type(state) ~= "table" or type(state.instance_id) ~= "string" or state.instance_id == "" then
    log.debug("instances.register: ignoring invalid instance state %s", vim.inspect(state))

    return
  end

  items[state.instance_id] = state
end

---Forget a daemon instance this Neovim frontend no longer controls.
---@param instance_id string?
function M.forget(instance_id)
  if type(instance_id) ~= "string" or instance_id == "" then
    return
  end

  items[instance_id] = nil
end

---Return the managed instance state for `instance_id`, when known.
---@param instance_id string?
---@return hyprpilot.InstanceState?
function M.get(instance_id)
  if type(instance_id) ~= "string" or instance_id == "" then
    return nil
  end

  return items[instance_id]
end

---Snapshot of daemon instances registered in this Neovim frontend.
---@return table<string, hyprpilot.InstanceState>
function M.list()
  return vim.deepcopy(items)
end

---True when no daemon instances are registered locally.
---@return boolean
function M.is_empty()
  return next(items) == nil
end

---Return any registered instance id.
---@return string?
function M.first_id()
  return next(items)
end

---Test-only reset hook.
function M._reset()
  items = {}
end

return M
