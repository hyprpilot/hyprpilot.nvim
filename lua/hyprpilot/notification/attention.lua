--- Attention list — tracks per-instance "captain needs to look at
--- this" entries. Permissions stay on the list until they resolve;
--- turn_endeds stay until the captain enters the instance's chat
--- buffer (focus-clears). Subscribers (the bell, a future
--- statusline pill, the attention picker) read the live list via
--- `on_change` or pull on demand via `list()` / `is_attention_needed()`.
---
--- Wiring is autocmd-driven against `User Hyprpilot*` so attention
--- semantics layer on top of the existing event surface without
--- coupling chat / composer / permissions to this module directly.

local log = require("hyprpilot.log")
local instances = require("hyprpilot.instances")

local M = {}

---@class hyprpilot.notification.attention.Entry
---@field instance_id string
---@field kind "permission" | "turn_ended"
---@field bufnr? integer
---@field request_id? string  -- permission entries only; lets `resolved` find the right row
---@field added_at integer    -- vim.uv.hrtime(); used for stable ordering across ties

---@type hyprpilot.notification.attention.Entry[]
local entries = {}

---@type table<integer, fun(snapshot: hyprpilot.notification.attention.Entry[]): nil>
local subscribers = {}
local subscriber_counter = 0

local listeners_wired = false

---Notify every subscriber with a fresh snapshot of the entry list.
---`pcall` per handler so one bad subscriber can't break the others.
local function fire_change()
  local snapshot = M.list()
  for _, handler in pairs(subscribers) do
    pcall(handler, snapshot)
  end
end

---Snapshot of the current attention list. Deep-copied so subscribers
---can mutate freely without touching internal state.
---@return hyprpilot.notification.attention.Entry[]
function M.list()
  local out = {}
  for _, entry in ipairs(entries) do
    if instances.get(entry.instance_id) ~= nil then
      table.insert(out, vim.deepcopy(entry))
    end
  end

  return out
end

---True when at least one entry needs the captain's attention. With
---`instance_id` passed, scoped to that instance only — useful for
---status pills that highlight per-instance markers.
---@param instance_id? string
---@return boolean
function M.is_attention_needed(instance_id)
  if instance_id == nil then
    return #M.list() > 0
  end
  if instances.get(instance_id) == nil then
    return false
  end
  for _, entry in ipairs(entries) do
    if entry.instance_id == instance_id then
      return true
    end
  end
  return false
end

---Subscribe to attention-list changes. Handler receives a fresh
---snapshot on every add / remove / replace. Returns an unsubscribe
---closure.
---@param handler fun(snapshot: hyprpilot.notification.attention.Entry[]): nil
---@return fun(): nil
function M.on_change(handler)
  subscriber_counter = subscriber_counter + 1
  local key = subscriber_counter
  subscribers[key] = handler

  return function()
    subscribers[key] = nil
  end
end

---Add a permission entry. De-dups by `request_id` so a noisy
---re-emit from the daemon doesn't double-row the picker.
---@param instance_id string
---@param bufnr? integer
---@param request_id string
function M._add_permission(instance_id, bufnr, request_id)
  if instances.get(instance_id) == nil then
    return
  end

  for _, entry in ipairs(entries) do
    if entry.kind == "permission" and entry.request_id == request_id then
      return
    end
  end

  table.insert(entries, {
    instance_id = instance_id,
    kind = "permission",
    bufnr = bufnr,
    request_id = request_id,
    added_at = vim.uv.hrtime(),
  })
  fire_change()
end

---Add a turn_ended entry. One per instance — re-firing on the same
---instance refreshes the timestamp + bufnr but doesn't duplicate
---(the captain has nothing to gain from "turn ended on inst-1"
---stacking three times).
---@param instance_id string
---@param bufnr? integer
function M._add_turn_ended(instance_id, bufnr)
  if instances.get(instance_id) == nil then
    return
  end

  for _, entry in ipairs(entries) do
    if entry.kind == "turn_ended" and entry.instance_id == instance_id then
      entry.added_at = vim.uv.hrtime()
      entry.bufnr = bufnr
      fire_change()
      return
    end
  end

  table.insert(entries, {
    instance_id = instance_id,
    kind = "turn_ended",
    bufnr = bufnr,
    added_at = vim.uv.hrtime(),
  })
  fire_change()
end

---Drop a permission entry by `request_id`. No-op when not present.
---@param request_id string
function M._remove_permission(request_id)
  for i, entry in ipairs(entries) do
    if entry.kind == "permission" and entry.request_id == request_id then
      table.remove(entries, i)
      fire_change()
      return
    end
  end
end

---Drop every turn_ended entry for an instance (focus-clears semantic).
---Permissions stay — they need an explicit answer regardless of
---whether the captain looked at the chat.
---@param instance_id string
function M._clear_turn_ended(instance_id)
  local changed = false
  for i = #entries, 1, -1 do
    if entries[i].kind == "turn_ended" and entries[i].instance_id == instance_id then
      table.remove(entries, i)
      changed = true
    end
  end
  if changed then
    fire_change()
  end
end

---Drop every entry for an instance (used when the instance shuts
---down — both permissions and turn_endeds vanish).
---@param instance_id string
function M._clear_instance(instance_id)
  local changed = false
  for i = #entries, 1, -1 do
    if entries[i].instance_id == instance_id then
      table.remove(entries, i)
      changed = true
    end
  end
  if changed then
    fire_change()
  end
end

---Wire the autocmds that drive the list. Idempotent — second call
---reuses the existing autocmd group (cleared on each call) so a
---hot-reload of `setup()` doesn't accumulate duplicate listeners.
function M.ensure_listeners()
  if listeners_wired then
    return
  end
  listeners_wired = true

  local group = vim.api.nvim_create_augroup("HyprpilotAttention", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "HyprpilotPermissionRequested",
    callback = function(args)
      local data = args.data or {}
      if type(data.instance_id) == "string" and type(data.request_id) == "string" then
        M._add_permission(data.instance_id, data.bufnr, data.request_id)
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "HyprpilotPermissionResolved",
    callback = function(args)
      local data = args.data or {}
      if type(data.request_id) == "string" then
        M._remove_permission(data.request_id)
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "HyprpilotTurnEnded",
    callback = function(args)
      local data = args.data or {}
      if type(data.instance_id) == "string" then
        M._add_turn_ended(data.instance_id, data.bufnr)
      end
    end,
  })

  -- Terminal daemon-side states drop every entry for the instance.
  -- A crashed / errored / disconnected instance will never resolve
  -- its pending permissions, so leaving them on the list would
  -- dangle forever and a picker dispatch would target a dead
  -- buffer.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "HyprpilotInstanceStateChanged",
    callback = function(args)
      local data = args.data or {}
      local terminal_states = { crashed = true, error = true, disconnected = true }
      if type(data.instance_id) == "string" and terminal_states[data.state] then
        M._clear_instance(data.instance_id)
      end
    end,
  })

  -- Focus-clears: the captain entering an instance's chat buffer
  -- counts as "I saw what happened, drop the turn_ended marker".
  -- Permissions don't auto-clear here — they need an explicit
  -- accept / reject.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      local bufnr = args.buf
      if not require("hyprpilot.chat.buffer").has_filetype(bufnr, "hyprpilot") then
        return
      end

      for instance_id, state in pairs(instances.list()) do
        if state.bufnr == bufnr then
          M._clear_turn_ended(instance_id)
          return
        end
      end
    end,
  })

  log.debug("notification.attention: listeners wired")
end

---Test-only reset hook. Drops every entry, every subscriber, and
---resets the wired flag so a follow-on `ensure_listeners()` re-runs
---the autocmd setup against a fresh augroup.
function M._reset()
  entries = {}
  subscribers = {}
  subscriber_counter = 0
  listeners_wired = false
end

return M
