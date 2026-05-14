--- Behavioural tests for the instances setter API. Stubs
--- `client.request` to capture the wire payload; asserts the
--- snake_case → camelCase translation matches the daemon's
--- `instances/setMode` / `setModel` / `setOption` shapes.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["info calls instances/info and translates the Instance shape"] = function()
  local client = require("hyprpilot.client")
  local original = client.request
  local calls = {}

  client.request = function(method, params, _opts, callback)
    table.insert(calls, { method = method, params = params })
    callback(nil, {
      instanceId = "inst-1",
      name = "main",
      agentId = "claude-code",
      profileId = "default",
      sessionId = "sess-1",
      mode = "plan",
    })
  end

  local seen
  require("hyprpilot.rpc.instances").info("inst-1", function(err, info)
    seen = { err = err, info = info }
  end)

  client.request = original

  MiniTest.expect.equality(calls[1].method, "instances/info")
  MiniTest.expect.equality(calls[1].params.instanceId, "inst-1")
  MiniTest.expect.equality(seen.err, nil)
  MiniTest.expect.equality(seen.info.id, "inst-1")
  MiniTest.expect.equality(seen.info.name, "main")
  MiniTest.expect.equality(seen.info.agent_id, "claude-code")
  MiniTest.expect.equality(seen.info.mode, "plan")
end

T["meta calls instance/snapshot/meta and translates the MetaSnapshot shape"] = function()
  local client = require("hyprpilot.client")
  local original = client.request
  local calls = {}

  client.request = function(method, params, _opts, callback)
    table.insert(calls, { method = method, params = params })
    callback(nil, {
      profileId = "default",
      sessionId = "sess-1",
      cwd = "/tmp",
      currentModeId = "plan",
      currentModelId = "sonnet",
      availableModes = { { id = "plan", name = "Plan" } },
      availableModels = { { id = "sonnet", name = "Sonnet" } },
      mcpsCount = 2,
      usage = { used = 100, size = 1000 },
      latestSeq = 42,
    })
  end

  local seen
  require("hyprpilot.rpc.instances").meta("inst-1", function(err, meta)
    seen = { err = err, meta = meta }
  end)

  client.request = original

  MiniTest.expect.equality(calls[1].method, "instance/snapshot/meta")
  MiniTest.expect.equality(seen.err, nil)
  MiniTest.expect.equality(seen.meta.current_mode_id, "plan")
  MiniTest.expect.equality(seen.meta.current_model_id, "sonnet")
  MiniTest.expect.equality(#seen.meta.available_modes, 1)
  MiniTest.expect.equality(seen.meta.available_modes[1].id, "plan")
  MiniTest.expect.equality(#seen.meta.available_models, 1)
  MiniTest.expect.equality(seen.meta.mcps_count, 2)
  MiniTest.expect.equality(seen.meta.usage.used, 100)
  MiniTest.expect.equality(seen.meta.latest_seq, 42)
end

T["set_mode fires instances/setMode with camelCase params"] = function()
  local restore, calls = helpers.stub_client_request()
  require("hyprpilot.rpc.instances").set_mode("inst-1", "plan")

  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].method, "instances/setMode")
  MiniTest.expect.equality(calls[1].params.instanceId, "inst-1")
  MiniTest.expect.equality(calls[1].params.modeId, "plan")

  restore()
end

T["set_model fires instances/setModel"] = function()
  local restore, calls = helpers.stub_client_request()
  require("hyprpilot.rpc.instances").set_model("inst-1", "sonnet")

  MiniTest.expect.equality(calls[1].method, "instances/setModel")
  MiniTest.expect.equality(calls[1].params.modelId, "sonnet")

  restore()
end

T["set_option fires instances/setOption with configId + value"] = function()
  local restore, calls = helpers.stub_client_request()
  require("hyprpilot.rpc.instances").set_option("inst-1", "effort", "high")

  MiniTest.expect.equality(calls[1].method, "instances/setOption")
  MiniTest.expect.equality(calls[1].params.configId, "effort")
  MiniTest.expect.equality(calls[1].params.value, "high")

  restore()
end

T["setters skip with a warn on empty input"] = function()
  local restore, calls = helpers.stub_client_request()
  local instances = require("hyprpilot.rpc.instances")

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
  require("hyprpilot.rpc.instances").set_mode("inst-1", "plan", function(err, result)
    seen = { err = err, result = result }
  end)

  MiniTest.expect.equality(seen.err, nil)
  MiniTest.expect.equality(seen.result.ok, true)

  client.request = original
end

return T
