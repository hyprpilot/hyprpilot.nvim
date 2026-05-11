--- Behavioural tests for the chat-surface stat-pill formatter.
---
--- These pin the wire-shape contracts the rest of the renderer
--- (`render_pilot_header`, section headers, tool block headers) all
--- rely on. If a new chip variant lands on the daemon side and we
--- want it rendered, that goes here first.

local T = MiniTest.new_set()

T["format_tokens compacts large counts with k/M suffixes"] = function()
  local stats = require("hyprpilot.chat.stats")
  MiniTest.expect.equality(stats.format_tokens(120), "120")
  MiniTest.expect.equality(stats.format_tokens(1234), "1.2k")
  MiniTest.expect.equality(stats.format_tokens(120000), "120k")
  MiniTest.expect.equality(stats.format_tokens(1500000), "1.5M")
  MiniTest.expect.equality(stats.format_tokens(nil), nil)
end

T["format_duration scales ms → s → m+s"] = function()
  local stats = require("hyprpilot.chat.stats")
  MiniTest.expect.equality(stats.format_duration(234), "234ms")
  MiniTest.expect.equality(stats.format_duration(3500), "3.5s")
  MiniTest.expect.equality(stats.format_duration(89000), "1m29s")
end

T["format_cost picks currency symbol; falls back to ISO code"] = function()
  local stats = require("hyprpilot.chat.stats")
  MiniTest.expect.equality(stats.format_cost({ amount = 0.74, currency = "USD" }), "$0.74")
  MiniTest.expect.equality(stats.format_cost({ amount = 1.5, currency = "EUR" }), "€1.50")
  MiniTest.expect.equality(stats.format_cost({ amount = 2, currency = "JPY" }), "JPY2.00")
  MiniTest.expect.equality(stats.format_cost(nil), nil)
end

T["from_wire_stats expands diffs into separate +/- pills"] = function()
  local stats = require("hyprpilot.chat.stats")
  local labels = stats.from_wire_stats({
    { kind = "text", value = "ls -la" },
    { kind = "diff", added = 12, removed = 3 },
    { kind = "duration", ms = 234 },
  })
  -- text → "ls -la"; diff → "+12" and "-3"; duration → "234ms".
  MiniTest.expect.equality(labels[1], "ls -la")
  MiniTest.expect.equality(labels[2], "+12")
  MiniTest.expect.equality(labels[3], "-3")
  MiniTest.expect.equality(labels[4], "234ms")
end

T["from_wire_stats skips zero sides of a diff"] = function()
  local stats = require("hyprpilot.chat.stats")
  local labels = stats.from_wire_stats({ { kind = "diff", added = 4, removed = 0 } })
  MiniTest.expect.equality(#labels, 1)
  MiniTest.expect.equality(labels[1], "+4")
end

T["turn_pills builds tokens · cost · elapsed in that order"] = function()
  local stats = require("hyprpilot.chat.stats")
  local pills = stats.turn_pills({
    started_at_ms = 1000000,
    ended_at_ms = 1003500,
    usage = { used = 120000, size = 200000, cost = { amount = 0.74, currency = "USD" } },
  })
  MiniTest.expect.equality(pills[1], "120k/200k")
  MiniTest.expect.equality(pills[2], "$0.74")
  MiniTest.expect.equality(pills[3], "3.5s")
end

T["turn_pills omits chips that have no data"] = function()
  local stats = require("hyprpilot.chat.stats")
  -- Started + ended only — no usage. Should produce one elapsed chip.
  local pills = stats.turn_pills({ started_at_ms = 1000, ended_at_ms = 1234 })
  MiniTest.expect.equality(#pills, 1)
  MiniTest.expect.equality(pills[1], "234ms")
end

T["format_pills wraps labels in single-space-joined brackets"] = function()
  local stats = require("hyprpilot.chat.stats")
  MiniTest.expect.equality(stats.format_pills({ "120k/200k", "$0.74", "3s" }), " [120k/200k] [$0.74] [3s]")
  MiniTest.expect.equality(stats.format_pills({}), "")
  MiniTest.expect.equality(stats.format_pills(nil), "")
end

return T
