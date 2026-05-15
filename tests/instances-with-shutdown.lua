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

T["VimLeavePre fires instances/shutdown for owned instances only"] = function()
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

  -- Trigger the VimLeavePre autocmd we wired at module load.
  vim.api.nvim_exec_autocmds("VimLeavePre", { group = "HyprpilotInstancesCleanup" })

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

return T
