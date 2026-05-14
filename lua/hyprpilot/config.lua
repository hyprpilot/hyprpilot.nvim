local M = {}

---@class hyprpilot.Config
---@field log_level? number
---@field socket? string
---@field ui? hyprpilot.ConfigUi
---@field mcp? hyprpilot.ConfigMcp
---@field client? hyprpilot.ConfigClient
---@field chat? hyprpilot.ConfigChat
---@field composer? hyprpilot.ConfigComposer
---@field permission_row? hyprpilot.ConfigPermissionRow
---@field queue_strip? hyprpilot.ConfigQueueStrip
---@field palettes? hyprpilot.ConfigPalettes
---@field completion? hyprpilot.ConfigCompletion
---@field notification? hyprpilot.ConfigNotification
---@field diff_preview? hyprpilot.ConfigDiffPreview

---@class hyprpilot.ConfigDiffPreview
---@field keymaps? hyprpilot.ConfigDiffPreviewKeymaps
---@field highlights? hyprpilot.ConfigDiffPreviewHighlights
---@field reject_prompt? boolean         -- prompt for an optional rejection reason via `vim.ui.input` (default `true`)
---@field send_reject_feedback? boolean  -- when `true`, captain's reject reason rides the wire as `permissions/respond.feedback`. Default `false` until the daemon-side PR lands.

--- Buffer-local keymaps installed on the diff-preview target buffer
--- while a preview is open. Same `string | string[] | false` shape
--- captains see on every other keymap surface.
---@class hyprpilot.ConfigDiffPreviewKeymaps
---@field accept? string | string[] | false     -- resolve as allow + close preview
---@field reject? string | string[] | false     -- resolve as reject (optionally prompts for feedback) + close
---@field close? string | string[] | false      -- close preview without resolving (permission row stays)
---@field next_hunk? string | string[] | false  -- cursor jumps to next hunk anchor
---@field prev_hunk? string | string[] | false  -- cursor jumps to previous hunk anchor

---@class hyprpilot.ConfigDiffPreviewHighlights
---@field add? string     -- hl group for added lines (default `DiffAdd`)
---@field delete? string  -- hl group for removed lines (default `DiffDelete`)
---@field change? string  -- hl group for the row-level change marker (default `DiffChange`)

---@class hyprpilot.ConfigNotification
---@field bell? hyprpilot.ConfigNotificationBell

---@class hyprpilot.ConfigNotificationBell
---@field enabled? boolean  -- ring the terminal bell every time the attention list grows (default `false` — opt-in)

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

---@class hyprpilot.ConfigQueueStrip
---@field max_height? integer | (fun(lines: number): number?)  -- ceiling for the auto-sized strip (default 40% vh)
---@field keymaps? hyprpilot.ConfigQueueStripKeymaps

--- Composer-queue strip keybindings. Same shape semantics as
--- `permission_row.keymaps`: each value is `string | string[] |
--- false`, normal-mode only. Captain drains the queue explicitly;
--- there's no auto-dispatch on turn end.
---@class hyprpilot.ConfigQueueStripKeymaps
---@field send_head? string | string[] | false  -- send the head entry now
---@field drop_head? string | string[] | false  -- drop the head entry without sending
---@field drop_all?  string | string[] | false  -- clear the entire queue
---@field edit_head? string | string[] | false  -- pop the head into the composer for editing

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
---@field show_diff? string | string[] | false   -- toggle inline diff preview when the head entry is an edit-shaped tool

---@class hyprpilot.ConfigChat
---@field keymaps? hyprpilot.ConfigChatKeymaps

--- Chat-buffer keymaps. Buffer-local, normal mode only. Each value
--- is `string | string[] | false` — `false` disables, lists bind
--- multiple keys to the same action.
---@class hyprpilot.ConfigChatKeymaps
---@field goto_file? string | string[] | false  -- open the file ref under cursor (default `gf`)

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
  queue_strip = {
    max_height = function(lines)
      return math.max(3, math.floor(lines * 0.4))
    end,
    keymaps = {
      -- `<C-CR>` matches the composer's submit binding — sending
      -- the head feels like a chained submit. `dd` matches vim's
      -- delete-line idiom for "drop this row". `D` (capital)
      -- extends that to "drop everything".
      send_head = "<C-CR>",
      drop_head = "dd",
      drop_all = "D",
      edit_head = "e",
    },
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
      -- Opens / closes the inline diff preview for the head entry
      -- when it's an edit-shaped tool. `<C-o>` is normally the
      -- jumplist-back key, but the row buffer is read-only and the
      -- jumplist is meaningless inside it — the captain's
      -- expectation is "open this diff," which the keymap matches.
      show_diff = "<C-o>",
    },
  },
  diff_preview = {
    reject_prompt = true,
    -- Stays `false` until the daemon's `permissions/respond` adds a
    -- `feedback` field (it has `deny_unknown_fields`, so flipping
    -- this on prematurely makes every reject return `-32602`).
    send_reject_feedback = false,
    keymaps = {
      accept = "<C-g>",
      reject = "<C-r>",
      close = "<Esc>",
      next_hunk = "]h",
      prev_hunk = "[h",
    },
    highlights = {
      add = "DiffAdd",
      delete = "DiffDelete",
      change = "DiffChange",
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
  notification = {
    bell = {
      enabled = false,
    },
  },
  chat = {
    keymaps = {
      goto_file = "gf",
    },
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
