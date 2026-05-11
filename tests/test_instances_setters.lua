--- Behavioural tests for the instances setter API. Stubs
--- `client.request` to capture the wire payload; asserts the
--- snake_case → camelCase translation matches the daemon's
--- `instances/setMode` / `setModel` / `setOption` shapes.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["set_mode fires instances/setMode with camelCase params"] = function()
  local restore, calls = helpers.stub_client_request()
  require("hyprpilot.instances").set_mode("inst-1", "plan")

  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].method, "instances/setMode")
  MiniTest.expect.equality(calls[1].params.instanceId, "inst-1")
  MiniTest.expect.equality(calls[1].params.modeId, "plan")

  restore()
end

T["set_model fires instances/setModel"] = function()
  local restore, calls = helpers.stub_client_request()
  require("hyprpilot.instances").set_model("inst-1", "sonnet")

  MiniTest.expect.equality(calls[1].method, "instances/setModel")
  MiniTest.expect.equality(calls[1].params.modelId, "sonnet")

  restore()
end

T["set_option fires instances/setOption with configId + value"] = function()
  local restore, calls = helpers.stub_client_request()
  require("hyprpilot.instances").set_option("inst-1", "effort", "high")

  MiniTest.expect.equality(calls[1].method, "instances/setOption")
  MiniTest.expect.equality(calls[1].params.configId, "effort")
  MiniTest.expect.equality(calls[1].params.value, "high")

  restore()
end

T["setters skip with a warn on empty input"] = function()
  local restore, calls = helpers.stub_client_request()
  local instances = require("hyprpilot.instances")

  instances.set_mode("", "plan")
  instances.set_mode("inst-1", "")
  instances.set_model("inst-1", "")
  instances.set_option("inst-1", "", "x")
  instances.set_option("inst-1", "effort", nil)

  MiniTest.expect.equality(#calls, 0)

  restore()
end

T["setters propagate the daemon's reply through the callback"] = function()
  local client = require("hyprpilot.client")
  local original = client.request

  client.request = function(_, _, _, callback)
    callback(nil, { ok = true })
  end

  local seen
  require("hyprpilot.instances").set_mode("inst-1", "plan", function(err, result)
    seen = { err = err, result = result }
  end)

  MiniTest.expect.equality(seen.err, nil)
  MiniTest.expect.equality(seen.result.ok, true)

  client.request = original
end

return T
