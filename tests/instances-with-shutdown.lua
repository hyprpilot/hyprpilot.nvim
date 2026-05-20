--- Behavioural tests for the `with_shutdown` opt on
--- `instances.spawn` / `focus`. Default true — stays plugin-side
--- (NOT sent to the daemon); stamps the registry state so the
--- `VimLeavePre` cleanup hook fires `instances/shutdown` on exit
--- for instances we own. `with_shutdown = false` opts out for
--- daemon-side agents the captain wants to outlive nvim.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["spawn: with_shutdown stays out of the wire payload"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["instances/spawn"] = { result = { instanceId = "inst-owned" } },
  })

  require("hyprpilot.rpc.instances").spawn({
    profile_id = "engineer",
    show = false,
    with_shutdown = true,
  })

  MiniTest.expect.equality(calls[1].method, "instances/spawn")
  -- The flag MUST NOT appear on the daemon-bound payload — it's a
  -- plugin-side ownership marker only.
  MiniTest.expect.equality(calls[1].params.with_shutdown, nil)
  MiniTest.expect.equality(calls[1].params.withShutdown, nil)

  helpers.cleanup_instance("inst-owned")
  restore_client()
end

T["spawn: with_shutdown defaults to true (stamps registry without the opt)"] = function()
  local restore_client = helpers.stub_client_with({
    ["instances/spawn"] = { result = { instanceId = "inst-owned" } },
  })

  -- No explicit with_shutdown — should default true.
  require("hyprpilot.rpc.instances").spawn({
    profile_id = "engineer",
    show = false,
  })

  local state = require("hyprpilot.chat.window")._instances["inst-owned"]
  MiniTest.expect.equality(state ~= nil, true)
  MiniTest.expect.equality(state.spawned_with_shutdown, true)

  helpers.cleanup_instance("inst-owned")
  restore_client()
end

T["spawn: with_shutdown=false opts out of cleanup (instance survives nvim exit)"] = function()
  local restore_client = helpers.stub_client_with({
    ["instances/spawn"] = { result = { instanceId = "inst-survives" } },
  })

  require("hyprpilot.rpc.instances").spawn({
    profile_id = "engineer",
    show = false,
    with_shutdown = false,
  })

  local state = require("hyprpilot.chat.window")._instances["inst-survives"]
  MiniTest.expect.equality(state ~= nil, true)
  MiniTest.expect.equality(state.spawned_with_shutdown, false)

  helpers.cleanup_instance("inst-survives")
  restore_client()
end

T["focus(ensure=true) defaults with_shutdown true; ensure=false (pure focus) never marks owned"] = function()
  local restore_client = helpers.stub_client_with({
    ["instances/focus"] = { result = { instanceId = "inst-foc", name = "foc" } },
  })

  -- Ensure-spawn path with no explicit flag → default true.
  require("hyprpilot.rpc.instances").focus("foc", {
    ensure = true,
    show = false,
  })

  local owned_state = require("hyprpilot.chat.window")._instances["inst-foc"]
  MiniTest.expect.equality(owned_state.spawned_with_shutdown, true)
  helpers.cleanup_instance("inst-foc")

  -- Pure focus (no ensure) — even with the flag set explicitly,
  -- ownership stays false because we didn't actually spawn
  -- anything (focus resolved to a pre-existing live instance).
  require("hyprpilot.rpc.instances").focus("foc2", {
    ensure = false,
    show = false,
    with_shutdown = true,
  })

  local borrowed_state = require("hyprpilot.chat.window")._instances["inst-foc"]
  MiniTest.expect.equality(borrowed_state.spawned_with_shutdown, false)

  helpers.cleanup_instance("inst-foc")
  restore_client()
end

T["cleanup_owned fires instances/shutdown for owned instances only"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["instances/shutdown"] = { result = { instanceId = "ignored" } },
  })

  local window = require("hyprpilot.chat.window")
  local buffer = require("hyprpilot.chat.buffer")

  -- Wipe `_instances` first so owned-default spawns from earlier
  -- tests don't pollute the iteration. The cleanup helper only
  -- forgets render state; the window registry is owned separately.
  for id, state in pairs(window._instances) do
    if vim.api.nvim_buf_is_valid(state.bufnr) then
      pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
    end
    window._instances[id] = nil
  end

  -- Two instances: one owned (with_shutdown stamped), one borrowed.
  window.register({
    bufnr = buffer.create("inst-owned"),
    instance_id = "inst-owned",
    spawned_with_shutdown = true,
  }, { activate = false })
  window.register({
    bufnr = buffer.create("inst-borrowed"),
    instance_id = "inst-borrowed",
    spawned_with_shutdown = false,
  }, { activate = false })

  -- Drive the public entry point directly. Production wires this
  -- into `rpc/shutdown.lua::M.shutdown` BEFORE `client.disconnect`
  -- so the requests reach the daemon — see the audit gap fix where
  -- the prior standalone `VimLeavePre` autocmd lost the order race.
  require("hyprpilot.rpc.instances").cleanup_owned()

  -- Only the owned instance gets the shutdown call.
  local shutdown_targets = {}
  for _, c in ipairs(calls) do
    if c.method == "instances/shutdown" then
      table.insert(shutdown_targets, c.params.instanceId)
    end
  end
  MiniTest.expect.equality(#shutdown_targets, 1)
  MiniTest.expect.equality(shutdown_targets[1], "inst-owned")

  helpers.cleanup_instance("inst-owned")
  helpers.cleanup_instance("inst-borrowed")
  window._instances["inst-owned"] = nil
  window._instances["inst-borrowed"] = nil
  restore_client()
end

T["shutdown: last instance closes the chat window; registry wiped"] = function()
  local window = require("hyprpilot.chat.window")
  local instances = require("hyprpilot.rpc.instances")
  local buffer = require("hyprpilot.chat.buffer")

  local restore_client, calls = helpers.stub_client_with({
    ["instances/shutdown"] = { result = { instanceId = "solo" } },
  })

  -- Register a single instance so `active_instance()` resolves.
  local bufnr = buffer.create("solo")
  window.register({
    bufnr = bufnr,
    instance_id = "solo",
    spawned_with_shutdown = true,
  }, { activate = true })

  -- Snapshot the pre-shutdown state.
  MiniTest.expect.equality(window._instances["solo"] ~= nil, true)

  -- Fire the manual shutdown.
  instances.shutdown("solo")

  -- After the (synchronous stub) RPC callback: instance wiped + window hidden.
  MiniTest.expect.equality(window._instances["solo"], nil)
  -- Window is not visible (was never opened in headless; `hide()` is a no-op
  -- when not visible — key assertion is that the registry is empty).
  MiniTest.expect.equality(next(window._instances), nil)

  -- Exactly one `instances/shutdown` wire call.
  local shutdown_calls = vim.tbl_filter(function(c)
    return c.method == "instances/shutdown"
  end, calls)
  MiniTest.expect.equality(#shutdown_calls, 1)
  MiniTest.expect.equality(shutdown_calls[1].params.instanceId, "solo")

  helpers.cleanup_instance("solo")
  restore_client()
end

T["attach: with_shutdown defaults true (palette-picked instance is owned)"] = function()
  local restore_client = helpers.stub_client_with({
    ["instances/info"] = { result = { instanceId = "inst-attached" } },
    ["instance/snapshot/chat"] = { result = { items = {}, latestSeq = 0, oldestSeq = 0, hasMore = false } },
    ["events/subscribe"] = { result = vim.NIL },
    ["instance/snapshot/meta"] = { result = {} },
    ["instance/snapshot/queue"] = { result = { items = {} } },
  })

  require("hyprpilot.rpc.instances").attach("inst-attached", { show = false })

  local state = require("hyprpilot.chat.window")._instances["inst-attached"]
  MiniTest.expect.equality(state ~= nil, true)
  MiniTest.expect.equality(state.spawned_with_shutdown, true)

  helpers.cleanup_instance("inst-attached")
  restore_client()
end

T["attach: with_shutdown=false opts out (peek-at-foreign-instance flow)"] = function()
  local restore_client = helpers.stub_client_with({
    ["instances/info"] = { result = { instanceId = "inst-peeked" } },
    ["instance/snapshot/chat"] = { result = { items = {}, latestSeq = 0, oldestSeq = 0, hasMore = false } },
    ["events/subscribe"] = { result = vim.NIL },
    ["instance/snapshot/meta"] = { result = {} },
    ["instance/snapshot/queue"] = { result = { items = {} } },
  })

  require("hyprpilot.rpc.instances").attach("inst-peeked", { show = false, with_shutdown = false })

  local state = require("hyprpilot.chat.window")._instances["inst-peeked"]
  MiniTest.expect.equality(state ~= nil, true)
  MiniTest.expect.equality(state.spawned_with_shutdown, false)

  helpers.cleanup_instance("inst-peeked")
  restore_client()
end

return T
