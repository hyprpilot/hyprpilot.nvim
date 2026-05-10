local M = {}

---@class hyprpilot.Config
---@field log_level? number
---@field socket? string
---@field ui? hyprpilot.ConfigUi
---@field mcp? hyprpilot.ConfigMcp
---@field client? hyprpilot.ConfigClient
---@field composer? hyprpilot.ConfigComposer

---@class hyprpilot.ConfigUi
---@field position? "left" | "right"
---@field width? number | (fun(columns: number): number?)

---@class hyprpilot.ConfigMcp
---@field enabled? boolean

---@class hyprpilot.ConfigClient
---@field timeout_ms? integer        -- per-request timeout
---@field connect_attempts? integer  -- connect tries before giving up
---@field retry_delay_ms? integer    -- delay between connect attempts

---@class hyprpilot.ConfigComposer
---@field height? integer | (fun(lines: number): number?)
---@field keymaps? hyprpilot.ConfigComposerKeymaps

---@class hyprpilot.ConfigComposerKeymaps
---@field submit? hyprpilot.ConfigComposerKeymapAction | false
---@field cancel? hyprpilot.ConfigComposerKeymapAction | false
---@field close?  hyprpilot.ConfigComposerKeymapAction | false

---@class hyprpilot.ConfigComposerKeymapAction
---@field normal? string | string[] | false
---@field insert? string | string[] | false

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
  client = {
    timeout_ms = 5000,
    connect_attempts = 3,
    retry_delay_ms = 1000,
  },
  composer = {
    height = 5,
    keymaps = {
      submit = { normal = "<C-CR>", insert = "<C-CR>" },
      cancel = { normal = "<C-c>", insert = "<C-c>" },
      close = { normal = "<Esc><Esc>" },
    },
  },
}

---Live config — reads here resolve to defaults until `M.setup()` runs
---and merges the captain's overrides. Modules can `require` and read
---`config.options.*` regardless of setup order.
---@type hyprpilot.Config
M.options = vim.deepcopy(defaults)

---@param config hyprpilot.Config
---@return hyprpilot.Config
function M.setup(config)
  M.options = vim.tbl_deep_extend("force", {}, defaults, config or {})

  return M.options
end

return M
