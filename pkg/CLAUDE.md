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

## Publishing to PyPI

The `build-pypi` + `publish-pypi` jobs in
`.github/workflows/release-please.yml` publish `hyprpilot-nvim-mcp`
to PyPI as a downstream chain of the `release-please` job, gated
on `release_created == 'true'`. Auth is **PyPI Trusted Publishing
(OIDC)** — no API token is stored in GitHub. PyPI verifies the
workflow's identity via OIDC and issues a short-lived publish token
at runtime.

The publish jobs live in `release-please.yml` (not a separate
`publish-pypi.yml` reusable workflow) because PyPI's trusted-
publisher matches the OIDC token's `job_workflow_ref` claim
against the registered workflow file. With `workflow_call`, that
claim points at the CALLING workflow regardless of where the
job's steps are defined — so a reusable workflow path requires
PyPI to register the CALLER's filename, which is confusing and
error-prone. Inlining keeps OIDC identity = trusted-publisher
filename = `release-please.yml`.

### One-time setup (captain only)

> **Migrating from a `publish-pypi.yml`-named publisher?** If you
> registered the trusted publisher with `Workflow name:
> publish-pypi.yml` (the pre-PR-#67 setup), update it to
> `release-please.yml`. PyPI: project settings → "Trusted
> publishers" → the existing entry → edit the workflow name. No
> other field changes.

**1. Create the PyPI project** (skip if already published).
   The first publish has to seed the project; PyPI doesn't accept a
   trusted publisher for a project that doesn't exist yet. Two paths:

   - **Recommended — pending publisher.** PyPI lets you register a
     trusted publisher BEFORE the project exists, via
     [pypi.org/manage/account/publishing](https://pypi.org/manage/account/publishing/)
     → "Add a new pending publisher". Use the values in step 2 below.
     The first tag-push then publishes via OIDC and the pending
     publisher is auto-promoted.
   - **Alternative — manual seed.** Build locally
     (`cd pkg && uv build`) and `uv run twine upload dist/*` once with
     an API token, then add the trusted publisher per step 2.

**2. Add the trusted publisher.**
   On [pypi.org/manage/project/hyprpilot-nvim-mcp/settings/publishing/](https://pypi.org/manage/project/hyprpilot-nvim-mcp/settings/publishing/):

   | Field | Value |
   |---|---|
   | PyPI Project Name | `hyprpilot-nvim-mcp` |
   | Owner | `hyprpilot` |
   | Repository name | `hyprpilot.nvim` |
   | Workflow name | `release-please.yml` |
   | Environment name | `pypi` |

   The environment binding scopes the OIDC grant to a single
   GitHub Environment, so a workflow running outside `pypi` (a
   forked PR, a misconfigured workflow) can't grab the publish
   token even if it can read the repo.

**3. Create the GitHub Environment.**
   On [github.com/hyprpilot/hyprpilot.nvim/settings/environments](https://github.com/hyprpilot/hyprpilot.nvim/settings/environments)
   → "New environment" → name it `pypi`.

   Optional but recommended:
   - **Deployment branch rule** → "Selected branches" → add `main`.
     Protects against publishes from feature branches.
   - **Required reviewers** → list the captain. The publish job
     will pause until approved on each tag.

**4. Pin the publish action's SHA.**
   The workflow ships with `pypa/gh-action-pypi-publish@release/v1`
   (a moving tag) for the first checkin. Run:

   ```bash
   gh api repos/pypa/gh-action-pypi-publish/git/refs/tags/release/v1 \
     --jq '.object.sha'
   ```

   …and replace the `release/v1` ref with the resolved SHA, with a
   `# release/v1` trailing comment so Renovate / Dependabot can
   track it (matches the `release-please-action@<sha> # v5.0.0`
   pattern in the same file). Skip this step in dev; ship it
   before the first tagged release.

### How it runs

1. Captain merges the release-please PR on `main`. release-please
   cuts a `vX.Y.Z` tag and a GitHub Release.
2. The same workflow's `build-pypi` job (gated on
   `release_created == 'true'`) produces the wheel + sdist via
   `task build` (uv backend); `publish-pypi` downloads the
   artifact and calls `pypa/gh-action-pypi-publish` which
   OIDC-authenticates against PyPI's trusted-publisher entry.
   Both run in the same workflow run as `release-please` — no
   tag-push trigger involved (and none would fire anyway, because
   `secrets.GITHUB_TOKEN`-pushed tags don't trigger workflows by
   GitHub's anti-loop design).
3. PyPI verifies the OIDC claims (repo, workflow, environment) match
   the registered publisher and accepts the upload. Captain sees
   the new version on
   [pypi.org/project/hyprpilot-nvim-mcp/](https://pypi.org/project/hyprpilot-nvim-mcp/)
   within a minute.
4. `skip-existing: true` makes a tag re-push (e.g. release-please
   re-cutting the same version) idempotent — the publish step
   no-ops instead of failing.

### Why trusted publishing over an API token

- **No long-lived secret in the repo.** API tokens get leaked,
  rotated, forgotten. OIDC tokens are minted per-job, valid for
  ~15 minutes.
- **PyPI scopes the grant.** The trusted-publisher entry binds to
  an exact (repo, workflow, environment) tuple. A different
  workflow in the same repo cannot publish, even with admin
  access.
- **No setup on the captain's local machine.** `pip config` /
  `.pypirc` aren't needed for CI publishing.

### Local publishing (if you ever need to)

For one-off pushes off the CI path (manual seed in step 1 above,
hotfix when GitHub Actions is down):

```bash
cd pkg
uv build                           # → dist/*.whl + *.tar.gz
uv run twine upload dist/*         # prompts for an API token
```

Generate the token at
[pypi.org/manage/account/token](https://pypi.org/manage/account/token/);
scope it to the `hyprpilot-nvim-mcp` project. Stash it in your
password manager — never commit it, never paste it into a CI
secret (the workflow uses OIDC; an API token there would be
strictly worse).

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
