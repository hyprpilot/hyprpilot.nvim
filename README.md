# hyprpilot.nvim

Bridge your live Neovim's editor state — LSP, buffers, cursor, files — into the [`hyprpilot`](https://github.com/hyprpilot/hyprpilot) agent as MCP tools.

## Features

- Exposes your running Neovim to the hyprpilot agent over MCP, so the agent can read buffers, query the LSP, jump the cursor, and search files in the editor you are actually using.
- Built-in `lsp_*` and `editor_*` tool categories — opt into the ones you want.
- Register your own tools with a small Lua API; their JSON Schema is handed to the agent verbatim.
- Ships a `uvx`-runnable MCP server (`hyprpilot-nvim-mcp`) — no install dance, `uvx` fetches it on first run.
- Fails fast: the server exits if it cannot reach Neovim, so it never runs toolless.

## Installation

### lazy.nvim

```lua
{
  "hyprpilot/hyprpilot.nvim",
  config = function()
    require("hyprpilot").setup({})

    -- Register the tool categories you want the agent to see.
    require("hyprpilot.mcp.lsp").register()
    require("hyprpilot.mcp.editor").register()
  end,
}
```

Requires [`uv`](https://docs.astral.sh/uv/) on the agent's `$PATH` so it can spawn `uvx hyprpilot-nvim-mcp`.

## Configuration

### Setup

Plugin requires no setup by default. The only option is the log level:

```lua
require("hyprpilot").setup({
  log_level = vim.log.levels.INFO, -- one of vim.log.levels.*
})
```

Tool registration is deliberately not config-driven — you call `register()` (or register individual tools) yourself, so the daemon-side per-profile allow / deny lists stay the single source of policy.

## Tools

Built-in categories, named `<category>_<verb>`:

- `lsp_*` — `ensure_loaded`, `definition`, `type_definition`, `implementation`, `references`, `incoming_calls`, `outgoing_calls`, `hover`, `document_symbols`, `workspace_symbols`, `code_actions`, `rename`, `diagnostics_get`
- `editor_*` — `cursor`, `buffers`, `read`, `grep`, `files`, `status`, `file_open`, `jump`, `select`, `quickfix_set`, `format`
- `plugin_*` — integrations with third-party plugins you already run: `diffview`, `neotest`, `dap`, `coverage`, `todo_comments`

Each category's `register(opts?)` doubles as a setup call. Omit `opts` to register everything; pass `items` to register a subset. Calling it again overrides — the category's registered set is replaced, not added to.

```lua
-- Everything in one shot:
require("hyprpilot.mcp.lsp").register()
require("hyprpilot.mcp.editor").register()

-- A subset:
require("hyprpilot.mcp.lsp").register({ items = { "definition", "hover", "diagnostics_get" } })
```

`editor.register` also routes navigation (`file_open`, `jump`, `cursor`, …) away from windows whose filetype or buftype you exclude, so an open doesn't land in a file explorer, terminal, or quickfix window:

```lua
require("hyprpilot.mcp.editor").register({
  disabled_filetypes = { "neo-tree", "qf", "help" },
  disabled_buffer_types = { "terminal", "prompt" },
})
```

Without further config the landing window is picked for you: a usable window on the current tabpage already showing the file, else the current window, else the first usable one — where usable means not a float and not on those exclusion lists. Pass `pick_window` to decide yourself instead. It gets the same exclusion lists as `{ filetype = ..., buftype = ... }`, so an interactive picker can forward them as its own filter rules, and anything unusable coming back (`nil` from a cancelled pick, a stale winid, `0`, a throw) falls back to the built-in choice:

```lua
require("hyprpilot.mcp.editor").register({
  disabled_filetypes = { "neo-tree", "qf", "help" },
  disabled_buffer_types = { "terminal", "prompt" },
  pick_window = function(filter)
    return require("window-picker").pick_window({ filter_rules = { bo = filter } })
  end,
})
```

Only `file_open`, `jump`, and `select` consult it, and only when the target isn't already in a usable window — read-only tools like `editor_cursor` never prompt you. Two things worth knowing about an interactive picker: `filter_rules.bo` is replaced wholesale by what you pass, and the picker blocks the entire bridge (not just the one tool call) until you press a key, since every request serializes through one connection. Enable `autoselect_one` so the common single-window case never prompts.

### Plugin integrations

`plugin_*` categories expose plugins you already run. Each one registers only when its plugin loads, so wiring a category you don't have installed logs a line and moves on:

```lua
require("hyprpilot.mcp.plugin.diffview").register()
require("hyprpilot.mcp.plugin.neotest").register()
require("hyprpilot.mcp.plugin.dap").register()
require("hyprpilot.mcp.plugin.coverage").register()
require("hyprpilot.mcp.plugin.todo_comments").register()
```

| Category | Tools | What the agent gets |
|---|---|---|
| `diffview` | `files`, `current`, `open`, `close`, `selection_get`, `selection_set` | The diff you have open and the files you marked in it. `open` takes `paths`, so an agent can put an exact set of changes on your screen |
| `neotest` | `status`, `positions`, `run` | Pass / fail counts from the run you already triggered, and tests mapped to `file:line` — no re-running a suite to learn what the adapter already parsed |
| `dap` | `status`, `stack` | Whether a session is live and where it stopped, with frames as 0-indexed positions you can feed to `editor_jump` |
| `coverage` | `report` | The parsed coverage report, whatever format the project emits |
| `todo_comments` | `search` | TODO / FIXME hits using your configured keywords and pattern, not a guessed regex |

They take the same `items` option as the built-in categories. `diffview`'s `selection_get` / `selection_set` additionally need the [diffview+](https://github.com/dlyongemallo/diffview-plus.nvim) fork's `diffview.api` module and return a clean error on upstream diffview.

`lsp.register` takes `disabled_lsps` to skip specific LSP clients (by name) when servicing a request:

```lua
require("hyprpilot.mcp.lsp").register({
  disabled_lsps = { "copilot", "null-ls" },
})
```

### Custom tools

Add your own tool with a name, description, JSON Schema, and handler:

```lua
local mcp = require("hyprpilot.mcp")

mcp.register({
  name = "git_blame_line",
  description = "Return git blame for the line at the cursor.",
  schema = {
    type = "object",
    properties = {
      bufnr = { type = "integer" },
      lnum = { type = "integer" },
    },
    required = { "bufnr", "lnum" },
  },
  handler = function(args)
    -- return a string, or a { json = {...}, text = ..., is_error = ... } table.
  end,
})

mcp.unregister("git_blame_line") -- accepts varargs
mcp.list() -- list registered tools
```

Bad input is logged and skipped, never thrown. Re-registering the same name overwrites it — the agent picks up the change via the `reload_dynamic_tools` tool, no restart needed.

## MCP server

Start Neovim with a listen socket:

```sh
nvim --listen "$XDG_RUNTIME_DIR/nvim.sock"
```

Then point the server at that socket from your `mcps.json`:

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

The socket is resolved, in order, from `--nvim-listen-address` (aliases `--nvim`, `-n`), then `$NVIM_LISTEN_ADDRESS`, then `$NVIM` (which Neovim sets automatically in its child processes). Set the server's own log level with `--log-level` or `$HYPRPILOT_NVIM_MCP_LOG_LEVEL`.

Two management tools are always available: `healthcheck` (bridge version, socket, connection state, registered tool count) and `reload_dynamic_tools` (re-scan the registered tools and refresh the agent's list).

## License

[MIT](LICENSE)
