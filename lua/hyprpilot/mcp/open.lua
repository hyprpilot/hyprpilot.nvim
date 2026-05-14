--- Built-in `open_*` MCP tool — generic system-level dispatcher
--- via `vim.ui.open`, the captain's existing muscle-memory entry
--- point for "open this thing in whatever handles it" (browser
--- for URLs, file manager for paths, etc.).
---
--- Captain wires it from their config:
---
---     require("hyprpilot.mcp.open").register_all()

local mcp = require("hyprpilot.mcp")

local M = {}

---@param msg string
---@return hyprpilot.mcp.RichResult
local function err(msg)
  return { is_error = true, text = msg }
end

M.tools = {}

M.tools.url = {
  name = "open_url",
  description = "Open a URL or file path in the captain's system handler (browser for `http(s)://`, file manager for paths, etc.) via `vim.ui.open`. Captain sees the result in whatever app the OS picks.",
  schema = {
    type = "object",
    properties = {
      target = {
        type = "string",
        description = "URL (`https://...`, `mailto:`, custom scheme like `obsidian://`) or absolute path.",
      },
    },
    required = { "target" },
    additionalProperties = false,
  },
  handler = function(args)
    if type(args.target) ~= "string" or args.target == "" then
      return err("target must be a non-empty string")
    end
    -- `vim.ui.open` returns a `vim.SystemObj` on success / nil + err
    -- on failure. The pcall guards against environments where
    -- `vim.ui.open` is unavailable (Neovim < 0.10) or the user has
    -- disabled it via `vim.ui` overrides.
    local ok, handle_or_err = pcall(vim.ui.open, args.target)
    if not ok then
      return err("vim.ui.open threw: " .. tostring(handle_or_err))
    end
    if handle_or_err == nil then
      return err("vim.ui.open returned no handle (no system opener configured?)")
    end
    return { text = "opened: " .. args.target }
  end,
}

---Register every tool in `M.tools`. Idempotent.
function M.register_all()
  for _, tool in pairs(M.tools) do
    mcp.register(tool)
  end
end

return M
