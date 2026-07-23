# hyprpilot-nvim-mcp

`uvx`-runnable MCP server that bridges a running Neovim's editor state into the [`hyprpilot`](https://github.com/hyprpilot/hyprpilot) agent's tool surface.

It is a pure dispatcher: at boot it attaches to Neovim over its listen socket, queries `require("hyprpilot.mcp").list()` for the tools you registered on the Lua side (via the [`hyprpilot.nvim`](https://github.com/hyprpilot/hyprpilot.nvim) plugin), and re-exposes each one to the agent through FastMCP with its JSON Schema carried through verbatim. It dies at startup if the socket cannot be reached.

## Install in `mcps.json`

```json
"hyprpilot-nvim": {
  "command": "uvx",
  "args": ["hyprpilot-nvim-mcp"],
  "env": { "NVIM_LISTEN_ADDRESS": "/run/user/1000/nvim.sock" }
}
```

`uvx` fetches the package from PyPI on first run and caches it. The daemon does not expand `${NVIM_LISTEN_ADDRESS}` — inline the literal socket path.

## Run from source

```sh
uv sync
uv run hyprpilot-nvim-mcp --nvim-listen-address /run/user/1000/nvim.sock
```

## Environment

The Neovim socket is resolved from `--nvim-listen-address` (aliases `--nvim`, `-n`), then `$NVIM_LISTEN_ADDRESS`, then `$NVIM` (set automatically by Neovim in its child processes). The server exits non-zero if none resolve or the socket is unreachable.

- `NVIM_LISTEN_ADDRESS` — path to the running Neovim's listen socket.
- `NVIM` — fallback socket; Neovim sets it in its child processes.
- `HYPRPILOT_NVIM_MCP_LOG_LEVEL` — stderr log level (default `INFO`).

## Built-in tools

Two management tools ship regardless of the Lua registry:

- `healthcheck` — bridge version, socket, connection state, nvim version, registered tool count.
- `reload_dynamic_tools` — re-discover the Lua registry and diff it against the live tool list.

Every other tool comes from the Lua side — this package ships no editor tool catalogue of its own.

## Development

```sh
task install   # uv sync --all-groups
task lint      # ruff format --check + ruff check + mypy
task test      # pytest
task build     # uv build
```

## License

[MIT](LICENSE)
