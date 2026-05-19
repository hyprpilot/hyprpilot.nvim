--- Daemon-side "needs attention" notifications surface.
---
--- The daemon raises a per-instance entry when one of three things
--- happens on a NON-FOCUSED instance:
---   1. TurnEnded — agent finished a turn.
---   2. PermissionRequested — agent fired session/request_permission.
---   3. InstanceError — instance entered State::Error.
---
--- Entries dedup per-instance (multiple reasons collapse into one
--- BTreeSet on the daemon → sorted string array on the wire). They
--- auto-clear on focus / prompt-send / permission-resolved / clean
--- Ended — the plugin does NOT need explicit clears on those paths,
--- the daemon's listener handles it.
---
--- Plugin's clear paths are dismiss-only: `notifications/clear` (per
--- instance) and `notifications/clear_all` (the whole set). Captain
--- fires these from the notifications palette's "dismiss all" entry.
---
--- Live updates ride `events/subscribe` as `notifications_changed`
--- events carrying the full items list (daemon-global event — no
--- per-instance filter). Cold-connect hydration goes through
--- `notifications/list` (one round-trip, then live).

local client = require("hyprpilot.client")
local log = require("hyprpilot.log")

local M = {}

---@class hyprpilot.NotificationEntry
---@field instance_id string
---@field reasons string[]      -- subset of {"turn_ended", "permission_requested", "instance_error"} — wire-stable snake_case, sorted
---@field since integer         -- epoch ms when first raised (sticky across re-raises)

---@alias hyprpilot.NotificationsCallback fun(err: hyprpilot.client.RpcError?, items: hyprpilot.NotificationEntry[]?): nil

---@param wire any
---@return hyprpilot.NotificationEntry?
local function from_wire(wire)
  if type(wire) ~= "table" then
    return nil
  end
  return {
    instance_id = wire.instanceId,
    reasons = type(wire.reasons) == "table" and wire.reasons or {},
    since = tonumber(wire.since) or 0,
  }
end

---Coerce a daemon-shipped items array into our snake_case shape.
---Drops malformed entries silently (daemon shouldn't ship any but
---defence-in-depth keeps a bad item from poisoning the picker).
---@param wire_items any
---@return hyprpilot.NotificationEntry[]
function M.items_from_wire(wire_items)
  if type(wire_items) ~= "table" then
    return {}
  end
  local out = {}
  for _, w in ipairs(wire_items) do
    local entry = from_wire(w)
    if entry ~= nil and type(entry.instance_id) == "string" and entry.instance_id ~= "" then
      table.insert(out, entry)
    end
  end
  return out
end

---List every needs-attention entry the daemon currently tracks.
---One round-trip; subsequent updates ride `notifications_changed`.
---@param callback hyprpilot.NotificationsCallback
function M.list(callback)
  client.request("notifications/list", nil, nil, function(err, result)
    if err ~= nil then
      log.warn("notifications.list: %s", err.message)
      callback(err, nil)
      return
    end
    callback(nil, M.items_from_wire(result and result.items))
  end)
end

---Fetch the entry for `instance_id` (or nil when none pending).
---Used for one-shot per-instance checks (e.g. a picker row that
---wants to badge an instance without subscribing to the firehose).
---@param instance_id string
---@param callback fun(err: hyprpilot.client.RpcError?, entry: hyprpilot.NotificationEntry?): nil
function M.get(instance_id, callback)
  if type(instance_id) ~= "string" or instance_id == "" then
    log.warn("notifications.get: instance_id must be a non-empty string")
    return
  end
  client.request("notifications/get", { instanceId = instance_id }, nil, function(err, result)
    if err ~= nil then
      log.warn("notifications.get: %s", err.message)
      callback(err, nil)
      return
    end
    local entry = result and result.entry
    if entry == nil or entry == vim.NIL then
      callback(nil, nil)
      return
    end
    callback(nil, from_wire(entry))
  end)
end

---Dismiss the entry for `instance_id`. Captain-explicit dismissal
---(the daemon clears entries automatically on focus / prompt /
---permission-resolve — this is the picker's "remove this row"
---affordance). Returns the daemon's `cleared: bool` flag.
---@param instance_id string
---@param callback? fun(err: hyprpilot.client.RpcError?, cleared: boolean?): nil
function M.clear(instance_id, callback)
  if type(instance_id) ~= "string" or instance_id == "" then
    log.warn("notifications.clear: instance_id must be a non-empty string")
    return
  end
  client.request("notifications/clear", { instanceId = instance_id }, nil, function(err, result)
    if err ~= nil then
      log.warn("notifications.clear: %s", err.message)
    end
    if callback ~= nil then
      callback(err, type(result) == "table" and result.cleared or nil)
    end
  end)
end

---Dismiss every pending entry. Captain hits "dismiss all" in the
---palette → one round-trip, daemon broadcasts the post-clear empty
---list, mirror updates from the event.
---@param callback? fun(err: hyprpilot.client.RpcError?, cleared: boolean?): nil
function M.clear_all(callback)
  client.request("notifications/clear_all", nil, nil, function(err, result)
    if err ~= nil then
      log.warn("notifications.clear_all: %s", err.message)
    end
    if callback ~= nil then
      callback(err, type(result) == "table" and result.cleared or nil)
    end
  end)
end

return M
