--- Behavioural tests for `instances.fork`, the Neovim frontend
--- wrapper around the daemon's `sessions/fork` RPC.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

local function find_call(calls, method)
  for _, call in ipairs(calls) do
    if call.method == method then
      return call
    end
  end
  return nil
end

T["fork: defaults to active instance and sends source metadata to sessions/fork"] = function()
  local restore_active = helpers.stub_active_instance("inst-source")
  local restore_client, calls = helpers.stub_client_with({
    ["instances/info"] = {
      {
        result = {
          instanceId = "inst-source",
          sessionId = "sess-source",
          agentId = "opencode",
          profileId = "personal/opencode/default",
          cwd = "/tmp/project",
        },
      },
      {
        result = {
          instanceId = "inst-forked",
          sessionId = "sess-forked",
          agentId = "opencode",
          profileId = "personal/opencode/default",
          cwd = "/tmp/project",
        },
      },
    },
    ["sessions/fork"] = { result = { instanceId = "inst-forked" } },
  })

  local callback_err, callback_instance
  require("hyprpilot.rpc.instances").fork(nil, { show = false }, function(err, instance)
    callback_err = err
    callback_instance = instance
  end)

  local fork_call = find_call(calls, "sessions/fork")
  MiniTest.expect.equality(fork_call ~= nil, true)
  MiniTest.expect.equality(fork_call.params.sessionId, "sess-source")
  MiniTest.expect.equality(fork_call.params.agentId, "opencode")
  MiniTest.expect.equality(fork_call.params.profileId, "personal/opencode/default")
  MiniTest.expect.equality(fork_call.params.cwd, "/tmp/project")
  MiniTest.expect.equality(fork_call.opts.timeout_ms, 30000)
  MiniTest.expect.equality(callback_err, nil)
  MiniTest.expect.equality(callback_instance.id, "inst-forked")

  helpers.cleanup_instance("inst-forked")
  restore_client()
  restore_active()
end

T["fork: forwards overrides, with_config, and keeps with_shutdown plugin-side"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["instances/info"] = {
      {
        result = {
          instanceId = "inst-source",
          sessionId = "sess-source",
          agentId = "opencode",
          profileId = "personal/opencode/default",
          cwd = "/tmp/project",
        },
      },
      {
        result = {
          instanceId = "inst-target",
          sessionId = "sess-forked",
          agentId = "claude-code",
          profileId = "personal/claude/opus",
          cwd = "/tmp/override",
        },
      },
    },
    ["sessions/fork"] = { result = { instanceId = "inst-target" } },
  })

  require("hyprpilot.rpc.instances").fork("inst-source", {
    target_instance_id = "inst-target",
    agent_id = "claude-code",
    profile_id = "personal/claude/opus",
    cwd = "/tmp/override",
    show = false,
    with_shutdown = false,
    with_config = {
      { agents = { { id = "claude-code", default = true } } },
    },
  })

  local fork_call = find_call(calls, "sessions/fork")
  MiniTest.expect.equality(fork_call.params.instanceId, "inst-target")
  MiniTest.expect.equality(fork_call.params.agentId, "claude-code")
  MiniTest.expect.equality(fork_call.params.profileId, "personal/claude/opus")
  MiniTest.expect.equality(fork_call.params.cwd, "/tmp/override")
  MiniTest.expect.equality(#fork_call.params.withConfig, 1)
  MiniTest.expect.equality(fork_call.params.with_shutdown, nil)
  MiniTest.expect.equality(fork_call.params.withShutdown, nil)

  local state = require("hyprpilot.instances").get("inst-target")
  MiniTest.expect.equality(state ~= nil, true)
  MiniTest.expect.equality(state.spawned_with_shutdown, false)

  helpers.cleanup_instance("inst-target")
  restore_client()
end

T["fork: resolves missing source session metadata from instance meta fallback"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["instances/info"] = {
      { result = { instanceId = "inst-source", agentId = "opencode" } },
      { result = { instanceId = "inst-forked" } },
    },
    ["instance/snapshot/meta"] = {
      result = {
        sessionId = "sess-meta",
        profileId = "personal/opencode/default",
        cwd = "/tmp/meta",
      },
    },
    ["sessions/fork"] = { result = { instanceId = "inst-forked" } },
  })

  require("hyprpilot.rpc.instances").fork("inst-source", { show = false })

  local meta_call = find_call(calls, "instance/snapshot/meta")
  local fork_call = find_call(calls, "sessions/fork")
  MiniTest.expect.equality(meta_call ~= nil, true)
  MiniTest.expect.equality(meta_call.params.instanceId, "inst-source")
  MiniTest.expect.equality(fork_call.params.sessionId, "sess-meta")
  MiniTest.expect.equality(fork_call.params.profileId, "personal/opencode/default")
  MiniTest.expect.equality(fork_call.params.cwd, "/tmp/meta")

  helpers.cleanup_instance("inst-forked")
  restore_client()
end

T["fork: no active instance warns and never calls sessions/fork"] = function()
  local restore_active = helpers.stub_active_instance(nil)
  local restore_client, calls = helpers.stub_client_with({})

  local callback_err
  require("hyprpilot.rpc.instances").fork(nil, { show = false }, function(err)
    callback_err = err
  end)

  MiniTest.expect.equality(callback_err.message, "no active instance")
  MiniTest.expect.equality(find_call(calls, "sessions/fork"), nil)
  MiniTest.expect.equality(#calls, 0)

  restore_client()
  restore_active()
end

T["fork: source without a session refuses before sessions/fork"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["instances/info"] = { result = { instanceId = "inst-source" } },
    ["instance/snapshot/meta"] = { result = {} },
  })

  local callback_err
  require("hyprpilot.rpc.instances").fork("inst-source", { show = false }, function(err)
    callback_err = err
  end)

  MiniTest.expect.equality(callback_err.message, "no live session to fork")
  MiniTest.expect.equality(find_call(calls, "sessions/fork"), nil)

  restore_client()
end

return T
