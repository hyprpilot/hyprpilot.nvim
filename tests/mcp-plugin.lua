--- Behavioural tests for the `plugin_*` categories. The test
--- environment has none of the third-party plugins installed, which is
--- the case that matters most: registering a category whose plugin is
--- absent must skip quietly rather than throwing at the captain's
--- startup. Tool specs are asserted directly off `M.tools`, which needs
--- no plugin loaded.

local T = MiniTest.new_set()

-- Module names mirror each plugin's git repo name, minus a trailing
-- `.nvim`; tool prefixes are the same with `-` as `_`.
local CATEGORIES = { "diffview", "neotest", "nvim-dap", "nvim-coverage", "todo-comments" }

T["register: a category whose plugin is absent registers nothing and doesn't throw"] = function()
  local mcp = require("hyprpilot.mcp")

  for _, name in ipairs(CATEGORIES) do
    mcp._reset()
    local category = require("hyprpilot.mcp.plugin." .. name)

    -- No third-party plugins in the test runtime, so every one of these
    -- takes the skip path.
    category.register()

    MiniTest.expect.equality(#mcp.list(), 0, name .. ": expected no tools registered")
  end

  mcp._reset()
end

T["every plugin tool is named plugin_* with a description and object schema"] = function()
  for _, name in ipairs(CATEGORIES) do
    local category = require("hyprpilot.mcp.plugin." .. name)
    MiniTest.expect.equality(next(category.tools) ~= nil, true, name .. ": expected at least one tool")

    for key, tool in pairs(category.tools) do
      local label = name .. "." .. key
      MiniTest.expect.equality(tool.name:sub(1, 7), "plugin_", label .. ": name must start with plugin_")
      MiniTest.expect.equality(tool.name:match("^[a-z][a-z0-9_]*$") ~= nil, true, label .. ": name must match the registry pattern")
      MiniTest.expect.equality(type(tool.description) == "string" and tool.description ~= "", true, label .. ": needs a description")
      MiniTest.expect.equality(tool.schema.type, "object", label .. ": schema.type must be object")
      MiniTest.expect.equality(type(tool.handler), "function", label .. ": handler must be a function")
    end
  end
end

T["tool names are unique across every plugin category"] = function()
  local seen = {}
  for _, name in ipairs(CATEGORIES) do
    for _, tool in pairs(require("hyprpilot.mcp.plugin." .. name).tools) do
      MiniTest.expect.equality(seen[tool.name], nil, "duplicate tool name: " .. tool.name)
      seen[tool.name] = name
    end
  end
end

T["plugin.optional: returns nil for a missing module, the module otherwise"] = function()
  local plugin = require("hyprpilot.mcp.plugin")

  MiniTest.expect.equality(plugin.optional("hyprpilot-nothing-here"), nil)
  MiniTest.expect.equality(type(plugin.optional("hyprpilot.mcp")), "table")
end

T["registrar: registers, then drops tools that fall out of items on re-register"] = function()
  local mcp = require("hyprpilot.mcp")
  local plugin = require("hyprpilot.mcp.plugin")
  mcp._reset()

  local tools = {
    one = {
      name = "plugin_fake_one",
      description = "First fake tool.",
      schema = { type = "object" },
      handler = function()
        return { json = {} }
      end,
    },
    two = {
      name = "plugin_fake_two",
      description = "Second fake tool.",
      schema = { type = "object" },
      handler = function()
        return { json = {} }
      end,
    },
  }

  -- `hyprpilot.mcp` is always loadable, so it stands in for an
  -- installed plugin and the registrar takes its normal path.
  local register = plugin.registrar(tools, "hyprpilot.mcp")

  register()
  MiniTest.expect.equality(#mcp.list(), 2)

  register({ items = { "one" } })
  local names = {}
  for _, t in ipairs(mcp.list()) do
    names[t.name] = true
  end
  MiniTest.expect.equality(names["plugin_fake_one"], true)
  MiniTest.expect.equality(names["plugin_fake_two"], nil)

  mcp._reset()
end

return T
