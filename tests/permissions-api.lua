--- Behavioural tests for the public `hyprpilot.permissions` Lua API.
--- We stub `client.request` so the tests stay self-contained — no
--- daemon required — and assert on the wire shape we send.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["respond fires permissions/respond with camelCase params"] = function()
  local restore, calls = helpers.stub_client_request()
  local permissions = require("hyprpilot.rpc.permissions")

  permissions.respond("req-1", "allow-once")

  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].method, "permissions/respond")
  MiniTest.expect.equality(calls[1].params.requestId, "req-1")
  MiniTest.expect.equality(calls[1].params.optionId, "allow-once")
  MiniTest.expect.equality(calls[1].params.focus, false)

  restore()
end

T["respond skips invalid input without dispatching"] = function()
  local restore, calls = helpers.stub_client_request()
  local permissions = require("hyprpilot.rpc.permissions")

  permissions.respond("", "allow")
  permissions.respond("req", "")

  MiniTest.expect.equality(#calls, 0)

  restore()
end

T["accept resolves the active permission allow option from anywhere"] = function()
  local restore_active = helpers.stub_active_instance("inst-active")
  local restore_client, calls = helpers.stub_client_request()
  local row = require("hyprpilot.chat.permission-row")
  local permissions = require("hyprpilot.rpc.permissions")

  row.reset()
  row.enqueue("inst-bg", {
    request_id = "req-bg",
    tool = "Bash",
    options = {
      { optionId = "allow-bg", name = "Allow" },
      { optionId = "reject-bg", name = "Reject" },
    },
    allow_option_id = "allow-bg",
    reject_option_id = "reject-bg",
  })
  row.enqueue("inst-active", {
    request_id = "req-active",
    tool = "Bash",
    options = {
      { optionId = "allow-active", name = "Allow" },
      { optionId = "reject-active", name = "Reject" },
    },
    allow_option_id = "allow-active",
    reject_option_id = "reject-active",
  })

  MiniTest.expect.equality(permissions.accept(), true)
  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].method, "permissions/respond")
  MiniTest.expect.equality(calls[1].params.requestId, "req-active")
  MiniTest.expect.equality(calls[1].params.optionId, "allow-active")

  row.reset()
  restore_client()
  restore_active()
end

T["reject resolves the active permission reject option from anywhere"] = function()
  local restore_active = helpers.stub_active_instance("inst-active")
  local restore_client, calls = helpers.stub_client_request()
  local row = require("hyprpilot.chat.permission-row")
  local permissions = require("hyprpilot.rpc.permissions")

  row.reset()
  row.enqueue("inst-active", {
    request_id = "req-active",
    tool = "Bash",
    options = {
      { optionId = "allow-active", name = "Allow" },
      { optionId = "reject-active", name = "Reject" },
    },
    allow_option_id = "allow-active",
    reject_option_id = "reject-active",
  })

  MiniTest.expect.equality(permissions.reject(), true)
  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].method, "permissions/respond")
  MiniTest.expect.equality(calls[1].params.requestId, "req-active")
  MiniTest.expect.equality(calls[1].params.optionId, "reject-active")

  row.reset()
  restore_client()
  restore_active()
end

T["accept and reject skip when no active option id is available"] = function()
  local restore_active = helpers.stub_active_instance("inst-active")
  local restore_client, calls = helpers.stub_client_request()
  local row = require("hyprpilot.chat.permission-row")
  local permissions = require("hyprpilot.rpc.permissions")

  row.reset()
  row.enqueue("inst-active", {
    request_id = "req-active",
    tool = "Bash",
    options = {
      { optionId = "manual", name = "Manual" },
    },
  })

  MiniTest.expect.equality(permissions.accept(), false)
  MiniTest.expect.equality(permissions.reject(), false)
  MiniTest.expect.equality(#calls, 0)

  row.reset()
  restore_client()
  restore_active()
end

T["pending unwraps the daemon's { pending = [...] } envelope"] = function()
  local client = require("hyprpilot.client")
  local original = client.request

  client.request = function(_, _, _, callback)
    callback(nil, { pending = { { requestId = "r1" }, { requestId = "r2" } } })
  end

  local permissions = require("hyprpilot.rpc.permissions")
  local got
  permissions.pending(nil, function(err, pending)
    got = { err = err, pending = pending }
  end)

  MiniTest.expect.equality(got.err, nil)
  MiniTest.expect.equality(#got.pending, 2)
  MiniTest.expect.equality(got.pending[1].requestId, "r1")

  client.request = original
end

T["pending forwards the instance_id filter as instanceId"] = function()
  local restore, calls = helpers.stub_client_request()
  local permissions = require("hyprpilot.rpc.permissions")

  permissions.pending({ instance_id = "inst-1" }, function() end)

  MiniTest.expect.equality(calls[1].method, "permissions/pending")
  MiniTest.expect.equality(calls[1].params.instanceId, "inst-1")

  restore()
end

return T
