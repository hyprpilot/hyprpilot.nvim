# hyprpilot.nvim

Neovim frontend for the [`hyprpilot`](https://github.com/hyprpilot/hyprpilot)
daemon — drive an AI agent from a side-split chat buffer with streaming
output, collapsible tool-call / plan / thought blocks, in-buffer
permission prompts, multi-instance switching, and an MCP bridge that
exposes captain-registered Lua tools to the agent. All over the
daemon's Unix socket at `$XDG_RUNTIME_DIR/hyprpilot.sock`; no daemon
changes required.

This repository is a mono-repo. Alongside the Lua plugin it ships
[`hyprpilot-nvim-mcp`](pkg/) — a `uvx`-runnable MCP server (Python)
that bridges Lua-registered tools into the agent's tool surface.

## Requirements

- Neovim **0.10+**
- A running [`hyprpilot`](https://github.com/hyprpilot/hyprpilot) daemon
- (Optional, for the MCP bridge) [`uv`](https://docs.astral.sh/uv/) on
  the daemon's `$PATH` so it can spawn `uvx hyprpilot-nvim-mcp`

No `plenary.nvim` dependency.

## Install

### lazy.nvim

```lua
return {
  "hyprpilot/hyprpilot.nvim",
  opts = {},
}
```

The plugin ships **no Ex commands** and **no default keymaps** — wire
your own to `require("hyprpilot.*")` calls (see
[Keymap recipes](#keymap-recipes)).

## Quick start

```lua
require("hyprpilot").setup({})

vim.keymap.set("n", "<leader>at", require("hyprpilot").toggle, { desc = "hyprpilot: toggle chat" })
vim.keymap.set("n", "<leader>as", function()
  require("hyprpilot.instances").spawn({ name = "main" })
end, { desc = "hyprpilot: spawn instance" })
```

Hit `<leader>at` to open the side split, `<leader>as` to spawn an
instance. The composer opens below the chat buffer in insert mode;
type a prompt and submit with `<C-CR>`.

## Configuration

`setup({})` accepts the table below. Every field is optional; the
defaults work for a stock setup.

```lua
require("hyprpilot").setup({
  log_level = vim.log.levels.INFO,            -- vim.log.levels.*

  -- Daemon socket. nil → $XDG_RUNTIME_DIR/hyprpilot.sock
  socket = nil,

  ui = {
    position = "right",                       -- "left" | "right"
    width = function(columns)                 -- number | fun(columns): number
      if columns < 200 then
        return math.floor(columns * 0.35)
      end
      return 80
    end,
  },

  client = {
    timeout_ms = 5000,                        -- per-request timeout
    connect_attempts = 3,                     -- connect tries before giving up
    retry_delay_ms = 1000,                    -- ms between attempts
  },

  composer = {
    height = 5,                               -- integer | fun(lines): number
    keymaps = {
      submit = { normal = "<C-CR>", insert = "<C-CR>" },
      cancel = { normal = "<C-c>",  insert = "<C-c>" },
      close  = { normal = "<Esc><Esc>" },
    },
  },

  permission_row = {
    -- Each action accepts `string | string[] | false`. The row is
    -- read-only / normal-mode-only, so no per-mode nesting.
    keymaps = {
      accept     = "<C-g>",                   -- smart-match `^allow|^accept|^proceed`
      reject     = "<C-r>",                   -- smart-match `^reject|^deny|^abort|^cancel`
      submit     = "<CR>",                    -- commit currently-focused option
      cycle_next = "<Tab>",
      cycle_prev = "<S-Tab>",
    },
  },

  queue_strip = {
    -- Pinned bar between the permission row and the composer.
    -- When the captain submits a prompt while the agent is non-
    -- idle, the submit is parked in the queue instead of going
    -- straight to the daemon; the strip auto-shows and the
    -- captain drains explicitly via these keymaps. Cancel-turn
    -- flushes the queue alongside the cancelled head.
    keymaps = {
      send_head = "<C-CR>",                   -- send the head entry now
      drop_head = "dd",                       -- drop the head entry
      drop_all  = "D",                        -- clear the queue
      edit_head = "e",                        -- send head via composer for editing
    },
  },

  mcp = {
    enabled = true,                           -- false → MCP bridge skipped
  },

  palettes = {
    -- Backend for the palette pickers under `lua/hyprpilot/palettes/`.
    -- "auto" uses snacks.nvim's picker when installed (with previews)
    -- and falls back to `vim.ui.select` otherwise. Force one backend
    -- via "snacks" / "vim.ui.select" if you want explicit control.
    picker = "auto",
  },

  completion = {
    -- Daemon-side completion sources the blink.cmp provider queries.
    -- `path` is excluded by default — Neovim's native path completion
    -- (omnifunc, blink.cmp's `path` provider) handles that better
    -- than a daemon round-trip. Extend if the daemon advertises more.
    sources = { "skills" },
  },
})
```

Set any keymap action to `false` to disable it. Set per-mode (e.g.
`submit = { insert = false }`) to disable in insert only.

## Lua API

Captains call modules directly — no re-exports through
`require("hyprpilot")` beyond the window helpers.

### Window

```lua
require("hyprpilot").toggle()
require("hyprpilot").show(instance_id?)
require("hyprpilot").hide()
require("hyprpilot").close(instance_id?)               -- wipes the per-instance buffer
require("hyprpilot").switch(instance_id)
require("hyprpilot").active_instance()                 -- → string?

-- History pagination — bumps the snapshot page size and re-hydrates
-- so older transcript items appear above the current view. No-op when
-- the daemon already reported `hasMore == false`.
require("hyprpilot.chat.window").load_older(instance_id?, opts?, callback?)
```

### Multi-instance

```lua
local instances = require("hyprpilot.instances")

instances.list(function(err, list) ... end)
instances.info(instance_id, function(err, info) ... end)         -- → { id, name, agent_id, profile_id, session_id, mode, cwd }
instances.meta(instance_id, function(err, meta) ... end)         -- → { current_mode_id, current_model_id, available_modes, available_models, usage, mcps_count, ... }
instances.spawn({ name = "main", cwd = vim.fn.getcwd(), restore = false }, callback?)
instances.focus(instance_id, opts?, callback?)
instances.restart(instance_id, callback?)
instances.shutdown(instance_id, callback?)
instances.rename(instance_id, name, callback?)

-- Setters — ids come from the meta payload (`available_modes` /
-- `available_models` on `acp:instance-meta` and `instance/snapshot/meta`).
instances.set_mode(instance_id, mode_id, callback?)
instances.set_model(instance_id, model_id, callback?)
instances.set_option(instance_id, config_id, value, callback?)
```

`spawn` auto-shows the chat split and focuses the composer in insert
mode. `spawn({ restore = true })` resumes the daemon's last matching
session.

### Composer

```lua
local composer = require("hyprpilot.ui.composer")

composer.toggle()
composer.open()
composer.close()
composer.is_visible()                                  -- → boolean
composer.submit(text, opts?)                           -- defaults to active instance
composer.cancel(instance_id?)                          -- cancel the in-flight turn
composer.wipe(instance_id)                             -- drop the per-instance composer buffer

-- Attachments — staged on the active (or named) instance, included in
-- the next prompts/send, cleared on success.
composer.attach({ path = "/abs/path", title?, slug?, mime?, body?, data? })
composer.detach(slug, opts?)
composer.clear_attachments(instance_id?)
composer.attachments(instance_id?)                     -- → Attachment[]

-- Convenience helpers.
composer.attach_buffer(bufnr?, opts?)                  -- attach the buffer's file path
composer.attach_clipboard_image(opts?)                 -- needs img-clip.nvim
```

Staged attachments render as a stack of virt_lines pinned to the
bottom of the composer buffer (one row per attachment, highlight
group `HyprpilotComposerAttachments`). The composer auto-resizes to
fit content + attachment rows, capped at `max_height` — so more
attachments eat into the writing area rather than growing the split
indefinitely. The stack clears once the prompt sends successfully.

> [!NOTE]
> The Unix-socket `prompts/send` daemon RPC currently **does not**
> accept an `attachments` field — the staging UX, slug deduping, and
> indicator all work, but the wire-side delivery needs a small daemon
> patch. Tracking handoff plan:
> `~/.claude/plans/2026-05-11-hyprpilot-prompts-send-attachments.md`.

### Permissions

```lua
local permissions = require("hyprpilot.permissions")

permissions.respond(request_id, option_id, callback?)
permissions.pending({ instance_id = "..." }, function(err, pending) ... end)
```

In-buffer UX (installed automatically when a `permission_request`
block renders): `<Tab>` / `<S-Tab>` cycle the focused button, `<CR>`
commits, `g` smart-matches an `^allow|^accept|^proceed` option and
commits, `d` smart-matches `^reject|^deny|^abort|^cancel`. Cursor
outside the button row falls through normally.

### Status

```lua
local status = require("hyprpilot.status")

status.get()                                           -- → { connection, active_instance?, activity }
status.reconnect()
status.disconnect()
status.socket_address()                                -- → string?
```

`status.get()` returns the connection state (`"connected"` /
`"connecting"` / `"disconnected"`), the active instance id, and the
current activity (`idle` / `thinking` / `streaming` / `tool` /
`awaiting_permission`).

The status surface fires `User Hyprpilot*` autocmds so statuslines
refresh without polling: `HyprpilotConnected`, `HyprpilotDisconnected`,
`HyprpilotInstanceChanged`, `HyprpilotActivityChanged`.

### Lifecycle autocmds

Every daemon wire event the chat dispatcher consumes also fans out
as a `User Hyprpilot<*>` autocmd with a structured `data` payload.
Captains hook these for toasts, statuslines, sound effects, jira
integrations — without having to re-implement the wire envelope
decode. Every payload is snake_case Lua (we translate the daemon's
camelCase on the way out).

| Pattern | `data` shape | Fires when |
|---|---|---|
| `HyprpilotTurnStarted` | `{ instance_id, turn_id, started_at? }` | Pilot turn starts streaming. |
| `HyprpilotTurnEnded` | `{ instance_id, turn_id, ended_at?, stop_reason?, error? }` | Turn finishes (clean, cancel, or error). |
| `HyprpilotPermissionRequested` | `{ instance_id, request_id, tool, tool_kind?, options }` | Tool asks the captain to authorise an action. |
| `HyprpilotPermissionResolved` | `{ instance_id, request_id, option_id }` | Captain (or another peer) resolved the prompt. |
| `HyprpilotInstanceStateChanged` | `{ instance_id, state }` | Instance moved through `starting` / `running` / `ended` / `error`. |

Usage / mode / session-title / lagged-recovery events are
intentionally **not** surfaced as autocmds — they fire too often
(every turn drips multiple usage updates) or have no captain-side
hook surface. Read them off `winbar._meta[id]` or `status.get()`
on demand instead.

Example — toast on every permission request:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "HyprpilotPermissionRequested",
  callback = function(ev)
    vim.notify(("hyprpilot wants to run %s"):format(ev.data.tool), vim.log.levels.WARN)
  end,
})
```

### Lua-side MCP tools

```lua
local mcp = require("hyprpilot.mcp")

mcp.register({
  name = "git_blame_line",
  description = "Return git blame for the line at the cursor.",
  schema = {
    type = "object",
    properties = {
      bufnr = { type = "integer" },
      lnum  = { type = "integer" },
    },
    required = { "bufnr", "lnum" },
  },
  handler = function(args)
    -- ... return a string or { content = {...} } table.
  end,
})

mcp.unregister("git_blame_line")               -- accepts varargs
mcp.list()                                     -- → ToolSummary[]
```

Validation logs and skips on bad input (no `error()` thrown). The
Python MCP bridge picks up the registered tools at boot and re-exposes
them to the agent. Re-registering the same `name` overwrites; that
hot-reload is the captain's intended workflow.

### Completion (blink.cmp)

`lua/hyprpilot/completion/blink.lua` ships a blink.cmp source that
round-trips through the daemon's `completion/query` + `resolve`
RPCs. Opt-in via your blink.cmp config:

```lua
require("blink.cmp").setup({
  sources = {
    default = { "hyprpilot", "lsp", "buffer" },
    providers = {
      hyprpilot = {
        name = "hyprpilot",
        module = "hyprpilot.completion.blink",
        opts = {
          -- (optional) override config.completion.sources for this provider:
          sources = { "skills" },
          -- (optional) widen the activation predicate; default is the
          -- hyprpilot composer buffer only.
          enabled = function() return true end,
        },
      },
    },
  },
})
```

The source only fires inside the composer buffer (filetype
`hyprpilot_input`) by default — other buffers keep their native
LSP / path / buffer providers as the source of truth. Path
completion is intentionally **not** routed through the daemon
(`config.completion.sources` defaults to `{ "skills" }`); Neovim's
native path completion handles that better.

### Palettes (snacks previews)

`lua/hyprpilot/palettes/*.lua` use `vim.ui.select` by default; when
[snacks.nvim](https://github.com/folke/snacks.nvim) is installed,
`config.palettes.picker = "auto"` upgrades them to
`Snacks.picker.pick` with previews. Each palette ships a per-row
preview function the snacks pane renders as markdown — mode /
model / effort descriptions, instance metadata, session
cwd + sessionId + additional directories.

Force a backend explicitly via `palettes.picker = "snacks"` or
`palettes.picker = "vim.ui.select"`, or override per-call:

```lua
require("hyprpilot.palettes.modes").open({ picker = "snacks" })
```

## Statusline integration

The status surface is the single source of truth — compose your own
component however your statusline plugin prefers. Lualine example:

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      {
        function()
          local s = require("hyprpilot.status").get()
          local glyph = s.connection == "connected" and "●"
            or s.connection == "connecting" and "…"
            or "○"
          return glyph .. " " .. (s.active_instance or "—")
        end,
      },
    },
  },
})

vim.api.nvim_create_autocmd("User", {
  pattern = {
    "HyprpilotConnected",
    "HyprpilotDisconnected",
    "HyprpilotInstanceChanged",
    "HyprpilotActivityChanged",
  },
  callback = function()
    require("lualine").refresh()
  end,
})
```

## MCP bridge setup

The Python MCP server is a pure dispatcher: it queries
`require("hyprpilot.mcp").list()` at boot and re-exposes each tool to
the agent via FastMCP. It needs the running nvim's listen socket to
attach.

Add an entry to your `mcps.json` (the daemon **does not** expand
`${NVIM_LISTEN_ADDRESS}` — inline the literal path):

```json
{
  "hyprpilot-nvim": {
    "command": "uvx",
    "args": ["hyprpilot-nvim-mcp"],
    "env": {
      "NVIM_LISTEN_ADDRESS": "/run/user/1000/nvim.sock"
    }
  }
}
```

Start nvim with `nvim --listen /run/user/1000/nvim.sock` (or set
`vim.fn.serverstart(...)` in your config). Run
`:checkhealth hyprpilot` to confirm the listen socket matches the env
var.

> [!NOTE]
> v1 supports **one nvim per `mcps.json` entry**. Daemon-side per-spawn
> MCP injection (and / or env-var expansion) is on the v2 roadmap to
> unlock multi-nvim. See [Limitations](#limitations).

## Health check

```vim
:checkhealth hyprpilot
```

Reports: nvim version → daemon socket reachability → live
`daemon/version` over the socket → nvim listen socket
(`v:servername`) and `NVIM_LISTEN_ADDRESS` drift detection → MCP
enablement and registered tool count.

## Highlight groups

The chat buffer applies its own line-level highlight groups, all
linked by default to common semantic targets so a stock colorscheme
just works:

| Group                              | Default link        |
|------------------------------------|---------------------|
| `HyprpilotToolHeader`              | `Function`          |
| `HyprpilotToolStatusOk`            | `DiagnosticOk`      |
| `HyprpilotToolStatusFail`          | `DiagnosticError`   |
| `HyprpilotToolStatusRunning`       | `DiagnosticInfo`    |
| `HyprpilotToolStatusPending`       | `DiagnosticHint`    |
| `HyprpilotToolBody`                | `Comment`           |
| `HyprpilotPlanHeader`              | `Title`             |
| `HyprpilotPlanStepDone`            | `Comment`           |
| `HyprpilotPlanStepInProgress`      | `Function`          |
| `HyprpilotPlanStepPending`         | `Identifier`        |
| `HyprpilotThoughtHeader`           | `Conceal`           |
| `HyprpilotThoughtBody`             | `Comment`           |
| `HyprpilotPermissionHeader`        | `WarningMsg`        |
| `HyprpilotPermissionBody`          | `Comment`           |
| `HyprpilotPermissionButton`        | `Pmenu`             |
| `HyprpilotPermissionButtonFocused` | `PmenuSel`          |
| `HyprpilotPermissionResolved`      | `Comment`           |
| `HyprpilotTurnEndOk`               | `DiagnosticOk`      |
| `HyprpilotTurnEndError`            | `DiagnosticError`   |
| `HyprpilotTurnEndCancelled`        | `DiagnosticWarn`    |
| `HyprpilotComposerAttachments`     | `Comment`           |

Override any group with `vim.api.nvim_set_hl(0, "HyprpilotXxx", {...})`
to break the link.

## Keymap recipes

```lua
local set = vim.keymap.set
local hp = require("hyprpilot")
local instances = require("hyprpilot.instances")

set("n", "<leader>at", hp.toggle,                                       { desc = "hyprpilot: toggle chat" })
set("n", "<leader>as", function() instances.spawn({ name = "main" }) end, { desc = "hyprpilot: spawn instance" })
set("n", "<leader>ar", function() instances.restart() end,              { desc = "hyprpilot: restart current" })
set("n", "<leader>ax", function() instances.shutdown() end,             { desc = "hyprpilot: shutdown current" })

-- Palettes — `vim.ui.select`-driven pickers under
-- `lua/hyprpilot/palettes/`. Each one fetches its options off the
-- daemon (instance meta or a list RPC), shows a picker, and commits
-- via the matching setter. Every `vim.ui.select` call passes a
-- `kind = "hyprpilot.<axis>"` field so dressing.nvim / telescope /
-- snacks / fzf-lua can route to a custom selector per axis if you
-- want previews or a richer view.
set("n", "<leader>ai", function() require("hyprpilot.palettes.instances").open() end,
  { desc = "hyprpilot: pick instance" })
set("n", "<leader>am", function() require("hyprpilot.palettes.modes").open() end,
  { desc = "hyprpilot: pick mode" })
set("n", "<leader>aM", function() require("hyprpilot.palettes.models").open() end,
  { desc = "hyprpilot: pick model" })
set("n", "<leader>ae", function() require("hyprpilot.palettes.effort").open() end,
  { desc = "hyprpilot: pick effort" })
set("n", "<leader>aS", function() require("hyprpilot.palettes.sessions").open() end,
  { desc = "hyprpilot: pick session" })

-- Attach the current buffer to the active instance's next prompt.
local composer = require("hyprpilot.ui.composer")
set("n", "<leader>ab", function() composer.attach_buffer() end,
  { desc = "hyprpilot: attach current buffer" })

-- Detach a staged attachment via vim.ui.select.
set("n", "<leader>aD", function()
  local list = composer.attachments()
  if #list == 0 then return end
  vim.ui.select(list, {
    prompt = "detach attachment",
    format_item = function(a) return a.title or a.slug end,
  }, function(choice)
    if choice ~= nil then composer.detach(choice.slug) end
  end)
end, { desc = "hyprpilot: detach attachment" })

-- Paste a clipboard image as an attachment (requires img-clip.nvim).
set("n", "<leader>ap", function() composer.attach_clipboard_image() end,
  { desc = "hyprpilot: attach clipboard image" })

-- Pull older transcript items (deeper history) on demand.
set("n", "<leader>au", function()
  require("hyprpilot.chat.window").load_older()
end, { desc = "hyprpilot: load older history" })
```

> **Sessions palette** rides on the daemon's `sessions/list` +
> `sessions/load` RPCs (shipped daemon-side in PR #41). The ACP
> wire shape per `SessionInfo` is lean — only `sessionId` + `cwd`
> per entry, so the row format is `<cwd> · <short-id>`. The
> `profile_id` / `agent_id` you pass via `palettes.sessions.open({
> profile_id = "..." })` is forwarded to `sessions/load` so the
> daemon resolves the right agent for the resume.

## Limitations

- **One nvim per `mcps.json` entry.** Daemon doesn't expand
  `${NVIM_LISTEN_ADDRESS}` in env values, and `mcps.json` isn't
  per-spawn. Workaround: one `mcps.json` entry per long-lived nvim.
  Multi-nvim is on the v2 roadmap.
- **Snapshot-replayed permission rows render as live.** Daemon
  transcript items don't carry per-request resolution state; if you
  click a stale one you get a `warn` log and the row stays. Active
  permissions (live event) work fine.
- **Initial chat snapshot is the latest 100 items.** Older history is
  pulled on demand via `require("hyprpilot.chat.window").load_older()`,
  which bumps the snapshot page and re-hydrates. The transcript isn't
  trimmed once loaded — sessions with thousands of items will keep
  growing buffer-side memory.
- **Edit / diff tool calls render as plain folded blocks**, not
  side-by-side diffs. The agent's diff content shows verbatim inside
  the fold.

## Troubleshooting

- `:checkhealth hyprpilot` is the first stop. It catches: missing
  socket, daemon not running, nvim not listening,
  `NVIM_LISTEN_ADDRESS` drift, MCP disabled / no tools registered.
- Bump `log_level = vim.log.levels.DEBUG` in `setup({})` for verbose
  trace output through `vim.notify`.
- The chat buffer is `modifiable = false`; if you see `E21: Cannot
  make changes`, that's expected — submit through the composer or
  `composer.submit(text)`.
- Folds collapse on `turn_ended` / tool completion. Use `zo` to peek
  inside a closed turn or block, `zR` to open everything.

## Roadmap

- v2: per-spawn MCP injection (unlocks multi-nvim), pager / buffer
  trim, native edit/diff rendering, xterm.js-style ANSI for terminal
  blocks, async Lua tool handlers, coroutine `await` RPC API, skills /
  mode / model pickers.

## License

[MIT](LICENSE)
