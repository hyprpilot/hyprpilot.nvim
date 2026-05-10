# CLAUDE.md

## Overview

`hyprpilot.nvim` is the Neovim frontend for the
[`hyprpilot`](https://github.com/hyprpilot/hyprpilot) daemon — a local
AI agent runtime that exposes a JSON-RPC surface over a Unix socket at
`$XDG_RUNTIME_DIR/hyprpilot.sock`. The plugin drives the daemon as a
first-class second frontend alongside the desktop app: chat buffer,
streaming output, permission prompts, mode/model switching, session
restoration. All wire-protocol-driven; no daemon changes required.

## Mono-repo Layout

This repository ships **two packages** managed together:

- **Lua plugin (root)** — `lua/hyprpilot/`, `plugin/hyprpilot.lua`. The
  Neovim frontend itself.
- **Python MCP bridge** — `pkg/` subdirectory. `uvx`-runnable MCP
  server (`hyprpilot-nvim-mcp`) that bridges Neovim editor state into
  the agent's tool surface via `pynvim`. See
  [`pkg/CLAUDE.md`](pkg/CLAUDE.md) for Python-specific conventions and
  [`docs/plans/2026-05-09-nvim-mcp-handoff.md`](docs/plans/2026-05-09-nvim-mcp-handoff.md)
  for the implementation roadmap.

`task lint` and `task test` at the root run both subprojects via
`Taskfile.yml`'s `includes:` block (`pkg:` namespace). The Python side
is a [uv workspace](https://docs.astral.sh/uv/concepts/projects/workspaces/):
the root `pyproject.toml` declares `pkg/` as a member, so `uv.lock` and
`.venv/` live at the repo root and are shared across the workspace.
`release-please` is configured for both packages independently — tags
are `hyprpilot.nvim-vX.Y.Z` and `hyprpilot-nvim-mcp-vX.Y.Z`.

## Stack & Structure (Lua plugin)

- **Language:** Lua, Neovim 0.10+.
- **No external runtime dependencies** — `plenary.nvim` is intentionally
  avoided (deprecated). Stay on Neovim core APIs (`vim.fn.sockconnect`
  for socket I/O, `vim.system` for processes, `vim.json` for JSON,
  `vim.uv` for timers, `vim.ui.*` for prompts, `vim.fs` for paths).
- **Tooling:** `stylua` (format), `selene` (lint), `Taskfile.yml`
  (`task format` / `task lint`), `mise.toml` pins versions.
- **Layout:**
  - **Root modules:** `init`, `config`, `log`, `health`, `utils`,
    `client`, `status`, `instances`, `mcp` (each one file).
  - `chat/` — chat surface: `buffer`, `window`, `render`, `events`.
    Future: `folds`, per-block-kind renderers.
  - `ui/` — interactive widgets: `composer`. Future: `permissions`,
    `button_group`.
  - Subdirectories appear only when a concern grows past ~3 files;
    everything else stays flat in `lua/hyprpilot/`.
- **Plugin entry:** `plugin/hyprpilot.lua` runs once at load
  (`vim.treesitter.language.register("markdown", "hyprpilot")`).
- **Style anchor:** [`cenk1cenk2/schema-companion.nvim`](https://github.com/cenk1cenk2/schema-companion.nvim).
  The `init`/`config`/`log` shape is lifted near-verbatim. Match it.

## Conventions

- **Conventional Commits** — `feat:`, `fix:`, `chore:`, `docs:`,
  `refactor:`, `test:`. Scope when meaningful (`feat(client): ...`).
- **Branching** — `feature/*` for new work, `fix/*` or `hotfix/*` for
  fixes, `chore/*` for tooling/infra, `docs/*` for documentation-only
  changes. Branches are local until the captain pushes.
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
- **Use the logger directly** — `lua/hyprpilot/log.lua` auto-wires the
  level functions (`log.debug` / `log.info` / `log.warn` / `log.error`)
  at module load. Any module can `require("hyprpilot.log")` and call
  the level methods immediately, before `setup({})` runs. Do not write
  defensive `if log.debug then ... end` wrappers.
- **`:checkhealth` from day one** — even the bootstrap PR ships a real
  `health.lua`. The captain runs it first when something is off.
- **No `plenary.nvim`** — deprecated. Use core APIs: `vim.uv` for IO
  and async, `vim.system` for processes, `vim.fs` for paths,
  `vim.json` for JSON, `vim.ui.*` for prompts. If a helper truly
  doesn't exist, write the small primitive in `utils.lua` instead of
  pulling a dependency.
- **Inline single-use values** — never name a variable, constant, or
  intermediate table that has only one consumer. Inline directly into
  the call site. The only reason to lift a value into a binding is
  multi-use or a genuine readability win that no inline can match.
  Applies equally to Lua locals, module-level constants, and config
  literals (the `defaults` and `M.options` tables in `config.lua`
  duplicate their contents on purpose to keep zero shared sub-tables).
- **Config knobs ship with their behaviour, not before** — never
  declare a config field whose handler doesn't exist yet. Forward-
  looking knobs rot, drift from their eventual semantic, and confuse
  captains. Add the field in the same PR that wires it.
- **Validation logs and skips, not throws** — captain-facing entry
  points (`mcp.register`, `setup`, anywhere a misconfig is plausible)
  use `log.error` + early return on invalid input rather than `error()`.
  A bad config line should never crash nvim startup; the captain sees
  the warning in their notify backend and life continues.
- **Batch-friendly varargs where it matters** — public APIs that the
  captain might want to call with a list of values take `...` directly
  (e.g., `mcp.unregister(name1, name2, ...)`). Saves the captain a
  loop and signals the operation is naturally batchable.
- **Resolve merge conflicts proactively, in PRs** — when a sibling PR
  lands on `main` and our open PR touches the same file, merge `main`
  back into the open PR's branch immediately and resolve the conflict
  there. Don't push a branch that will conflict at merge time and
  don't ask the reviewer to handle it.
- **Build on Neovim's native primitives, don't re-roll them** — every
  problem with a stock Neovim API gets solved with that API. Examples
  the captain has corrected: `vim.fn.sockconnect("pipe", path,
  { on_data = fn })` over `vim.uv.new_pipe()` for Unix-socket I/O;
  `vim.lsp.rpc.connect()` would be the move *if* the daemon spoke
  Content-Length-framed JSON-RPC (it doesn't — see Decision Log).
  When no native primitive exists for the exact protocol shape, write
  the smallest possible adapter and document the gap.
- **No silent drops** — every code path that ignores or skips a value
  logs it at `debug` (normal flow) or `warn` (unexpected-but-recoverable).
  The captain greps `:messages` (or sets `log_level = TRACE`) when
  something doesn't render and expects to see *why*.
- **Don't re-export module APIs from `init.lua` by default** — captains
  call `require("hyprpilot.instances").spawn(...)` /
  `require("hyprpilot.ui.composer").submit()` etc. directly.
  `init.lua` carries `setup()` plus narrowly-justified shortcuts only.
  We may revisit this when the v1 surface is settled.
- **Group tightly-coupled changes into one PR** — five tiny stacked
  PRs that exist only because they could be split is more reviewer
  burden than one cohesive PR. The captain consolidated the original
  linebuffer + envelope + transport + rpc + status PRs (#7–#11) into
  a single `client.lua` PR (#12) — same lesson applies going forward:
  if changes share a design or a test plan, ship them together.
- **`config.lua` shape: one `defaults` table, `M.options =
  vim.deepcopy(defaults)`** — no shadowing or duplication. Setup
  re-creates `M.options` via `vim.tbl_deep_extend("force", {},
  defaults, user)`. Reads before setup resolve to the deep-copied
  defaults, not a separate stub.

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

- **Transport (shipped in #12)**
  - Chose: `vim.fn.sockconnect("pipe", path, { on_data = fn })` —
    Neovim's stock channel API. `chansend` writes, `chanclose` tears
    down. `on_data` callbacks land on the main loop (no `vim.schedule`
    dance, unlike `vim.uv.new_pipe`).
  - Why: native API exists, use it. Less custom state to maintain
    than `vim.uv.new_pipe()` + `read_start`. State machine collapses
    to `disconnected | connecting | connected`.
  - Rejected: `vim.uv.new_pipe()` — captain pushed back: "USE NATIVE
    FUNCTIONALITY TO BUILD UP ON INSTEAD OF ROLLING OUR OWN STUPID
    SOLUTIONS". sockconnect is the higher-level native; `vim.uv` is
    fine for timers and other primitives that don't have a
    `vim.fn.*` equivalent.
  - Rejected: `vim.lsp.rpc.connect(path)` — supports Unix sockets but
    is **Content-Length framed only**. The hyprpilot daemon ships
    NDJSON. Bridging the daemon to Content-Length framing would touch
    every other frontend (desktop app, `ctl`, future ones); not worth
    it for ~150 lines of plugin Lua.
  - Rejected: msgpack-RPC via `vim.fn.sockconnect("pipe", path,
    { rpc = true })` — would let us use `vim.rpcrequest` directly
    (zero plugin RPC code) but requires the daemon to speak
    msgpack-RPC. Same daemon-rewrite cost as Content-Length, no
    upside for v1.

- **JSON-RPC dispatch (shipped in #12)**
  - Chose: hand-rolled NDJSON line-splitting + `vim.json.decode` +
    in-flight callback table inside `client.lua` (~150 lines total).
  - Why: Neovim ships no NDJSON+JSON-RPC client (its `vim.lsp.rpc`
    is LSP/Content-Length-specific). The smallest adapter wins;
    the daemon's NDJSON wire is a contract used by other frontends
    so we don't change it.
  - Rejected: separate `client/{linebuffer,envelope,transport,rpc}.lua`
    files (the original #7–#11 stack). Captain consolidated to one
    file — too much surface area for what's effectively one unit.

- **Request IDs: UUIDv4 (shipped in #12)**
  - Chose: UUIDv4 strings via a 10-line `math.random` template.
  - Why: collision-free across reconnects and concurrent in-flight
    requests; standard JSON-RPC id shape.
  - Rejected: monotonic integer + `id_generator` helper — captain
    pushed back; UUID is plenty for our scale and removes the helper.

- **Reconnect: simple N-attempt with fixed delay (shipped in #12)**
  - Chose: configurable `connect_attempts` (default 3) and
    `retry_delay_ms` (default 1000) via
    `setup({ client = { ... } })`.
  - Why: the daemon socket is local IPC. Either it's up or it's not.
    Exponential back-off is over-engineering; a couple of fast
    retries and a clean failure is enough.
  - Rejected: `1s → 2s → 5s → 10s → 30s → 60s` exponential ladder
    (the original design). Captain pushed back as "overengineering
    bullshit" for a local socket.

- **Composer keymaps shape (shipped in #15)**
  - Chose: avante-style nested config —
    `composer.keymaps = { submit = { normal = ..., insert = ... },
    cancel = { ... }, close = { ... } }`. Each value is `string |
    string[] | false`. Captain disables an action with `submit =
    false` or per-mode with `submit = { insert = false }`.
  - Why: terse, every action visible at a glance, list values
    cover multi-key bindings. `vim.tbl_deep_extend` keeps any
    sub-field the captain doesn't override.
  - Rejected: codecompanion's heavier `{ modes = { n = ..., i = ... },
    callback = ..., description = ... }` — overkill for our small
    action set.

- **Permission UX (planned)**
  - Will use avante's `ButtonGroupLine` pattern (`lua/avante/ui/
    button_group_line.lua`): horizontal `[ Accept ] [ Reject ] [...]`
    with `<Tab>` cycling focus, `<CR>` clicking, per-buffer dispatch
    registry routing keys by cursor row, fall-through when off the
    button line. Smart-match `g`/`d` shortcuts jump-focus + commit
    Accept/Reject on demand.

- **`init.lua` re-exports (shipped in #13/#15)**
  - Chose: don't re-export module APIs from `init.lua` by default.
    Captains call `require("hyprpilot.instances").spawn(...)` etc.
    directly. `init.lua` keeps `setup()` plus the existing window
    shortcuts (already shipped, kept until proven extra).
  - Why: every re-export is a maintenance touchpoint that drifts
    from the underlying module. The captain greenlit revisiting
    once the v1 surface settles.

- **CLAUDE.md vs AGENTS.md**
  - Chose: `CLAUDE.md` at the repo root.
  - Why: captain's explicit instruction at bootstrap.

## Approaches Tried

- **Five stacked PRs (#7–#11) for the wire stack** —
  `client/{linebuffer, envelope, transport, rpc}.lua` + `status.lua`,
  each as its own PR. Captain rejected for being too granular:
  "we can combine them into bigger ones". Re-shipped as a single
  `client.lua` + `status.lua` PR (#12). Lesson: tight-coupling →
  one PR.
- **`vim.uv.new_pipe()` for the daemon socket (#9)** — captain
  rejected: "we can generally use the native neovim lua mechanisms".
  Re-implemented with `vim.fn.sockconnect` in #12.
- **Exponential reconnect back-off (#9)** — captain rejected:
  "overengineering bullshit" for a local IPC socket. Replaced with
  configurable N-attempt + fixed delay.
- **Forward-looking config knobs (`autoclose`, `enable_exec_lua`,
  defensive logger wrapper `trace()`, etc.)** — every one got pulled
  in review under "config knobs ship with their behaviour, not
  before". Don't add fields/helpers without an active consumer.
- **Hard-coded composer keymaps (#15)** — captain wanted them
  config-driven. Adopted avante's nested-action shape.
- **Re-exporting every module API through `init.lua` (#13, #15)** —
  captain wants modules self-contained for now: "we will think about
  whether we will reexport them or not". Pulled the new re-exports.
- **Duplicating `defaults` and `M.options` literals in `config.lua`** —
  captain pushed back: "why do we have both things at the defaults
  and the config itself it should be either one or other no?".
  Replaced with `M.options = vim.deepcopy(defaults)`.
- **Python `exec_lua` MCP tool (#14)** — captain pulled: "we will
  register it from explicitly the plugin side of the neovim". The
  Python MCP is a pure dispatcher; escape-hatch tools live on the
  Lua side via `require("hyprpilot.mcp").register({...})`.
- **Single-use method constants (`SUBSCRIBE_METHOD`,
  `NOTIFICATION_METHOD`, `SNAPSHOT_METHOD` in #16)** — caught by the
  inline-single-use rule. Inlined.

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
- **GitHub Actions** — `.github/workflows/lint.yml` runs three jobs on
  every PR and push to `main`: `lint-lua` (stylua + selene), `lint-python`
  (`task pkg:lint` — ruff + mypy), and `test-python` (`task pkg:test` —
  pytest). `release-please.yml` opens release PRs per package on push to
  `main`.

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
- **`vim.fn.sockconnect` `on_data` runs on the main thread** — unlike
  `vim.uv.new_pipe`'s `read_start`, you don't need `vim.schedule`
  before touching Neovim API state. The newer-API choice removes a
  whole class of off-thread footguns; don't reintroduce
  `vim.schedule` wrappers when porting code.
- **`events/subscribe` is single-per-connection** — `chat/events.lua`
  calls it once with no `instanceId` filter so every chat buffer
  receives its share. Per-instance routing happens in `dispatch()`
  by reading `event.instanceId`. Don't subscribe again per buffer
  (the daemon returns `-32600`).
- **No Ex commands** — captain wires their own keybinds against
  `require("hyprpilot.*").<fn>(...)`. Don't add `:HyprpilotToggle`
  etc.; they're on the explicit-no list per the planning interview.
