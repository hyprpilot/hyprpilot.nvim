--- Behavioural tests for the MCP registry surface
--- (`hyprpilot.mcp`). The registry no longer gates on a config flag
--- (`mcp.enabled` was removed because the captain wires categories
--- explicitly); empty registry → `list()` returns empty.

local T = MiniTest.new_set()

T["register: well-formed tool lands in list()"] = function()
  local mcp = require("hyprpilot.mcp")
  mcp._reset()

  mcp.register({
    name = "demo_one",
    description = "Demo tool one.",
    schema = { type = "object", additionalProperties = false },
    handler = function()
      return { text = "hi" }
    end,
  })

  local listed = mcp.list()
  MiniTest.expect.equality(#listed, 1)
  MiniTest.expect.equality(listed[1].name, "demo_one")
  MiniTest.expect.equality(listed[1].description, "Demo tool one.")

  mcp._reset()
end

T["register: invalid tool logs and skips, doesn't throw"] = function()
  local mcp = require("hyprpilot.mcp")
  mcp._reset()

  -- Bad name pattern, missing description, no handler — three different
  -- validation failures. None should throw.
  mcp.register({ name = "BAD-Name", description = "x", schema = { type = "object" }, handler = function() end })
  mcp.register({ name = "demo_two", schema = { type = "object" }, handler = function() end })
  mcp.register({ name = "demo_three", description = "x", schema = { type = "object" } })

  MiniTest.expect.equality(#mcp.list(), 0)
  mcp._reset()
end

T["call: dispatches to the registered handler with args"] = function()
  local mcp = require("hyprpilot.mcp")
  mcp._reset()

  local captured
  mcp.register({
    name = "demo_capture",
    description = "captures args",
    schema = { type = "object", additionalProperties = true },
    handler = function(args)
      captured = args
      return { json = { ok = true } }
    end,
  })

  local result = mcp.call("demo_capture", { foo = "bar", n = 42 })
  MiniTest.expect.equality(captured.foo, "bar")
  MiniTest.expect.equality(captured.n, 42)
  MiniTest.expect.equality(result.json.ok, true)

  mcp._reset()
end

T["unregister: drops the named tool from list()"] = function()
  local mcp = require("hyprpilot.mcp")
  mcp._reset()

  mcp.register({
    name = "demo_drop",
    description = "x",
    schema = { type = "object" },
    handler = function() end,
  })
  MiniTest.expect.equality(#mcp.list(), 1)

  mcp.unregister("demo_drop")
  MiniTest.expect.equality(#mcp.list(), 0)

  mcp._reset()
end

T["list() with empty registry returns an empty list (no mcp.enabled gate)"] = function()
  local mcp = require("hyprpilot.mcp")
  mcp._reset()

  MiniTest.expect.equality(#mcp.list(), 0)
end

return T
