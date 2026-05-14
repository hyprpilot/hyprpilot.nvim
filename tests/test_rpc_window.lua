--- Behavioural tests for `rpc.window`. Stubs `client.on_notification`
--- to capture subscribed methods + their handlers, then drives the
--- captured handlers and asserts the right `ui.window` function
--- fires with the right params.

local T = MiniTest.new_set()

---Stub `client.on_notification` to capture (method, handler) pairs.
---Returns the restore closure + the capture table.
---@return fun(), table<string, fun(params: any): nil>
local function stub_on_notification()
  local client = require("hyprpilot.client")
  local original = client.on_notification
  local captured = {}
  client.on_notification = function(method, handler)
    captured[method] = handler
    return function() end
  end
  return function()
    client.on_notification = original
  end, captured
end

---Stub a `ui.window` function to record the args it received.
---@param fn_name string
---@return fun(), table
local function stub_ui_window(fn_name)
  local ui_window = require("hyprpilot.ui.window")
  local original = ui_window[fn_name]
  local calls = {}
  ui_window[fn_name] = function(...)
    table.insert(calls, { ... })
  end
  return function()
    ui_window[fn_name] = original
  end, calls
end

T["rpc.window.register: subscribes the four nvim/* notification methods"] = function()
  local restore_on, captured = stub_on_notification()

  require("hyprpilot.rpc.window").register()

  MiniTest.expect.equality(type(captured["nvim/focus"]), "function")
  MiniTest.expect.equality(type(captured["nvim/toggle"]), "function")
  MiniTest.expect.equality(type(captured["nvim/show"]), "function")
  MiniTest.expect.equality(type(captured["nvim/hide"]), "function")

  restore_on()
end

T["rpc.window: nvim/focus handler forwards params to ui.window.focus"] = function()
  local restore_on, captured = stub_on_notification()
  local restore_focus, focus_calls = stub_ui_window("focus")

  require("hyprpilot.rpc.window").register()
  captured["nvim/focus"]({ target = "chat" })

  MiniTest.expect.equality(#focus_calls, 1)
  MiniTest.expect.equality(focus_calls[1][1].target, "chat")

  restore_focus()
  restore_on()
end

T["rpc.window: nvim/show extracts instanceId from camelCase params"] = function()
  local restore_on, captured = stub_on_notification()
  local restore_show, show_calls = stub_ui_window("show")

  require("hyprpilot.rpc.window").register()
  captured["nvim/show"]({ instanceId = "inst-7" })

  MiniTest.expect.equality(#show_calls, 1)
  MiniTest.expect.equality(show_calls[1][1], "inst-7")

  restore_show()
  restore_on()
end

T["rpc.window: nvim/toggle + nvim/hide forward to ui.window without params"] = function()
  local restore_on, captured = stub_on_notification()
  local restore_toggle, toggle_calls = stub_ui_window("toggle")
  local restore_hide, hide_calls = stub_ui_window("hide")

  require("hyprpilot.rpc.window").register()
  captured["nvim/toggle"](nil)
  captured["nvim/hide"](nil)

  MiniTest.expect.equality(#toggle_calls, 1)
  MiniTest.expect.equality(#hide_calls, 1)

  restore_toggle()
  restore_hide()
  restore_on()
end

return T
