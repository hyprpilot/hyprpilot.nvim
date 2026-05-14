--- JSON-RPC 2.0 client for the hyprpilot daemon.
---
--- Wire: NDJSON over `$XDG_RUNTIME_DIR/hyprpilot.sock` (or
--- `setup({ socket = ... })`). Socket connection uses Neovim's native
--- `vim.fn.sockconnect` channel (raw `on_data` mode); we own the
--- newline split + JSON-RPC dispatch because Neovim ships no NDJSON
--- JSON-RPC client for non-LSP use cases.
---
--- Single plugin-global connection. Lazy first connect, simple
--- N-attempt retry on failure (no exponential back-off — the socket
--- is local and either there or not). Public surface: `request`,
--- `notify`, `on_notification`, `on_state_change`, `state`, `connect`,
--- `disconnect`, `reconnect`.

local config = require("hyprpilot.config")
local log = require("hyprpilot.log")

local M = {}

---@alias hyprpilot.client.State "disconnected" | "connecting" | "connected"

---@class hyprpilot.client.Inflight
---@field method string
---@field timer uv.uv_timer_t
---@field callback hyprpilot.client.Callback

---@class hyprpilot.client.RpcError
---@field kind "transport" | "timeout" | "rpc"
---@field code? integer
---@field message string
---@field data any?

---@class hyprpilot.client.RequestOpts
---@field timeout_ms? integer  -- override `config.client.timeout_ms` for this call

---@alias hyprpilot.client.Callback fun(err: hyprpilot.client.RpcError?, result: any?): nil
---@alias hyprpilot.client.NotificationHandler fun(params: any): nil
---@alias hyprpilot.client.StateHandler fun(state: hyprpilot.client.State, err: string?): nil

---@type integer?
local channel = nil
---@type hyprpilot.client.State
local state = "disconnected"
---@type string  pending NDJSON byte accumulator
local buffer = ""
---@type table<string, hyprpilot.client.Inflight>
local inflight = {}
---@type table<string, hyprpilot.client.NotificationHandler[]>
local listeners = {}
---@type hyprpilot.client.StateHandler[]
local state_listeners = {}

---Generate a UUIDv4 string. Used for JSON-RPC ids.
---@return string
local function uuid4()
  return ("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
    local v = c == "x" and math.random(0, 15) or math.random(8, 11)

    return string.format("%x", v)
  end)
end

---Set the connection state and notify every listener (best-effort).
---@param next hyprpilot.client.State
---@param err string?
local function set_state(next, err)
  if state == next then
    return
  end

  log.debug("client: %s → %s%s", state, next, err ~= nil and " (" .. err .. ")" or "")

  state = next

  for _, fn in ipairs(state_listeners) do
    pcall(fn, next, err)
  end
end

---Close the active channel and fail every in-flight request. Idempotent.
---@param err_message string?
local function teardown(err_message)
  if channel ~= nil then
    pcall(vim.fn.chanclose, channel)

    channel = nil
  end

  buffer = ""

  for id, entry in pairs(inflight) do
    inflight[id] = nil

    pcall(entry.timer.stop, entry.timer)
    pcall(entry.timer.close, entry.timer)

    pcall(entry.callback, {
      kind = "transport",
      message = err_message or "client disconnected",
    }, nil)
  end
end

---Resolve the daemon socket path from config or `$XDG_RUNTIME_DIR`.
---Resolve the daemon socket path. Returns nil when neither
---`config.socket` nor `$XDG_RUNTIME_DIR` is set so callers can
---fail the connect attempt cleanly instead of throwing past
---`try_connect`'s `pcall` (the previous `error()` here was raised
---when computing the second arg to `vim.fn.sockconnect`, which
---is BEFORE the pcall protects the call — so the throw escaped
---and crashed the captain's notify path).
---@return string?
local function socket_path()
  local from_config = config.options.socket

  if type(from_config) == "string" and from_config ~= "" then
    return from_config
  end

  local runtime = vim.env.XDG_RUNTIME_DIR

  if runtime == nil or runtime == "" then
    log.error("client: XDG_RUNTIME_DIR is unset; pass setup({ socket = ... })")
    return nil
  end

  return runtime .. "/hyprpilot.sock"
end

---Dispatch a parsed JSON-RPC payload to the right handler.
---@param payload table
local function dispatch_payload(payload)
  if type(payload) ~= "table" then
    return
  end

  if payload.method ~= nil then
    log.debug("client.dispatch: notification method=%s", payload.method)

    local fns = listeners[payload.method]

    if fns == nil then
      log.debug("client.dispatch: no listeners for %s (dropping)", payload.method)
      return
    end

    for _, fn in ipairs(fns) do
      local ok, err = pcall(fn, payload.params)

      if not ok then
        log.error("client: handler for %s threw: %s", payload.method, tostring(err))
      end
    end

    return
  end

  if payload.id ~= nil then
    local entry = inflight[payload.id]

    if entry == nil then
      log.warn("client.dispatch: reply for unknown id=%s (in-flight ids=%s)", tostring(payload.id), vim.inspect(vim.tbl_keys(inflight)))

      return
    end

    log.debug("client.dispatch: reply for %s id=%s", entry.method, tostring(payload.id))

    inflight[payload.id] = nil

    pcall(entry.timer.stop, entry.timer)
    pcall(entry.timer.close, entry.timer)

    if payload.error ~= nil then
      pcall(entry.callback, {
        kind = "rpc",
        code = payload.error.code,
        message = payload.error.message or "rpc error",
        data = payload.error.data,
      }, nil)

      return
    end

    pcall(entry.callback, nil, payload.result)

    return
  end

  log.warn("client: payload has neither method nor id: %s", vim.inspect(payload))
end

---`vim.fn.sockconnect` `on_data` callback. Accumulates bytes, splits on
---`\n`, decodes JSON, dispatches.
---@param _chan integer
---@param data string[]
---@param _name string
local function on_data(_chan, data, _name)
  -- Neovim's channel callback semantics for raw byte channels are
  -- the "split on newlines, strip them" shape (see :h channel-bytes):
  -- `data` is a list where each item is the content between newlines,
  -- the first item continues the previous chunk's tail, and a
  -- trailing `""` indicates the chunk ended on a newline boundary.
  --
  -- The canonical reconstruction: join with literal "\n", then split
  -- back the same way. That keeps the line boundaries we need to
  -- pass JSON-RPC frames to the dispatcher.
  if type(data) ~= "table" or #data == 0 then
    return
  end

  log.debug("client.on_data: %d chunks (total %d bytes)", #data, #table.concat(data, "\n"))

  -- Stitch the first chunk onto any partial buffered tail; everything
  -- between subsequent items is a real newline boundary.
  buffer = buffer .. data[1]

  for i = 2, #data do
    local line = buffer
    buffer = data[i]

    if line ~= "" then
      log.debug("client.on_data: line (first 200 chars): %s", line:sub(1, 200))

      -- `luanil = { object = true, array = true }` maps JSON `null` to
      -- Lua `nil` instead of `vim.NIL`. The userdata sentinel is a
      -- consumer trap (`x ~= nil` returns true, `x or default` keeps
      -- the sentinel, table indexing throws) and the daemon emits
      -- nullable fields liberally (`replacement` on completion items,
      -- `stopReason` on `turn_ended`, etc.). Convert once at the
      -- boundary so every downstream module can treat absence as nil.
      local ok, payload = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })

      if ok then
        dispatch_payload(payload)
      else
        log.warn("client: failed to decode line: %s", line:sub(1, 200))
      end
    end
  end
end

---Try `sockconnect` once, retry up to `connect_attempts` times with
---`retry_delay_ms` between attempts. Final failure flips to
---`disconnected` with the underlying error.
---@param attempt integer
local function try_connect(attempt)
  set_state("connecting")

  local cfg = config.options.client or {}
  local max_attempts = cfg.connect_attempts or 3
  local retry_delay = cfg.retry_delay_ms or 1000

  local path = socket_path()
  if path == nil then
    set_state("disconnected", "no socket path: set XDG_RUNTIME_DIR or setup({ socket = ... })")
    return
  end

  local ok, chan_or_err = pcall(vim.fn.sockconnect, "pipe", path, { on_data = on_data })

  if ok and type(chan_or_err) == "number" and chan_or_err > 0 then
    channel = chan_or_err

    set_state("connected")

    return
  end

  local err = type(chan_or_err) == "string" and chan_or_err or "sockconnect failed"

  if attempt < max_attempts then
    log.warn("client: connect attempt %d/%d failed (%s); retrying in %dms", attempt, max_attempts, err, retry_delay)

    vim.defer_fn(function()
      try_connect(attempt + 1)
    end, retry_delay)

    return
  end

  log.error("client: connect failed after %d attempts: %s", max_attempts, err)

  set_state("disconnected", err)
end

---Open the connection. Idempotent — no-op while `connecting` or
---`connected`.
function M.connect()
  if state == "connected" or state == "connecting" then
    return
  end

  try_connect(1)
end

---Close the connection. Fails every in-flight request with a
---`transport` error.
function M.disconnect()
  teardown("client.disconnect")

  set_state("disconnected")
end

---Force a reconnect now.
function M.reconnect()
  teardown("client.reconnect")

  set_state("disconnected")

  M.connect()
end

---@return hyprpilot.client.State
function M.state()
  return state
end

---@return boolean
function M.is_connected()
  return state == "connected"
end

---Send a JSON-RPC request. The callback fires with `(err, result)` on
---reply, on timeout, or on transport failure — exactly once.
---@param method string
---@param params table?
---@param opts hyprpilot.client.RequestOpts?
---@param callback hyprpilot.client.Callback
function M.request(method, params, opts, callback)
  M.connect()

  if state ~= "connected" or channel == nil then
    pcall(callback, {
      kind = "transport",
      message = "client not connected (state=" .. state .. ")",
    }, nil)

    return
  end

  local cfg = config.options.client or {}
  local timeout_ms = (opts ~= nil and opts.timeout_ms) or cfg.timeout_ms or 5000

  local id = uuid4()
  local timer = vim.uv.new_timer()

  ---@type hyprpilot.client.Inflight
  local entry = {
    method = method,
    timer = timer,
    callback = callback,
  }

  inflight[id] = entry

  timer:start(timeout_ms, 0, function()
    vim.schedule(function()
      if inflight[id] ~= entry then
        return
      end

      inflight[id] = nil

      pcall(timer.close, timer)

      pcall(entry.callback, {
        kind = "timeout",
        message = string.format("client: %s timed out after %dms", method, timeout_ms),
      }, nil)
    end)
  end)

  vim.fn.chansend(channel, vim.json.encode({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params,
  }) .. "\n")
end

---Fire-and-forget notification.
---@param method string
---@param params table?
function M.notify(method, params)
  M.connect()

  if state ~= "connected" or channel == nil then
    log.warn("client.notify: not connected, dropping %s", method)

    return
  end

  vim.fn.chansend(channel, vim.json.encode({
    jsonrpc = "2.0",
    method = method,
    params = params,
  }) .. "\n")
end

---Subscribe to a notification method. Returns an unsubscribe closure.
---@param method string
---@param handler hyprpilot.client.NotificationHandler
---@return fun(): nil
function M.on_notification(method, handler)
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

---Subscribe to state-change events. Returns an unsubscribe closure.
---@param handler hyprpilot.client.StateHandler
---@return fun(): nil
function M.on_state_change(handler)
  table.insert(state_listeners, handler)

  return function()
    for i, fn in ipairs(state_listeners) do
      if fn == handler then
        table.remove(state_listeners, i)

        return
      end
    end
  end
end

---Test-only — drop every listener + in-flight + close the channel.
function M._reset()
  teardown("client._reset")

  state = "disconnected"
  buffer = ""
  inflight = {}
  listeners = {}
  state_listeners = {}
end

return M
