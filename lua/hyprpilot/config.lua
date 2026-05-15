local M = {}

---@class hyprpilot.Config
---@field log_level? number
---@field socket? string
---@field ui? hyprpilot.ConfigUi
---@field client? hyprpilot.ConfigClient
---@field chat? hyprpilot.ConfigChat
---@field composer? hyprpilot.ConfigComposer
---@field permission_row? hyprpilot.ConfigPermissionRow
---@field queue_strip? hyprpilot.ConfigQueueStrip
---@field palettes? hyprpilot.ConfigPalettes
---@field completion? hyprpilot.ConfigCompletion
---@field notification? hyprpilot.ConfigNotification
---@field diff_preview? hyprpilot.ConfigDiffPreview
---@field icons? hyprpilot.ConfigIcons
---@field with_config? hyprpilot.ConfigPatch[]
--- Global baseline overlay patches the daemon applies to every
--- spawn-bearing RPC (`instances.spawn`, `instances.focus` with
--- `ensure=true`, `composer.submit`). Per-call `with_config` lists
--- stack on top: global goes first, per-call goes after, daemon
--- applies in declaration order with last-wins semantics.

--- Glyph overrides for tool status badges and tool-kind prefixes
--- rendered into the chat. Defaults are nerd-font glyphs (the
--- captain's terminal is expected to ship one); ASCII fallbacks
--- live a few lines below in case the captain prefers a no-font
--- look or copies their setup to a non-nerd-font terminal.
---@class hyprpilot.ConfigIcons
---@field tool_status? table<string, string>  -- keys: completed | failed | pending | running | awaiting_permission
---@field tool_kind? table<string, string>    -- keys: execute | terminal | edit | write | read | fetch | search | glob | delete | think | default
---@field task_status? table<string, string>  -- keys: pending | in_progress | completed (mirror of daemon's PlanStepStatus)
---@field turn_status? table<string, string>  -- keys: ok | cancelled | error (rendered into the turn-end stop chip)

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
---@field goto_file? string | string[] | false      -- open the file ref under cursor (default `gf`)
---@field next_turn? string | string[] | false      -- jump to next `## pilot` / `## captain` header (default `]h`)
---@field prev_turn? string | string[] | false      -- jump to previous turn header (default `[h`)
---@field next_section? string | string[] | false   -- jump to next `### tools` / `### thoughts` / etc (default `]s`)
---@field prev_section? string | string[] | false   -- jump to previous section header (default `[s`)

---@class hyprpilot.ConfigUi
---@field position? "left" | "right"
---@field width? number | (fun(columns: number): number?)

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
      -- `<localleader>` defaults stay clear of vim's normal-mode
      -- prefixes — `<C-o>` (the previous diff binding) collides with
      -- the jumplist; `<C-g>` / `<C-r>` collide with file info /
      -- redo if the captain ever switches into the row from a
      -- modifiable buffer. Each action accepts `string |
      -- string[] | false`, so captains who prefer the older
      -- bindings can pass `accept = { "<localleader>a", "<C-g>" }`
      -- (or the bare list) without code changes.
      accept = "<localleader>a",
      reject = "<localleader>d",
      submit = "<CR>",
      cycle_next = "<Tab>",
      cycle_prev = "<S-Tab>",
      -- Opens / closes the inline diff preview for the head entry
      -- when it's an edit-shaped tool.
      show_diff = "<localleader>g",
    },
  },
  diff_preview = {
    reject_prompt = true,
    -- Stays `false` until the daemon's `permissions/respond` adds a
    -- `feedback` field (it has `deny_unknown_fields`, so flipping
    -- this on prematurely makes every reject return `-32602`).
    send_reject_feedback = false,
    keymaps = {
      -- Match the row's `<localleader>a/d/g` so the captain doesn't
      -- have to learn a second alphabet inside the diff preview.
      accept = "<localleader>a",
      reject = "<localleader>d",
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
      enabled = true,
    },
  },
  chat = {
    keymaps = {
      goto_file = "gf",
      -- `[`/`]` family follows vim's stock next-of-kind motions
      -- (`]m`, `]s`, etc.). `h` for "header" stays clear of `]s`
      -- which spell-checking would normally claim — but the chat
      -- buffer is read-only with `spell = false`, so reusing it
      -- for "section" doesn't fight anything.
      next_turn = "]h",
      prev_turn = "[h",
      next_section = "]s",
      prev_section = "[s",
    },
  },
  -- Nerd-font glyphs by default (Font Awesome set, mirrors the
  -- desktop overlay's `@fortawesome/free-solid-svg-icons` choices in
  -- `ui/src/lib/tools/presentation.ts`). Captains without a nerd
  -- font override with ASCII via `setup({ icons = { tool_status =
  -- { completed = "[ok]", ... } } })`. Glyphs are pasted as literal
  -- UTF-8 — they look blank in editors that don't ship a nerd font
  -- but render correctly in Neovim under one.
  icons = {
    tool_status = {
      completed = "", -- nf-fa-check (U+F00C)
      failed = "", -- nf-fa-times (U+F00D)
      pending = "", -- nf-fa-clock_o (U+F017)
      running = "", -- nf-fa-refresh (U+F021)
      awaiting_permission = "", -- nf-fa-exclamation_triangle (U+F071)
    },
    tool_kind = {
      execute = "", -- nf-fa-terminal (U+F120)
      terminal = "", -- nf-fa-terminal (U+F120)
      edit = "", -- nf-fa-pencil (faPen) (U+F040)
      write = "", -- nf-fa-edit (faPenToSquare) (U+F044)
      read = "", -- nf-fa-file_text_o (faFileLines) (U+F15C)
      fetch = "", -- nf-fa-globe (U+F0AC)
      search = "", -- nf-fa-search (faMagnifyingGlass) (U+F002)
      glob = "", -- nf-fa-star (faStarOfLife approximation) (U+F005)
      delete = "", -- nf-fa-trash (U+F1F8)
      think = "", -- nf-fa-lightbulb_o (faBrain approximation) (U+F0EB)
      default = "", -- nf-fa-cog (U+F013)
    },
    task_status = {
      pending = "", -- nf-fa-square_o (U+F0C8)
      in_progress = "", -- nf-fa-dot_circle_o (U+F192)
      completed = "", -- nf-fa-check_square (U+F14A)
    },
    turn_status = {
      ok = "", -- nf-fa-check (U+F00C)
      cancelled = "", -- nf-fa-times (captain aborted)
      error = "", -- nf-fa-exclamation_triangle
    },
    -- Per-instance lifecycle states (header status pill — leftmost
    -- column). Captains override via `setup({ icons = { instance_state
    -- = { ... } } })`. ASCII fallback aware (empty strings degrade
    -- to the bare label in the renderer).
    instance_state = {
      starting = "", -- nf-fa-spinner (U+F110) — booting
      running = "", -- nf-fa-circle (U+F111) — live / accepting prompts
      ended = "", -- nf-fa-stop (U+F04D) — daemon shut down
      error = "", -- nf-fa-exclamation_triangle (U+F071)
    },
    -- Composer activity strip (single virt-text row above the
    -- composer's first writable line). Mirrors the per-instance
    -- activity emitted by chat events: streaming / thinking / tool /
    -- awaiting_permission.
    activity = {
      streaming = "", -- nf-fa-bolt (U+F0E7)
      thinking = "", -- nf-fa-lightbulb_o (U+F0EB)
      tool = "", -- nf-fa-cog (U+F013)
      permission = "", -- nf-fa-exclamation_triangle (U+F071)
    },
  },
  composer = {
    min_height = 12,
    max_height = function(lines)
      return math.max(12, math.floor(lines * 0.4))
    end,
    keymaps = {
      submit = { normal = "<CR>", insert = "<C-s>" },
      -- `<C-c>` stays the insert-mode cancel because that's the
      -- muscle-memory key in every TUI prompt. Normal mode swaps to
      -- `<localleader>c` so a captain who escapes-then-aborts isn't
      -- racing vim's normal-mode `<C-c>` (which interrupts pending
      -- operators and visual selections).
      cancel = { normal = "<localleader>c", insert = "<C-c>" },
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
