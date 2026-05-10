--- Callback-based JSON-RPC layer on top of `client.transport`.
---
--- Maintains the in-flight request map (id → callback) and the
--- per-method notification listener list. Wires `transport.on_message`
--- to demux replies and notifications. The captain (and our own
--- internal modules) call `M.request` / `M.notify` / `M.on_notification`.

local envelope = require("hyprpilot.client.envelope")
local log = require("hyprpilot.log")
local transport = require("hyprpilot.client.transport")

local M = {}

---@class hyprpilot.client.RpcOpts
---@field timeout_ms? integer  -- default 5000

---@class hyprpilot.client.RpcError
---@field kind "transport" | "timeout" | "rpc"
---@field code? integer
---@field message string
---@field data any?

---@alias hyprpilot.client.RpcCallback fun(err: hyprpilot.client.RpcError?, result: any?): nil
---@alias hyprpilot.client.NotificationHandler fun(params: any): nil

---@class hyprpilot.client.RpcInflight
---@field method string
---@field timer? uv.uv_timer_t
---@field callback hyprpilot.client.RpcCallback

local DEFAULT_TIMEOUT_MS = 5000

---@type table<integer, hyprpilot.client.RpcInflight>
local inflight = {}

---@type table<string, hyprpilot.client.NotificationHandler[]>
local listeners = {}

local id_gen = envelope.id_generator()

local wired = false

---Tear down an in-flight entry's resources without firing its callback.
---@param entry hyprpilot.client.RpcInflight
local function cleanup(entry)
  if entry.timer ~= nil then
    pcall(entry.timer.stop, entry.timer)
    pcall(entry.timer.close, entry.timer)

    entry.timer = nil
  end
end

---Dispatch an incoming notification to every registered listener.
---@param method string
---@param params any
local function dispatch_notification(method, params)
  local fns = listeners[method]

  if fns == nil then
    return
  end

  for _, fn in ipairs(fns) do
    local ok, err = pcall(fn, params)

    if not ok then
      log.error("rpc: notification handler for %s threw: %s", method, tostring(err))
    end
  end
end

---Resolve an in-flight request from its server reply.
---@param payload table
local function dispatch_reply(payload)
  local entry = inflight[payload.id]

  if entry == nil then
    log.warn("rpc: reply for unknown id=%s", tostring(payload.id))

    return
  end

  inflight[payload.id] = nil
  cleanup(entry)

  if payload.error ~= nil then
    entry.callback({
      kind = "rpc",
      code = payload.error.code,
      message = payload.error.message or "rpc error",
      data = payload.error.data,
    }, nil)

    return
  end

  entry.callback(nil, payload.result)
end

---Wire transport.on_message to our demuxer. Idempotent.
local function ensure_wired()
  if wired then
    return
  end

  transport.on_message(function(payload)
    if type(payload) ~= "table" then
      log.warn("rpc: ignoring non-table payload")

      return
    end

    if payload.method ~= nil then
      dispatch_notification(payload.method, payload.params)

      return
    end

    if payload.id ~= nil then
      dispatch_reply(payload)

      return
    end

    log.warn("rpc: payload has neither method nor id")
  end)

  transport.on_state_change(function(state, err)
    if state == "connected" or state == "connecting" then
      return
    end

    -- Fail every in-flight request — daemon is unreachable.
    for id, entry in pairs(inflight) do
      inflight[id] = nil
      cleanup(entry)

      entry.callback({
        kind = "transport",
        message = err or ("transport " .. state),
      }, nil)
    end
  end)

  wired = true
end

---Send a request, fire `callback(err, result)` when the daemon replies
---or the timeout elapses.
---@param method string
---@param params table?
---@param opts hyprpilot.client.RpcOpts?
---@param callback hyprpilot.client.RpcCallback
function M.request(method, params, opts, callback)
  ensure_wired()
  transport.connect()

  local id = envelope.next_id(id_gen)
  local timeout_ms = (opts ~= nil and opts.timeout_ms) or DEFAULT_TIMEOUT_MS

  ---@type hyprpilot.client.RpcInflight
  local entry = {
    method = method,
    callback = callback,
  }

  inflight[id] = entry

  entry.timer = vim.uv.new_timer()
  entry.timer:start(timeout_ms, 0, function()
    vim.schedule(function()
      local current = inflight[id]

      if current ~= entry then
        return
      end

      inflight[id] = nil
      cleanup(entry)

      entry.callback({
        kind = "timeout",
        message = string.format("rpc: %s timed out after %dms", method, timeout_ms),
      }, nil)
    end)
  end)

  if not transport.send(envelope.request(method, params, id)) then
    inflight[id] = nil
    cleanup(entry)

    entry.callback({
      kind = "transport",
      message = "transport not connected",
    }, nil)
  end
end

---Fire-and-forget notification.
---@param method string
---@param params table?
function M.notify(method, params)
  ensure_wired()
  transport.connect()

  transport.send(envelope.notification(method, params))
end

---Subscribe to incoming notifications by method. Returns an unsubscribe
---function — call it once to drop the listener.
---@param method string
---@param handler hyprpilot.client.NotificationHandler
---@return fun(): nil
function M.on_notification(method, handler)
  ensure_wired()

  if listeners[method] == nil then
    listeners[method] = {}
  end

  table.insert(listeners[method], handler)

  return function()
    local fns = listeners[method]

    if fns == nil then
      return
    end

    for i, fn in ipairs(fns) do
      if fn == handler then
        table.remove(fns, i)

        return
      end
    end
  end
end

---Test-only — drop in-flight + listeners + rewire flag.
function M._reset()
  for id, entry in pairs(inflight) do
    inflight[id] = nil
    cleanup(entry)
  end

  listeners = {}
  id_gen = envelope.id_generator()
  wired = false
end

return M
