--- Per-instance prompt-queue RPC namespace — thin wrapper over the
--- daemon's `queue/*` verbs + the `instance/snapshot/queue`
--- hydration endpoint. Daemon owns the queue (single mailbox, lock-
--- protected, monotonic `enqueued_seq`); the plugin is a pure
--- observer + dispatcher.
---
--- Public surface:
---   `M.list(instance_id, callback)`              — `queue/list`
---   `M.edit(instance_id, item_id, opts, cb)`    — `queue/edit`
---   `M.remove(instance_id, item_id, callback)`   — `queue/remove`
---   `M.move(instance_id, item_id, position, cb)` — `queue/move`
---   `M.clear(instance_id, callback)`             — `queue/clear`
---   `M.dispatch(instance_id, item_id?, cb)`     — `queue/dispatch`
---   `M.snapshot(instance_id, callback)`          — `instance/snapshot/queue`
---
--- Wire-shape ↔ Lua-shape translation lives here so consumers (the
--- queue strip, the composer's edit-submit path) get snake_case
--- tables back. The local `from_wire` mirrors what `winbar` /
--- `instances` do for their respective wire types.

local client = require("hyprpilot.client")
local log = require("hyprpilot.log")

local M = {}

---@class hyprpilot.QueueItem
---@field id string                  -- server-minted UUIDv4, stable across reorders
---@field text string                 -- prompt body
---@field attachments? table[]        -- composer attachments (same shape `prompts/send` accepts)
---@field enqueued_seq integer        -- per-instance monotonic counter; load-bearing for ordering
---@field enqueued_at integer         -- epoch-ms; display-only ("queued 4s ago")

---@alias hyprpilot.QueueCallback fun(err: hyprpilot.client.RpcError?, items: hyprpilot.QueueItem[]?): nil
---@alias hyprpilot.QueueItemCallback fun(err: hyprpilot.client.RpcError?, item: hyprpilot.QueueItem?): nil
---@alias hyprpilot.QueueRemoveCallback fun(err: hyprpilot.client.RpcError?, removed: boolean?): nil
---@alias hyprpilot.QueueMoveCallback fun(err: hyprpilot.client.RpcError?, moved: boolean?): nil
---@alias hyprpilot.QueueClearCallback fun(err: hyprpilot.client.RpcError?, cleared: integer?): nil
---@alias hyprpilot.QueueDispatchCallback fun(err: hyprpilot.client.RpcError?, result: hyprpilot.QueueDispatchResult?): nil

---@class hyprpilot.QueueDispatchResult
---@field item? hyprpilot.QueueItem  -- the popped item; nil when queue was empty / unknown id
---@field session_id? string         -- nil before `session/new` succeeded
---@field accepted boolean           -- actor-channel accept; UI watches `acp:turn-ended` for completion

---Translate the daemon's camelCase `QueueItem` shape to snake_case.
---Defensively coerces non-table input to an empty item so a
---malformed reply degrades cleanly through the callback chain.
---@param wire any
---@return hyprpilot.QueueItem
local function from_wire(wire)
  if type(wire) ~= "table" then
    return { id = "", text = "", enqueued_seq = 0, enqueued_at = 0 }
  end
  return {
    id = wire.id or "",
    text = wire.text or "",
    attachments = wire.attachments,
    enqueued_seq = tonumber(wire.enqueuedSeq) or 0,
    enqueued_at = tonumber(wire.enqueuedAt) or 0,
  }
end

---Translate the daemon's `QueueDispatchResult` shape.
---@param wire any
---@return hyprpilot.QueueDispatchResult
local function dispatch_from_wire(wire)
  if type(wire) ~= "table" then
    return { accepted = false }
  end
  return {
    item = wire.item ~= nil and from_wire(wire.item) or nil,
    session_id = wire.sessionId,
    accepted = wire.accepted == true,
  }
end

---Build a list-of-items result from `{ items: QueueItem[] }` shaped
---wire replies (`queue/list` + `instance/snapshot/queue`).
---@param result any
---@return hyprpilot.QueueItem[]
local function items_from_wire(result)
  local raw = (type(result) == "table" and type(result.items) == "table") and result.items or {}
  return vim.tbl_map(from_wire, raw)
end

---List the queued items for an instance. Defaults to the focused
---instance daemon-side when `instance_id` is nil.
---@param instance_id string?
---@param callback hyprpilot.QueueCallback
function M.list(instance_id, callback)
  local params = nil
  if instance_id ~= nil then
    params = { instanceId = instance_id }
  end
  client.request("queue/list", params, nil, function(err, result)
    if err ~= nil then
      callback(err, nil)
      return
    end
    callback(nil, items_from_wire(result))
  end)
end

---In-place edit a queued item. Preserves `id` / `enqueued_seq` /
---`enqueued_at`. `opts.attachments`:
---  - nil  → keep existing attachments
---  - {}   → clear attachments
---  - non-empty array → replace
---@param instance_id string?
---@param item_id string
---@param opts { text?: string, attachments?: table[] }
---@param callback hyprpilot.QueueItemCallback
function M.edit(instance_id, item_id, opts, callback)
  if type(item_id) ~= "string" or item_id == "" then
    log.warn("queue.edit: item_id must be a non-empty string")
    callback({ message = "item_id required" }, nil)
    return
  end
  opts = opts or {}
  local params = { itemId = item_id }
  if instance_id ~= nil then
    params.instanceId = instance_id
  end
  if opts.text ~= nil then
    params.text = opts.text
  end
  if opts.attachments ~= nil then
    params.attachments = opts.attachments
  end
  client.request("queue/edit", params, nil, function(err, result)
    if err ~= nil then
      callback(err, nil)
      return
    end
    local item = type(result) == "table" and result.item or nil
    callback(nil, item ~= nil and from_wire(item) or nil)
  end)
end

---Drop one queued item by id.
---@param instance_id string?
---@param item_id string
---@param callback hyprpilot.QueueRemoveCallback
function M.remove(instance_id, item_id, callback)
  if type(item_id) ~= "string" or item_id == "" then
    log.warn("queue.remove: item_id must be a non-empty string")
    callback({ message = "item_id required" }, nil)
    return
  end
  local params = { itemId = item_id }
  if instance_id ~= nil then
    params.instanceId = instance_id
  end
  client.request("queue/remove", params, nil, function(err, result)
    if err ~= nil then
      callback(err, nil)
      return
    end
    callback(nil, type(result) == "table" and result.removed == true)
  end)
end

---Reorder a queued item to `position` (0-indexed; daemon clamps).
---@param instance_id string?
---@param item_id string
---@param position integer
---@param callback hyprpilot.QueueMoveCallback
function M.move(instance_id, item_id, position, callback)
  if type(item_id) ~= "string" or item_id == "" then
    log.warn("queue.move: item_id must be a non-empty string")
    callback({ message = "item_id required" }, nil)
    return
  end
  if type(position) ~= "number" then
    log.warn("queue.move: position must be a number")
    callback({ message = "position required" }, nil)
    return
  end
  local params = { itemId = item_id, position = math.max(0, math.floor(position)) }
  if instance_id ~= nil then
    params.instanceId = instance_id
  end
  client.request("queue/move", params, nil, function(err, result)
    if err ~= nil then
      callback(err, nil)
      return
    end
    callback(nil, type(result) == "table" and result.moved == true)
  end)
end

---Drop every queued item. Returns the count of items cleared.
---@param instance_id string?
---@param callback hyprpilot.QueueClearCallback
function M.clear(instance_id, callback)
  local params = nil
  if instance_id ~= nil then
    params = { instanceId = instance_id }
  end
  client.request("queue/clear", params, nil, function(err, result)
    if err ~= nil then
      callback(err, nil)
      return
    end
    callback(nil, tonumber(type(result) == "table" and result.cleared) or 0)
  end)
end

---Dispatch a queued item NOW (bypasses auto-route's busy-check).
---`item_id == nil` dispatches the head. The daemon pops the item,
---fires its prompt, and emits a fresh `QueueChanged` snapshot.
---Captain "send-now" path.
---@param instance_id string?
---@param item_id string?
---@param callback hyprpilot.QueueDispatchCallback
function M.dispatch(instance_id, item_id, callback)
  local params = {}
  if instance_id ~= nil then
    params.instanceId = instance_id
  end
  if item_id ~= nil then
    params.itemId = item_id
  end
  client.request("queue/dispatch", params, nil, function(err, result)
    if err ~= nil then
      callback(err, nil)
      return
    end
    callback(nil, dispatch_from_wire(result))
  end)
end

---First-mount hydration. `instance_id` is REQUIRED daemon-side (no
---focused-instance fallback on the snapshot endpoint).
---@param instance_id string
---@param callback hyprpilot.QueueCallback
function M.snapshot(instance_id, callback)
  if type(instance_id) ~= "string" or instance_id == "" then
    log.warn("queue.snapshot: instance_id required")
    callback({ message = "instance_id required" }, nil)
    return
  end
  client.request("instance/snapshot/queue", { instanceId = instance_id }, nil, function(err, result)
    if err ~= nil then
      callback(err, nil)
      return
    end
    callback(nil, items_from_wire(result))
  end)
end

---Translate camelCase `items` from a wire `QueueChanged` payload
---into snake_case `hyprpilot.QueueItem[]`. Used by `chat/events.lua`
---to forward the event payload to `chat/queue-strip.lua`'s mirror
---update path. Public so consumers don't have to import a private
---helper.
---@param wire_items any
---@return hyprpilot.QueueItem[]
function M.items_from_wire(wire_items)
  if type(wire_items) ~= "table" then
    return {}
  end
  return vim.tbl_map(from_wire, wire_items)
end

return M
