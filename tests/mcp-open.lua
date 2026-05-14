--- Behavioural tests for `hyprpilot.mcp.open`. Stubs `vim.ui.open`
--- so the tests don't actually launch the captain's browser.

local T = MiniTest.new_set()

T["register_all: open_url lands in the registry"] = function()
  local mcp = require("hyprpilot.mcp")
  local open = require("hyprpilot.mcp.open")
  mcp._reset()

  open.register_all()

  local listed = mcp.list()
  MiniTest.expect.equality(#listed, 1)
  MiniTest.expect.equality(listed[1].name, "open_url")

  mcp._reset()
end

T["open_url: dispatches the target via vim.ui.open"] = function()
  local original = vim.ui.open
  local captured
  vim.ui.open = function(target)
    captured = target
    return { pid = 1234 } -- mock SystemObj
  end

  local open = require("hyprpilot.mcp.open")
  local result = open.tools.url.handler({ target = "https://example.com" })

  MiniTest.expect.equality(captured, "https://example.com")
  MiniTest.expect.equality(result.text:find("opened", 1, true) ~= nil, true)

  vim.ui.open = original
end

T["open_url: empty target → is_error result"] = function()
  local open = require("hyprpilot.mcp.open")
  local result = open.tools.url.handler({ target = "" })
  MiniTest.expect.equality(result.is_error, true)
end

T["open_url: vim.ui.open returning nil → is_error result"] = function()
  local original = vim.ui.open
  vim.ui.open = function()
    return nil
  end

  local open = require("hyprpilot.mcp.open")
  local result = open.tools.url.handler({ target = "https://example.com" })
  MiniTest.expect.equality(result.is_error, true)

  vim.ui.open = original
end

return T
