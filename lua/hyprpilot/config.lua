local M = {}

---@class hyprpilot.Config
---@field log_level? number
---@field socket? string
---@field ui? hyprpilot.ConfigUi
---@field mcp? hyprpilot.ConfigMcp
---@field client? hyprpilot.ConfigClient
---@field composer? hyprpilot.ConfigComposer
---@field permission_row? hyprpilot.ConfigPermissionRow
---@field palettes? hyprpilot.ConfigPalettes
---@field completion? hyprpilot.ConfigCompletion

---@class hyprpilot.ConfigPalettes
---@field picker? "auto" | "snacks" | "vim.ui.select"  -- picker backend; "auto" = snacks if available, else vim.ui.select

---@alias hyprpilot.CompletionSource "skills" | "path" | "ripgrep" | "commands"

---@class hyprpilot.ConfigCompletion
---@field sources? hyprpilot.CompletionSource[]
--- Daemon-side completion sources to query (default: `{ "skills" }`).
--- The daemon's closed set today is `skills | path | ripgrep |
--- commands` (mirror of `CompletionSourceId` on the wire). `path` is
--- intentionally excluded by default — Neovim has native path
--- completion sources that don't need a daemon round-trip.

---@class hyprpilot.ConfigPermissionRow
---@field max_height? integer | (fun(lines: number): number?)  -- ceiling for the auto-sized row (default 40% vh)
---@field keymaps? hyprpilot.ConfigPermissionRowKeymaps

--- Permission-row keybindings. Each action accepts:
---   - a single key string (`"<C-g>"`)
---   - a list of key strings (`{ "<C-g>", "ga" }`)
---   - `false` to disable that action entirely
--- Permission row buffer is read-only (normal mode only), so no
--- per-mode nesting — flat string/list form throughout.
---@class hyprpilot.ConfigPermissionRowKeymaps
---@field accept? string | string[] | false      -- smart-match `^allow|^accept|^proceed`
---@field reject? string | string[] | false      -- smart-match `^reject|^deny|^abort|^cancel`
---@field submit? string | string[] | false      -- commit currently-focused option
---@field cycle_next? string | string[] | false  -- focus next option
---@field cycle_prev? string | string[] | false  -- focus previous option

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
---@field min_height? integer | (fun(lines: number): number?)  -- minimum / initial composer rows
---@field max_height? integer | (fun(lines: number): number?)  -- ceiling for auto-grow (default 40% vh)
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
  permission_row = {
    max_height = function(lines)
      return math.max(3, math.floor(lines * 0.4))
    end,
    keymaps = {
      -- `<C-g>` / `<C-r>` defaults dodge vim's bare-`g` prefix
      -- (with bare `g`, the captain couldn't type `gg` to top of
      -- the row). The captain can override any action with a
      -- string / list / `false` (disable).
      accept = "<C-g>",
      reject = "<C-r>",
      submit = "<CR>",
      cycle_next = "<Tab>",
      cycle_prev = "<S-Tab>",
    },
  },
  palettes = {
    picker = "auto",
  },
  completion = {
    -- Daemon advertises `path` and `skills` today; we exclude `path`
    -- by default because Neovim has native path completion sources
    -- (omnifunc, blink.cmp's `path` provider) that don't need to
    -- round-trip through the daemon. Captain can extend this list
    -- when the daemon adds more sources.
    sources = { "skills" },
  },
  composer = {
    min_height = 12,
    max_height = function(lines)
      return math.max(12, math.floor(lines * 0.4))
    end,
    keymaps = {
      submit = { normal = "<CR>", insert = "<C-s>" },
      cancel = { normal = "<C-c>", insert = "<C-c>" },
      close = { normal = "q" },
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
