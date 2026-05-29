--- Tests for `permission_row.enqueue` raw_input plumbing. The row
--- carries `raw_input` from the wire through to its Entry so the
--- diff preview can read it without re-fetching from the daemon.

local T = MiniTest.new_set()
local helpers = require("tests.helpers")

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

T["enqueue: live content diff blocks land on the Entry verbatim"] = function()
  local row = require("hyprpilot.chat.permission-row")
  row.reset()

  row.enqueue("inst-1", {
    request_id = "req-content",
    tool = "Edit",
    tool_kind = "edit",
    options = { { optionId = "allow", name = "Allow" } },
    content = { { type = "diff", path = "/tmp/x.lua", oldText = "a", newText = "b" } },
  })

  local entry = row._entry_by_request_id("req-content")
  MiniTest.expect.equality(entry ~= nil, true)
  MiniTest.expect.equality(entry.content[1].type, "diff")
  MiniTest.expect.equality(entry.content[1].oldText, "a")

  row.reset()
end

T["_entry_by_request_id returns nil for unknown ids"] = function()
  local row = require("hyprpilot.chat.permission-row")
  row.reset()
  MiniTest.expect.equality(row._entry_by_request_id("nope"), nil)
end

T["render: diffable entries show the configured diff key hint"] = function()
  require("hyprpilot.config").setup({})
  local row = require("hyprpilot.chat.permission-row")
  row.reset()
  local restore_active = helpers.stub_active_instance("inst-1")
  local previous_localleader = vim.g.maplocalleader
  vim.g.maplocalleader = "\\"

  row.enqueue("inst-1", {
    request_id = "req-diff",
    tool = "Edit",
    tool_kind = "edit",
    options = { { optionId = "allow", name = "Allow" } },
    raw_input = { path = "/tmp/x.lua", old_string = "a", new_string = "b" },
  })
  row.refresh()

  local lines = vim.api.nvim_buf_get_lines(row._bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "[ Diff: \\o ]"), true)

  row.reset()
  restore_active()
  vim.g.maplocalleader = previous_localleader
end

T["render: diff hint is hidden when the diff keymap is disabled"] = function()
  require("hyprpilot.config").setup({ permission_row = { keymaps = { show_diff = false } } })
  local row = require("hyprpilot.chat.permission-row")
  row.reset()
  local restore_active = helpers.stub_active_instance("inst-1")

  row.enqueue("inst-1", {
    request_id = "req-diff-disabled",
    tool = "Edit",
    tool_kind = "edit",
    options = { { optionId = "allow", name = "Allow" } },
    raw_input = { path = "/tmp/x.lua", old_string = "a", new_string = "b" },
  })
  row.refresh()

  local lines = vim.api.nvim_buf_get_lines(row._bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "Diff:"), false)

  row.reset()
  restore_active()
  require("hyprpilot.config").setup({})
end

return T
