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

- `lsp_*` — `ensure_loaded`, `definition`, `references`, `hover`, `document_symbols`, `workspace_symbols`, `code_actions`, `rename`, `diagnostics_get`
- `editor_*` — `cursor`, `buffers`, `read`, `grep`, `files`, `status`, `file_open`, `jump`, `select`, `format`

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
