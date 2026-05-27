local T = MiniTest.new_set()

T["classify accepts legacy string and structured kinds"] = function()
  local tool_kind = require("hyprpilot.tool_kind")

  MiniTest.expect.equality(tool_kind.classify("execute"), "execute")
  MiniTest.expect.equality(tool_kind.classify({ type = "edit" }), "edit")
  MiniTest.expect.equality(tool_kind.classify({}), nil)
end

T["label renders mcp server/tool"] = function()
  local tool_kind = require("hyprpilot.tool_kind")

  MiniTest.expect.equality(tool_kind.label({ type = "mcp", server = "memory", tool = "read_graph" }), "memory/read_graph")
  MiniTest.expect.equality(tool_kind.label({ type = "execute" }), "execute")
end

return T
