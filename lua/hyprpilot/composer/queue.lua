--- Per-instance FIFO submit queue for the composer.
---
--- When the captain submits a prompt while the agent is non-idle
--- (`status.activity.kind ~= "idle"`), the composer routes the
--- payload through this module instead of dispatching straight to
--- the daemon. Drainage is captain-driven: a separate keybind on
--- `chat.queue_strip` fires the head entry; the queue NEVER
--- auto-dispatches on turn-end (matches the desktop overlay's
--- explicit-drain contract — keeps the captain in control of when
--- the next prompt lands).
---
--- Cancel-flush: when a turn ends with `stopReason = cancelled`,
--- every queued item for that instance gets dropped alongside the
--- cancelled head (mirror `pilot.py` semantics — captain wanted to
--- abandon the line of thought, not also send the queued follow-ups).
--- Wired from `chat/events.lua`.
---
--- Per-instance state keyed by daemon `instance_id`. The strip UI
--- (`chat/queue-strip.lua`) subscribes via `M.on_change` so it
--- repaints whenever the queue mutates without polling.

local log = require("hyprpilot.log")

local M = {}

---@class hyprpilot.composer-queue.Item
---@field id string                 -- plugin-side UUID for keymap addressing + edit roundtrip
---@field text string                -- the prompt body
---@field attachments? table[]       -- composer attachments snapshot at enqueue time
---@field enqueued_at_ms integer     -- wall-clock for the strip's "queued Ns ago" label

---@type table<string, hyprpilot.composer-queue.Item[]>
local queues = {}

---@type fun(instance_id: string)[]
local subscribers = {}

---Notify every subscriber that an instance's queue changed.
---Synchronous fan-out so the strip repaints before control returns
---to the caller (no flicker frame).
---@param instance_id string
local function notify(instance_id)
  for _, cb in ipairs(subscribers) do
    pcall(cb, instance_id)
  end
end

---Generate a plugin-side UUID for queue entries. Crypto strength
---isn't required — collision avoidance within a single nvim
---process for the duration of the queue is enough.
---@return string
local function new_id()
  return string.format(
    "%08x-%04x-%04x-%04x-%012x",
    math.random(0, 0xffffffff),
    math.random(0, 0xffff),
    math.random(0, 0xffff),
    math.random(0, 0xffff),
    math.random(0, 0xffffffffffff)
  )
end

---Append a prompt to the tail of `instance_id`'s queue. Returns
---the persisted entry (id + enqueued_at_ms populated).
---@param instance_id string
---@param item { text: string, attachments?: table[] }
---@return hyprpilot.composer-queue.Item
function M.enqueue(instance_id, item)
  queues[instance_id] = queues[instance_id] or {}
  local entry = {
    id = new_id(),
    text = item.text or "",
    attachments = item.attachments,
    enqueued_at_ms = os.time() * 1000,
  }
  table.insert(queues[instance_id], entry)
  log.debug("composer_queue.enqueue: instance=%s id=%s len=%d", instance_id, entry.id, #queues[instance_id])
  notify(instance_id)
  return entry
end

---Pop the head of `instance_id`'s queue. Returns the popped entry
---or nil when empty.
---@param instance_id string
---@return hyprpilot.composer-queue.Item?
function M.pop_head(instance_id)
  local slot = queues[instance_id]
  if slot == nil or #slot == 0 then
    return nil
  end
  local entry = table.remove(slot, 1)
  log.debug("composer_queue.pop_head: instance=%s id=%s remaining=%d", instance_id, entry.id, #slot)
  notify(instance_id)
  return entry
end

---Pop a specific entry by id; returns the popped entry + its
---original position so callers can re-insert at the same slot
---(edit round-trip).
---@param instance_id string
---@param entry_id string
---@return hyprpilot.composer-queue.Item?, integer?
function M.pop_by_id(instance_id, entry_id)
  local slot = queues[instance_id]
  if slot == nil then
    return nil, nil
  end
  for i, entry in ipairs(slot) do
    if entry.id == entry_id then
      table.remove(slot, i)
      notify(instance_id)
      return entry, i
    end
  end
  return nil, nil
end

---Insert at a specific slot, clamped to `[1, #items + 1]`. Pairs
---with `pop_by_id` for the edit-then-resubmit round trip so the
---queue order survives editing.
---@param instance_id string
---@param position integer            -- 1-indexed insertion slot
---@param item { text: string, attachments?: table[] }
---@return hyprpilot.composer-queue.Item
function M.insert_at(instance_id, position, item)
  queues[instance_id] = queues[instance_id] or {}
  local slot = queues[instance_id]
  local at = math.max(1, math.min(position, #slot + 1))
  local entry = {
    id = new_id(),
    text = item.text or "",
    attachments = item.attachments,
    enqueued_at_ms = os.time() * 1000,
  }
  table.insert(slot, at, entry)
  notify(instance_id)
  return entry
end

---Drop a specific entry by id; no-op when missing.
---@param instance_id string
---@param entry_id string
function M.remove(instance_id, entry_id)
  local slot = queues[instance_id]
  if slot == nil then
    return
  end
  for i, entry in ipairs(slot) do
    if entry.id == entry_id then
      table.remove(slot, i)
      log.debug("composer_queue.remove: instance=%s id=%s remaining=%d", instance_id, entry_id, #slot)
      notify(instance_id)
      return
    end
  end
end

---Drop every queued item for `instance_id`. Called from the
---cancel-flush path in `chat/events.lua` on `turn_ended` with
---`stopReason = cancelled` (matches the desktop overlay's
---pilot.py-derived semantics).
---@param instance_id string
function M.flush(instance_id)
  local slot = queues[instance_id]
  if slot == nil or #slot == 0 then
    return
  end
  queues[instance_id] = {}
  log.debug("composer_queue.flush: instance=%s dropped=%d", instance_id, #slot)
  notify(instance_id)
end

---Drop the queue slot entirely. Called from `chat/window.close`
---when an instance is wiped so we don't leak per-instance state.
---@param instance_id string
function M.reset(instance_id)
  if queues[instance_id] == nil then
    return
  end
  queues[instance_id] = nil
  notify(instance_id)
end

---Read-only view of the queue. Returns an empty list when the
---instance has no slot yet.
---@param instance_id string
---@return hyprpilot.composer-queue.Item[]
function M.list(instance_id)
  return queues[instance_id] or {}
end

---True when `instance_id` has at least one queued entry.
---@param instance_id string
---@return boolean
function M.has_items(instance_id)
  local slot = queues[instance_id]
  return slot ~= nil and #slot > 0
end

---Subscribe to queue-mutation notifications. The callback fires
---synchronously with the affected `instance_id` after every
---enqueue / pop / remove / flush / reset. Returns the unsubscribe
---closure.
---@param callback fun(instance_id: string): nil
---@return fun()
function M.on_change(callback)
  table.insert(subscribers, callback)
  return function()
    for i, sub in ipairs(subscribers) do
      if sub == callback then
        table.remove(subscribers, i)
        return
      end
    end
  end
end

return M
