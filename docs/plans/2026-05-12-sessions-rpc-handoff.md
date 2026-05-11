# Daemon handoff: expose `sessions/list` + `sessions/load` on the Unix-socket RPC

> **For the daemon-side AI:** This is a self-contained handoff.
> Everything you need to scope, implement, and verify the work is
> below. If a section turns out to be wrong (e.g. the adapter API
> moved since this was written), check the current code as the
> authoritative source and update this doc as you go.

## TL;DR

The Neovim plugin (`hyprpilot.nvim`) now ships a sessions palette
that calls `sessions/list` + `sessions/load` over the Unix-socket
RPC. Both methods exist as Tauri commands today (the desktop app
drives them) but the public socket dispatcher returns
`-32601 method_not_found` for both.

Wire them on the dispatcher, mirroring the PR #36 pattern that
exposed `instances/setMode` / `setModel` / `setOption`. Adapter
methods already exist; just need handler routing + a public
trait surface (if not already there).

After this lands, the plugin's existing `palettes/sessions.lua`
(graceful `-32601` fallback today) lights up automatically with
zero plugin-side changes.

## Audit context (where this came from)

Cross-check of every RPC the plugin invokes against the daemon's
public socket dispatcher. 19 unique methods called; 17 wired, 2
missing — both sessions:

| RPC | Wire status |
|---|---|
| `daemon/version` | ✅ |
| `events/subscribe` | ✅ |
| `instances/{list,focus,spawn,info,restart,shutdown,rename}` | ✅ |
| `instance/snapshot/{chat,meta,terminals}` | ✅ |
| `instances/{setMode,setModel,setOption}` | ✅ (PR #36) |
| `permissions/{pending,respond}` | ✅ |
| `prompts/send` | ✅ (#37 added attachments support) |
| **`sessions/list`** | ❌ — pruned (`src-tauri/src/rpc/server.rs:555`, `src-tauri/src/rpc/mod.rs:224`) |
| **`sessions/load`** | ❌ — no handler, no entry in pruned list either |

`sessions/list` is in the
`dispatch_pruned_namespaces_are_method_not_found` test → returns
`-32601` over the socket. `sessions/load` isn't even mentioned;
the dispatcher's catch-all `method_not_found` arm catches it.

Same shape as the PR #36 handoff: adapter method already exists
(the Tauri command layer drives it for the desktop app), wire
dispatcher routing is what's missing.

## Required wire methods

### `sessions/list`

**Params** (all optional — empty object means "every session"):
```json
{
  "cwd": "/path/to/project"   // when present, filter to sessions whose cwd matches
}
```

**Reply**:
```json
{
  "sessions": [
    {
      "sessionId": "uuid",
      "agentId": "claude-code",
      "profileId": "personal/claude/opus",
      "cwd": "/path/to/project",
      "title": "Refactor the auth middleware",
      "lastSeenAt": "2026-05-12T15:34:21Z"
    }
  ]
}
```

The desktop app's `tauri_proxy::session_list` handler (currently
at `src-tauri/src/rpc/handlers/tauri_proxy.rs:643`) already
returns this shape — lift it onto the wire. The plugin's
`palettes/sessions.lua::from_wire(...)` does camelCase →
snake_case translation on its end, so any of these field names
the daemon already settled on will work as long as they're the
same camelCase the Tauri command emits.

### `sessions/load`

**Params**:
```json
{
  "sessionId": "uuid",
  "cwd": "/path/to/project",          // optional; default: session's recorded cwd
  "agentId": "claude-code",            // optional; the daemon resolves from session
  "profileId": "personal/claude/opus"  // optional; same
}
```

**Reply**:
```json
{
  "instanceId": "fresh-instance-uuid"
}
```

Mirrors the `instances/spawn` reply shape so the plugin's
post-load handoff (`instances.info(instance_id)` →
`chat.window.show(instance_id)`) Just Works™.

The daemon adopts the supplied `sessionId` verbatim into the
spawned instance — no UUID re-mint on the daemon side. Same
contract `acp::load_session` already enforces for the desktop
app.

## Implementation steps

### 1. Recon

Use these as starting points (verify they're current — files may
have moved):

- `src-tauri/src/rpc/handlers/instances.rs` — model handler
  module to mirror (look at how `setMode` / `setModel` /
  `setOption` route through the `Adapter` trait).
- `src-tauri/src/rpc/handlers/tauri_proxy.rs:643` — existing
  `session_list` Tauri handler that today bridges the desktop
  app's call into `acp::list_sessions`. The same adapter call
  is what the wire handler should make.
- `src-tauri/src/adapters/acp/instances.rs` — confirm where
  `list_sessions` and `load_session` live on `AcpAdapter`. If
  they're concrete-impl-only (not on the `Adapter` trait), you
  have two options:
  1. Lift them onto the trait (clean — matches setMode /
     setModel / setOption shape).
  2. Downcast through the registry the way `instances/info`
     does. Slightly heavier but no trait change.

### 2. Add handler module

Create `src-tauri/src/rpc/handlers/sessions.rs` mirroring
`instances.rs`:

```rust
pub struct SessionsHandler;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListParams {
    #[serde(default)]
    cwd: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoadParams {
    session_id: String,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    agent_id: Option<String>,
    #[serde(default)]
    profile_id: Option<String>,
}

#[async_trait::async_trait]
impl RpcHandler for SessionsHandler {
    fn methods(&self) -> &'static [&'static str] {
        &["sessions/list", "sessions/load"]
    }

    async fn handle(
        &self,
        method: &str,
        params: Option<Value>,
        ctx: &HandlerCtx<'_>,
    ) -> Result<HandlerOutcome, RpcError> {
        match method {
            "sessions/list" => {
                let ListParams { cwd } =
                    params_or_default::<ListParams>(params, method)?;
                let sessions = ctx
                    .adapter
                    .list_sessions(cwd.as_deref())
                    .await
                    .map_err(map_adapter_err)?;
                Ok(HandlerOutcome::Reply(json!({ "sessions": sessions })))
            }
            "sessions/load" => {
                let LoadParams {
                    session_id,
                    cwd,
                    agent_id,
                    profile_id,
                } = parse_params::<LoadParams>(params, method)?;
                let instance_id = ctx
                    .adapter
                    .load_session(&session_id, cwd, agent_id, profile_id)
                    .await
                    .map_err(map_adapter_err)?;
                Ok(HandlerOutcome::Reply(json!({ "instanceId": instance_id })))
            }
            other => Err(RpcError::method_not_found(other)),
        }
    }
}
```

### 3. Register the handler

In `src-tauri/src/rpc/mod.rs::RpcDispatcher::with_defaults`,
register the new handler alongside the existing instances /
permissions / events / etc. blocks.

### 4. Drop `sessions/list` from the pruned-namespaces test

`src-tauri/src/rpc/mod.rs` has a test
`dispatch_pruned_namespaces_are_method_not_found` that asserts
`sessions/list` returns `-32601`. Remove it from that array (the
test still serves the rest of the pruned namespaces; it just
graduates one out).

If your style is to add a positive test that `sessions/list`
returns a real result, add it next to the existing
`instances/focus` invocation in the `dispatch_*` happy-path
tests.

### 5. Verify

After the daemon ships, inside the `hyprpilot.nvim` repo:

1. `cd ~/development/hyprpilot.nvim`
2. Toggle the chat (`<space>ctt` in the captain's config).
3. Open the sessions palette: `<space>ctS`
4. Pick a session row → the chat split should switch to the
   loaded transcript inside a fresh instance.
5. Plugin logs (`:HyprpilotLogs` or `:checkhealth hyprpilot`)
   should show `palettes.sessions: sessions/list ok` (debug
   level) instead of the current
   `sessions/list failed: method not found: sessions/list` warn.

Plugin-side test reference: `tests/test_palettes.lua` has a case
`palettes.sessions: pick → fires sessions/load with the chosen
sessionId` that drives the contract end-to-end with stubs.

## Risks / things to double-check

- **`AcpAdapter::list_sessions` may not be on the `Adapter`
  trait yet.** If it's concrete-impl-only today, decide between
  trait-lift and registry-downcast (see step 1 recon notes).
- **`sessions/load` adoption semantics.** The reply must carry
  the daemon-assigned `instanceId` so the plugin can register
  the buffer + show the chat split. The plugin's post-load chain
  in `palettes/sessions.lua` calls `instances.info(instance_id)`
  next, then `chat.window.register({ bufnr, instance_id })` and
  `chat.window.show(instance_id)`. If `sessions/load` succeeds
  but no `instanceId` comes back, the plugin warns and bails.
- **Empty list reply shape.** Plugin tolerates both
  `{ "sessions": [] }` and a missing `sessions` key (treats
  either as "no resumable sessions" → warn + no-op).
- **Backwards-compat.** Pre-v0.1.0 plugin; no need to dual-stack
  the old Tauri command into the wire. The Tauri side stays as
  is (desktop app keeps using it); the wire handler is purely
  additive.

## What "done" looks like

- [ ] `sessions.rs` handler ships, registered in the
      dispatcher.
- [ ] `dispatch_pruned_namespaces_are_method_not_found` no
      longer lists `sessions/list`.
- [ ] At least one happy-path test asserts `sessions/list`
      returns a sane shape (mirror the existing positive
      `instances/focus` test).
- [ ] Plugin smoke test from a captain shell: open sessions
      palette → pick a row → chat shows the loaded transcript.

When this is shipped, drop a note here so we can delete this
handoff doc from `docs/plans/`.
