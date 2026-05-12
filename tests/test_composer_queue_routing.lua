--- Behavioural tests for `composer.submit`'s queue routing.
--- When the agent is non-idle the submit must park in
--- `composer_queue` instead of firing the wire RPC. When idle,
--- the wire RPC fires as before. `bypass_queue = true` forces the
--- wire RPC regardless of activity (used by the queue strip's
--- "send head now" path).

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

---Mint a composer buffer for the given instance so submit has
---something to read text from. Returns the bufnr.
---@param instance_id string
---@return integer
local function mint_composer_buffer(instance_id)
  local composer = require("hyprpilot.ui.composer")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "hyprpilot://composer/" .. instance_id)
  vim.bo[bufnr].filetype = "hyprpilot_input"
  composer._register_buffer_for_tests(instance_id, bufnr)
  return bufnr
end

T["composer.submit while activity != idle enqueues + no wire call"] = function()
  local restore_active = helpers.stub_active_instance("inst-1")
  local restore_client, calls = helpers.stub_client_with({})
  local queue = require("hyprpilot.composer_queue")
  queue.reset("inst-1")

  local _ = mint_composer_buffer("inst-1")

  -- Force activity to non-idle so submit routes to the queue.
  local status = require("hyprpilot.status")
  status.set_activity({ kind = "streaming" })

  local composer = require("hyprpilot.ui.composer")
  composer.submit("queued prompt", { instance_id = "inst-1" })

  -- No wire RPC fired.
  MiniTest.expect.equality(#calls, 0)
  -- Queue carries the text.
  local items = queue.list("inst-1")
  MiniTest.expect.equality(#items, 1)
  MiniTest.expect.equality(items[1].text, "queued prompt")

  status.set_activity({ kind = "idle" })
  queue.reset("inst-1")
  restore_client()
  restore_active()
end

T["composer.submit while idle fires prompts/send (no queue)"] = function()
  local restore_active = helpers.stub_active_instance("inst-1")
  local restore_client, calls = helpers.stub_client_with({
    ["prompts/send"] = { result = { ok = true } },
  })
  local queue = require("hyprpilot.composer_queue")
  queue.reset("inst-1")

  local _ = mint_composer_buffer("inst-1")

  local status = require("hyprpilot.status")
  status.set_activity({ kind = "idle" })

  require("hyprpilot.ui.composer").submit("ship it", { instance_id = "inst-1" })

  -- Wire fired with the prompt text.
  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].method, "prompts/send")
  MiniTest.expect.equality(calls[1].params.text, "ship it")
  -- Queue stays empty.
  MiniTest.expect.equality(queue.has_items("inst-1"), false)

  queue.reset("inst-1")
  restore_client()
  restore_active()
end

T["composer.submit with bypass_queue=true fires the wire even when busy"] = function()
  local restore_active = helpers.stub_active_instance("inst-1")
  local restore_client, calls = helpers.stub_client_with({
    ["prompts/send"] = { result = { ok = true } },
  })
  local queue = require("hyprpilot.composer_queue")
  queue.reset("inst-1")

  local _ = mint_composer_buffer("inst-1")

  -- Activity is non-idle, but bypass_queue overrides.
  require("hyprpilot.status").set_activity({ kind = "streaming" })

  require("hyprpilot.ui.composer").submit("force send", {
    instance_id = "inst-1",
    bypass_queue = true,
  })

  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].method, "prompts/send")
  MiniTest.expect.equality(calls[1].params.text, "force send")
  MiniTest.expect.equality(queue.has_items("inst-1"), false)

  require("hyprpilot.status").set_activity({ kind = "idle" })
  queue.reset("inst-1")
  restore_client()
  restore_active()
end

T["turn_ended with stopReason=cancelled flushes the queue"] = function()
  local events = require("hyprpilot.chat.events")
  local queue = require("hyprpilot.composer_queue")
  queue.reset("inst-1")

  queue.enqueue("inst-1", { text = "a" })
  queue.enqueue("inst-1", { text = "b" })
  MiniTest.expect.equality(#queue.list("inst-1"), 2)

  -- Drive the cancel-flush path. The events module subscribes to
  -- the daemon notification; instead of running the full client
  -- harness, we hand-craft an `events/changed` payload + invoke
  -- the dispatch listener directly via the on_notification stub
  -- the same way `test_lifecycle_autocmds.lua` does.
  local client = require("hyprpilot.client")
  local original_on_notification = client.on_notification
  local captured
  client.on_notification = function(method, callback)
    if method == "events/changed" then
      captured = callback
    end
    return function() end
  end
  local original_request = client.request
  client.request = function(_m, _p, _o, cb)
    if cb ~= nil then
      cb(nil, {})
    end
  end

  events._reset()
  events.ensure_subscribed()
  client.on_notification = original_on_notification
  client.request = original_request

  MiniTest.expect.equality(captured ~= nil, true)
  captured({
    payload = {
      event = "turn_ended",
      instanceId = "inst-1",
      turnId = "t1",
      stopReason = "cancelled_by_user",
    },
  })

  MiniTest.expect.equality(queue.has_items("inst-1"), false)

  events._reset()
  queue.reset("inst-1")
end

T["turn_ended with non-cancel stopReason leaves the queue alone"] = function()
  local events = require("hyprpilot.chat.events")
  local queue = require("hyprpilot.composer_queue")
  queue.reset("inst-1")

  queue.enqueue("inst-1", { text = "stays" })

  local client = require("hyprpilot.client")
  local original_on_notification = client.on_notification
  local captured
  client.on_notification = function(method, callback)
    if method == "events/changed" then
      captured = callback
    end
    return function() end
  end
  local original_request = client.request
  client.request = function(_m, _p, _o, cb)
    if cb ~= nil then
      cb(nil, {})
    end
  end

  events._reset()
  events.ensure_subscribed()
  client.on_notification = original_on_notification
  client.request = original_request

  captured({
    payload = {
      event = "turn_ended",
      instanceId = "inst-1",
      turnId = "t1",
      stopReason = "end_turn",
    },
  })

  -- Queue survived a clean turn-end.
  MiniTest.expect.equality(#queue.list("inst-1"), 1)

  events._reset()
  queue.reset("inst-1")
end

return T
