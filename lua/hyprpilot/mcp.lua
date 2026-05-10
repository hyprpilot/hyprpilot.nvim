--- Lua-side MCP tool registry. Captain registers Lua tools here; the
--- Python MCP server (`hyprpilot-nvim-mcp`) queries `list()` at boot
--- and round-trips `call(name, args)` for every agent invocation.
---
--- This module is independent of the chat surface — captains who only
--- want the MCP-bridge half can `register({...})` without ever calling
--- `require("hyprpilot").setup({})`.

local config = require("hyprpilot.config")
local log = require("hyprpilot.log")

---Log a debug line only when the logger has been set up. The MCP API is
---reachable before `hyprpilot.setup()` runs (the module is independent),
---so log calls must tolerate the un-initialized state.
---@param fmt string
local function trace(fmt, ...)
  if log.debug ~= nil then
    log.debug(fmt, ...)
  end
end

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

---Validate a tool spec. Throws on invalid input via `error()`.
---@param tool any
local function validate(tool)
  if type(tool) ~= "table" then
    error("mcp.register: tool must be a table, got " .. type(tool))
  end

  if type(tool.name) ~= "string" or tool.name == "" then
    error("mcp.register: tool.name must be a non-empty string")
  end

  if not tool.name:match(NAME_PATTERN) then
    error(string.format("mcp.register: tool.name %q must match %s", tool.name, NAME_PATTERN))
  end

  if #tool.name > NAME_MAX_LENGTH then
    error(string.format("mcp.register: tool.name %q exceeds %d chars", tool.name, NAME_MAX_LENGTH))
  end

  if type(tool.description) ~= "string" or tool.description == "" then
    error("mcp.register: tool.description must be a non-empty string")
  end

  if type(tool.schema) ~= "table" then
    error("mcp.register: tool.schema must be a table")
  end

  if tool.schema.type ~= "object" then
    error('mcp.register: tool.schema.type must be "object" (v1 restriction)')
  end

  if type(tool.handler) ~= "function" then
    error("mcp.register: tool.handler must be a function")
  end
end

---Fire the tool-list-changed autocmd, defensively.
local function emit_changed()
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "HyprpilotMcpToolsChanged" })
end

---True when MCP discovery is enabled. Captains can flip this via
---`setup({ mcp = { enabled = false } })`.
---@return boolean
local function is_enabled()
  local cfg = config.options.mcp

  if cfg == nil then
    return true
  end

  return cfg.enabled ~= false
end

---Register or overwrite a tool. Validation throws on malformed input.
---@param tool hyprpilot.mcp.Tool
function M.register(tool)
  validate(tool)

  local existed = registry[tool.name] ~= nil
  registry[tool.name] = tool

  trace("mcp.register: %s (overwrite=%s)", tool.name, tostring(existed))
  emit_changed()
end

---Remove a tool by name. Throws when no entry exists.
---@param name string
function M.unregister(name)
  if type(name) ~= "string" or name == "" then
    error("mcp.unregister: name must be a non-empty string")
  end

  if registry[name] == nil then
    error("mcp.unregister: no tool registered as " .. name)
  end

  registry[name] = nil

  trace("mcp.unregister: %s", name)
  emit_changed()
end

---Discovery shape — the Python MCP server consumes this verbatim.
---Returns an empty table when MCP is disabled via config.
---@return hyprpilot.mcp.ToolSummary[]
function M.list()
  if not is_enabled() then
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
