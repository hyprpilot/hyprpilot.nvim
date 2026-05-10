# hyprpilot-nvim-mcp

`uvx`-runnable MCP server that bridges Neovim editor state into the
[`hyprpilot`](https://github.com/hyprpilot/hyprpilot) agent's tool surface.

> [!IMPORTANT]
> This package is in early bootstrap. Only the CLI entry point and a
> stub `ping` tool are wired today. Buffer / LSP / treesitter / dynamic
> tool registration land in follow-up PRs (see
> [`docs/plans/2026-05-09-nvim-mcp-handoff.md`](docs/plans/2026-05-09-nvim-mcp-handoff.md)).

## Install in `mcps.json`

```json
"neovim": {
  "command": "uvx",
  "args": ["hyprpilot-nvim-mcp"],
  "env": { "NVIM_LISTEN_ADDRESS": "${NVIM_LISTEN_ADDRESS}" }
}
```

`uvx` fetches the package from PyPI on first run and caches it.

## Run from source

```sh
uv sync
uv run hyprpilot-nvim-mcp
```

## Environment

| Variable | Default | Description |
| --- | --- | --- |
| `NVIM_LISTEN_ADDRESS` | _required_ | Path to the running Neovim's listen socket. |
| `HYPRPILOT_NVIM_MCP_LOG_LEVEL` | `INFO` | Stderr log level. |
| `HYPRPILOT_NVIM_MCP_ENABLE_EXEC_LUA` | `0` | Enables the `exec_lua` tool (RCE surface — leave off unless you know why). |

## Development

```sh
task install   # uv sync --all-groups
task lint      # ruff format --check + ruff check + mypy
task test      # pytest
task build     # uv build
```

## License

[MIT](LICENSE)
