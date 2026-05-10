# CLAUDE.md (`pkg/` workspace)

> Sub-CLAUDE.md for the Python package inside the `hyprpilot.nvim`
> mono-repo. The root [`../CLAUDE.md`](../CLAUDE.md) covers shared
> conventions (commits, branching, mono-repo layout, release-please).
> This file covers Python-specific stack, tooling, and gotchas.

## Overview

`hyprpilot-nvim-mcp` is a `uvx`-runnable MCP server that bridges Neovim
editor state into the [`hyprpilot`](https://github.com/hyprpilot/hyprpilot)
agent's tool surface. It attaches to a running Neovim via the
`$NVIM_LISTEN_ADDRESS` socket using `pynvim`, and exposes a curated set
of editor-state tools (current buffer, open buffers, LSP definition /
references / hover / diagnostics, treesitter symbols at cursor) plus
any user-defined Lua tools registered via the `hyprpilot.nvim` plugin's
`require('hyprpilot.mcp').register(...)` API.

## Stack & Structure

- **Language:** Python 3.10+ (CI on 3.13).
- **Package manager:** [`uv`](https://docs.astral.sh/uv/) (Astral). This
  package is a member of the repo-root **uv workspace**; `uv.lock` and
  `.venv/` live at the repo root, not in `pkg/`. Run `uv sync` from the
  root (or anywhere — uv finds the workspace).
- **MCP framework:** [`fastmcp`](https://gofastmcp.com/) — decorator-based
  tool registration, JSON Schema auto-derived from type hints + docstrings.
- **Neovim client:** [`pynvim`](https://github.com/neovim/pynvim) — msgpack-RPC
  over the listen socket. Sync API.
- **Lint / format:** `ruff` (single binary, replaces black + isort + flake8).
- **Type-check:** `mypy --strict` (configured via `pyproject.toml`).
- **Test:** `pytest` + `pytest-asyncio` (headless `nvim --embed --clean`
  fixture in `conftest.py`).
- **Toolchain pin:** `mise.toml` pins `python = "3.13"`, `uv = "latest"`,
  `task = "3"`.
- **Build backend:** `hatchling` (pure-Python wheel; flat package layout).
- **Layout:** `hyprpilot_nvim_mcp/{__init__,cli,config,log,nvim,server,
  dynamic}.py` + `hyprpilot_nvim_mcp/tools/{buffer,lsp,treesitter,
  exec_lua}.py`. One function per tool.

## Conventions

- **Conventional Commits** — `feat:`, `fix:`, `chore:`, `docs:`,
  `refactor:`, `test:`. Scope when meaningful (`feat(tools): ...`).
- **Branching** — `feature/*` for new work, `fix/*` or `hotfix/*` for
  fixes.
- **stdout is sacred** — MCP wire bytes go on stdout. Logs go to stderr
  via the `log` module. **Never** `print()` from a tool; never log to
  stdout. One stray `print` corrupts the daemon's parser.
- **`mypy --strict` from day one** — every public function annotated,
  every helper too. No `# type: ignore` without a comment explaining why.
- **One function per tool** — tools live in `tools/<group>.py` as
  top-level functions with type hints + docstrings. FastMCP reads both
  for the JSON Schema. No clever metaprogramming.
- **Errors are values** — wrap every `nvim.*` call to translate pynvim
  exceptions into typed `MCPToolError`. The daemon never sees a Python
  traceback; the captain reads clean messages in the chat surface.
- **Reconnect, don't crash** — nvim quitting/restarting is normal;
  the bridge survives it. Exponential back-off (1s → 30s cap).
- **`pyproject.toml` is the single source of truth** for deps, scripts,
  ruff config, mypy config. No `setup.py`, no `setup.cfg`, no
  `requirements.txt`.

## Decision Log

- **Framework: FastMCP**
  - Chose: decorator-based tool registration with auto-derived schemas.
  - Why: zero-ceremony registration, schema comes from type hints +
    docstrings (one source of truth). Upstreamed into the official MCP
    Python SDK.
  - Rejected: hand-rolled JSON-RPC server — boilerplate without payoff.

- **Neovim client: pynvim**
  - Chose: official client, msgpack-RPC over the listen socket.
  - Why: idiomatic Python API for buffers/windows/LSP, supports
    `exec_lua` for arbitrary Lua callouts.
  - Rejected: writing our own msgpack-RPC client — reinventing what
    `pynvim` already battle-tests.

- **Build backend: hatchling**
  - Chose: hatchling with src layout.
  - Why: `uv` defaults to it for new packages, `pyproject.toml`-only
    config, no quirks.
  - Rejected: setuptools — unnecessary legacy surface for a fresh
    project.

- **Sync vs async tools**
  - Chose: synchronous tool handlers.
  - Why: `pynvim`'s msgpack-RPC is sync; FastMCP allows async tools
    but the underlying transport gains nothing from it.

## Approaches Tried

(Empty — bootstrap repo. Append failed approaches and dead ends here so
no one repeats them.)

## Tools & MCP Usage

- **`uv`** — package + venv manager. `uv sync` installs deps from
  `pyproject.toml` + `uv.lock`. `uvx <pkg>` is the no-install spawn
  idiom (PyPI fetch + cache).
- **`ruff`** — single-binary lint + format. `task lint` runs both
  `ruff format --check` and `ruff check`.
- **`mypy --strict`** — full type-check of `hyprpilot_nvim_mcp/` and
  `tests/`. `task lint` runs it after ruff.
- **`pytest`** — test runner. `tests/conftest.py` spawns headless
  `nvim --embed --clean` per fixture; tests assert against the in-process
  pynvim handle.
- **`task`** — entry points. `task install`, `task lint`, `task test`,
  `task build`.
- **`mise`** — pins `python`, `uv`, and `task` versions. CI installs
  via `jdx/mise-action@v4`.
- **GitHub Actions** — `.github/workflows/ci.yml` (ruff + mypy + pytest)
  and `.github/workflows/release-please.yml` (release-please opens PRs
  on `main` from conventional commits, tags + creates GitHub Release on
  merge).

## Gotchas

- **`NVIM_LISTEN_ADDRESS` must be a Unix socket path** that the running
  Neovim was started with (`nvim --listen /tmp/nvim.sock`). The bridge
  fails fast with a typed error if the socket is missing.
- **Logging to stdout corrupts the MCP wire** — see Conventions above.
  All logs go to stderr; the `log` module's helpers enforce this.
- **`exec_lua` is RCE** — gated behind `HYPRPILOT_NVIM_MCP_ENABLE_EXEC_LUA=1`.
  Off by default. Document the risk loudly when enabling.
- **`pynvim` is thread-unsafe** — the bridge wraps every `nvim.*` access
  in a lock; FastMCP's tool dispatch can run on multiple threads under
  load.
- **`uv.lock` lives at the repo root**, not in `pkg/`. The workspace
  shares one lockfile and one `.venv/`. Update via `uv sync` or
  `uv lock` from any directory; never edit by hand.
- **One bridge per nvim** — N Neovim instances mean N entries in
  `mcps.json`, each with its own `NVIM_LISTEN_ADDRESS`. No multi-attach
  in v0.
