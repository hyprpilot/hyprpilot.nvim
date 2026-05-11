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

  mcp = {
    enabled = true,                           -- false → MCP bridge skipped
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

Staged attachments paint a `[N attached: ...]` indicator on the
composer buffer's first line (highlight group `HyprpilotComposerAttachments`).
The indicator clears once the prompt sends successfully.

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

-- vim.ui.select-based picker — no extra dependency required.
set("n", "<leader>ai", function()
  instances.list(function(err, list)
    if err ~= nil or list == nil then return end
    vim.ui.select(list, {
      prompt = "hyprpilot instance",
      format_item = function(i) return i.name or i.id end,
    }, function(choice)
      if choice ~= nil then hp.switch(choice.id) end
    end)
  end)
end, { desc = "hyprpilot: pick instance" })

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

-- Mode picker — drive `instances.set_mode` from the active instance's
-- `available_modes` (read off `instances.meta`, the MetaSnapshot RPC).
set("n", "<leader>am", function()
  local id = hp.active_instance()
  if id == nil then return end
  instances.meta(id, function(err, meta)
    if err ~= nil or meta == nil then return end
    local modes = meta.available_modes or {}
    if #modes == 0 then return end
    vim.ui.select(modes, {
      prompt = "hyprpilot mode",
      format_item = function(m) return m.name or m.id end,
    }, function(choice)
      if choice ~= nil then instances.set_mode(id, choice.id) end
    end)
  end)
end, { desc = "hyprpilot: pick mode" })

-- Model picker — same shape, swaps to `available_models` + `set_model`.
set("n", "<leader>aM", function()
  local id = hp.active_instance()
  if id == nil then return end
  instances.meta(id, function(err, meta)
    if err ~= nil or meta == nil then return end
    local models = meta.available_models or {}
    if #models == 0 then return end
    vim.ui.select(models, {
      prompt = "hyprpilot model",
      format_item = function(m) return m.name or m.id end,
    }, function(choice)
      if choice ~= nil then instances.set_model(id, choice.id) end
    end)
  end)
end, { desc = "hyprpilot: pick model" })

-- Pull older transcript items (deeper history) on demand.
set("n", "<leader>au", function()
  require("hyprpilot.chat.window").load_older()
end, { desc = "hyprpilot: load older history" })
```

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
