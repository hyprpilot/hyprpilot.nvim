local M = {}

---@class hyprpilot.Config
---@field log_level? number
---@field socket? string
---@field ui? hyprpilot.ConfigUi
---@field mcp? hyprpilot.ConfigMcp

---@class hyprpilot.ConfigUi
---@field position? "left" | "right"
---@field width? number | (fun(columns: number): number?)

---@class hyprpilot.ConfigMcp
---@field enabled? boolean

---@type hyprpilot.Config
local defaults = {
  log_level = vim.log.levels.INFO,
  socket = nil,
  ui = {
    position = "right",
    width = function(columns)
      if columns < 200 then
        return math.floor(columns * 0.35)
      end

      return 80
    end,
  },
  mcp = {
    enabled = true,
  },
}

---@type hyprpilot.Config
---@diagnostic disable-next-line: missing-fields
M.options = {
  log_level = vim.log.levels.INFO,
  socket = nil,
  ui = {
    position = "right",
    width = function(columns)
      if columns < 200 then
        return math.floor(columns * 0.35)
      end

      return 80
    end,
  },
  mcp = {
    enabled = true,
  },
}

---@param config hyprpilot.Config
---@return hyprpilot.Config
function M.setup(config)
  M.options = vim.tbl_deep_extend("force", {}, defaults, config or {})

  return M.options
end

return M
