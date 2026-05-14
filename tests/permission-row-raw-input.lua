--- Tests for `permission_row.enqueue` raw_input plumbing. The row
--- carries `raw_input` from the wire through to its Entry so the
--- diff preview can read it without re-fetching from the daemon.

local T = MiniTest.new_set()

T["enqueue: raw_input lands on the Entry verbatim"] = function()
  local row = require("hyprpilot.chat.permission-row")
  row.reset()

  row.enqueue("inst-1", {
    request_id = "req-1",
    tool = "Edit",
    tool_kind = "edit",
    options = { { optionId = "allow", name = "Allow" } },
    raw_input = { path = "/tmp/x.lua", old_string = "a", new_string = "b" },
  })

  local entry = row._entry_by_request_id("req-1")
  MiniTest.expect.equality(entry ~= nil, true)
  MiniTest.expect.equality(entry.raw_input.path, "/tmp/x.lua")
  MiniTest.expect.equality(entry.raw_input.old_string, "a")
  MiniTest.expect.equality(entry.raw_input.new_string, "b")

  row.reset()
end

T["_entry_by_request_id returns nil for unknown ids"] = function()
  local row = require("hyprpilot.chat.permission-row")
  row.reset()
  MiniTest.expect.equality(row._entry_by_request_id("nope"), nil)
end

return T
