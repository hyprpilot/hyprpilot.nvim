--- Tests for the cwd filter on `palettes.instances.open`. Mirrors
--- the `palettes/sessions.lua` shape: nil → vim cwd default, false →
--- no filter, string → that path. Filter operates against the wire
--- payload's `item.cwd` (the daemon ships it on `instances/list`).

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

--- Wire shape — `instances/list` reply with three rows in three cwds.
local function three_cwd_reply()
  return {
    result = {
      instances = {
        { instanceId = "inst-a", agentId = "claude-code", cwd = "/tmp/proj-a" },
        { instanceId = "inst-b", agentId = "claude-code", cwd = "/tmp/proj-b" },
        { instanceId = "inst-c", agentId = "claude-code", cwd = "/tmp/proj-a" },
      },
    },
  }
end

--- Stub `vim.fn.getcwd` to a fixed string so the default-filter
--- case isn't sensitive to where the test runner runs from. Avoids
--- creating real directories under `/tmp` for the test.
local function stub_getcwd(path)
  local original = vim.fn.getcwd
  vim.fn.getcwd = function()
    return path
  end
  return function()
    vim.fn.getcwd = original
  end
end

T["palettes.instances: default cwd filter restricts to vim cwd"] = function()
  local restore_client = helpers.stub_client_with({
    ["instances/list"] = three_cwd_reply(),
  })
  local restore_cwd = stub_getcwd("/tmp/proj-a")
  local restore_select, ui_calls = helpers.stub_ui_select(function() end)

  require("hyprpilot.palettes.instances").open({ picker = "vim.ui.select" })

  -- Picker should see only the two rows whose cwd matches.
  MiniTest.expect.equality(#ui_calls, 1)
  MiniTest.expect.equality(#ui_calls[1].items, 2)
  local ids = {}
  for _, item in ipairs(ui_calls[1].items) do
    table.insert(ids, item.id)
  end
  table.sort(ids)
  MiniTest.expect.equality(ids[1], "inst-a")
  MiniTest.expect.equality(ids[2], "inst-c")

  restore_select()
  restore_cwd()
  restore_client()
end

T["palettes.instances: opts.cwd = false disables the filter"] = function()
  local restore_client = helpers.stub_client_with({
    ["instances/list"] = three_cwd_reply(),
  })
  local restore_select, ui_calls = helpers.stub_ui_select(function() end)

  require("hyprpilot.palettes.instances").open({ picker = "vim.ui.select", cwd = false })

  MiniTest.expect.equality(#ui_calls[1].items, 3)

  restore_select()
  restore_client()
end

T["palettes.instances: opts.cwd = '<path>' filters by that path"] = function()
  local restore_client = helpers.stub_client_with({
    ["instances/list"] = three_cwd_reply(),
  })
  local restore_select, ui_calls = helpers.stub_ui_select(function() end)

  require("hyprpilot.palettes.instances").open({ picker = "vim.ui.select", cwd = "/tmp/proj-b" })

  MiniTest.expect.equality(#ui_calls[1].items, 1)
  MiniTest.expect.equality(ui_calls[1].items[1].id, "inst-b")

  restore_select()
  restore_client()
end

T["palettes.instances: filter against a cwd nothing matches → no picker, warn-only"] = function()
  local restore_client = helpers.stub_client_with({
    ["instances/list"] = three_cwd_reply(),
  })
  local restore_select, ui_calls = helpers.stub_ui_select(function() end)

  require("hyprpilot.palettes.instances").open({ picker = "vim.ui.select", cwd = "/nowhere" })

  -- Filter dropped every row → palette warns and skips opening the
  -- picker. (We don't assert the warn message; just that no picker
  -- launched against an empty list.)
  MiniTest.expect.equality(#ui_calls, 0)

  restore_select()
  restore_client()
end

return T
