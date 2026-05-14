--- Behavioural tests for `composer.cancel`. The daemon's
--- `prompts/cancel` is request-shaped (`HandlerOutcome::Reply` in
--- `rpc/handlers/prompts.rs`) so the wire payload MUST carry a
--- JSON-RPC `id` — sending it as a notification gets back `id: null`
--- + `-32600 "missing or invalid id"` and the captain's <C-c>
--- silently no-ops.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["composer.cancel: sends prompts/cancel as a request (with id), not a notification"] = function()
  local restore_active = helpers.stub_active_instance("inst-cancel")
  local restore_client, calls = helpers.stub_client_with({
    ["prompts/cancel"] = { result = {} },
  })

  require("hyprpilot.ui.composer").cancel()

  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].method, "prompts/cancel")
  MiniTest.expect.equality(calls[1].params.instanceId, "inst-cancel")

  restore_client()
  restore_active()
end

T["composer.cancel: no active instance → warns + no RPC fired"] = function()
  local restore_active = helpers.stub_active_instance(nil)
  local restore_client, calls = helpers.stub_client_with({})

  require("hyprpilot.ui.composer").cancel()

  MiniTest.expect.equality(#calls, 0)

  restore_client()
  restore_active()
end

return T
