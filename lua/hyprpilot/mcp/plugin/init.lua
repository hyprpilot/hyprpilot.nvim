--- Shared plumbing for the `plugin_*` tool categories — integrations
--- that expose a third-party plugin's state to the agent.
---
--- Unlike `lsp` and `editor`, these depend on something the captain may
--- not have installed, so a category registers only when its plugin
--- loads. Registering an absent one logs and skips; it never throws.

local log = require("hyprpilot.log")
local mcp = require("hyprpilot.mcp")

local M = {}

---Require a module, returning nil instead of throwing when it isn't
---installed. Used both to gate a whole category and to gate individual
---tools that need an optional part of a plugin.
---@param modname string
---@return table?
function M.optional(modname)
  local ok, mod = pcall(require, modname)
  if not ok then
    return nil
  end

  return mod
end

---Build a category's `register`, closing over its own bookkeeping so a
---re-register with a smaller `items` list drops the tools that fell out
---of the selection — same override semantics as the built-in
---categories.
---@param tools table<string, hyprpilot.mcp.Tool>
---@param requires string  -- module the category drives; absent = skip
---@return fun(opts?: { items?: string[] })
function M.registrar(tools, requires)
  local registered = {}

  return function(opts)
    opts = opts or {}

    if M.optional(requires) == nil then
      log.info("mcp.plugin: %s is not installed — skipping its tools", requires)
      return
    end

    ---@type table<string, hyprpilot.mcp.Tool>
    local desired = {}
    if opts.items == nil then
      for _, tool in pairs(tools) do
        desired[tool.name] = tool
      end
    else
      for _, name in ipairs(opts.items) do
        local tool = tools[name]
        if tool == nil then
          log.warn("mcp.plugin.register: unknown tool %q for %s", name, requires)
        else
          desired[tool.name] = tool
        end
      end
    end

    local live = mcp._registry()
    for name in pairs(registered) do
      if desired[name] == nil and live[name] ~= nil then
        mcp.unregister(name)
      end
    end

    registered = {}
    for name, tool in pairs(desired) do
      mcp.register(tool)
      registered[name] = true
    end
  end
end

---@param msg string
---@return hyprpilot.mcp.RichResult
function M.err(msg)
  return { is_error = true, text = msg }
end

return M
