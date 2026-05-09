local M = {}

--- Configures the hyprpilot.nvim plugin.
---@param config hyprpilot.Config
function M.setup(config)
  local c = require("hyprpilot.config").setup(config)

  require("hyprpilot.log").setup({ level = c.log_level })
end

return M
