--- Behavioural tests for the `with_config` opt on `instances.spawn`
--- and `instances.focus`. Stubs `client.request` to capture the wire
--- params and asserts `withConfig` is forwarded verbatim (and
--- omitted when nil/empty so the daemon's serde-default kicks in).

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["instances.spawn: forwards with_config patches as `withConfig` on the wire"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["instances/spawn"] = { result = { instanceId = "inst-new" } },
  })

  require("hyprpilot.instances").spawn({
    profile_id = "engineer",
    show = false,
    with_config = {
      { agents = { { id = "code", capabilities = { "web" } } } },
      { mcps = { { id = "fs", enabled = true } } },
    },
  })

  MiniTest.expect.equality(calls[1].method, "instances/spawn")
  MiniTest.expect.equality(#calls[1].params.withConfig, 2)
  MiniTest.expect.equality(calls[1].params.withConfig[1].agents[1].id, "code")
  MiniTest.expect.equality(calls[1].params.withConfig[2].mcps[1].enabled, true)

  restore_client()
end

T["instances.spawn: omits `withConfig` from the wire when no patches given"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["instances/spawn"] = { result = { instanceId = "inst-new" } },
  })

  require("hyprpilot.instances").spawn({ profile_id = "engineer", show = false })

  MiniTest.expect.equality(calls[1].method, "instances/spawn")
  MiniTest.expect.equality(calls[1].params.withConfig, nil)

  restore_client()
end

T["instances.spawn: empty patch list also omitted (daemon serde-defaults to empty)"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["instances/spawn"] = { result = { instanceId = "inst-new" } },
  })

  require("hyprpilot.instances").spawn({ profile_id = "engineer", show = false, with_config = {} })

  MiniTest.expect.equality(calls[1].params.withConfig, nil)

  restore_client()
end

T["instances.focus: forwards with_config on the ensure-spawn path"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["instances/focus"] = { result = { instanceId = "inst-new", name = "feature-x" } },
  })

  require("hyprpilot.instances").focus("feature-x", {
    ensure = true,
    show = false,
    with_config = { { profiles = { { id = "engineer", default = true } } } },
  })

  MiniTest.expect.equality(calls[1].method, "instances/focus")
  MiniTest.expect.equality(calls[1].params.ensure, true)
  MiniTest.expect.equality(#calls[1].params.withConfig, 1)
  MiniTest.expect.equality(calls[1].params.withConfig[1].profiles[1].id, "engineer")

  restore_client()
end

T["instances.spawn(name=...) routes through focus and carries with_config"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["instances/focus"] = { result = { instanceId = "inst-new", name = "feature-x" } },
  })

  require("hyprpilot.instances").spawn({
    name = "feature-x",
    profile_id = "engineer",
    show = false,
    with_config = { { agents = { { id = "code" } } } },
  })

  MiniTest.expect.equality(calls[1].method, "instances/focus")
  MiniTest.expect.equality(calls[1].params.ensure, true)
  MiniTest.expect.equality(#calls[1].params.withConfig, 1)

  restore_client()
end

return T
