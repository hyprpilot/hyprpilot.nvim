--- Behavioural tests for `palettes.attention`. Seeds the attention
--- list, drives the picker with stubbed `vim.ui.select`, and asserts
--- the default on-pick action invokes `window.switch` +
--- `ui.window.focus({ target = "chat" })`.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

local function fresh_attention()
  local attention = require("hyprpilot.notification.attention")
  local instances = require("hyprpilot.instances")
  instances._reset()
  attention._reset()

  return attention
end

---Stub `window.switch` + `ui.window.focus` to record their calls.
---@return fun(), table, table
local function stub_actions()
  local window = require("hyprpilot.chat.window")
  local ui_window = require("hyprpilot.ui.window")
  local switch_calls = {}
  local focus_calls = {}
  local original_switch = window.switch
  local original_focus = ui_window.focus
  window.switch = function(id)
    table.insert(switch_calls, id)
  end
  ui_window.focus = function(opts)
    table.insert(focus_calls, opts)
  end
  return function()
    window.switch = original_switch
    ui_window.focus = original_focus
  end, switch_calls, focus_calls
end

T["palettes.attention: empty list → warn + no picker"] = function()
  fresh_attention()
  local restore_select, ui_calls = helpers.stub_ui_select(function() end)

  require("hyprpilot.palettes.attention").open({ picker = "vim.ui.select" })

  MiniTest.expect.equality(#ui_calls, 0)
  restore_select()
end

T["palettes.attention: pick → switch + focus chat"] = function()
  local attention = fresh_attention()
  local instances = require("hyprpilot.instances")
  instances.register({ instance_id = "inst-1", bufnr = 42 })
  instances.register({ instance_id = "inst-2", bufnr = 43 })
  attention._add_permission("inst-1", 42, "req-1")
  attention._add_turn_ended("inst-2", 43)

  local restore_actions, switch_calls, focus_calls = stub_actions()
  local restore_select, ui_calls = helpers.stub_ui_select(function(items)
    return items[2]
  end)

  require("hyprpilot.palettes.attention").open({ picker = "vim.ui.select" })

  MiniTest.expect.equality(#ui_calls, 1)
  MiniTest.expect.equality(ui_calls[1].opts.kind, "hyprpilot.attention")
  MiniTest.expect.equality(#ui_calls[1].items, 2)

  MiniTest.expect.equality(switch_calls[1], "inst-2")
  MiniTest.expect.equality(focus_calls[1].target, "chat")

  restore_select()
  restore_actions()
end

T["palettes.attention: on_pick override receives the full entry"] = function()
  local attention = fresh_attention()
  require("hyprpilot.instances").register({ instance_id = "inst-7", bufnr = 42 })
  attention._add_permission("inst-7", 42, "req-7")

  local picked
  local restore_select = helpers.stub_ui_select(function(items)
    return items[1]
  end)

  require("hyprpilot.palettes.attention").open({
    picker = "vim.ui.select",
    on_pick = function(entry)
      picked = entry
    end,
  })

  MiniTest.expect.equality(picked.instance_id, "inst-7")
  MiniTest.expect.equality(picked.request_id, "req-7")
  MiniTest.expect.equality(picked.kind, "permission")

  restore_select()
end

return T
