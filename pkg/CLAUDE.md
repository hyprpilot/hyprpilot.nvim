# CLAUDE.md (`pkg/` workspace)

> Sub-CLAUDE.md for the Python package inside the `hyprpilot.nvim`
> mono-repo. The root [`../CLAUDE.md`](../CLAUDE.md) covers shared
> conventions (commits, branching, mono-repo layout, release-please).
> This file covers Python-specific stack, tooling, and gotchas.

## Overview

`hyprpilot-nvim-mcp` is a `uvx`-runnable MCP server that bridges Neovim
editor state into the [`hyprpilot`](https://github.com/hyprpilot/hyprpilot)
agent's tool surface. It attaches to a running Neovim via the
`$NVIM_LISTEN_ADDRESS` socket using `pynvim` and acts as a **pure
dispatcher**: at boot it queries the Lua side
(`require("hyprpilot.mcp").list()`) for the captain-registered tool
catalogue and re-exposes each tool to the agent via FastMCP. The Python
package ships **zero default tools**; the captain registers what they
need on the Lua side. Two management tools (`reload_dynamic_tools`,
`healthcheck`) are the only built-ins.

## Stack & Structure

- **Language:** Python 3.14+ (`requires-python = ">=3.14"` in
  `pyproject.toml`; ruff `target-version = "py314"`).
- **CLI:** [`click`](https://click.palletsprojects.com/) with a
  class-based command tree. The `Server` class hosts state + behaviour;
  `Server.cli` is the `@click.group` exposed to `[project.scripts]`.
  click owns env-var parsing for every option (`envvar=`, `click.BOOL`
  coercion). Do not write a separate `Config.from_env()` layer.
- **Logging:** [`rich`](https://rich.readthedocs.io/) `RichHandler`
  bound to a stderr `Console`. The wrapper module
  (`hyprpilot_nvim_mcp/log.py`) exports `configure(level)` + `get(name)`;
  every module imports `from hyprpilot_nvim_mcp import log` and uses
  the standard logging level methods.
- **Package manager:** [`uv`](https://docs.astral.sh/uv/) (Astral). This
  package is a member of the repo-root **uv workspace**; `uv.lock` and
  `.venv/` live at the repo root, not in `pkg/`. Run `uv sync` from the
  root (or anywhere — uv finds the workspace).
- **MCP framework:** [`fastmcp`](https://gofastmcp.com/) — but we don't
  use the decorator path for dynamic tools. We construct
  `fastmcp.tools.FunctionTool(name=..., description=..., parameters=schema, fn=dispatcher)`
  directly so the **Lua schema passes through verbatim** as the agent's
  tool view — single source of truth on the Lua side. Decorator-based
  registration is fine for the management tools (`healthcheck`,
  `reload_dynamic_tools`) where we own both ends.
- **Neovim client:** [`pynvim`](https://github.com/neovim/pynvim) — msgpack-RPC
  over the listen socket. Sync API.
- **Lint / format:** `ruff` (single binary, replaces black + isort + flake8).
- **Type-check:** `mypy --strict` (configured via `pyproject.toml`).
- **Test:** `pytest` + `pytest-asyncio` (headless `nvim --embed --clean`
  fixture in `conftest.py`).
- **Toolchain pin:** `mise.toml` pins `python = "3.14"`, `uv = "latest"`,
  `task = "3"`.
- **Build backend:** `hatchling` (pure-Python wheel; flat package layout).
- **Layout:**
  `hyprpilot_nvim_mcp/{__init__,cli,log,nvim,server,dispatcher}.py`
  + `hyprpilot_nvim_mcp/tools/{healthcheck,reload}.py`. `cli.py` hosts
  the `Server` class (click group + runtime state); `dispatcher.py`
  builds the FastMCP `FunctionTool` per Lua-registered tool;
  `tools/<name>.py` exposes a single `register(mcp, nvim, ...)` entry
  point that the CLI wires.

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
- **One file per management tool** — `tools/<name>.py` exports a
  `register(mcp, nvim, ...)` function and nothing else. Dynamic
  Lua-side tools live in `dispatcher.py` (single closure factory) — no
  per-tool Python file for those.
- **No tool catalogue in Python** — the captain's tools live on the Lua
  side; Python just dispatches. If you find yourself adding a Python
  tool that talks to nvim editor state (LSP, treesitter, buffers, etc.),
  stop and add it to `lua/hyprpilot/mcp.lua` examples instead. Python
  built-ins are reserved for things only the bridge can do
  (`healthcheck`, `reload_dynamic_tools`).
- **Errors are values** — wrap every `nvim.*` call to translate pynvim
  exceptions into typed `MCPToolError`. The daemon never sees a Python
  traceback; the captain reads clean messages in the chat surface.
- **Reconnect, don't crash** — nvim quitting/restarting is normal;
  the bridge survives it. Exponential back-off (1s → 30s cap).
- **`pyproject.toml` is the single source of truth** for deps, scripts,
  ruff config, mypy config. No `setup.py`, no `setup.cfg`, no
  `requirements.txt`.
- **Inline single-use values** — same rule as the root CLAUDE.md.
  Never name a local, constant, or intermediate dict that has only one
  consumer. Inline directly into the call site.
- **Config knobs ship with their behaviour** — never declare a CLI
  option, env var, or config dataclass field whose handler doesn't
  exist yet. Add it in the same PR that wires it.
- **Validation logs and skips, not throws** for captain-facing input
  (CLI args, env vars, MCP tool registration). Tool handler errors
  still translate to `MCPToolError` per the "Errors are values" rule
  above; that's a different surface.

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

- **Pure dispatcher, zero default tools (shipped in #14)**
  - Chose: Python ships only `healthcheck` + `reload_dynamic_tools`.
    Everything else comes from `require("hyprpilot.mcp").list()` on the
    Lua side and is registered via FastMCP `FunctionTool(parameters=schema)`
    so the Lua schema is the agent's view verbatim.
  - Why: single source of truth for the tool catalogue (Lua), and the
    captain registers what they need — no curated Python defaults to
    fight with. Bridge stays small (~150 LOC of dispatcher + nvim wrapper).
  - Rejected: shipping built-in `buffer`/`lsp`/`treesitter`/`exec_lua`
    tools on the Python side. Captain explicitly pulled this:
    "we will register it from explicitly the plugin side of the neovim".

- **CLI: class-based click `Server`**
  - Chose: a single `Server` class hosts log config, parsed options,
    and a `serve()` method. `Server.cli` is the `@click.group` exposed
    via `[project.scripts]`. Subcommands receive the instance via
    `click.pass_obj`.
  - Why: keeps option parsing, env-var resolution, and runtime wiring
    in one cohesive unit; matches the captain's pattern across other
    Python projects.
  - Rejected: function-based click commands with separate `Config`
    dataclass — adds an env-parsing layer click already provides.

## Approaches Tried

- **Built-in `exec_lua` tool (#14)** — gated behind an env var, with a
  separate `tools/exec_lua.py` file. Captain pulled it entirely:
  "we will register it from explicitly the plugin side of the neovim".
  If the captain wants an arbitrary-Lua escape hatch, they register it
  via `require("hyprpilot.mcp").register({...})`. The Python side does
  not own that surface.
- **Forward-looking config knobs** — same lesson as the root CLAUDE.md.
  Don't declare a CLI option / env var whose handler doesn't exist yet.
- **Decorator registration for dynamic tools** — `@mcp.tool` derives
  the schema from Python type hints + docstring. For Lua-side tools
  whose schema lives on the Lua side, that's the wrong direction:
  use `FunctionTool(parameters=schema)` so the Lua schema is verbatim.

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
- **`pynvim` is thread-unsafe** — the bridge wraps every `nvim.*` access
  in a lock; FastMCP's tool dispatch can run on multiple threads under
  load.
- **`pynvim` lacks `py.typed`** — mypy can't see its types. We carry
  one targeted `[[tool.mypy.overrides]]` block in `pyproject.toml` to
  silence missing-imports for `pynvim`. Don't widen this to other deps
  without a stated reason.
- **`FunctionTool` parameters take JSON Schema verbatim** — pass the
  Lua-side `schema` table straight through; do not Pythonize it. FastMCP
  forwards the JSON Schema to the agent. Rebuilding it from Python
  type hints would defeat the purpose of dynamic discovery.
- **`uv.lock` lives at the repo root**, not in `pkg/`. The workspace
  shares one lockfile and one `.venv/`. Update via `uv sync` or
  `uv lock` from any directory; never edit by hand.
- **One bridge per nvim** — N Neovim instances mean N entries in
  `mcps.json`, each with its own `NVIM_LISTEN_ADDRESS`. No multi-attach
  in v0.
