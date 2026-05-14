--- Behavioural tests for the per-instance composer submit queue.
--- Covers enqueue / pop_head / remove / flush / reset semantics +
--- the subscriber-notification path that the queue strip relies on.

local T = MiniTest.new_set()

T["enqueue + list + has_items"] = function()
  local q = require("hyprpilot.composer.queue")
  q.reset("inst-1")

  MiniTest.expect.equality(q.has_items("inst-1"), false)
  MiniTest.expect.equality(#q.list("inst-1"), 0)

  local a = q.enqueue("inst-1", { text = "first" })
  local b = q.enqueue("inst-1", { text = "second" })

  MiniTest.expect.equality(q.has_items("inst-1"), true)
  MiniTest.expect.equality(#q.list("inst-1"), 2)
  MiniTest.expect.equality(q.list("inst-1")[1].id, a.id)
  MiniTest.expect.equality(q.list("inst-1")[2].id, b.id)
  MiniTest.expect.equality(q.list("inst-1")[1].text, "first")

  q.reset("inst-1")
end

T["pop_head returns FIFO order, nil when empty"] = function()
  local q = require("hyprpilot.composer.queue")
  q.reset("inst-1")

  q.enqueue("inst-1", { text = "a" })
  q.enqueue("inst-1", { text = "b" })

  local head = q.pop_head("inst-1")
  MiniTest.expect.equality(head.text, "a")
  MiniTest.expect.equality(#q.list("inst-1"), 1)
  MiniTest.expect.equality(q.list("inst-1")[1].text, "b")

  MiniTest.expect.equality(q.pop_head("inst-1").text, "b")
  MiniTest.expect.equality(q.pop_head("inst-1"), nil)

  q.reset("inst-1")
end

T["pop_by_id removes a specific entry + reports its original position"] = function()
  local q = require("hyprpilot.composer.queue")
  q.reset("inst-1")

  q.enqueue("inst-1", { text = "x" })
  local target = q.enqueue("inst-1", { text = "y" })
  q.enqueue("inst-1", { text = "z" })

  local entry, pos = q.pop_by_id("inst-1", target.id)
  MiniTest.expect.equality(entry.text, "y")
  MiniTest.expect.equality(pos, 2)
  MiniTest.expect.equality(#q.list("inst-1"), 2)
  MiniTest.expect.equality(q.list("inst-1")[2].text, "z")

  q.reset("inst-1")
end

T["insert_at preserves order on edit roundtrip"] = function()
  local q = require("hyprpilot.composer.queue")
  q.reset("inst-1")

  q.enqueue("inst-1", { text = "a" })
  q.enqueue("inst-1", { text = "b" })
  q.enqueue("inst-1", { text = "c" })

  -- Pop "b" (position 2), re-insert at the same slot with new
  -- text — simulates the edit-then-resubmit round trip.
  local entry, pos = q.pop_by_id("inst-1", q.list("inst-1")[2].id)
  MiniTest.expect.equality(entry.text, "b")
  q.insert_at("inst-1", pos, { text = "b-edited" })

  local items = q.list("inst-1")
  MiniTest.expect.equality(#items, 3)
  MiniTest.expect.equality(items[1].text, "a")
  MiniTest.expect.equality(items[2].text, "b-edited")
  MiniTest.expect.equality(items[3].text, "c")

  q.reset("inst-1")
end

T["flush drops every entry for an instance but leaves others alone"] = function()
  local q = require("hyprpilot.composer.queue")
  q.reset("inst-1")
  q.reset("inst-2")

  q.enqueue("inst-1", { text = "a" })
  q.enqueue("inst-1", { text = "b" })
  q.enqueue("inst-2", { text = "x" })

  q.flush("inst-1")

  MiniTest.expect.equality(q.has_items("inst-1"), false)
  MiniTest.expect.equality(q.has_items("inst-2"), true)
  MiniTest.expect.equality(q.list("inst-2")[1].text, "x")

  q.reset("inst-1")
  q.reset("inst-2")
end

T["on_change fires synchronously on enqueue / pop / flush / reset"] = function()
  local q = require("hyprpilot.composer.queue")
  q.reset("inst-1")

  local hits = {}
  local unsub = q.on_change(function(id)
    table.insert(hits, id)
  end)

  q.enqueue("inst-1", { text = "a" })
  q.pop_head("inst-1")
  q.enqueue("inst-1", { text = "b" })
  q.flush("inst-1")
  q.reset("inst-1")

  -- enqueue + pop + enqueue + flush + reset = 5 notifications.
  MiniTest.expect.equality(#hits, 5)
  MiniTest.expect.equality(hits[1], "inst-1")

  unsub()
  q.reset("inst-1")
end

T["on_change unsubscribe stops fanout"] = function()
  local q = require("hyprpilot.composer.queue")
  q.reset("inst-1")

  local hits = 0
  local unsub = q.on_change(function()
    hits = hits + 1
  end)
  q.enqueue("inst-1", { text = "a" })
  unsub()
  q.enqueue("inst-1", { text = "b" })

  MiniTest.expect.equality(hits, 1)

  q.reset("inst-1")
end

return T
