--- Profiles — read-only enumeration of the daemon's `[[profiles]]`
--- catalog. Surfaces the same shape the desktop overlay sees so
--- captains can pick a profile to spawn against from a palette.
---
--- The daemon exposes profiles only through the Tauri-proxy bridge
--- (`tauri/profiles_list`); there is no native `profiles/list`
--- namespace today. The wire method is centralised in one constant
--- below so a future daemon rename has a single swap point.

local client = require("hyprpilot.client")
local log = require("hyprpilot.log")

local M = {}

---@class hyprpilot.Profile
---@field id string             -- profile slug; what `instances/spawn` consumes as `profileId`
---@field agent_id string       -- ACP agent slug (`claude-code`, `opencode`, ...)
---@field model? string         -- default model override; omitted by daemon when unset
---@field is_default boolean

---@alias hyprpilot.ProfilesCallback fun(err: hyprpilot.client.RpcError?, profiles: hyprpilot.Profile[]?): nil

---@param wire table
---@return hyprpilot.Profile
local function from_wire(wire)
  return {
    id = wire.id,
    agent_id = wire.agent,
    model = wire.model,
    is_default = wire.isDefault == true,
  }
end

---List every profile the daemon advertises in its `[[profiles]]`
---config. One round-trip, no params; the daemon enumerates from
---in-memory config so this is cheap to call on demand.
---@param callback hyprpilot.ProfilesCallback
function M.list(callback)
  client.request("tauri/profiles_list", nil, nil, function(err, result)
    if err ~= nil then
      log.warn("profiles.list: %s", err.message)
      callback(err, nil)
      return
    end

    local items = {}
    for _, wire in ipairs(result.profiles or {}) do
      table.insert(items, from_wire(wire))
    end
    callback(nil, items)
  end)
end

return M
