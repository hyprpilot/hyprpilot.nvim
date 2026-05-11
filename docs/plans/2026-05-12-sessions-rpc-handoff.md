# Daemon handoff: expose `sessions/list` + `sessions/load` on the Unix-socket RPC

## Context

`hyprpilot.nvim`'s palettes module ships in PR `feature/palettes`
with a `palettes/sessions.lua` leaf that calls `sessions/list` and
`sessions/load` over the Unix-socket RPC. Both methods exist
today as Tauri commands (the desktop app drives them) but the
public socket dispatcher returns `-32601 method_not_found` for
`sessions/*` — confirmed by the test
`dispatch_pruned_namespaces_are_method_not_found` in
`src-tauri/src/rpc/mod.rs`.

This is the same shape as the `instances/setMode` /
`setModel` / `setOption` handoff that landed in PR #36 (commit
`87c2de6`): the adapter already implements the operations, the
Tauri command layer already exports them, the wire dispatcher
just needs to add the routing.

The plugin-side palette ships now with a graceful `-32601`
fallback (warns + no-ops, no crash). When the daemon-side handoff
lands, the palette automatically lights up.

## Required wire methods

### `sessions/list`

**Params** (all optional):
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

The desktop app's `tauri_proxy::session_list` handler already
returns this shape — just lift it onto the wire.

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
  "instanceId": "fresh-instance-uuid"  // the daemon adopted the session into a fresh instance
}
```

Mirrors the `instances/spawn` reply shape so the plugin's
post-load hand-off (`instances.info(instance_id)` →
`chat.window.show(instance_id)`) Just Works™.

## Implementation outline

Add a new handler module
`src-tauri/src/rpc/handlers/sessions.rs` (mirror the existing
`instances.rs` module structure):

```rust
pub struct SessionsHandler;

#[async_trait::async_trait]
impl RpcHandler for SessionsHandler {
    fn methods(&self) -> &'static [&'static str] {
        &["sessions/list", "sessions/load"]
    }

    async fn handle(
        &self,
        method: &str,
        params: Option<Value>,
        _ctx: &HandlerCtx<'_>,
    ) -> Result<HandlerOutcome, RpcError> {
        match method {
            "sessions/list" => {
                let ListParams { cwd } = params_or_default::<ListParams>(params, method)?;
                let sessions = ctx.adapter.list_sessions(cwd.as_deref()).await
                    .map_err(map_adapter_err)?;
                Ok(HandlerOutcome::Reply(json!({ "sessions": sessions })))
            }
            "sessions/load" => {
                let LoadParams { session_id, cwd, agent_id, profile_id } =
                    parse_params::<LoadParams>(params, method)?;
                let instance_id = ctx.adapter
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

Register the handler in `RpcDispatcher::with_defaults`
(`src-tauri/src/rpc/mod.rs`) and remove `sessions/list` from the
`dispatch_pruned_namespaces_are_method_not_found` test.

The `AcpAdapter::list_sessions` and `load_session` methods
already exist (the Tauri commands call them); just expose them on
the trait if they aren't already, and the handler's a thin
forwarder.

## Verification

After the daemon ships:

1. `cd ~/development/hyprpilot.nvim`
2. Toggle the chat (`<space>ctt`).
3. Open the sessions palette via the keybind that captain wires
   against `require("hyprpilot.palettes.sessions").open()`.
4. Pick a session row → the chat split should show the loaded
   transcript inside a fresh instance.
5. Logs should show `palettes.sessions: sessions/list ok` (debug
   level) instead of the current `-32601 method_not_found` warn.

## Risks

- **`AcpAdapter::list_sessions` may not be on the trait.** If
  it's currently a concrete-impl-only method on `AcpAdapter`,
  the handler can downcast through the registry the same way
  `instances/info` does. No new infrastructure needed.
- **Session id ownership.** `sessions/load` should adopt the
  session id verbatim into the spawned instance (the desktop app
  already does this via `acp::load_session`); no UUID mint on the
  daemon side.
