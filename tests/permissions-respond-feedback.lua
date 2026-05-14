--- Tests for `permissions.respond`'s optional feedback param. The
--- daemon currently has `deny_unknown_fields` on `RespondParams`,
--- so the field stays plugin-side until the captain opts in via
--- `config.diff_preview.send_reject_feedback = true` AND the
--- matching daemon PR lands.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["respond w/o opts: only requestId + optionId on the wire (back-compat call shape)"] = function()
  local restore, calls = helpers.stub_client_with({ ["permissions/respond"] = { result = {} } })

  require("hyprpilot.rpc.permissions").respond("req-1", "allow")

  MiniTest.expect.equality(calls[1].method, "permissions/respond")
  MiniTest.expect.equality(calls[1].params.requestId, "req-1")
  MiniTest.expect.equality(calls[1].params.optionId, "allow")
  MiniTest.expect.equality(calls[1].params.feedback, nil)

  restore()
end

T["respond w/ feedback BUT flag OFF: feedback is dropped (would otherwise -32602 daemon-side)"] = function()
  local restore, calls = helpers.stub_client_with({ ["permissions/respond"] = { result = {} } })
  local config = require("hyprpilot.config")
  config.options.diff_preview = config.options.diff_preview or {}
  config.options.diff_preview.send_reject_feedback = false

  require("hyprpilot.rpc.permissions").respond("req-2", "reject", { feedback = "wrong file" })

  MiniTest.expect.equality(calls[1].params.feedback, nil)

  restore()
end

T["respond w/ feedback AND flag ON: feedback rides on the wire"] = function()
  local restore, calls = helpers.stub_client_with({ ["permissions/respond"] = { result = {} } })
  local config = require("hyprpilot.config")
  config.options.diff_preview = config.options.diff_preview or {}
  config.options.diff_preview.send_reject_feedback = true

  require("hyprpilot.rpc.permissions").respond("req-3", "reject", { feedback = "not the right file" })

  MiniTest.expect.equality(calls[1].params.feedback, "not the right file")

  -- Reset flag so other tests aren't infected.
  config.options.diff_preview.send_reject_feedback = false

  restore()
end

T["respond legacy 3-arg shape still works (opts_or_callback as callback)"] = function()
  local restore = helpers.stub_client_with({ ["permissions/respond"] = { result = { ok = true } } })

  local captured
  require("hyprpilot.rpc.permissions").respond("req-legacy", "allow", function(err, result)
    captured = { err = err, result = result }
  end)

  MiniTest.expect.equality(captured.err, nil)
  MiniTest.expect.equality(captured.result.ok, true)

  restore()
end

return T
