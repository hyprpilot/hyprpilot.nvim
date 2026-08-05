# CLAUDE.md

## Overview

`hyprpilot.nvim` is the Neovim side of the
[`hyprpilot`](https://github.com/hyprpilot/hyprpilot) MCP bridge. It is
**purely an MCP server**: it exposes a running Neovim's editor state
(LSP, buffers, cursor, files) to the hyprpilot agent as MCP tools.
There is no chat buffer, no daemon frontend — hyprpilot v3 and the
desktop app own that surface. The old daemon-frontend plugin (chat,
composer, permissions UI, RPC, palettes, completion, notifications) was
removed in the v2 breaking change.

## Mono-repo Layout

Two packages ship together, released under one `vX.Y.Z` tag:

- **Lua plugin (root)** — `lua/hyprpilot/`. The Lua-side MCP tool
  registry (`mcp/init.lua`) plus the built-in `lsp_*` / `editor_*` tool
  categories, and a small optional `setup()` (log level only).
- **Python MCP bridge** — `pkg/`. `uvx`-runnable MCP server
  (`hyprpilot-nvim-mcp`) that attaches to Neovim over its listen socket
  and re-exposes the Lua-registered tools to the agent via FastMCP. See
  [`pkg/CLAUDE.md`](pkg/CLAUDE.md) for Python-side conventions.

`task lint` and `task test` at the root run both subprojects via
`Taskfile.yml`'s `includes:` block (`pkg:` namespace). The Python side
is a [uv workspace](https://docs.astral.sh/uv/concepts/projects/workspaces/):
the root `pyproject.toml` declares `pkg/` as a member, so `uv.lock` and
`.venv/` live at the repo root. `release-please` treats the repo as a
single versioned project — one tag covers both surfaces, and
`pkg/pyproject.toml`'s `version` is mechanically locked to the tag via
release-please's `extra-files` updater.

## How the bridge works

The Python server is a **pure dispatcher**. At boot it:

1. Resolves the Neovim socket from `--nvim-listen-address`, then
   `$NVIM_LISTEN_ADDRESS`, then `$NVIM`.
2. Eagerly attaches (`NvimWrapper.connect()`) and **dies non-zero** if
   the socket can't be reached — it never runs toolless.
3. Queries `require("hyprpilot.mcp").list()` and registers one FastMCP
   `FunctionTool` per Lua tool, carrying the Lua JSON Schema through
   verbatim.

Every agent invocation round-trips `require("hyprpilot.mcp").call(name,
args)` through `nvim.exec_lua`. Two management tools are built into the
Python side (`healthcheck`, `reload_dynamic_tools`); every editor tool
lives on the Lua side.

## Stack & Structure (Lua plugin)

- **Language:** Lua, Neovim 0.10+.
- **No external runtime dependencies** — no `plenary.nvim`. Core APIs
  only (`vim.lsp`, `vim.json`, `vim.uv`, `vim.fs`, `vim.ui.*`).
- **Tooling:** `stylua` (format), `selene` (lint), `Taskfile.yml`,
  `mise.toml` pins versions.
- **Layout:**
  - `lua/hyprpilot/init.lua` — optional `setup({ log_level })`. The
    plugin works fully without it.
  - `lua/hyprpilot/log.lua` — `vim.notify`-backed leveled logger,
    self-configured at load (defaults INFO). Any module can
    `require("hyprpilot.log")` and call `log.debug/info/warn/error`
    immediately.
  - `lua/hyprpilot/mcp/init.lua` — the tool registry
    (`register` / `unregister` / `list` / `call`). Validation logs and
    skips on bad input; never throws.
  - `lua/hyprpilot/mcp/lsp.lua`, `mcp/editor.lua` — built-in tool
    categories. Each exposes a `register_all()` helper plus a `M.tools`
    table for selective registration. Tool names follow
    `<category>_<verb>`.

## Conventions

- **Conventional Commits** — `feat:`, `fix:`, `chore:`, `docs:`,
  `refactor:`, `test:`. Scope when meaningful (`feat(mcp): ...`).
  Breaking changes use `type(scope)!:` + a `BREAKING CHANGE:` footer so
  release-please cuts a major bump.
- **Branching** — `feature/*` for new work, `fix/*` / `hotfix/*` for
  fixes, `chore/*` / `docs/*` for the rest.
- **Module pattern** — every Lua module exports a single `local M = {}`
  … `return M`. No global state outside `M`.
- **LuaCATS on public functions** — `---@class hyprpilot.X`, `---@field`,
  `---@param`, `---@return`. Dot form (`hyprpilot.X`), not underscore.
- **MCP tool registration is captain-opt-in, not config-driven** — the
  captain calls `require("hyprpilot.mcp.lsp").register_all()` (etc.)
  from their own config. There is no `setup({ tools = ... })` flag; the
  daemon-side per-profile allow / deny lists own that policy.
- **Config knobs ship with their behaviour** — never declare a config
  field whose handler doesn't exist yet. `setup()`'s only knob is
  `log_level`.
- **Validation logs and skips, not throws** — captain-facing entry
  points (`mcp.register`, `setup`) use `log.error` + early return on
  invalid input rather than `error()`.
- **Inline single-use values** — never name a local, constant, or
  intermediate table with only one consumer. Inline it.
- **MCP tool implementations vet against current Neovim APIs** —
  `mcp/lsp.lua` uses per-client `client:request_sync()` (not the
  soft-deprecated `vim.lsp.buf_request_sync`),
  `make_text_document_params(bufnr)` + manual position, and carries
  `client.offset_encoding` through so multi-encoding setups don't
  mis-translate columns.
- **Editor tools route to a real window** — `mcp/editor.lua`'s
  `editor_winid()` targets the current window unless it's a floating
  popup, in which case the first non-floating window; navigation tools
  spawn a `topleft new` split only when nothing else is available.
  `register({ pick_window = ... })` hands that choice to the captain
  instead — consulted by `file_open` / `jump` / `select` only, only
  when the target isn't already in a usable window on the current
  tabpage, and only after the built-in reuse check; read-only tools
  never call it, and an unusable return degrades to the heuristic.

## Tools & MCP Usage

- **`stylua`** — formatter. `.stylua.toml` pins 180 col, 2-space,
  prefer-double quotes. `task format` runs it; `task lint` checks.
- **`selene`** — linter. `selene.toml` uses `std = "vim"`; `vim.toml`
  declares the vim/test globals.
- **`Taskfile.yml`** — `task format` / `task lint` / `task test-lua`
  (mini.test) / `task test` (chains `test-lua` + `pkg:test`).
- **`mini.test`** — Lua test runner. `scripts/minimal-init.lua` clones
  `mini.nvim` into `vim.fn.tempname()` per run; Neovim wipes it on exit.
  Tests live in `tests/test_*.lua` (currently `mcp-registry`,
  `mcp-lsp`, `mcp-editor`) and drive real public entry points asserting
  on visible output.
- **`mise.toml`** — pins `selene`, `stylua`, `neovim` for CI.
- **GitHub Actions** — `.github/workflows/lint.yml` runs stylua/selene
  + `task pkg:lint` + the Lua and Python test suites.
  `release-please.yml` opens release PRs on push to `main`.

## Gotchas

- **The MCP server dies if it can't reach Neovim** — the eager
  `connect()` in `serve()` exits non-zero rather than starting with an
  empty tool list. Start Neovim with `nvim --listen <sock>` and point
  the socket env var at the same path.
- **`plugin/` and treesitter registration are gone** — there is no
  plugin-owned filetype anymore. Editor tools operate on ordinary
  editor windows.
- **Logger uses `vim.notify`** — output respects the captain's notify
  backend. Don't bypass it with `print`.
