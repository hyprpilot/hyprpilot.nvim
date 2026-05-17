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
`release-please` treats the repo as a single versioned project — one
`vX.Y.Z` tag covers both surfaces. The Lua plugin's "version" lives
only as the git tag (lazy.nvim / packer install from tags directly);
`pkg/pyproject.toml`'s `version` field is mechanically locked to the
tag via release-please's `extra-files` updater. The publish workflow
(`.github/workflows/publish-pypi.yml`) chains off the release-please
job and pushes `hyprpilot-nvim-mcp` to PyPI on every release.

## Stack & Structure (Lua plugin)

- **Language:** Lua, Neovim 0.10+.
- **No external runtime dependencies** — `plenary.nvim` is intentionally
  avoided (deprecated). Stay on Neovim core APIs (`vim.fn.sockconnect`
  for socket I/O, `vim.system` for processes, `vim.json` for JSON,
  `vim.uv` for timers, `vim.ui.*` for prompts, `vim.fs` for paths).
- **Tooling:** `stylua` (format), `selene` (lint), `Taskfile.yml`
  (`task format` / `task lint`), `mise.toml` pins versions.
- **Layout:**
  - **Root modules:** `init`, `config`, `log`, `health`, `client`,
    `status`. The root is reserved for plugin-wide entry points
    and the wire transport — every other concern lives in a
    subdirectory.
  - `rpc/` — daemon RPC wrappers: `instances`, `permissions`,
    `profiles`, `shutdown`. One file per RPC namespace; each module
    is a thin camelCase ↔ snake_case translation layer over
    `client.request` / `client.notify`.
  - `mcp/` — Lua-side MCP tool registry (`init.lua`) plus
    captain-opt-in tool categories (`lsp`, `editor`, `open`). The
    Python bridge in `pkg/` queries `require("hyprpilot.mcp").list()`
    and re-exposes whatever the captain registered. Tool names
    follow `<category>_<verb>` (e.g. `lsp_definition`,
    `editor_grep`, `open_url`); category modules expose a
    `register_all()` helper plus a `M.tools` table for selective
    registration.
  - `chat/` — chat surface (the per-instance markdown buffer):
    `buffer`, `window`, `render`, `events`, `header`, `keymaps`,
    `permission-row`, `queue-strip`, `winbar`, `stats`.
  - `composer/` — captain's typing surface: `init` (the composer
    module proper, reachable as `require("hyprpilot.composer")`)
    and `queue` (per-instance prompt queue).
  - `ui/` — UI widgets + shared UI utilities: `window` (captain-
    facing focus/show/hide facade), `diff-preview` (inline edit
    preview), `keymaps` (shared `apply_action` helper),
    `highlights` (colour scheme).
  - `palettes/` — picker-driven captain UIs over the RPC layer.
  - `completion/` — daemon-backed completion source providers.
  - `notification/` — captain-side attention / bell hooks.
  - Subdirectories appear once a concern grows past ~3 files;
    files stay flat inside their subdirectory until that threshold.
- **Plugin entry:** `plugin/hyprpilot.lua` runs once at load
  (`vim.treesitter.language.register("markdown", "hyprpilot")`).
- **Module shape:** `init` exposes `setup`; `config` holds `defaults`
  + `M.options = vim.deepcopy(defaults)`; `log` is a single
  `vim.notify`-backed leveled logger. The shape is intentionally
  flat and reused across the captain's plugin portfolio — match it.

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
  `vim.json` for JSON, `vim.ui.*` for prompts. If a small primitive
  truly doesn't exist, add it to the module that needs it (or a new
  root module) instead of pulling a dependency.
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
  call `require("hyprpilot.rpc.instances").spawn(...)` /
  `require("hyprpilot.composer").submit()` etc. directly.
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
- **Glyph defaults are nerd-font, configurable, ASCII fallback in
  tests** — `config.options.icons.{tool_status, tool_kind,
  task_status, turn_status}` ship as Font Awesome glyphs (literal
  UTF-8 PUA bytes — `\u{XXXX}` escapes break selene's parser).
  Renderers (`tool_status_badge`, `tool_icon`, `render_plan`,
  `format_stop_chip`) read from these maps with a hard-coded
  ASCII fallback for the case where the captain pre-emptively
  clears the table. Behavioural tests pin the maps to ASCII
  (`[ok]` / `[x]` / etc.) so visible-output assertions stay
  source-readable. Empty-string is treated as "unset" by
  glyph-prefixing helpers — never use Lua truthiness as a
  presence check on user-supplied strings.
- **Don't fight peer plugins** — buffer-level opt-out markers we
  set (the well-known buffer-local keys for git-sign decorators,
  linters, and indent-guide drawers) cover decorations that would
  visually corrupt our render. Layout managers — anything that
  inspects filetype to adopt windows into a managed sidebar —
  get NO opt-out marker. Captains who want adoption register our
  filetypes in their layout-manager config; captains who don't
  set the opt-out themselves. Default stance is "let peers see
  us"; the plugin only opts out where the third-party decoration
  would actively corrupt our render, never preemptively.
- **MCP tool registration is captain-opt-in, not config-driven** —
  every category module under `lua/hyprpilot/mcp/` ships a
  `register_all()` helper plus a `M.tools` table, but the
  captain calls them from their own config. There's no
  `setup({ mcp = { lsp = true, ... } })` flag because the
  captain already has finer-grained control on the daemon side
  (per-profile allow / deny / auto-allow per tool name) and a
  config-side flag would just be a coarser duplicate of that
  policy. Tool names follow `<category>_<verb>` so the agent
  reads the prefix and knows the surface (`lsp_*` for language
  server, `editor_*` for editor state, `open_*` for system
  dispatch).
- **MCP tool implementations vet against current Neovim APIs,
  not third-party plugins** — `mcp/lsp.lua` uses per-client
  `client:request_sync()` (not the soft-deprecated
  `vim.lsp.buf_request_sync`), `make_text_document_params(bufnr)`
  + manual position (not `make_position_params()` which ignores
  `bufnr`), and carries `client.offset_encoding` into
  `locations_to_items` / `apply_workspace_edit` so multi-encoding
  setups don't mis-translate columns. The `mcp-diagnostics.nvim`
  reference repo got the tool surface right but wired the older
  APIs throughout — we took the shape, not the code.
- **Auto-spawn on first show** — `chat.window.show()` with no
  `instance_id` argument and an empty `_instances` registry kicks
  off `instances.spawn({})` and re-enters from the callback. Never
  show captain-facing instructions like "spawn one first" — the
  plugin owns the bootstrap. Placeholder buffer text stays passive
  ("starting…").
- **Behaviour tests, not idiomatic ones** — every Lua test in
  `tests/test_*.lua` drives a real public entry point (the same call
  shape a live wire event or captain keypress would produce) and
  asserts on visible output: buffer text, fold state via
  `foldclosed()`, recorded RPC dispatches. Don't poke at extmark ids,
  block table internals, or other implementation details — those
  shift as the code evolves and tests bound to them lock in
  arbitrary choices instead of catching regressions. Stub
  `client.request` / `permissions.respond` (helpers in
  `tests/helpers.lua`) to capture wire-side effects; never mock the
  modules under test.
- **Plugin filetypes use the dotted `<bare>.markdown` form** — chat
  is `hyprpilot.markdown`, composer is `hyprpilot_composer.markdown`,
  header / queue strip / permission row follow the same shape. The
  bare component drives autocmd patterns (vim's ft pattern matching
  iterates dotted components on its own); the second component
  pulls in markdown's ftplugin AND cmp / snippet sources keyed to
  `"markdown"` for free. Equality checks (`ft == "hyprpilot"` etc.)
  go through `chat_buffer.has_filetype(bufnr, "<bare>")` /
  `is_plugin_buffer(bufnr)` so both bare and dotted forms match.
  `vim.filetype.add` is for path → ft *detection*, not inheritance —
  the dotted compound is the only mechanism vim ships for "this ft
  inherits behavior from another."
- **Per-instance state cleanup is registry-driven** — every module
  that keys a top-level table by `instance_id` (e.g.
  `render._states[id]`, `winbar._meta[id]`, `composer.attachments_by_instance[id]`)
  exposes `M.forget(instance_id)` and is called from
  `chat/window.lua::M.close`'s teardown cascade. Audit gap = stores
  that lingerforever as captains close + reopen instances. New
  per-instance state needs the matching `forget` + cascade entry in
  the same PR. Stores not keyed by instance (e.g.
  `diff_preview._state` — single slot) get a `M.forget(id)` that
  nils itself when `state.instance_id == id`.
- **Lifecycle resources need explicit teardown wiring** — augroups
  with `clear = true` so a hot-reload (`shutdown()` → `setup()`)
  doesn't double-register; subscription APIs return unsubscribe
  closures that get tracked + invoked from `rpc/shutdown.lua`'s step
  list (not from a per-module `_reset`-only path); per-buffer
  autocmds use a per-buffer augroup name so re-attaching the same
  buffer doesn't pile up handlers.

## Decision Log

- **Module shape**
  - Chose: flat `init` / `config` / `log` modules, one `local M = {}`
    per file, `setup(opts)` as the only entry point, `M.options`
    deep-copied from a single `defaults` literal in `config.lua`.
  - Why: matches the rest of the captain's plugin portfolio so a
    one-look read on any file is enough to find the surface.
  - Rejected: bespoke layout per concern (separate `init`/`bootstrap`/
    `start` files, OO wrapper around the module table) — every
    re-spelling of the same shape is a cognitive tax for no gain.

- **Logger source**
  - Chose: a single `vim.notify`-backed leveled logger
    (`log.trace/debug/info/warn/error`) auto-wired at module load, no
    `setup()` order dependency. Two namespaces per level (`log.info`
    deep-inspects via `vim.inspect`, `log.p.info` is plain
    `string.format`).
  - Why: `vim.notify` is the captain's own routing surface, so log
    output respects whatever notification backend they wire.
  - Rejected: rolling a custom file-tail / structured-event logger —
    overkill for a frontend plugin; `:messages` plus the captain's
    notify backend is the canonical Neovim log surface.

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
  - Chose: nested per-mode config —
    `composer.keymaps = { submit = { normal = ..., insert = ... },
    cancel = { ... }, close = { ... } }`. Each value is `string |
    string[] | false`. Captain disables an action with `submit =
    false` or per-mode with `submit = { insert = false }`.
  - Why: terse, every action visible at a glance, list values
    cover multi-key bindings. `vim.tbl_deep_extend` keeps any
    sub-field the captain doesn't override.
  - Rejected: heavier `{ modes = { n = ..., i = ... }, callback =
    ..., description = ... }` shape — overkill for our small
    action set; the per-mode collapse beats it on read-time.

- **Permission UX (shipped)**
  - Horizontal button strip `[ Accept ] [ Reject ] [ Diff ]` with
    `<Tab>` cycling focus, `<CR>` committing the focused option,
    smart-match `<localleader>a` / `<localleader>d` jump-focusing
    Accept / Reject on demand. The strip lives in its own pinned
    1-row split below the chat (auto-grows to `max_height`); the
    chat buffer never carries permission UI inline.

- **`init.lua` re-exports (shipped in #13/#15)**
  - Chose: don't re-export module APIs from `init.lua` by default.
    Captains call `require("hyprpilot.rpc.instances").spawn(...)` etc.
    directly. `init.lua` keeps `setup()` plus the existing window
    shortcuts (already shipped, kept until proven extra).
  - Why: every re-export is a maintenance touchpoint that drifts
    from the underlying module. The captain greenlit revisiting
    once the v1 surface settles.

- **CLAUDE.md vs AGENTS.md**
  - Chose: `CLAUDE.md` at the repo root.
  - Why: captain's explicit instruction at bootstrap.

- **Window chrome / icon / keymap conventions (shipped in #60)**
  - **`buffer.suppress_external_ui(bufnr)` + `buffer.clean_window_chrome(winid)`** —
    paired helpers in `chat/buffer.lua` applied to every plugin-
    owned buffer / window (chat, header, queue strip, permission
    row, composer). Sets the documented buffer-local opt-out keys
    for git-sign decorators, linters, and indent-guide drawers;
    sets blank `statusline` / `winbar`, no numbers / signcolumn /
    cursorline / fold column, hides EOB `~` glyphs via `fillchars
    eob: `. Chat folds use `foldcolumn = "0"` (cleaner UI; folds
    still drive via `[h` / `]h` jumps and the manual `:N,Mfold`
    calls from `chat/render.lua`) and re-assert their setup via
    `chat/window.lua::M.apply_fold_setup(winid)` on every
    `BufWinEnter` / `WinEnter` / `FileType` so a layout manager
    (edgy) adopting the window can't strand us with stock
    `foldmethod` defaults.
  - Why a single helper pair: every plugin window had been
    re-spelling the same six `vim.wo` lines. One helper means a
    new opt-out marker gets added in exactly one place.
  - **`config.icons.{tool_status, tool_kind, task_status, turn_status}`** —
    nerd-font glyphs by default (Font Awesome subset). Pasted as
    literal UTF-8 PUA bytes (NOT `\u{XXXX}` escapes — selene's
    parser rejects them). Captains without a nerd font override
    with ASCII via `setup({ icons = { ... } })`. Tests pin to
    ASCII fallback so visual assertions (`[ok]`, `[run]`, `[x]`,
    etc.) stay readable in source.
  - Why nerd-font defaults: the captain's terminal already ships
    one for everything else (LSP signs, tree-sitter folds, file
    explorers). Defaulting to ASCII would make hyprpilot the
    odd-one-out; ASCII is opt-in for the no-font case.
  - **`<localleader>` defaults across permission row / diff preview /
    composer cancel** — sidesteps every collision class (`<C-o>` =
    jumplist back, `<C-g>` = file info, `<C-r>` = redo, `<C-c>` =
    pending-operator interrupt) without claiming top-level keys.
    Captains who prefer the older `<C-*>` binds add them as
    `accept = { "<localleader>a", "<C-g>" }` (list form) — no API
    break.
  - **`[h`/`]h` (turn) + `[s`/`]s` (section) jump keymaps** in
    `chat/keymaps.lua`. Anchor rows come from the live
    `render._states[*].turn_layouts[*].pilot_header_mark` /
    `sections[*].head_mark` extmarks (re-exported as `render.NS`
    so `keymaps.lua` doesn't redeclare the namespace string). The
    `[h`/`]h` pair follows vim's stock next-of-kind family
    (`]m`, `]s`); `[s`/`]s` would normally claim spell-check, but
    the chat buffer is read-only with `spell = false` so reusing
    it for "section" doesn't fight anything.

- **Auto load-older on cursor-near-top (shipped in #60)**
  - Chose: `CursorMoved` autocmd on the chat buffer; when
    `vim.fn.line('w0') <= 3` and `state.has_more`, fire
    `events.load_older(instance_id)` once. In-flight lock
    (`state._load_older_lock`) released in the hydrate callback
    so a fast `<C-u>` doesn't queue N daemon round-trips.
  - Why: a manual "load older" keybind is friction; the captain
    expects scrollback to extend as they scroll up, the way every
    chat client does it. The throttle keeps the daemon happy.
  - Rejected: `WinScrolled` only — fires per scroll event without
    a position guard; would over-trigger. `CursorMoved` plus a
    `w0 <= 3` check is the cheap right thing.

- **Lua test framework: `mini.test`**
  - Chose: `mini.test` (from `echasnovski/mini.nvim`), shallow-cloned
    into `vim.fn.tempname()` by `scripts/minimal-init.lua` on every
    `task test-lua` invocation. Neovim wipes the temp dir on exit;
    nothing persists in the repo or the user's cache.
  - Why: `plenary.nvim`'s `busted` is the de facto standard but
    plenary is on the explicit-no list (see Conventions). `mini.test`
    has zero hard deps, ships full test isolation via child-nvim
    factories when we want it (`MiniTest.new_child_neovim()`), and is
    a single repo we can pin without pulling its sibling modules.
  - Rejected: a repo-local `.testdeps/` cache — leaks state into the
    project tree and needs `.gitignore` / `.styluaignore` /
    `selene.toml` exclusions. Captain pushed back: just use a Neovim-
    managed temp dir.
  - Rejected: `stdpath('cache')` for persistence — also leaks state,
    just into `~/.cache/nvim` instead of the repo. Per-run clones
    are fast enough with `--depth=1 --filter=blob:none`.
  - Rejected: `nvim-test` (lower adoption, wraps busted directly);
    rolling our own (`/tmp/smoke_*.lua`-style headless scripts) — no
    diffs, no per-case isolation, no shared collector. We did this in
    early development and graduated to `mini.test` once the surface
    was big enough to warrant it.

- **Always-folded tool calls + no re-fold during streaming**
  - Chose: fold every `tool_call` block once at create-time (in
    `render_tool_call`), NEVER re-fold during `handle_tool_call_update`.
    Manual folds survive `nvim_buf_set_lines` body modifications via
    the extmark range.
  - Why: the original "fold on terminal state" UX flopped layout
    under the cursor every time a tool finished. Re-folding on every
    streaming chunk stacked manual folds (`:N,Mfold` creates a NEW
    fold per call) — captains needed N+1 `zo`s to read a tool's
    output. Fold once, trust the extmark range, stay collapsed.

- **Turn outcome at prose tail, not header pill**
  - Chose: drop a single `> <reason>` markdown blockquote at the
    prose tail in `handle_turn_ended`, highlighted by category via
    `HyprpilotTurnEnd{Ok,Cancelled,Error}`. Cancel-shaped reasons
    match `:lower():find("cancel")`; errors win over reasons. Text
    is the daemon's verbatim `event.stopReason` / `event.error` —
    no `"ok " .. reason` humanisation.
  - Why: header pill was easy to miss past a long response. The
    captain's eyes are at the prose tail after reading the answer;
    the marker lives there. Daemon is the source of truth for
    wording; humanising plugin-side drifts from the desktop UI.
  - Rejected: `format_stop_chip` with glyph + `"ok " / "cancelled "
    / "error: "` prefixes — drift problem above; plus the empty-
    glyph footgun (Lua truthy includes `""`) bit us once already.

- **Tools section header aggregated stats**
  - Chose: `### tools [N calls] [+X] [-Y] [Zs]` with diffs +
    duration summed across every tool_call in the section.
    `recompute_section_aggregate(state, section)` walks
    `section.block_ids`, sums `formatted.stats[*]` diff (`added` /
    `removed`) and duration (`ms`) entries. Wholesale per-block
    replacement on update mirrors the daemon's running totals (per-
    event state, not delta — summing on top would double-count).
  - Why: tool blocks now stay folded for their lifecycle; without
    the rolled-up section pill the captain has no at-a-glance
    sense of "this turn touched +120 -30 lines in 3.4s."

- **Auto-reconnect (peer EOF + timeout streak)**
  - Chose: `client.lua` self-heals two failure modes — vim's
    `{""}` channel-callback EOF (daemon crash / restart closes the
    socket) AND a 3-consecutive-timeout streak (daemon hung but
    socket open). Both teardown + flip disconnected + schedule a
    deferred `M.connect()` after `retry_delay_ms`.
    `auto_reconnect_pending` flag gates so a flood of EOFs can't
    enqueue parallel reconnects. `timeout_streak` resets on every
    successful reply.
  - Why: a daemon restart used to leave the plugin in
    `disconnected` until the captain manually called
    `client.reconnect()`. Self-healing makes the captain's session
    survive routine daemon churn.

- **Diff preview window resolution**
  - Chose: `ui/diff-preview.lua::resolve_host_window` uses
    `chat_buffer.find_editor_winid` (same routing
    `mcp/editor.lua` uses for `editor_file_open` / `jump`) and
    returns `(winid, owned)`. `owned = true` when no editor
    window was visible and we created a fresh `:topleft new` —
    `M.close`'s `unwire` then `nvim_win_close`s it so the
    captain doesn't end up with a `[No Name]` ghost split.
  - Why: previous bespoke `vim.startswith(ft, "hyprpilot")`
    filter drifted from the shared helper; fresh splits hung
    around after preview close.

- **Shutdown step order: `cleanup_owned` BEFORE `client.disconnect`**
  - Chose: `rpc/shutdown.lua::M.shutdown` runs `instances.cleanup_owned()`
    as a step BEFORE `client.disconnect` so daemon-side
    `instances/shutdown` requests reach the channel for owned
    (`spawned_with_shutdown = true`) instances. Manual `M.shutdown()`
    (hot-reload) and `VimLeavePre` both pick up the cleanup.
  - Rejected: a standalone `VimLeavePre` autocmd in
    `rpc/instances.lua` — registered when the module first
    lazy-loaded (typically when the captain spawned an instance),
    so the autocmd registered AFTER `HyprpilotShutdown` (eager
    during `setup()`). Vim fires autocmds in registration order
    → disconnect ran first → cleanup hit a dead channel → silently
    no-op'd. Order-sensitive teardown joins the eager surface
    instead of competing with it.

- **Plugin-owned filetypes mirror markdown via the dotted alias**
  - Chose: every plugin buffer's `vim.bo[bufnr].filetype` is
    `<bare>.markdown` — chat (`hyprpilot.markdown`), composer
    (`hyprpilot_composer.markdown`), header
    (`hyprpilot_header.markdown`), permission row, queue strip.
    Bare component still drives our pattern-matching autocmds (vim
    iterates dotted components on its own); second component
    inherits markdown's ftplugin + treesitter parser + cmp /
    snippet sources keyed to `"markdown"`. Equality checks shift
    to `chat_buffer.has_filetype` / `is_plugin_buffer`.
  - Why: composer needed markdown's tooling surface (codeblock
    snippets, table expansions). Symmetric dotting across every
    plugin ft eliminates the chat-bare-vs-composer-dotted asymmetry
    captains hit when wiring `add_disabled_filetypes` / cmp's
    `per_filetype` table.
  - Rejected: keep the asymmetry (chat bare, composer dotted) —
    captains kept tripping on it. Rejected: drop the dot from
    composer and manually `runtime ftplugin/markdown.vim` from a
    `FileType` autocmd — workable but loses cmp / snippet
    inheritance, and captains still have to enumerate sources
    per ft.

- **`composer.attach_file(path)` — generic disk-file attach**
  - Chose: `composer.attach_file(path, opts?)` reads the file,
    classifies via mime (`guess_mime`) → text routes to `body`
    (`vim.fn.readfile`); binary routes to `data` (`vim.uv.fs_read`
    + `vim.base64.encode`). Unknown mime falls through to a null-
    byte sniff on the first 1 KiB. `composer.attach.max_bytes`
    (default 8 MiB) caps per-file payload so a stray
    `attach_file("/var/log/syslog")` doesn't ship a 200 MB blob.
  - Why: previous `attach_clipboard_image` was image-specific
    plumbing; `attach_buffer` is unsaved-buffer-specific. Generic
    disk-file path covers every other case (PDFs, screenshots,
    arbitrary blobs) without per-mime helpers.
  - Rejected: keep `attach_clipboard_image` as a first-class API
    — captains needing the clipboard flow write a 3-line wrapper
    (`img-clip.save_image(temp_path) → attach_file(temp_path)`).

- **`chat.window.M.show` re-entry guard (`_show_in_progress`)**
  - Chose: top-level `M.show` is a thin wrapper that bails when
    `_show_in_progress == true`, sets the flag, pcalls
    `M._show_inner(instance_id)`, clears the flag. The cascade body
    (capture associated buffer, open split, hydrate, header / queue-
    strip / permission-row / composer opens) lives in `_show_inner`.
  - Why: `show()`'s lifecycle restore cascade fires a chain of
    `BufWinEnter` / `WinEnter` / `BufEnter` autocmds across every
    surface. A peer plugin (layout manager retrying adoption,
    completion engine rebinding) or a captain's `User
    HyprpilotInstanceChanged` autocmd that calls our focus / show
    path re-enters mid-cascade, re-running every step on the half-
    built layout — captain's "infinite loop of trying to restore
    it." Guard makes the re-entrant call a no-op; the first call's
    cascade completes cleanly. Async paths (auto-spawn callback)
    re-enter via the public `M.show` after the wrapper has cleared
    the flag, so they work normally.
  - Rejected: per-surface guards (header + composer + queue-strip
    each tracking their own re-entry). The cascade is the unit of
    work; the guard wraps the unit.

- **`palettes/instances` cwd filter (sessions-style API)**
  - Chose: `palettes.instances.open({ cwd? })` filters rows
    against `item.cwd`. `nil` → `vim.fn.getcwd()` default,
    `false` → no filter, `string` → that path. Mirrors
    `palettes/sessions.lua` exactly so captains learn the shape
    once.
  - Why: captains in a different project hit "pick instance" and
    don't want to scroll past unrelated instances; default
    behaviour matches the cwd they're in.
  - Cross-repo dependency: daemon must ship `cwd` on
    `InstanceListEntry` (plan handoff at
    `~/.claude/plans/hello-this-will-be-mutable-papert.md`).
    Until that lands every item's `cwd = nil` and the default
    filter shows nothing — the right fail-loud signal.

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
  config-driven. Adopted the per-mode nested-action shape under
  `composer.keymaps.{submit,cancel,close}.{normal,insert}`.
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
- **`prompts/cancel` as `client.notify`** — daemon's handler returns
  `HandlerOutcome::Reply` (request-shaped, requires id). Notification
  shape got back `id: null` + `-32600 "missing or invalid id"` and
  silently no-op'd `<C-c>`. Re-shipped as `client.request` with a
  warn-on-error callback. Lesson: always cross-check the wire shape
  in `src-tauri/src/rpc/handlers/*.rs` before picking
  `request` vs `notify`.
- **Default permission focus computed plugin-side only** — the daemon
  now ships `defaultOptionId` on `PermissionRequestSnapshot`
  (`src-tauri/src/adapters/permission.rs`). The local `kind` /
  `^allow` heuristic stays as a fallback (older daemons), but the
  daemon hint wins when present so policy decisions stay server-side.
- **`<C-o>` for show_diff** — collided with vim's jumplist-back. Re-
  bound to `<localleader>g`; same swap for accept (`<localleader>a`)
  / reject (`<localleader>d`) on permission row + diff preview.
  Composer cancel kept `<C-c>` for insert mode (TUI muscle memory)
  but flipped normal-mode to `<localleader>c` so it doesn't race
  vim's pending-operator interrupt.
- **Pre-emptive opt-out from layout-manager adoption** — captain
  rejected: layout-manager peer plugins should be free to adopt
  our windows when the captain registers our filetypes with them.
  We keep buffer-local opt-outs for git-sign decorators / linters /
  indent-guide drawers (those produce visual noise on a pure UI
  buffer) but stay hands-off on layout managers. Lesson: respect
  peer plugins; opt out only when the third-party decoration would
  make our surface unreadable.
- **Empty-string glyph treated as truthy in `format_stop_chip`** —
  Lua's `truthy` includes `""`, so a captain who clears
  `icons.turn_status.ok = ""` would have gotten ` ok end_turn`
  with a leading space. Switched to explicit `nil`/`""` check via
  a `with_glyph(glyph, body)` helper. Lesson: never use Lua's
  short-circuit truthiness as a "is this set?" check for strings.
- **"Spawn a session first" placeholder text** — captain rejected:
  "if a session does not exists please spawn it with empty
  variables". `chat.window.M.show()` now auto-fires
  `instances.spawn({})` and re-enters with the new id when the
  registry is empty. Placeholder text reduced to "starting…" — the
  captain shouldn't be told to do something the plugin can do for
  them.
- **Re-folding tool blocks on every streaming chunk** — `:N,Mfold`
  STACKS manual folds; calling `:fold` on the same range twice
  creates two separate fold objects. Captain hit `zo` once → outer
  layer opened, inner stayed closed → "I can't expand the tool."
  Now: fold once at create, trust the extmark range.
- **Stop reason as `## pilot` header pill** — easy to miss past a
  long response. Replaced with the prose-tail `> <reason>` marker
  (PR #89). Daemon-verbatim text — no humanisation, since
  plugin-side wording drifts from whatever the desktop UI shows.
- **Standalone `VimLeavePre` autocmd for `instances/shutdown`
  cleanup** — `rpc/instances.lua` registered its cleanup autocmd at
  module-load time, AFTER `HyprpilotShutdown` (eager during
  `setup()`). Vim fires autocmds in registration order →
  `client.disconnect` ran first → cleanup hit a dead channel and
  silently no-op'd via `pcall + empty callback`. Manual
  `M.shutdown()` (hot-reload) didn't trigger the autocmd at all.
  Moved cleanup into `rpc/shutdown.lua::M.shutdown` as a step before
  `client.disconnect`.
- **`attach_clipboard_image` as a first-class composer API** — folded
  into `attach_file(path)` once mime detection covered binary + text.
  Captains needing the clipboard flow write a 3-line wrapper
  (`img-clip.save_image(temp_path) → attach_file(temp_path)`).
- **Synchronous `require("edgy.layout").layout()` inside
  `open_aux_split`** — was firing right after `nvim_win_set_buf`
  to close the "edgy unhooks on empty-ft scratch split then
  doesn't re-adopt after the buffer swap" race. Worked in
  isolation but re-entered `BufWinEnter` / `WinEnter` autocmds
  on the same tick. Under the lifecycle restore cascade in
  `chat.window.M.show()` (four aux-splits opening in
  succession), a sibling-collapse race produced the captain's
  "infinite loop of trying to restore it" symptom. Replaced
  with the debounced `M.nudge_edgy_layout()` helper (already
  used by composer / queue-strip / permission-row resize
  paths); the 100ms coalesce closes the same race without the
  same-tick autocmd re-entry. Lesson: anything that triggers
  `BufWinEnter` / `WinEnter` indirectly belongs OUT of the
  current tick when it lives inside an open-path that is
  itself called many times during a cascade.

## Tools & MCP Usage

- **`stylua`** — formatter. `.stylua.toml` pins 180 col, 2-space,
  prefer-double quotes, `collapse_simple_statement = "Never"`.
  `task format` runs it; `task lint` runs `stylua --check`.
- **`selene`** — linter. `selene.toml` uses `std = "vim"` with
  `mixed_table = "allow"`. `vim.toml` declares the vim/jit/test
  globals (`describe`, `it`, `assert`, `MiniTest`).
- **`Taskfile.yml`** — `task format` and `task lint` are the canonical
  entry points. `task test-lua` runs the Lua suite via `mini.test`;
  `task test` chains `test-lua` + `pkg:test`. CI calls `task lint`
  per language and `task test-lua` / `task pkg:test` separately.
- **`mini.test`** — Lua test runner. `scripts/minimal-init.lua`
  clones `mini.nvim` into `vim.fn.tempname()` on every invocation;
  Neovim wipes the temp dir on exit, so the repo (and the user's
  cache / data dirs) stay untouched. Then `nvim --headless -u
  scripts/minimal-init.lua -c "lua MiniTest.run()" -c "qa!"` collects
  every `tests/test_*.lua`. The clone is `--depth=1
  --filter=blob:none` so it stays fast even without caching.
- **`mise.toml`** — pins `aqua:Kampfkarren/selene` and `stylua` to
  `latest`, plus `neovim = "latest"` so CI has `nvim` for `task
  test-lua`. CI installs via mise.
- **`.luarc.json`** — declares `vim` as a global for
  `lua-language-server` so editor diagnostics align with `selene`.
- **GitHub Actions** — `.github/workflows/lint.yml` runs four jobs on
  every PR and push to `main`: `lint-lua` (stylua + selene),
  `lint-python` (`task pkg:lint` — ruff + mypy), `test-python`
  (`task pkg:test` — pytest), and `test-lua` (`task test-lua` —
  mini.test, fresh clone per run via `tempname()`).
  `release-please.yml` opens release PRs per package on push to `main`.

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
- **Logger uses `vim.notify`** — output respects whatever notify
  backend the captain has wired. Do not bypass it with
  `print` / `vim.api.nvim_echo` for plugin output.
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
- **`:N,Mfold` stacks** — running `:fold` over an already-folded
  range creates a SECOND fold object on top. Captain has to `zo`
  once per layer to expand. For "always folded" semantics, fold
  ONCE at block creation; trust the manual fold to survive
  `nvim_buf_set_lines` body modifications via the extmark range.
  Re-folding mid-stream is the bug.
- **Vim autocmd registration order matters** — autocmds fire in
  registration order within an event. A lazy-required module that
  registers its autocmd on first use lands AFTER an eager module
  that registered during `setup()`. Order-sensitive teardown joins
  the eager surface (`rpc/shutdown.lua`'s step list) instead of
  competing as a separate autocmd.
- **`nvim_buf_delete(force = true)` doesn't close windows** —
  windows showing the deleted buffer switch to an alternate
  (usually a new empty unnamed buffer). On VimLeavePre we walk
  `nvim_list_wins()` and explicitly close any window holding a
  `hyprpilot://` buffer BEFORE wiping the buffers themselves.
  Otherwise the captain's exit screen carries blank `[No Name]`
  ghosts where the chat / composer used to be.
- **`vim.filetype.add` is for path → ft *detection*, not
  inheritance** — the dotted compound (`<ft>.markdown`) is the
  only mechanism vim ships for "this ft inherits behavior from
  another." A `FileType` autocmd that runs `runtime
  ftplugin/markdown.vim` is a workaround that loses cmp / snippet
  inheritance; the dot is the right tool.
- **Cascade-shaped public APIs need a re-entry guard** — anything
  that fires many `BufWinEnter` / `WinEnter` / `BufEnter` autocmds
  in sequence (most notably `chat.window.M.show`'s lifecycle
  restore: chat split → header → queue-strip → permission-row →
  composer) is an attractor for peer-plugin reactions and captain-
  wired `User Hyprpilot*` autocmds. The mid-cascade re-entry runs
  every step against a half-built layout. Wrap the cascade body
  in an `_in_progress` flag; the top-level entry no-ops when set.
  Async paths (RPC reply callbacks) hit the public entry AFTER
  the wrapper has cleared the flag, so they aren't impacted.
