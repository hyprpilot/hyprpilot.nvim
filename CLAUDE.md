# CLAUDE.md

## Overview

`hyprpilot.nvim` is the Neovim frontend for the
[`hyprpilot`](https://github.com/hyprpilot/hyprpilot) daemon — a local
AI agent runtime that exposes a JSON-RPC surface over a Unix socket at
`$XDG_RUNTIME_DIR/hyprpilot.sock`. The plugin drives the daemon as a
first-class second frontend alongside the desktop app: chat buffer,
streaming output, permission prompts, mode/model switching, session
restoration. All wire-protocol-driven; no daemon changes required.

## Stack & Structure

- **Language:** Lua, Neovim 0.10+.
- **No external runtime dependencies** — `plenary.nvim` is intentionally
  avoided (deprecated). Stay on Neovim core APIs (`vim.uv`,
  `vim.system`, `vim.json`, `vim.ui.*`, `vim.fs`, etc.).
- **Tooling:** `stylua` (format), `selene` (lint), `Taskfile.yml`
  (`task format` / `task lint`), `mise.toml` pins versions.
- **Layout:** flat `lua/hyprpilot/{init,config,log,health,utils,meta}.lua`.
  Subdirectories are added only when a concern grows past ~3 files
  (planned: `client/` for transport + RPC, `chat/` for buffer +
  rendering + folds + pager, `ui/` for composer + permissions).
- **Plugin entry:** `plugin/hyprpilot.lua` runs once at load
  (`vim.treesitter.language.register("markdown", "hyprpilot")`).
- **Style anchor:** [`cenk1cenk2/schema-companion.nvim`](https://github.com/cenk1cenk2/schema-companion.nvim).
  The `init`/`config`/`log` shape is lifted near-verbatim. Match it.

## Conventions

- **Conventional Commits** — `feat:`, `fix:`, `chore:`, `docs:`,
  `refactor:`, `test:`. Scope when meaningful (`feat(client): ...`).
- **Branching** — `feature/*` for new work, `fix/*` or `hotfix/*` for
  fixes. Branches are local until the captain pushes.
- **Module pattern** — every Lua module exports a single `local M = {}` …
  `return M`. No global state outside `M`.
- **Setup chain** — `require("hyprpilot").setup({})` is the only entry
  point. Every behaviour toggle is a config flag with a sensible
  default. Nothing magic.
- **LuaCATS on every public function** — `---@class hyprpilot.Config`,
  `---@field`, `---@param`, `---@return`. Use the dot form
  (`hyprpilot.X`), not underscore.
- **Logger first** — call `log.trace` / `log.debug` liberally during
  development; demote to `info` once a path stabilises. Bad logs equal
  un-debuggable plugin.
- **`:checkhealth` from day one** — even the bootstrap PR ships a real
  `health.lua`. The captain runs it first when something is off.
- **No `plenary.nvim`** — deprecated. Use core APIs: `vim.uv` for IO
  and async, `vim.system` for processes, `vim.fs` for paths,
  `vim.json` for JSON, `vim.ui.*` for prompts. If a helper truly
  doesn't exist, write the small primitive in `utils.lua` instead of
  pulling a dependency.

## Decision Log

- **Style anchor**
  - Chose: mirror `cenk1cenk2/schema-companion.nvim` layout, logger,
    config/setup pattern.
  - Why: captain's own conventions, already battle-tested. Reduces
    cognitive load across the captain's plugin portfolio.
  - Rejected: bespoke layout — would diverge from the captain's other
    plugins for no gain.

- **Logger source**
  - Chose: copy `schema-companion`'s `log.lua` near-verbatim, swap the
    plugin name. It is the rxi → tjdevries (`vlog.nvim`) chain.
  - Why: same shape across the captain's plugins; `vim.notify`-backed
    so it respects user notify backends; two namespaces per level
    (`log.info` deep-inspects via `vim.inspect`, `log.p.info` is plain
    `string.format`).
  - Rejected: rolling our own from scratch — schema-companion's logger
    is already battle-tested and matches the captain's other plugins.

- **Transport (planned for Phase 1)**
  - Chose: `vim.uv.new_pipe()` + `pipe:connect(sockpath, cb)` for the
    JSON-RPC NDJSON stream over the daemon's Unix socket.
  - Why: native Neovim primitive, no external deps for the wire layer,
    full control over the `connecting → connected → disconnected`
    state machine and reconnect back-off.
  - Rejected: HTTP client libraries — the daemon speaks raw JSON-RPC
    over a Unix socket, not HTTP. `vim.uv` is the right primitive.

- **CLAUDE.md vs AGENTS.md**
  - Chose: `CLAUDE.md` at the repo root.
  - Why: captain's explicit instruction at bootstrap.

## Approaches Tried

(Empty — bootstrap PR. Future sessions: append failed approaches and
dead ends here so no one repeats them.)

## Tools & MCP Usage

- **`stylua`** — formatter. `.stylua.toml` is verbatim from
  `schema-companion`: 180 col, 2-space, prefer-double quotes,
  `collapse_simple_statement = "Never"`. `task format` runs it; `task
  lint` runs `stylua --check`.
- **`selene`** — linter. `selene.toml` uses `std = "vim"` with
  `mixed_table = "allow"`. `vim.toml` declares the vim/jit/test
  globals (`describe`, `it`, `assert`).
- **`Taskfile.yml`** — `task format` and `task lint` are the canonical
  entry points. CI calls `task lint`.
- **`mise.toml`** — pins `aqua:Kampfkarren/selene` and `stylua` to
  `latest`. CI installs via mise.
- **`.luarc.json`** — declares `vim` as a global for
  `lua-language-server` so editor diagnostics align with `selene`.
- **GitHub Actions** — `.github/workflows/lint.yml` runs `task lint`
  on every PR and push to `main`.

## Gotchas

- **No `plenary.nvim`** — older Neovim plugin examples reach for
  `plenary.curl`, `plenary.log`, `plenary.async`, `plenary.path`. Do
  not. Use the core API equivalents listed under Conventions.
- **Daemon socket path** — defaults to `$XDG_RUNTIME_DIR/hyprpilot.sock`.
  Override via `setup({ socket = "/path/to/sock" })`. `:checkhealth`
  warns when the socket is missing (daemon not running).
- **`plugin/hyprpilot.lua` runs on every `nvim` start** — keep it
  cheap. Today it only calls
  `vim.treesitter.language.register("markdown", "hyprpilot")`. Do not
  add expensive work there.
- **Treesitter registration is imperative, not via `vim.filetype.add`** —
  the chat buffer (Phase 2+) sets `vim.bo[buf].filetype = "hyprpilot"`
  imperatively when opened. The `language.register` call gives full
  markdown highlighting for free without writing a custom parser.
- **Logger uses `vim.notify`** — output respects the user's notify
  backend (e.g. `nvim-notify`, `noice`). Do not bypass it with
  `print`/`vim.api.nvim_echo` for plugin output.
- **No commands registered yet** — `plugin/hyprpilot.lua` is
  intentionally minimal in the bootstrap PR. `:HyprpilotPrompt`,
  `:HyprpilotInstances`, etc. land in Phase 7+ (see
  `docs/plans/2026-05-09-nvim-plugin-handoff.md`).
