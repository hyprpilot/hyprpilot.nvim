--- Lua-side MCP tool registry. Captain registers Lua tools here; the
--- Python MCP server (`hyprpilot-nvim-mcp`) queries `list()` at boot
--- and round-trips `call(name, args)` for every agent invocation.
---
--- This module is independent of the chat surface — captains who only
--- want the MCP-bridge half can `register({...})` without ever calling
--- `require("hyprpilot").setup({})`.

local config = require("hyprpilot.config")
local log = require("hyprpilot.log")

local M = {}

---@class hyprpilot.mcp.Tool
---@field name string                       -- final segment; agent sees `mcp__neovim__<name>`. Validated `^[a-z][a-z0-9_]*$`.
---@field description string                -- one-liner the agent reads to decide when to call. Required.
---@field schema hyprpilot.mcp.ToolSchema   -- JSON Schema for input args. Required (use `{ type = "object" }` for no args).
---@field handler hyprpilot.mcp.ToolHandler -- function the agent invokes via `call(name, args)`.

---@class hyprpilot.mcp.ToolSchema
---@field type "object"                     -- v1 supports object inputs only
---@field properties? table<string, hyprpilot.mcp.SchemaProperty>
---@field required? string[]
---@field additionalProperties? boolean

---@class hyprpilot.mcp.SchemaProperty
---@field type "string" | "integer" | "number" | "boolean" | "array" | "object"
---@field description? string
---@field enum? any[]
---@field items? hyprpilot.mcp.SchemaProperty   -- for arrays

---@alias hyprpilot.mcp.ToolHandler fun(args: table): hyprpilot.mcp.ToolResult

---@alias hyprpilot.mcp.ToolResult string | table | hyprpilot.mcp.RichResult

---@class hyprpilot.mcp.RichResult
---@field text? string                      -- plain text payload
---@field json? table                       -- structured payload (auto-encoded by the Python side)
---@field is_error? boolean                 -- mark result as error without throwing

---@class hyprpilot.mcp.ToolSummary
---@field name string
---@field description string
---@field schema hyprpilot.mcp.ToolSchema

local NAME_PATTERN = "^[a-z][a-z0-9_]*$"
local NAME_MAX_LENGTH = 64

---@type table<string, hyprpilot.mcp.Tool>
local registry = {}

---Validate a tool spec. Returns true when the spec is well-formed; logs an
---error line and returns false otherwise. Captains see the warning in their
---notify backend and the registration is silently skipped — bad configs
---don't crash nvim startup.
---@param tool any
---@return boolean
local function validate(tool)
  if type(tool) ~= "table" then
    log.error("mcp.register: tool must be a table, got %s", type(tool))

    return false
  end

  if type(tool.name) ~= "string" or tool.name == "" then
    log.error("mcp.register: tool.name must be a non-empty string")

    return false
  end

  if not tool.name:match(NAME_PATTERN) then
    log.error("mcp.register: tool.name %q must match %s", tool.name, NAME_PATTERN)

    return false
  end

  if #tool.name > NAME_MAX_LENGTH then
    log.error("mcp.register: tool.name %q exceeds %d chars", tool.name, NAME_MAX_LENGTH)

    return false
  end

  if type(tool.description) ~= "string" or tool.description == "" then
    log.error("mcp.register: tool.description must be a non-empty string for %q", tostring(tool.name))

    return false
  end

  if type(tool.schema) ~= "table" then
    log.error("mcp.register: tool.schema must be a table for %q", tostring(tool.name))

    return false
  end

  if tool.schema.type ~= "object" then
    log.error('mcp.register: tool.schema.type must be "object" for %q (v1 restriction)', tostring(tool.name))

    return false
  end

  if type(tool.handler) ~= "function" then
    log.error("mcp.register: tool.handler must be a function for %q", tostring(tool.name))

    return false
  end

  return true
end

---Register or overwrite a tool. Logs an error and skips when validation
---fails — never throws.
---@param tool hyprpilot.mcp.Tool
function M.register(tool)
  if not validate(tool) then
    return
  end

  log.debug("mcp.register: %s (overwrite=%s)", tool.name, tostring(registry[tool.name] ~= nil))

  registry[tool.name] = tool

  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "HyprpilotMcpToolsChanged" })
end

---Remove one or more tools by name. Missing entries are logged and skipped;
---never throws. Fires the change autocmd once when at least one tool was
---actually removed.
---@param ... string
function M.unregister(...)
  local removed = 0

  for _, name in ipairs({ ... }) do
    if type(name) ~= "string" or name == "" then
      log.error("mcp.unregister: name must be a non-empty string, got %s", vim.inspect(name))
    elseif registry[name] == nil then
      log.warn("mcp.unregister: no tool registered as %s", name)
    else
      log.debug("mcp.unregister: %s", name)

      registry[name] = nil
      removed = removed + 1
    end
  end

  if removed > 0 then
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "HyprpilotMcpToolsChanged" })
  end
end

---Discovery shape — the Python MCP server consumes this verbatim.
---Returns an empty table when MCP is disabled via config.
---@return hyprpilot.mcp.ToolSummary[]
function M.list()
  if config.options.mcp == nil or config.options.mcp.enabled == false then
    return {}
  end

  ---@type hyprpilot.mcp.ToolSummary[]
  local out = {}

  for _, tool in pairs(registry) do
    table.insert(out, {
      name = tool.name,
      description = tool.description,
      schema = tool.schema,
    })
  end

  table.sort(out, function(a, b)
    return a.name < b.name
  end)

  return out
end

---Invoke a tool. Used by the Python MCP dispatcher; rarely called directly.
---Throws when the tool is unknown, propagates handler errors verbatim.
---@param name string
---@param args table?
---@return hyprpilot.mcp.ToolResult
function M.call(name, args)
  if type(name) ~= "string" or name == "" then
    error("mcp.call: name must be a non-empty string")
  end

  local tool = registry[name]

  if tool == nil then
    error("mcp.call: unknown tool " .. name)
  end

  return tool.handler(args or {})
end

---Debug accessor — returns the live registry. Not for the wire.
---@return table<string, hyprpilot.mcp.Tool>
function M.registry()
  return registry
end

---Test-only helper to drop every entry. Out of public surface.
function M._reset()
  registry = {}
end

return M
