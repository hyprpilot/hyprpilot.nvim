--- Single plugin-global Unix-socket pipe to the hyprpilot daemon.
---
--- Lifetime: lazy connect on first use, persistent for nvim's lifetime,
--- automatic reconnect with exponential back-off on disconnect. Holds a
--- single `vim.uv` pipe; `rpc.lua` (Phase D) sits on top.
---
--- All libuv callbacks wrap their Neovim-API touches in `vim.schedule`
--- because read/connect callbacks run off the main thread.

local config = require("hyprpilot.config")
local linebuffer = require("hyprpilot.client.linebuffer")
local log = require("hyprpilot.log")

local M = {}

---@alias hyprpilot.client.TransportState "disconnected" | "connecting" | "connected" | "reconnecting"

---@class hyprpilot.client.Transport
---@field state hyprpilot.client.TransportState
---@field pipe? uv.uv_pipe_t
---@field linebuffer hyprpilot.client.LineBuffer
---@field reconnect_step integer
---@field reconnect_timer? uv.uv_timer_t
---@field auto_reconnect boolean
---@field last_error? string
---@field on_message? fun(payload: table): nil
---@field on_state_change? fun(state: hyprpilot.client.TransportState, err: string?): nil

local BACKOFF_MS = { 1000, 2000, 5000, 10000, 30000, 60000 }

---@type hyprpilot.client.Transport?
M._t = nil

---Lazy-init the singleton state without connecting.
---@return hyprpilot.client.Transport
local function ensure_state()
  if M._t == nil then
    M._t = {
      state = "disconnected",
      linebuffer = linebuffer.new(),
      reconnect_step = 1,
      auto_reconnect = true,
    }
  end

  return M._t
end

---Resolve the daemon socket path from config + env.
---@return string
local function socket_path()
  local from_config = config.options.socket

  if type(from_config) == "string" and from_config ~= "" then
    return from_config
  end

  local runtime = vim.env.XDG_RUNTIME_DIR

  if runtime == nil or runtime == "" then
    error("transport: XDG_RUNTIME_DIR is unset; pass setup({ socket = ... })")
  end

  return runtime .. "/hyprpilot.sock"
end

---Set the transport state and notify the listener (best-effort, pcall'd).
---@param t hyprpilot.client.Transport
---@param next hyprpilot.client.TransportState
---@param err string?
local function set_state(t, next, err)
  if t.state == next and t.last_error == err then
    return
  end

  log.debug("transport: %s → %s%s", t.state, next, err ~= nil and " (" .. err .. ")" or "")

  t.state = next
  t.last_error = err

  if t.on_state_change ~= nil then
    pcall(t.on_state_change, next, err)
  end
end

---Tear down the active pipe (idempotent).
---@param t hyprpilot.client.Transport
local function tear_down(t)
  if t.pipe ~= nil then
    pcall(t.pipe.read_stop, t.pipe)
    pcall(t.pipe.close, t.pipe)

    t.pipe = nil
  end

  linebuffer.reset(t.linebuffer)
end

---Cancel any pending reconnect timer.
---@param t hyprpilot.client.Transport
local function cancel_reconnect(t)
  if t.reconnect_timer ~= nil then
    pcall(t.reconnect_timer.stop, t.reconnect_timer)
    pcall(t.reconnect_timer.close, t.reconnect_timer)

    t.reconnect_timer = nil
  end
end

---Schedule a reconnect after the current back-off step.
---@param t hyprpilot.client.Transport
local function schedule_reconnect(t)
  if not t.auto_reconnect then
    return
  end

  cancel_reconnect(t)

  local delay = BACKOFF_MS[math.min(t.reconnect_step, #BACKOFF_MS)]
  t.reconnect_step = t.reconnect_step + 1

  log.debug("transport: reconnecting in %dms (step %d)", delay, t.reconnect_step - 1)

  t.reconnect_timer = vim.uv.new_timer()
  t.reconnect_timer:start(delay, 0, function()
    cancel_reconnect(t)
    vim.schedule(function()
      M.connect()
    end)
  end)
end

---Connect to the daemon. Idempotent — no-op while `connected` /
---`connecting`. Triggers auto-reconnect on failure.
function M.connect()
  local t = ensure_state()

  if t.state == "connected" or t.state == "connecting" then
    return
  end

  set_state(t, "connecting")

  local pipe = vim.uv.new_pipe(false)
  t.pipe = pipe

  pipe:connect(socket_path(), function(connect_err)
    if connect_err ~= nil then
      vim.schedule(function()
        tear_down(t)
        set_state(t, "reconnecting", connect_err)
        schedule_reconnect(t)
      end)

      return
    end

    vim.schedule(function()
      set_state(t, "connected")

      t.reconnect_step = 1
    end)

    pipe:read_start(function(read_err, chunk)
      if read_err ~= nil then
        vim.schedule(function()
          tear_down(t)
          set_state(t, "reconnecting", read_err)
          schedule_reconnect(t)
        end)

        return
      end

      if chunk == nil then
        vim.schedule(function()
          tear_down(t)
          set_state(t, "reconnecting", "EOF")
          schedule_reconnect(t)
        end)

        return
      end

      linebuffer.push(t.linebuffer, chunk, function(line)
        if line == "" then
          return
        end

        local ok, payload = pcall(vim.json.decode, line)

        if not ok then
          log.warn("transport: failed to decode line: %s", line:sub(1, 200))

          return
        end

        if t.on_message ~= nil then
          vim.schedule(function()
            pcall(t.on_message, payload)
          end)
        end
      end)
    end)
  end)
end

---Send a JSON-RPC payload as one NDJSON line. Returns true on enqueue,
---false when not currently connected (caller decides what to do).
---@param payload table
---@return boolean
function M.send(payload)
  local t = M._t

  if t == nil or t.state ~= "connected" or t.pipe == nil then
    log.warn("transport.send: not connected (state=%s)", t ~= nil and t.state or "uninit")

    return false
  end

  local ok, encoded = pcall(vim.json.encode, payload)

  if not ok then
    log.error("transport.send: failed to encode payload: %s", tostring(encoded))

    return false
  end

  t.pipe:write(encoded .. "\n")

  return true
end

---Force a reconnect attempt now, cancelling any pending back-off timer.
---Useful after the captain restarts the daemon.
function M.reconnect()
  local t = ensure_state()

  cancel_reconnect(t)
  tear_down(t)

  t.reconnect_step = 1
  t.auto_reconnect = true

  set_state(t, "disconnected")

  M.connect()
end

---Close the connection without scheduling a reconnect. Mostly a hook for
---tests + explicit tear-down.
function M.disconnect()
  local t = ensure_state()

  cancel_reconnect(t)
  tear_down(t)

  t.auto_reconnect = false

  set_state(t, "disconnected")
end

---Current transport state. Returns `"disconnected"` before the first
---`connect()` call.
---@return hyprpilot.client.TransportState
function M.state()
  return M._t ~= nil and M._t.state or "disconnected"
end

---Last transport error, if any. Cleared on successful reconnect.
---@return string?
function M.last_error()
  return M._t ~= nil and M._t.last_error or nil
end

---Register the per-line message handler. Latest wins.
---@param fn fun(payload: table): nil
function M.on_message(fn)
  ensure_state().on_message = fn
end

---Register the state-change listener. Latest wins.
---@param fn fun(state: hyprpilot.client.TransportState, err: string?): nil
function M.on_state_change(fn)
  ensure_state().on_state_change = fn
end

---Test-only — drop the singleton state without touching live pipes.
---Used by tests to start each case with a clean slate.
function M._reset()
  if M._t ~= nil then
    cancel_reconnect(M._t)
    tear_down(M._t)
  end

  M._t = nil
end

return M
