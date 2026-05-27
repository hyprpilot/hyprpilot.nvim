--- Behavioural tests for layout-manager cooperation. Edgy is allowed
--- to adopt hyprpilot windows. Initial sizing is seeded once so Edgy
--- does not equalize auxiliary rows, while plugin-driven dynamic
--- resizing stays opt-in so layout passes do not steal focus/cursor
--- during ordinary edits.

local T = MiniTest.new_set()

T["edgy layout nudge is disabled by default and enabled by config"] = function()
  local buffer = require("hyprpilot.chat.buffer")
  local config = require("hyprpilot.config")

  local original_edgy = package.loaded["edgy"]
  local original_edgy_layout = package.loaded["edgy.layout"]
  local original_ui = vim.deepcopy(config.options.ui)
  local calls = 0

  package.loaded["edgy"] = {}
  package.loaded["edgy.layout"] = {
    layout = function()
      calls = calls + 1
    end,
  }

  config.options.ui.auto_resize_with_layout_manager = false
  buffer.nudge_edgy_layout()
  vim.wait(150)
  MiniTest.expect.equality(calls, 0)

  config.options.ui.auto_resize_with_layout_manager = true
  buffer.nudge_edgy_layout()
  vim.wait(200, function()
    return calls == 1
  end)
  MiniTest.expect.equality(calls, 1)

  config.options.ui = original_ui
  package.loaded["edgy"] = original_edgy
  package.loaded["edgy.layout"] = original_edgy_layout
end

T["edgy initial sizing can force one adoption layout"] = function()
  local buffer = require("hyprpilot.chat.buffer")
  local config = require("hyprpilot.config")

  local original_edgy = package.loaded["edgy"]
  local original_edgy_layout = package.loaded["edgy.layout"]
  local original_ui = vim.deepcopy(config.options.ui)
  local calls = 0
  local winid = vim.api.nvim_get_current_win()

  package.loaded["edgy"] = {}
  package.loaded["edgy.layout"] = {
    layout = function()
      calls = calls + 1
    end,
  }

  config.options.ui.auto_resize_with_layout_manager = false
  buffer.set_layout_manager_height(winid, 7)
  MiniTest.expect.equality(vim.w[winid].edgy_height, 7)

  buffer.nudge_edgy_layout({ force = true })
  vim.wait(200, function()
    return calls == 1
  end)
  MiniTest.expect.equality(calls, 1)

  vim.w[winid].edgy_height = nil
  config.options.ui = original_ui
  package.loaded["edgy"] = original_edgy
  package.loaded["edgy.layout"] = original_edgy_layout
end

return T
