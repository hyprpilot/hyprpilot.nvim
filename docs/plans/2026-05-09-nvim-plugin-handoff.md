# `hyprpilot.nvim` — implementation handoff

> **Status**: handoff doc, ready for the implementer (next session, separate
> repo). The daemon-side contract is settled — PR #31 lands the missing
> `events/subscribe` primitive, plus a per-event `InstanceEvent::event_name()`
> method that gives the wire contract a single source of truth across
> transports. Everything below is the plugin-side scaffolding.

> **Goal**: a Neovim plugin that drives the daemon as a first-class second
> frontend — open a chat surface in a buffer, receive streaming agent output
> live, send prompts, answer permission prompts, switch mode/model, restore
> sessions, all over `$XDG_RUNTIME_DIR/hyprpilot.sock`. No daemon changes;
> fully wire-protocol-driven.

---

## Style anchor

The captain's own plugin sets the conventions: **`schema-companion.nvim`**
(<https://github.com/cenk1cenk2/schema-companion.nvim>). Mirror its layout
verbatim — the implementer should read its `lua/schema-companion/{config,
log,init}.lua` first to internalise the shape. Highlights to copy:

- **Flat `lua/hyprpilot/{init,config,log,health,utils,...}.lua`** — no
  subdirectory unless a concern grows past ~3 files (then promote, e.g.
  `lua/hyprpilot/client/` once the transport is more than one file).
- **Logger** (`log.lua`) — vlog-derived, `vim.notify`-backed. Two namespaces
  per level: `log.info("got %s", x)` deep-inspects args via `vim.inspect`;
  `log.p.info("plain %s", x)` is plain `string.format`. `setup({level})`
  remaps the level. **The implementer copies `schema-companion`'s
  `log.lua` near-verbatim, swaps the plugin name** — same shape, same API.
- **Config** (`config.lua`) — `defaults` table, `M.options` shadows it,
  `M.setup(c) → M.options = vim.tbl_deep_extend("force", {}, defaults, c
  or {})`. `init.lua` exports a thin `setup({})` that chains
  `config.setup → log.setup`.
- **LuaCATS everywhere** — `---@class hyprpilot.Config`, `---@field`,
  `---@type`. Helps the implementer (and future me) navigate without
  guessing shape.
- **No `plenary.nvim`** — deprecated. Stay on Neovim core APIs:
  `vim.uv` for IO/sockets/timers, `vim.system` for processes,
  `vim.json` for JSON, `vim.fs` for paths, `vim.ui.*` for prompts.
  If a small primitive is missing, write it in `utils.lua`.

## Inspirations (not anchors)

Specific techniques worth borrowing — the implementer adopts the patterns
without mimicking any sprawling host layout.

- **Streaming into the buffer** —
  `api.nvim_buf_set_text(buf, last_line, last_col, last_line, last_col,
  lines)` appends at the cursor without a redraw. Standard Neovim API,
  no fancy framework.
- **Tool-call collapsibles** — `foldmethod=manual` plus inline extmarks
  (`virt_text_pos = "inline"`) for icon-only summaries. Avoid
  `conceal_lines`; it's fragile. Manual folds + extmarks is the safer
  path.
- **Custom filetype with markdown highlighting** —
  `vim.treesitter.language.register("markdown", "<filetype>")` lights
  up markdown TS highlights on a custom filetype without writing a
  parser. **No `vim.filetype.add`** — set `vim.bo[buf].filetype =
  "hyprpilot"` imperatively when opening the chat buffer.
- **`LineBuffer` primitive for NDJSON framing** — accumulate fragments
  into a running string, walk for `\n`, fire a per-line callback. Plain
  Lua class, no deps. Lives in `client/linebuffer.lua`.
- **`vim.uv` pipe transport for JSON-RPC** — `vim.uv.new_pipe()` +
  `pipe:connect(sockpath, cb)`. `read_start` callback feeds a running
  `LineBuffer`; per-line: `vim.json.decode` inside a `pcall` guard.
  Keep the `connecting → connected → disconnected/error` state machine
  + `vim.defer_fn` auto-reconnect.
- **Throttled re-render** — `throttle(fn, 50)` on streams that fire
  faster than 60 Hz. Probably not needed for the daemon's streaming
  rate; reach for it if FPS suffers.
- **State badges via extmarks** — single tracked extmark id per badge
  (e.g. "current tool use" indicator), deleted + recreated on update.

## Architecture

```
lua/hyprpilot/
├── init.lua          -- public API + setup() chain
├── config.lua        -- defaults + setup pattern
├── log.lua           -- vlog-derived logger (verbatim from schema-companion)
├── health.lua        -- :checkhealth (socket reachable, nvim version)
├── client/
│   ├── transport.lua -- vim.uv unix-socket NDJSON client
│   ├── linebuffer.lua-- NDJSON framing primitive
│   ├── envelope.lua  -- JSON-RPC request/notification builders + IdGenerator
│   └── rpc.lua       -- request/notify with timeout + dispatch by id/method
├── chat/
│   ├── buffer.lua    -- chat buffer create + filetype + size
│   ├── render.lua    -- write turn / tool / thought to buffer (extmark-aware)
│   ├── pager.lua     -- buffer-trim hack + top-edge prefetch
│   └── folds.lua     -- collapsible blocks (manual fold + virt_text)
├── ui/
│   ├── input.lua     -- composer (split / floating window)
│   └── permissions.lua -- prompt for allow/deny on permission events
├── utils.lua         -- pure helpers (debounce, throttle, etc.)
└── meta.lua          -- shared types + LuaCATS aliases

plugin/hyprpilot.lua    -- one-time at-load: vim.treesitter.language.register("markdown", "hyprpilot")
```

## Phases — bite-sized commits

Each phase is one commit + tests where they make sense. The plugin runs
in a separate repo; CI is `nvim --headless` + `busted` (or `mini.test`)
once tests land.

### Phase 1 — Transport + RPC envelope

**Files**: `client/transport.lua`, `client/linebuffer.lua`,
`client/envelope.lua`, `client/rpc.lua`.

**Steps**:

1. `client/linebuffer.lua` — `LineBuffer:push(data, cb)` primitive.
   Accumulate fragments into a running string, walk for `\n`, fire a
   per-line callback. Plain Lua class; no deps.
2. `client/envelope.lua` — `request(method, params)`,
   `notification(method, params)`, `result(id, value)`, `error(id, code,
   msg)`, `IdGenerator` (incrementing). All JSON-RPC 2.0 standard codes
   as constants (`-32700/600/601/602/603`).
3. `client/transport.lua` — `vim.uv.new_pipe()` + `pipe:connect(sockpath,
   cb)`. `read_start` accumulates into a `LineBuffer`; per-line callback
   does `vim.json.decode`. `write(line)` does
   `pipe:write(line .. "\n")`. State machine: `connecting → connected →
   disconnected`. Reconnect with back-off (1s → 2s → 5s) — same envelope
   the daemon's `ctl status --watch` uses.
4. `client/rpc.lua` — sits on top of transport. `request(method, params,
   opts) → cancellable promise / vim.wait` (5s default timeout).
   `notify(method, params)` for fire-and-forget. Demuxer: response by
   `id` from in-flight map, notification by `method` to per-method
   listener list.

**Verify**: a smoke test that connects, calls `daemon/version`, asserts
the version field is a non-empty string. Fail closed on connect refuse
with a typed error.

### Phase 2 — Snapshot hydration

**Files**: `chat/buffer.lua`, `chat/render.lua`,
`plugin/hyprpilot.lua`.

**Steps**:

1. `plugin/hyprpilot.lua` — `vim.treesitter.language.register("markdown",
   "hyprpilot")` once at load.
2. `chat/buffer.lua` — `create({ instance_id })` returns `{ bufnr, winid
   }`. Sets `vim.bo[buf].filetype = "hyprpilot"`, `buftype=nofile`,
   `swapfile=false`, `bufhidden=hide`, `modifiable=false` (modified only
   under explicit `unlock_buf` / `lock_buf` brackets).
3. `chat/render.lua` —
   - `init(bufnr)` clears the buffer.
   - `render_turn(bufnr, turn)` writes `## user` / `## agent` headers
     + body. Markdown headings; treesitter highlights for free.
   - `render_tool_call(bufnr, call)` writes a placeholder line per
     tool call; phase 4 wraps it in a fold.
   - `render_thought(bufnr, thought)` writes inside a `<details>`-like
     fenced collapsible.
4. On open, call `tauri/instance_snapshot_meta` + `tauri/instance_snapshot_chat
   { limit: 100 }` (or `instance/snapshot/{meta,chat}` — same data via
   the proxy). Render every item.

**Verify**: open a buffer for an existing instance, see the recent
transcript replayed top-to-bottom, no flicker.

### Phase 3 — Live event subscription

**Files**: `client/rpc.lua` (router additions), `chat/render.lua`
(patch path).

**Steps**:

1. After hydration, call `events/subscribe { instanceId }`. Capture the
   reply ack (filter echo) for log + health.
2. Register notification handlers per `event_name`:
   - `acp:transcript` → `render.append_chunk(bufnr, payload)` —
     `nvim_buf_set_text` at end-of-buffer.
   - `acp:turn-started` → `render.open_turn(bufnr, payload)` — write
     `## agent` header (with placeholder for elapsed/usage chips).
   - `acp:turn-ended` → `render.close_turn(bufnr, payload)` — fill in
     elapsed / usage / cost in the header line via extmark virt_text.
   - `acp:permission-request` → `permissions.show(bufnr, payload)`
     (phase 5).
   - `acp:permission-resolved` → `permissions.dismiss(bufnr, payload)`.
   - `acp:terminal` → terminal scrollback updates (phase 4).
   - `acp:instance-meta` → header pill update (mode, model, etc.).
3. `events/lagged` notification → log warn + re-fetch
   `instance/snapshot/chat` for the most recent page (the daemon already
   has the data; just re-hydrate forward).

**Verify**: open a buffer, prompt the agent from elsewhere
(`hyprpilot ctl prompts send ...`), watch chunks land in the buffer
live. No re-render of unchanged turns; only the live tail rewrites.

### Phase 4 — Tool-call collapsibles via extmarks + manual folds

**Files**: `chat/folds.lua`, `chat/render.lua`.

**Steps** (manual-fold + extmark pattern, adapted to our schema):

1. Per-buffer `M.fold_summaries[bufnr] = { [start_row] = { content,
   status, kind } }` table — keyed by line number.
2. Render a tool call as N source lines (the formatter's
   `description`/`fields`/`output` rendered as markdown), then create a
   manual fold `:Nfold <start> <end>` inside `nvim_buf_call`.
3. Set `vim.wo[winid].foldtext = ...` to a global function that reads
   `fold_summaries[bufnr][line]` and emits a one-line summary with an
   icon. Icon resolution per nerd-font set (we own this map; the daemon
   ships `IconKey` enum).
4. `acp:transcript` with `tool_call_update` payload → look up the
   fold by tool-call id (stored in another extmark id table), update
   the fold's source lines, refresh the summary.
5. Status badges (running spinner / done check / failed cross) ride on
   `virt_text` extmarks at the fold's first line. Single tracked
   extmark id per call — delete + recreate on update.

**Verify**: a Bash tool call shows as a one-line collapsed fold with
"⚙ bash · ls (running)" → "✓ bash · ls (200ms)" on completion.
`za` toggles to reveal the description + output.

### Phase 5 — Permissions

**Files**: `ui/permissions.lua`.

**Steps**:

1. On `acp:permission-request`, render a fold-style collapsible IN the
   chat buffer at the current insertion point — same chrome as a tool
   call, but red border + a one-line summary line
   (`⚠ permission · <tool> — Tab/[g]rant/[d]eny`).
2. Buffer-local keybinds: `g` → `permissions/respond { optionId:
   "allow_once" }`, `d` → `... { optionId: "reject_once" }`, `<Tab>` →
   cycle through `formatted.options`. Disabled until the request is
   live (`buftype=nofile` blocks edits but not custom keys).
3. On `acp:permission-resolved` for the matching `requestId`, replace
   the fold's summary with the picked option ("✓ permission · allowed
   (Bash)") and unbind the buffer-local keys.

**Verify**: trigger a tool that needs permission, see the row, press
`g`, see it resolve.

### Phase 6 — Buffer-trim hack + backward pagination

**Files**: `chat/pager.lua`.

This is the captain's specific design ask — no off-the-shelf pattern in
the Neovim chat-buffer space implements it. We roll our own.

**Steps**:

1. Per-buffer `M.window = { max_lines = 5000, trim_to = 4000 }` config.
2. After every batch render, if `nvim_buf_line_count(bufnr) >
   window.max_lines`, drop the top `(line_count - window.trim_to)`
   lines via `nvim_buf_set_lines(bufnr, 0, drop_count, false, {})`
   — bracketed by `unlock_buf`/`lock_buf`.
3. Set a buffer extmark at line 0 with `right_gravity = false` after
   trimming — call this the "trim boundary". Stash the **oldest in-buf
   `seq`** (from the daemon's `SeqTranscriptItem.seq`) on the extmark's
   `details` for the next backward fetch.
4. `BufWinEnter` + `CursorMoved` autocmd: if the window's first
   visible line is within 50 lines of the trim boundary AND we
   haven't already prefetched, call:

   ```
   tauri/instance_snapshot_chat { instanceId, before: <oldest seq>, limit: 200 }
   ```

   Bracket the prepend in `unlock_buf` / `lock_buf` and use
   `nvim_buf_set_lines(bufnr, 0, 0, false, prev_page_lines)`. Update
   the trim-boundary extmark to the new top.
5. Cursor preservation: capture `nvim_win_get_cursor` before prepend,
   restore with `+ #prev_page_lines` row offset after — keeps the
   captain's reading position stable across the prepend.
6. Coalesce concurrent prefetches via a per-buffer `pending_prefetch`
   flag.

**Verify**: scroll up in a long chat, watch the older history page
prepend without losing scroll position; trim back down by scrolling
to the bottom past `max_lines`.

### Phase 7 — Composer

**Files**: `ui/input.lua`, `init.lua` (commands).

**Steps**:

1. `:HyprpilotPrompt` opens a floating window (or split — config flag).
   `filetype=hyprpilot_input`, `buftype=nofile`, `modifiable=true`.
2. `<CR>` (or configurable bind) submits via `tauri/session_submit
   { instanceId, text }`. Close the floater on success.
3. `<C-c>` cancels: `tauri/session_cancel { instanceId }`.
4. (Stretch) palette-style picker for skills / cwd / models / modes
   over the `tauri/skills_list` / `tauri/profiles_list` / etc.
   surfaces. Use telescope or vim.ui.select; the captain's plugin
   habits favour the latter for low ceremony.

**Verify**: prompt → see chunks land in the chat buffer live.

### Phase 8 — Polish + multi-instance

**Steps**:

1. `:HyprpilotInstances` — picker over `instances/list`. Selecting one
   either focuses an existing buffer for that instance or creates a
   new one. Buffer name: `hyprpilot://<instance-id>` for cleanliness.
2. `:checkhealth hyprpilot` — check socket reachable and daemon version
   in supported range.
3. Auto-reconnect: on transport `disconnected`, `vim.defer_fn(reconnect,
   1000 * backoff)` with `1, 2, 5, 10, 30, 60` cap. Surface via a
   statusline component or virt_text "🔌 reconnecting…" at the buffer's
   first line.
4. Per-instance log files via the existing `log.lua` —
   `~/.local/state/nvim/hyprpilot.log` keyed by instance id for the
   captain's grep-driven debugging.
5. README with a 30-second install snippet (lazy.nvim) + the events
   we listen for + the keybinds we register.

**Verify**: kill the daemon, watch the buffer flip to "disconnected",
restart, watch it auto-reconnect + re-hydrate.

## Critical files (in the daemon — for the implementer's reference)

The daemon side is settled; the implementer should not need to touch
any of these. Cite when explaining what each verb does:

- `src-tauri/src/rpc/handlers/events.rs` — `events/subscribe` handler
  + filter shape (this PR).
- `src-tauri/src/rpc/handlers/instances.rs:303-340` — snapshot RPCs
  (`meta`, `chat` with `before` pagination, `terminals`).
- `src-tauri/src/rpc/handlers/permissions.rs:55` —
  `permissions/respond` (the reply path).
- `src-tauri/src/rpc/handlers/prompts.rs` — `prompts/send`,
  `prompts/cancel` (the action path).
- `src-tauri/src/rpc/handlers/tauri_proxy.rs` — full action surface
  (`tauri/session_submit`, `tauri/session_load`, `tauri/permission_reply`,
  `tauri/models_set`, etc.). Use these for the rich verbs.
- `src-tauri/src/adapters/instance.rs` — `InstanceEvent` enum +
  `event_name()` method (the canonical event-name table the plugin
  dispatches on).
- `src-tauri/src/tools/formatter/types.rs` — `FormattedToolCall`
  schema (`title`, `stats`, `description`, `output`, `fields`).
  Plugin renders these verbatim; only icon resolution is plugin-side.

## Critical files (in the plugin — to create)

Listed above per phase. Tally:

- 4 `client/*.lua` files
- 4 `chat/*.lua` files
- 2 `ui/*.lua` files
- 5 root files (`init`, `config`, `log`, `health`, `utils`, `meta`)
- 1 `plugin/hyprpilot.lua`

~16 files total, ~1500-2000 lines of Lua.

## Verification matrix

Manual smoke checklist for the implementer's PR descriptions:

- [ ] `nvim` opens, `:HyprpilotInstances` shows live instances.
- [ ] Selecting one opens a buffer with the recent transcript hydrated.
- [ ] Pressing `<C-Enter>` opens the composer; `<CR>` sends.
- [ ] Streaming output lands in the buffer chunk-by-chunk (no full
      re-render flicker; cursor stays where the captain left it).
- [ ] Tool calls render as collapsed folds; `za` toggles; status
      badge updates from running → done.
- [ ] Permission prompt renders; `g`/`d` resolves; the resolution
      mirrors to the desktop overlay (cross-frontend sync via the
      existing `acp:permission-resolved` event).
- [ ] Scroll up far enough to trigger trim + prefetch; older history
      prepends without losing scroll position.
- [ ] Kill the daemon (`hyprpilot ctl daemon kill`); buffer shows
      "disconnected"; restart; buffer reconnects + re-hydrates.

## What NOT to ship in v0

Defer until the core works:

- **Treesitter parser for hyprpilot's own schema** — using markdown
  via `language.register` is enough for highlighting; a dedicated
  parser is a lot of work for marginal value.
- **xterm.js-style ANSI rendering for `acp:terminal`** — the
  desktop overlay has it (`<XtermView>`); the plugin can render
  terminal output as a plain folded block in v0. Add ANSI parsing
  later if the captain finds the difference jarring.
- **Conceal-based collapsibles** — fragile in practice; manual folds +
  extmarks are the safer path for v0.
- **Local skills/MCP picker** — `:HyprpilotSkills` etc. are nice but
  not blocking. Composer-only is fine for v0.

## Style invariants (from `schema-companion.nvim`)

Pin these in the implementer's brain:

- **Logger first, before any feature work.** Bad logs = un-debuggable
  plugin. `log.trace` calls liberally during development; demote to
  `debug` only when things settle.
- **`setup({})` is the only entry point** the captain configures
  through. Every behavior toggle is a config flag with a sensible
  default; nothing magic.
- **LuaCATS on every public function**. The implementer thanks
  themselves three months later.
- **No global state outside `M`**. Every module's state is namespaced
  to the module table.
- **`:checkhealth` exists from day one** even as a stub. Captain
  expects it; it's the first thing they run when something's off.
- **Stay on Neovim core APIs** — `vim.uv`, `vim.system`, `vim.json`,
  `vim.fs`, `vim.ui.*`. No `plenary.nvim` (deprecated). If a tiny
  helper is missing, write it in `utils.lua`.
