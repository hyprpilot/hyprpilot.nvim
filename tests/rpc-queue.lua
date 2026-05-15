--- Behavioural tests for `lua/hyprpilot/rpc/queue.lua` — the
--- daemon-side queue wire surface (queue/list, edit, remove, move,
--- clear, dispatch + instance/snapshot/queue). Stubs `client.request`
--- to capture the wire payload + assert the camelCase translation
--- and field-by-field forwarding.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["list: queue/list translates camelCase items → snake_case"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["queue/list"] = {
      result = {
        items = {
          { id = "i1", text = "first", enqueuedSeq = 1, enqueuedAt = 1000, attachments = { { path = "/tmp/a" } } },
          { id = "i2", text = "second", enqueuedSeq = 2, enqueuedAt = 2000 },
        },
      },
    },
  })

  local seen
  require("hyprpilot.rpc.queue").list("inst-1", function(err, items)
    seen = { err = err, items = items }
  end)

  MiniTest.expect.equality(calls[1].method, "queue/list")
  MiniTest.expect.equality(calls[1].params.instanceId, "inst-1")
  MiniTest.expect.equality(seen.err, nil)
  MiniTest.expect.equality(#seen.items, 2)
  MiniTest.expect.equality(seen.items[1].id, "i1")
  MiniTest.expect.equality(seen.items[1].enqueued_seq, 1)
  MiniTest.expect.equality(seen.items[1].enqueued_at, 1000)
  MiniTest.expect.equality(seen.items[1].attachments[1].path, "/tmp/a")
  MiniTest.expect.equality(seen.items[2].attachments, nil)

  restore_client()
end

T["edit: queue/edit forwards itemId + text + attachments verbatim"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["queue/edit"] = {
      result = { item = { id = "i1", text = "edited", enqueuedSeq = 1, enqueuedAt = 1000 } },
    },
  })

  local seen
  require("hyprpilot.rpc.queue").edit("inst-1", "i1", { text = "edited", attachments = {} }, function(err, item)
    seen = { err = err, item = item }
  end)

  MiniTest.expect.equality(calls[1].method, "queue/edit")
  MiniTest.expect.equality(calls[1].params.instanceId, "inst-1")
  MiniTest.expect.equality(calls[1].params.itemId, "i1")
  MiniTest.expect.equality(calls[1].params.text, "edited")
  MiniTest.expect.equality(#calls[1].params.attachments, 0)
  MiniTest.expect.equality(seen.item.id, "i1")
  MiniTest.expect.equality(seen.item.text, "edited")

  restore_client()
end

T["edit: empty itemId is rejected without firing the wire"] = function()
  local restore_client, calls = helpers.stub_client_with({})

  local seen_err
  require("hyprpilot.rpc.queue").edit("inst-1", "", { text = "x" }, function(err)
    seen_err = err
  end)

  MiniTest.expect.equality(seen_err ~= nil, true)
  MiniTest.expect.equality(#calls, 0)

  restore_client()
end

T["remove: queue/remove returns the daemon's removed boolean"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["queue/remove"] = { result = { removed = true } },
  })

  local seen_removed
  require("hyprpilot.rpc.queue").remove("inst-1", "i1", function(_err, removed)
    seen_removed = removed
  end)

  MiniTest.expect.equality(calls[1].method, "queue/remove")
  MiniTest.expect.equality(calls[1].params.itemId, "i1")
  MiniTest.expect.equality(seen_removed, true)

  restore_client()
end

T["move: queue/move clamps position to >= 0"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["queue/move"] = { result = { moved = true } },
  })

  require("hyprpilot.rpc.queue").move("inst-1", "i1", -5, function() end)

  MiniTest.expect.equality(calls[1].params.position, 0)

  restore_client()
end

T["clear: queue/clear returns the count of cleared items"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["queue/clear"] = { result = { cleared = 3 } },
  })

  local seen_cleared
  require("hyprpilot.rpc.queue").clear("inst-1", function(_err, cleared)
    seen_cleared = cleared
  end)

  MiniTest.expect.equality(calls[1].method, "queue/clear")
  MiniTest.expect.equality(seen_cleared, 3)

  restore_client()
end

T["dispatch: queue/dispatch (no itemId) targets the head"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["queue/dispatch"] = {
      result = {
        item = { id = "i1", text = "first", enqueuedSeq = 1, enqueuedAt = 1000 },
        sessionId = "sess-1",
        accepted = true,
      },
    },
  })

  local seen_result
  require("hyprpilot.rpc.queue").dispatch("inst-1", nil, function(_err, result)
    seen_result = result
  end)

  MiniTest.expect.equality(calls[1].method, "queue/dispatch")
  MiniTest.expect.equality(calls[1].params.instanceId, "inst-1")
  MiniTest.expect.equality(calls[1].params.itemId, nil)
  MiniTest.expect.equality(seen_result.accepted, true)
  MiniTest.expect.equality(seen_result.session_id, "sess-1")
  MiniTest.expect.equality(seen_result.item.id, "i1")

  restore_client()
end

T["snapshot: instance/snapshot/queue requires instance_id"] = function()
  local restore_client, calls = helpers.stub_client_with({})

  local seen_err
  require("hyprpilot.rpc.queue").snapshot("", function(err)
    seen_err = err
  end)

  MiniTest.expect.equality(seen_err ~= nil, true)
  MiniTest.expect.equality(#calls, 0)

  restore_client()
end

T["snapshot: instance/snapshot/queue returns translated items"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["instance/snapshot/queue"] = {
      result = { items = { { id = "i1", text = "x", enqueuedSeq = 1, enqueuedAt = 1 } } },
    },
  })

  local seen
  require("hyprpilot.rpc.queue").snapshot("inst-1", function(_err, items)
    seen = items
  end)

  MiniTest.expect.equality(calls[1].method, "instance/snapshot/queue")
  MiniTest.expect.equality(calls[1].params.instanceId, "inst-1")
  MiniTest.expect.equality(#seen, 1)
  MiniTest.expect.equality(seen[1].id, "i1")

  restore_client()
end

T["items_from_wire: defensive — non-table input → empty list"] = function()
  local rpc_queue = require("hyprpilot.rpc.queue")
  MiniTest.expect.equality(#rpc_queue.items_from_wire(nil), 0)
  MiniTest.expect.equality(#rpc_queue.items_from_wire("not a table"), 0)
end

return T
