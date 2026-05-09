local M = {}

---@class hyprpilot.Config
---@field log_level? number
---@field socket? string

---@type hyprpilot.Config
local defaults = {
  log_level = vim.log.levels.INFO,
  socket = nil,
}

---@type hyprpilot.Config
---@diagnostic disable-next-line: missing-fields
M.options = {
  log_level = vim.log.levels.INFO,
  socket = nil,
}

---@param config hyprpilot.Config
---@return hyprpilot.Config
function M.setup(config)
  M.options = vim.tbl_deep_extend("force", {}, defaults, config or {})

  return M.options
end

return M
