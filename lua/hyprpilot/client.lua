--- JSON-RPC 2.0 client for the hyprpilot daemon.
---
--- Wire: NDJSON over `$XDG_RUNTIME_DIR/hyprpilot.sock` (or
--- `setup({ socket = ... })`). Socket connection uses Neovim's native
--- `vim.fn.sockconnect` channel (raw `on_data` mode); we own the
--- newline split + JSON-RPC dispatch because Neovim ships no NDJSON
--- JSON-RPC client for non-LSP use cases.
---
--- Single plugin-global connection. Lazy first connect, one immediate
--- attempt on failure (the socket is local; if it is gone, fail fast).
--- EOF / stale-timeout recovery keeps a separate deferred reconnect path
--- for sockets that were already established. Public surface: `request`,
--- `notify`, `on_notification`, `on_state_change`, `state`, `connect`,
--- `disconnect`, and `reconnect`.

local config = require("hyprpilot.config")
local log = require("hyprpilot.log")
local instances = require("hyprpilot.instances")

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

--- Counter of consecutive request timeouts. Bumped in the per-request
--- timeout path; reset on every successful reply (`dispatch_payload`).
--- A daemon that's hung but hasn't closed the socket reads as a
--- string of timeouts to us; passing the threshold flips us into
--- reconnect-recovery mode (force-close the channel + try to redial).
local timeout_streak = 0
local STALE_TIMEOUT_THRESHOLD = 3

--- True while an auto-reconnect is queued (defer_fn'd) so a flood of
--- timeouts / EOF callbacks doesn't enqueue N parallel reconnects.
--- Cleared by the deferred callback right before it actually runs.
local auto_reconnect_pending = false

--- Consecutive EOF/stale auto-reconnect counter for exponential
--- back-off. Increments on every `schedule_auto_reconnect`; reset on the
--- next successful reply (`dispatch_payload`) — a real reply proves the
--- channel is healthy, so the next EOF/stale recovery starts fresh.
--- This does NOT keep polling a missing socket: the deferred callback
--- runs one normal `M.connect()` attempt, and initial connect failures
--- fail fast.
local reconnect_attempt_count = 0
local RECONNECT_BACKOFF_MAX_MS = 30000

---Force-close the channel + schedule a reconnect attempt. Called
---from EOF detection (daemon closed the socket) and from the
---stale-streak guard. No-op when a reconnect is already pending.
---Delay grows exponentially with `reconnect_attempt_count`:
---  attempt 0 → retry_delay_ms (default 1000ms)
---  attempt 1 → 2 × retry_delay_ms
---  attempt N → min(MAX, retry_delay_ms × 2^N)
---Capped at 30s for repeated EOF/stale cycles. If the next connect sees
---a missing socket, that attempt fails fast and no further reconnect is
---queued until another explicit connect/reconnect path runs.
---@param reason string
local function schedule_auto_reconnect(reason)
  if auto_reconnect_pending then
    return
  end
  auto_reconnect_pending = true
  local cfg = config.options.client or {}
  local base_ms = cfg.retry_delay_ms or 1000
  local delay_ms = math.min(RECONNECT_BACKOFF_MAX_MS, base_ms * (2 ^ reconnect_attempt_count))
  reconnect_attempt_count = reconnect_attempt_count + 1
  log.warn("client: auto-reconnect scheduled (reason=%s, delay=%dms, attempt=%d)", reason, delay_ms, reconnect_attempt_count)
  vim.defer_fn(function()
    auto_reconnect_pending = false
    -- Skip if the captain explicitly disconnected in the meantime,
    -- or if we already reconnected via some other path.
    if state == "connected" or state == "connecting" then
      return
    end
    M.connect()
  end, delay_ms)
end

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

    -- A live reply (success OR rpc error from the daemon) means the
    -- channel is healthy. Reset the stale-detector counter so a
    -- previously-bad streak doesn't carry over, AND the reconnect
    -- back-off counter so the next disconnect starts fresh from
    -- `retry_delay_ms` instead of inheriting a long delay from a
    -- prior flap cycle.
    timeout_streak = 0
    reconnect_attempt_count = 0

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

  -- EOF marker: vim invokes the channel callback once with `{ "" }`
  -- when the peer closes the socket (`:h channel-callback`). The
  -- daemon dying / restarting / dropping the connection arrives here.
  -- Tear down the in-flight state with a clean transport error and
  -- queue an auto-reconnect so a daemon restart self-heals without
  -- the captain noticing.
  if #data == 1 and data[1] == "" then
    if state == "connected" then
      log.warn("client: peer closed the channel (EOF on socket)")
      teardown("daemon closed connection")
      set_state("disconnected", "peer EOF")
      schedule_auto_reconnect("peer EOF")
    end
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

---Try `sockconnect` once. A missing local socket likely means the daemon
---session is gone, so initial connection failures fail fast instead of
---looping through delayed retries. EOF / stale-timeout recovery uses the
---separate auto-reconnect scheduler after a connection has existed.
local function try_connect()
  set_state("connecting")

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

  log.error("client: connect failed: %s", err)

  set_state("disconnected", err)
end

---Open the connection. Idempotent — no-op while `connecting` or
---`connected`.
function M.connect()
  if state == "connected" or state == "connecting" then
    return
  end

  try_connect()
end

---Close the connection. Fails every in-flight request with a
---`transport` error.
function M.disconnect()
  teardown("client.disconnect")

  set_state("disconnected")
end

---Force a reconnect now.
function M.reconnect()
  -- Captain-driven explicit reconnect should restart the backoff
  -- clock from zero — they're asserting intent, not continuing a
  -- flap cycle. Without this, a manual reconnect after a long
  -- flap would inherit the prior 30s delay on the next auto-
  -- triggered reconnect.
  reconnect_attempt_count = 0
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

      -- Stale-detector: a daemon that's hung but hasn't closed the
      -- socket reads as a string of timeouts (no EOF, no replies).
      -- After N consecutive timeouts force a reconnect — daemon
      -- restart self-heals; daemon truly gone re-enters the connect
      -- retry loop and surfaces a clean disconnected state.
      timeout_streak = timeout_streak + 1
      if timeout_streak >= STALE_TIMEOUT_THRESHOLD and state == "connected" then
        log.warn("client: %d consecutive timeouts — channel looks stale, forcing reconnect", timeout_streak)
        timeout_streak = 0
        teardown("stale channel")
        set_state("disconnected", "stale (timeout streak)")
        schedule_auto_reconnect("stale channel")
      end
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
  timeout_streak = 0
  reconnect_attempt_count = 0
  auto_reconnect_pending = false
  instances._reset()
end

return M
