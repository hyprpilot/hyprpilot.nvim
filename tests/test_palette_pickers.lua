--- Behavioural tests for the picker resolver. The snacks path
--- requires `Snacks.picker.pick` to exist at runtime (it doesn't in
--- our headless test env), so we only assert the resolution +
--- vim.ui.select fall-back behaviour here; the snacks integration
--- gets exercised by manual smoke against a real captain setup.

local T = MiniTest.new_set()

---@return fun(), table[]
local function stub_ui_select()
  local original = vim.ui.select
  local invocations = {}
  vim.ui.select = function(items, opts, callback)
    table.insert(invocations, { items = items, opts = opts })
    callback(items[1])
  end
  return function()
    vim.ui.select = original
  end, invocations
end

T["pickers.open: vim.ui.select setting routes through native picker, drops preview"] = function()
  local config = require("hyprpilot.config")
  local original = config.options.palettes
  config.options.palettes = { picker = "vim.ui.select" }

  local restore_select, invocations = stub_ui_select()

  local picked
  require("hyprpilot.palettes.pickers").open({
    items = { { id = "a" }, { id = "b" } },
    title = "test",
    kind = "hyprpilot.test",
    format_item = function(item)
      return item.id
    end,
    preview = function()
      return { "should not run under vim.ui.select" }
    end,
    on_pick = function(choice)
      picked = choice
    end,
  })

  MiniTest.expect.equality(#invocations, 1)
  MiniTest.expect.equality(invocations[1].opts.prompt, "test")
  MiniTest.expect.equality(invocations[1].opts.kind, "hyprpilot.test")
  MiniTest.expect.equality(picked.id, "a")

  restore_select()
  config.options.palettes = original
end

T["pickers.open: auto without snacks falls back to vim.ui.select"] = function()
  local config = require("hyprpilot.config")
  local original = config.options.palettes
  config.options.palettes = { picker = "auto" }

  local restore_select, invocations = stub_ui_select()

  require("hyprpilot.palettes.pickers").open({
    items = { "x" },
    title = "fallback",
    kind = "hyprpilot.test",
    format_item = function(item)
      return tostring(item)
    end,
    on_pick = function() end,
  })

  -- snacks.picker isn't installed in this test env; resolver picks
  -- vim.ui.select as the auto fallback.
  MiniTest.expect.equality(#invocations, 1)

  restore_select()
  config.options.palettes = original
end

T["pickers.open: cancel (callback(nil)) does NOT invoke on_pick"] = function()
  local original_select = vim.ui.select
  vim.ui.select = function(_items, _opts, callback)
    callback(nil)
  end

  local commits = 0
  require("hyprpilot.palettes.pickers").open({
    items = { "x" },
    title = "cancel",
    kind = "hyprpilot.test",
    format_item = function()
      return ""
    end,
    on_pick = function()
      commits = commits + 1
    end,
  })

  MiniTest.expect.equality(commits, 0)

  vim.ui.select = original_select
end

return T
