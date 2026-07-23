--- hyprpilot.nvim — the Neovim side of the hyprpilot MCP bridge.
---
--- This plugin is the Lua-side tool registry that the
--- `hyprpilot-nvim-mcp` server dispatches to. `setup()` is OPTIONAL:
--- without it the logger defaults to INFO and everything works. Call
--- it only to set the Lua log level up front:
---
---     require("hyprpilot").setup({ log_level = vim.log.levels.DEBUG })
---
--- Tool registration stays captain-opt-in — wire the categories you
--- want from your own config; there is no config flag for it (the
--- daemon-side profile allow / deny lists own that policy):
---
---     require("hyprpilot.mcp.lsp").register_all()
---     require("hyprpilot.mcp.editor").register_all()

local M = {}

---@class hyprpilot.Config
---@field log_level? integer  -- one of `vim.log.levels.*`; defaults to INFO

--- Optional plugin-wide configuration. Currently the Lua log level is
--- the only knob; skip the call entirely to keep the INFO default.
---@param opts? hyprpilot.Config
function M.setup(opts)
  opts = opts or {}

  if opts.log_level ~= nil then
    require("hyprpilot.log").setup({ level = opts.log_level })
  end
end

return M
