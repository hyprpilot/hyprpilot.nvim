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

    local list = (type(result) == "table" and type(result.profiles) == "table") and result.profiles or {}
    callback(nil, vim.tbl_map(from_wire, list))
  end)
end

---Read the daemon-singleton "currently selected profile" id. This
---is the cross-frontend pointer (overlay + nvim both read the same
---value) — separate from per-instance `profile_id`, which is
---whatever profile that instance was spawned under.
---
---Returns `nil` when no profile is selected AND no `[profile]
---default` is configured. Wire field is `profileId` on the reply.
---@param callback fun(err: hyprpilot.client.RpcError?, profile_id: string?): nil
function M.get_selected(callback)
  client.request("profile/get", nil, nil, function(err, result)
    if err ~= nil then
      log.warn("profiles.get_selected: %s", err.message)
      callback(err, nil)
      return
    end
    local pid = type(result) == "table" and result.profileId or nil
    if pid == vim.NIL then
      pid = nil
    end
    callback(nil, pid)
  end)
end

---Set the daemon-singleton selected profile. Daemon validates the
---id against the `[[profiles]]` catalog and broadcasts
---`acp:profile-changed { profileId }` on success — every connected
---frontend's listener picks it up and updates its own pill / picker
---marker. No mid-flight teardown of any running instance; the
---selection is a separate state from per-instance lifecycles.
---
---Captain workflow: `profile.set(id)` → `sessions/list` reflects
---the new profile's history → captain picks a session →
---`sessions/load` mints an actor under the picked profile.
---@param profile_id string
---@param callback? fun(err: hyprpilot.client.RpcError?, result: any?): nil
function M.set_selected(profile_id, callback)
  if type(profile_id) ~= "string" or profile_id == "" then
    log.warn("profiles.set_selected: profile_id must be a non-empty string")
    return
  end
  client.request("profile/set", { profileId = profile_id }, nil, function(err, result)
    if err ~= nil then
      log.warn("profiles.set_selected: %s", err.message)
    end
    if callback ~= nil then
      callback(err, result)
    end
  end)
end

return M
