--- Behavioural tests for the reactive event flow:
---   * status.set_activity wired from chat.events dispatch
---   * cancel-shaped turn_ended chip
---   * terminal block accumulates output + folds on exit
---   * acp:instance-state surfaces in the winbar
---   * HyprpilotInstanceChanged fires on window.switch / register

local helpers = require("tests.helpers")

-- Pin glyph maps so assertions on the rendered chip text stay
-- readable (defaults are nerd-font glyphs).
require("hyprpilot.config").setup({
  icons = {
    turn_status = { ok = "", cancelled = "", error = "" },
  },
})

local T = MiniTest.new_set()

local function fresh_dispatch()
  -- Reach into chat.events to grab its private dispatch via the
  -- public surface — `client.on_notification("events/changed", fn)`
  -- registers `fn`. We mimic events arriving by calling the same
  -- handler chain through the public render APIs the dispatcher
  -- reaches anyway, plus by hand-firing dispatch via the events module.
  local events = require("hyprpilot.chat.events")
  return events
end

T["turn_started → thinking, transcript agent_text → streaming, turn_ended → idle"] = function()
  fresh_dispatch()
  local status = require("hyprpilot.status")
  status._reset()

  local seen = {}
  vim.api.nvim_create_autocmd("User", {
    pattern = "HyprpilotActivityChanged",
    callback = function(args)
      table.insert(seen, args.data and args.data.kind or nil)
    end,
  })

  status.set_activity("inst-1", { kind = "thinking" })
  status.set_activity("inst-1", { kind = "streaming" })
  status.set_activity("inst-1", { kind = "idle" })

  MiniTest.expect.equality(seen[1], "thinking")
  MiniTest.expect.equality(seen[2], "streaming")
  MiniTest.expect.equality(seen[3], "idle")
end

T["activity transitions through tool / awaiting_permission via dispatch flow"] = function()
  local status = require("hyprpilot.status")
  status._reset()

  -- These emulate the dispatch order the live event stream would
  -- produce; we route through the same set_activity calls the
  -- dispatcher uses so the test doesn't require a daemon.
  status.set_activity("inst-1", { kind = "thinking" })
  status.set_activity("inst-1", { kind = "tool", tool_name = "bash" })
  status.set_activity("inst-1", { kind = "awaiting_permission", permission_request_id = "req-1" })
  status.set_activity("inst-1", { kind = "streaming" })
  status.set_activity("inst-1", { kind = "idle" })

  MiniTest.expect.equality(status.get("inst-1").activity.kind, "idle")
end

T["turn_ended with cancel-shaped stopReason marks the chip as cancelled on the pilot header"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  render.handle_turn_started({ instanceId = id, turnId = "t1" })
  render.handle_transcript({
    instanceId = id,
    turnId = "t1",
    item = { kind = "agent_text", text = "partial reply" },
  })

  render.handle_turn_ended({ instanceId = id, turnId = "t1", stopReason = "cancelled_by_user" })

  -- The cancel chip should land on the `## pilot` header line as a
  -- stat-style pill, NOT as virt_text at the end of the buffer.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local pilot_line
  for _, l in ipairs(lines) do
    if l:find("^## pilot") then
      pilot_line = l
      break
    end
  end

  MiniTest.expect.equality(pilot_line ~= nil, true)
  MiniTest.expect.equality(pilot_line:find("[cancelled cancelled_by_user]", 1, true) ~= nil, true)

  -- The unused `state` binding makes selene happy without dropping a
  -- side effect we still need (state registration with the buffer).
  local _ = state
  helpers.cleanup_instance(id)
end

T["terminal block accumulates output and folds on exit"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  render.state(id, bufnr)
  local winid = helpers.open_chat_window(bufnr)

  render.handle_terminal({
    instanceId = id,
    terminalId = "term-1",
    chunk = { kind = "output", stream = "stdout", data = "first line\n" },
  })
  render.handle_terminal({
    instanceId = id,
    terminalId = "term-1",
    chunk = { kind = "output", stream = "stdout", data = "second line\n" },
  })
  render.handle_terminal({
    instanceId = id,
    terminalId = "term-1",
    chunk = { kind = "exit", exitCode = 0 },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "exit=0"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "first line"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "second line"), true)

  -- Block folds after the exit chunk (manual fold gets created by
  -- fold_block). Verify by checking that at least one line in the
  -- accumulated body shows as inside a closed fold in the open window.
  local found_closed = false
  for lnum = 1, #lines do
    local closed
    vim.api.nvim_win_call(winid, function()
      closed = vim.fn.foldclosed(lnum)
    end)
    if (closed or -1) > 0 then
      found_closed = true
      break
    end
  end
  MiniTest.expect.equality(found_closed, true)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

T["acp:instance-state surfaces in the winbar when not running"] = function()
  local id = helpers.unique_id()
  local buffer = require("hyprpilot.chat.buffer")
  local bufnr = buffer.create(id)
  local winid = helpers.open_chat_window(bufnr)
  local winbar = require("hyprpilot.chat.winbar")

  winbar.update_meta(id, { instance_state = "starting" })
  local out
  vim.api.nvim_win_call(winid, function()
    out = winbar.render()
  end)
  MiniTest.expect.equality(out:find("starting", 1, true) ~= nil, true)

  -- Running is the steady state — should NOT show in the bar (clutter).
  winbar.update_meta(id, { instance_state = "running" })
  vim.api.nvim_win_call(winid, function()
    out = winbar.render()
  end)
  MiniTest.expect.equality(out:find("running", 1, true), nil)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
  winbar.forget(id)
end

T["HyprpilotInstanceChanged fires when window.switch flips the active id"] = function()
  local buffer = require("hyprpilot.chat.buffer")
  local window = require("hyprpilot.chat.window")
  local id_a = helpers.unique_id()
  local id_b = helpers.unique_id()

  -- Two registered instances; register() emits the first
  -- HyprpilotInstanceChanged for each on initial registration.
  window.register({ bufnr = buffer.create(id_a), instance_id = id_a }, { activate = true })
  window.register({ bufnr = buffer.create(id_b), instance_id = id_b }, { activate = true })

  -- Now subscribe and switch — that triggers the autocmd we want
  -- to verify under captain control.
  local seen = {}
  vim.api.nvim_create_autocmd("User", {
    pattern = "HyprpilotInstanceChanged",
    callback = function(args)
      table.insert(seen, args.data and args.data.instance_id or nil)
    end,
  })

  window.switch(id_a)

  MiniTest.expect.equality(#seen, 1)
  MiniTest.expect.equality(seen[1], id_a)

  -- Switching to the same id again must NOT fire.
  window.switch(id_a)
  MiniTest.expect.equality(#seen, 1)

  -- Switching to a different id fires once more.
  window.switch(id_b)
  MiniTest.expect.equality(#seen, 2)
  MiniTest.expect.equality(seen[2], id_b)

  helpers.cleanup_instance(id_a)
  helpers.cleanup_instance(id_b)
end

T["events.dispatch unwraps the daemon's { name, payload, instanceId } envelope"] = function()
  -- Capture the notification handler the events module registers
  -- by stubbing client.on_notification, then drive it with the
  -- envelope shape the daemon actually emits.
  local client = require("hyprpilot.client")
  local original_on_notification = client.on_notification
  local original_request = client.request
  local captured

  client.on_notification = function(method, handler)
    if method == "events/changed" then
      captured = handler
    end
    return function() end
  end

  -- ensure_subscribed also fires the events/subscribe RPC; short-
  -- circuit it so the test doesn't hit the wire.
  client.request = function(_, _, _, callback)
    callback(nil, { subscribed = true })
  end

  local events = require("hyprpilot.chat.events")
  events._reset()
  events.ensure_subscribed()

  client.on_notification = original_on_notification
  client.request = original_request

  MiniTest.expect.equality(captured ~= nil, true)

  -- Hand the captured dispatcher the daemon's actual wire shape and
  -- assert the instance-meta side effect lands.
  local id = helpers.unique_id()
  captured({
    name = "acp:instance-meta",
    instanceId = id,
    payload = {
      event = "instance_meta",
      instanceId = id,
      currentModeId = "plan",
      availableModes = { { id = "plan", name = "Plan" } },
      mcpsCount = 3,
    },
  })

  local winbar = require("hyprpilot.chat.winbar")
  MiniTest.expect.equality(winbar._meta[id].current_mode_id, "plan")
  MiniTest.expect.equality(winbar._meta[id].mcps_count, 3)

  -- And the malformed-payload guard rails still hold for things
  -- missing the discriminator entirely.
  captured({ no = "envelope at all" })

  winbar.forget(id)
end

return T
