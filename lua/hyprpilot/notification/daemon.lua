--- Daemon-side notifications mirror. Holds a wholesale-replaced
--- copy of the daemon's authoritative `notifications/list` so
--- captain-facing surfaces (palette, statusline hooks, per-instance
--- badges) can read without polling.
---
--- Updates ride `acp:notifications-changed` events (full snapshot
--- per push, daemon-global). Cold-connect hydration goes through
--- `notifications/list` — call `M.hydrate()` from the connect
--- listener.
---
--- DISTINCT from `notification/attention.lua` — that module tracks
--- LOCALLY-derived attention (permission_request fired in chat
--- events + turn_ended observed by this nvim). The daemon mirror
--- is the AUTHORITATIVE cross-frontend state: an overlay running
--- on the same daemon and an nvim attached to the same daemon both
--- receive the same raw notifications list because the daemon owns
--- it. Captain-facing reads filter that raw list to instances in
--- the local `hyprpilot.instances` registry.
---
--- Subscribers (palette, future statusline integration) read via
--- `on_change(fn)`; fires with a fresh snapshot on every apply.
--- Plugin-side never mutates the mirror — daemon broadcasts are
--- the only writer. Dismissals go through `M.dismiss(id)` /
--- `M.dismiss_all()` which round-trip via RPC; the post-clear
--- daemon broadcast updates the mirror.

local instances = require("hyprpilot.instances")
local log = require("hyprpilot.log")
local rpc = require("hyprpilot.rpc.notifications")

local M = {}

---@type hyprpilot.NotificationEntry[]
local items = {}

---@type table<integer, fun(snapshot: hyprpilot.NotificationEntry[]): nil>
local subscribers = {}
local subscriber_counter = 0

---@param snapshot hyprpilot.NotificationEntry[]
local function fire_change(snapshot)
  for _, handler in pairs(subscribers) do
    pcall(handler, snapshot)
  end
  -- Captain-facing autocmd so external consumers (lualine /
  -- statusline / etc.) can re-render off the standard event
  -- surface without coupling to this module directly.
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "HyprpilotNotificationsChanged",
    data = { count = #snapshot },
  })
end

---Deep-copy snapshot so subscribers can mutate freely without
---touching the internal table.
---@return hyprpilot.NotificationEntry[]
function M.list()
  local out = {}
  for _, item in ipairs(items) do
    if instances.get(item.instance_id) ~= nil then
      table.insert(out, vim.deepcopy(item))
    end
  end

  return out
end

---@return integer
function M.count()
  return #M.list()
end

---Lookup the entry for `instance_id` (or nil when not pending).
---Captain-facing per-instance badge helper.
---@param instance_id? string
---@return hyprpilot.NotificationEntry?
function M.get(instance_id)
  if instances.get(instance_id) == nil then
    return nil
  end
  for _, entry in ipairs(items) do
    if entry.instance_id == instance_id then
      return vim.deepcopy(entry)
    end
  end
  return nil
end

---@param instance_id? string
---@return boolean
function M.is_attention_needed(instance_id)
  if instance_id == nil then
    return M.count() > 0
  end
  return M.get(instance_id) ~= nil
end

---Subscribe to mirror updates. Handler receives a fresh snapshot
---on every daemon broadcast. Returns an unsubscribe closure.
---@param handler fun(snapshot: hyprpilot.NotificationEntry[]): nil
---@return fun(): nil
function M.on_change(handler)
  subscriber_counter = subscriber_counter + 1
  local key = subscriber_counter
  subscribers[key] = handler
  return function()
    subscribers[key] = nil
  end
end

---Wholesale-replace the mirror from a daemon broadcast. Called
---from `chat.events.dispatch` on `notifications_changed` events.
---@param new_items hyprpilot.NotificationEntry[]
function M.apply(new_items)
  items = type(new_items) == "table" and new_items or {}
  fire_change(M.list())
end

---Fetch the current daemon-side list and seed the mirror. Called
---on connect (the daemon's broadcast covers steady-state; this
---one-shot covers the cold-connect window before any broadcast
---arrives).
function M.hydrate()
  rpc.list(function(err, list)
    if err ~= nil then
      log.debug("notification.daemon.hydrate: %s", err.message)
      return
    end
    M.apply(list or {})
  end)
end

---Dismiss `instance_id`'s entry. Daemon clears + broadcasts; the
---mirror updates from the broadcast (no local optimistic write).
---@param instance_id string
function M.dismiss(instance_id)
  rpc.clear(instance_id)
end

---Dismiss every pending entry.
function M.dismiss_all()
  for _, entry in ipairs(M.list()) do
    rpc.clear(entry.instance_id)
  end
end

---Test-only reset hook. Drops every entry + subscription.
function M._reset()
  items = {}
  subscribers = {}
  subscriber_counter = 0
end

return M
