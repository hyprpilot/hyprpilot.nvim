--- Behavioural tests for the `User Hyprpilot<*>` lifecycle autocmds.
--- The plugin fires these whenever it dispatches a daemon wire event
--- — captains hook them for statusline, toast, or workflow plumbing
--- without having to re-implement the wire envelope decode.

local T = MiniTest.new_set()

---Subscribe to `pattern` once, capture the `data` payload of the
---next emission, then auto-unsubscribe. Returns a closure that
---returns the captured data (nil before the autocmd fires).
---@param pattern string
---@return fun(): table?
local function capture_user_autocmd(pattern)
  local captured
  local autocmd_id = vim.api.nvim_create_autocmd("User", {
    pattern = pattern,
    callback = function(ev)
      captured = ev.data
    end,
  })
  -- The teardown happens implicitly when the test ends — every
  -- case mints a fresh autocmd id, and mini.test's child-process
  -- isolation tears them down. For belt-and-suspenders we still
  -- expose a clear path:
  return function()
    pcall(vim.api.nvim_del_autocmd, autocmd_id)
    return captured
  end
end

---Drive the events module's private `dispatch` by invoking the
---`events/changed` notification path the client would normally
---deliver. The events module subscribes lazily; we go through
---`ensure_subscribed`'s public path and then synthesise an
---`events/changed` notification by directly calling
---`client.dispatch_payload` — no, simpler: hand-craft and call the
---dispatch via the helper exposed for tests. Since `dispatch` is
---local, fire through `client.on_notification` listeners by
---triggering an actual payload.
---
---Simplest path: invoke `render.handle_*` directly when relevant,
---but the autocmds fire from inside `dispatch`. So we need to drive
---`dispatch` itself. The events module returns a private dispatch;
---we monkey-patch `client.on_notification` to capture the listener
---reference at `ensure_subscribed` time, then call it with our
---synthetic payload.
---@param event_payload table                        -- the `payload` field of an events/changed envelope
local function fire_event(event_payload)
  local client = require("hyprpilot.client")
  local events = require("hyprpilot.chat.events")

  -- Capture the dispatch listener `events.ensure_subscribed`
  -- registers. We stub `on_notification` BEFORE the call so the
  -- subscription path stashes its dispatcher into `captured`.
  local original_on_notification = client.on_notification
  local captured_dispatch
  client.on_notification = function(method, callback)
    if method == "events/changed" then
      captured_dispatch = callback
    end
    return function() end -- unsubscribe noop
  end

  -- Stub request so `ensure_subscribed` doesn't actually hit the wire.
  local original_request = client.request
  client.request = function(_method, _params, _opts, callback)
    if callback ~= nil then
      callback(nil, {})
    end
  end

  events._reset()
  events.ensure_subscribed()

  -- Restore the real client surface before driving the dispatcher.
  client.on_notification = original_on_notification
  client.request = original_request

  MiniTest.expect.equality(captured_dispatch ~= nil, true)
  captured_dispatch({ payload = event_payload })

  events._reset()
end

T["dispatch fires HyprpilotTurnStarted with structured payload"] = function()
  local consume = capture_user_autocmd("HyprpilotTurnStarted")
  fire_event({
    event = "turn_started",
    instanceId = "inst-1",
    turnId = "turn-x",
    startedAt = 1700000000000,
  })
  local data = consume()
  MiniTest.expect.equality(data ~= nil, true)
  MiniTest.expect.equality(data.instance_id, "inst-1")
  MiniTest.expect.equality(data.turn_id, "turn-x")
  MiniTest.expect.equality(data.started_at, 1700000000000)
end

T["dispatch fires HyprpilotTurnEnded with stop_reason"] = function()
  local consume = capture_user_autocmd("HyprpilotTurnEnded")
  fire_event({
    event = "turn_ended",
    instanceId = "inst-1",
    turnId = "turn-x",
    endedAt = 1700000005000,
    stopReason = "end_turn",
  })
  local data = consume()
  MiniTest.expect.equality(data.instance_id, "inst-1")
  MiniTest.expect.equality(data.turn_id, "turn-x")
  MiniTest.expect.equality(data.stop_reason, "end_turn")
  MiniTest.expect.equality(data.ended_at, 1700000005000)
end

T["dispatch fires HyprpilotPermissionRequested with tool + options"] = function()
  local consume = capture_user_autocmd("HyprpilotPermissionRequested")
  fire_event({
    event = "permission_request",
    instanceId = "inst-1",
    requestId = "req-1",
    tool = "Bash",
    toolKind = "execute",
    options = {
      { optionId = "allow-once", name = "Allow" },
      { optionId = "reject-once", name = "Reject" },
    },
  })
  local data = consume()
  MiniTest.expect.equality(data.instance_id, "inst-1")
  MiniTest.expect.equality(data.request_id, "req-1")
  MiniTest.expect.equality(data.tool, "Bash")
  MiniTest.expect.equality(data.tool_kind, "execute")
  MiniTest.expect.equality(#data.options, 2)
  MiniTest.expect.equality(data.options[1].optionId, "allow-once")
end

T["dispatch fires HyprpilotPermissionResolved with option_id"] = function()
  -- Prime the row queue so the resolve handler has a request to
  -- drop. permission_row's resolve checks state.permissions[id] in
  -- render — sidestep by going straight through events. The
  -- autocmd fires regardless of whether render finds the block.
  local consume = capture_user_autocmd("HyprpilotPermissionResolved")
  fire_event({
    event = "permission_resolved",
    instanceId = "inst-1",
    requestId = "req-1",
    optionId = "allow-once",
  })
  local data = consume()
  MiniTest.expect.equality(data.instance_id, "inst-1")
  MiniTest.expect.equality(data.request_id, "req-1")
  MiniTest.expect.equality(data.option_id, "allow-once")
end

T["dispatch fires HyprpilotInstanceStateChanged on state"] = function()
  local consume = capture_user_autocmd("HyprpilotInstanceStateChanged")
  fire_event({
    event = "state",
    instanceId = "inst-1",
    state = "ended",
  })
  local data = consume()
  MiniTest.expect.equality(data.instance_id, "inst-1")
  MiniTest.expect.equality(data.state, "ended")
end

return T
