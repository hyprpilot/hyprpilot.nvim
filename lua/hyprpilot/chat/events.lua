--- Wire event subscription + dispatcher.
---
--- One `events/subscribe` per nvim process (no instance filter so every
--- chat buffer receives its share). Notifications arrive as
--- `events/changed` payloads with an `event` discriminator; we route
--- them to `chat.render` based on the kind.

local client = require("hyprpilot.client")
local log = require("hyprpilot.log")
local render = require("hyprpilot.chat.render")
local status = require("hyprpilot.status")
local winbar = require("hyprpilot.chat.winbar")

---Resolve the human label for an in-flight tool call.
---@param item table
---@return string?
local function tool_label(item)
  if type(item) ~= "table" then
    return nil
  end
  if type(item.formatted) == "table" and type(item.formatted.title) == "string" then
    return item.formatted.title
  end
  if type(item.title) == "string" then
    return item.title
  end
  if type(item.toolKind) == "string" then
    return item.toolKind
  end
  return nil
end

---Translate a `transcript` event's item into an activity update for
---the addressed instance. No-op for non-agent kinds. `instance_id`
---comes from the event envelope so concurrent instances each track
---their own activity in isolation.
---@param instance_id string?
---@param item table
local function activity_for_transcript(instance_id, item)
  if type(item) ~= "table" or type(item.kind) ~= "string" then
    return
  end

  local kind = item.kind

  if kind == "agent_text" or kind == "agent_thought" then
    status.set_activity(instance_id, { kind = "streaming" })
  elseif kind == "tool_call" then
    status.set_activity(instance_id, { kind = "tool", tool_name = tool_label(item) })
  elseif kind == "tool_call_update" then
    if item.state == "completed" or item.state == "failed" then
      status.set_activity(instance_id, { kind = "streaming" })
    else
      status.set_activity(instance_id, { kind = "tool", tool_name = tool_label(item) })
    end
  end
end

---Coerce `vim.NIL` (or anything non-numeric) to a clean number or nil.
---The daemon sometimes ships JSON-null for usage / size / cost on a
---fresh instance; without coercion `(value or 0) > 0` errors on the
---userdata sentinel.
---@param v any
---@return number?
local function to_number(v)
  return tonumber(v)
end

local M = {}

local subscribed = false
local unsubscribe = nil ---@type fun()?

---Fire a `User Hyprpilot<event>` autocmd with a structured `data`
---payload. Mirrors the pattern `status.lua` uses for
---`Connected` / `Disconnected` / `ActivityChanged`. `pcall`
---wrapped so a captain's autocmd callback that throws can't
---break the event-dispatch loop.
---@param event string                                 -- suffix appended to `Hyprpilot`
---@param data table?
local function emit(event, data)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "Hyprpilot" .. event,
    data = data,
  })
end

---Same as `emit`, but stamps `instance_id` + `bufnr` into the data
---table first. The `data.bufnr` field is the conventional handle a
---captain's autocmd handler reads to address the per-instance chat
---buffer without a side lookup.
---@param event string
---@param instance_id string?
---@param data table
local function emit_for_instance(event, instance_id, data)
  data.instance_id = instance_id
  if instance_id ~= nil then
    data.bufnr = require("hyprpilot.chat.window").get_bufnr(instance_id)
  end
  emit(event, data)
end

---Unwrap an `events/changed` notification's params to the daemon's
---underlying `InstanceEvent` payload. The wire shape is:
---
---   { name = "acp:<event>", instanceId = "...", payload = { event = "...", ... } }
---
---The discriminator and every event-specific field live inside
---`payload`; the outer envelope is just routing metadata. We pass
---`payload` down to the per-event handlers so they receive the
---untagged shape they were written against (`event.event`,
---`event.instanceId`, `event.turnId`, etc.).
---@param params table
---@return table?
local function unwrap_event(params)
  if type(params) ~= "table" then
    return nil
  end
  if type(params.payload) == "table" then
    return params.payload
  end
  -- Legacy / direct shape (no envelope) — accept as-is.
  if type(params.event) == "string" then
    return params
  end
  return nil
end

---@param raw table
local function dispatch(raw)
  local event = unwrap_event(raw)

  if event == nil or type(event.event) ~= "string" then
    log.warn("events.dispatch: dropping malformed payload: %s", vim.inspect(raw))

    return
  end

  -- ACP wire variants put the raw tool input under different keys
  -- depending on the agent's normalisation (`rawInput` for claude-acp;
  -- some adapters use `raw_input`). Normalize here so downstream
  -- consumers (render, permission_row, diff_preview) see one shape.
  if event.rawInput == nil and event.raw_input ~= nil then
    event.rawInput = event.raw_input
  end

  -- Wrap the dispatch body in pcall so one bad payload (or a render
  -- nil-deref on a half-built turn / state) doesn't take down sibling
  -- handlers in the same tick. Each branch's own failure logs and the
  -- dispatch loop survives — the daemon will keep streaming events
  -- regardless of what we drop on the floor.
  local ok, err = pcall(function()
    if event.event == "transcript" then
      render.handle_transcript(event)
      activity_for_transcript(event.instanceId, event.item)
    elseif event.event == "turn_started" then
      render.handle_turn_started(event)
      status.set_activity(event.instanceId, { kind = "thinking", started_at_ms = vim.uv.now() })
      -- Defensive queue resync — the daemon may have just popped
      -- the head as part of dispatching this turn. The strip's
      -- `queue_changed` subscription usually catches it, but on
      -- restart-window edges (events arrive out of order with the
      -- snapshot read) the cache can lag. Wholesale-replace
      -- semantics make this free when it's already accurate.
      if type(event.instanceId) == "string" then
        pcall(function()
          require("hyprpilot.chat.queue-strip").hydrate(event.instanceId)
        end)
      end
      emit_for_instance("TurnStarted", event.instanceId, {
        turn_id = event.turnId,
        started_at = event.startedAt or event.started_at,
      })
    elseif event.event == "turn_ended" then
      render.handle_turn_ended(event)
      status.set_activity(event.instanceId, { kind = "idle" })
      -- Daemon owns the queue (single mailbox, per-instance) and
      -- pins the contract: `prompts/cancel` never flushes.
      -- Cancel-during-dispatch loses the popped item; the daemon
      -- does NOT auto-dispatch the head on TurnEnded — captain
      -- drives drainage explicitly via the queue strip.
      --
      -- Defensive queue resync — same rationale as `turn_started`
      -- above. Turn-end is the most common point where the queue
      -- visibly drifts (the captain sees the row count "stuck"
      -- after the prompt resolves).
      if type(event.instanceId) == "string" then
        pcall(function()
          require("hyprpilot.chat.queue-strip").hydrate(event.instanceId)
        end)
      end
      emit_for_instance("TurnEnded", event.instanceId, {
        turn_id = event.turnId,
        ended_at = event.endedAt or event.ended_at,
        stop_reason = event.stopReason,
        error = event.error,
      })
    elseif event.event == "permission_request" then
      render.handle_permission_request(event)
      status.set_activity(event.instanceId, { kind = "awaiting_permission", permission_request_id = event.requestId })
      emit_for_instance("PermissionRequested", event.instanceId, {
        request_id = event.requestId,
        tool = event.tool,
        tool_kind = event.toolKind,
        options = event.options,
        -- Daemon-computed allow-shaped pre-selected option (see
        -- `PermissionRequestSnapshot::default_option_id` in
        -- `src-tauri/src/adapters/permission.rs`).
        default_option_id = event.defaultOptionId,
        raw_input = event.rawInput,
      })
    elseif event.event == "permission_resolved" then
      render.handle_permission_resolved(event)
      status.set_activity(event.instanceId, { kind = "streaming" })
      emit_for_instance("PermissionResolved", event.instanceId, {
        request_id = event.requestId,
        option_id = event.optionId,
      })
    elseif event.event == "instance_meta" then
      winbar.update_meta(event.instanceId, {
        agent_id = event.agentId,
        profile_id = event.profileId,
        session_id = event.sessionId,
        cwd = event.cwd,
        current_mode_id = event.currentModeId,
        current_model_id = event.currentModelId,
        available_modes = event.availableModes,
        available_models = event.availableModels,
        mcps_count = event.mcpsCount,
      })
    elseif event.event == "current_mode_update" then
      winbar.update_mode(event.instanceId, event.currentModeId)
      render.handle_current_mode_update(event)
    elseif event.event == "config_options_update" then
      render.handle_config_options_update(event)
    elseif event.event == "system_prompt_injected" then
      render.handle_system_prompt_injected(event)
    elseif event.event == "usage_update" then
      -- Coerce numeric fields at the boundary so vim.NIL (JSON null)
      -- never reaches arithmetic in winbar/header/render/stats.
      winbar.update_usage(event.instanceId, to_number(event.used), to_number(event.size), to_number(event.cost))
      render.handle_usage_update(event)
    elseif event.event == "session_info_update" then
      winbar.update_session(event.instanceId, event.title)
    elseif event.event == "state" then
      winbar.update_meta(event.instanceId, { instance_state = event.state })
      emit_for_instance("InstanceStateChanged", event.instanceId, {
        state = event.state,
      })
    elseif event.event == "terminal" then
      render.handle_terminal(event)
    elseif event.event == "queue_changed" then
      -- Daemon owns the per-instance prompt queue; this event
      -- ships the FULL snapshot (no deltas, idempotent on lossy
      -- broadcast). Forward to the queue strip's mirror so it
      -- repaints and the composer's edit-slot stays in sync.
      local rpc_queue = require("hyprpilot.rpc.queue")
      require("hyprpilot.chat.queue-strip").handle_queue_changed(event.instanceId, rpc_queue.items_from_wire(event.items))
    elseif event.event == "lagged" then
      -- Daemon dropped events on us (subscription overflow). The
      -- correct recovery is to refetch the latest page so the local
      -- view matches the daemon mirror again. Each tracked instance
      -- gets re-hydrated.
      log.warn("events.dispatch: events/lagged — re-hydrating tracked instances")
      render.iter_states(function(instance_id, st)
        M.hydrate(instance_id, st.bufnr)
      end)
    else
      log.debug("events.dispatch: ignoring event=%s (no handler in v1)", event.event)
    end
  end)

  if not ok then
    log.warn("events.dispatch: handler for event=%s threw: %s", tostring(event.event), tostring(err))
  end
end

---Subscribe to the daemon's event stream once. Idempotent.
function M.ensure_subscribed()
  if subscribed then
    return
  end

  subscribed = true

  unsubscribe = client.on_notification("events/changed", dispatch)

  client.request("events/subscribe", nil, nil, function(err, result)
    if err ~= nil then
      subscribed = false

      if unsubscribe ~= nil then
        unsubscribe()

        unsubscribe = nil
      end

      log.warn("events.subscribe: %s", err.message)

      return
    end

    log.debug("events.subscribe: ack %s", vim.inspect(result))
  end)
end

---Hydrate the per-instance buffer from `instance/snapshot/chat` then
---ensure the live event stream is wired. Snapshot page size comes
---from `state.snapshot_limit`, which `load_older` bumps to fetch
---deeper history.
---@param instance_id string
---@param bufnr integer
---@param callback? fun(err: hyprpilot.client.RpcError?): nil
function M.hydrate(instance_id, bufnr, callback)
  M.ensure_subscribed()

  local state = render.state(instance_id, bufnr)

  log.debug("events.hydrate: requesting snapshots for instance=%s limit=%d", instance_id, state.snapshot_limit)

  client.request("instance/snapshot/chat", { instanceId = instance_id, limit = state.snapshot_limit }, nil, function(err, snapshot)
    if err ~= nil then
      log.warn("events.hydrate: chat snapshot failed for instance=%s: %s", instance_id, err.message)
      if callback ~= nil then
        callback(err)
      end
      return
    end

    if type(snapshot) ~= "table" then
      log.warn("events.hydrate: chat snapshot is not a table for instance=%s (got %s)", instance_id, type(snapshot))
      if callback ~= nil then
        callback({ message = "snapshot is not a table" })
      end
      return
    end

    render.hydrate(state, snapshot)

    if callback ~= nil then
      callback(nil)
    end
  end)

  client.request("instance/snapshot/meta", { instanceId = instance_id }, nil, function(err, snapshot)
    if err ~= nil then
      log.debug("events.hydrate: meta snapshot failed for instance=%s: %s", instance_id, err.message)
      return
    end

    if type(snapshot) ~= "table" then
      log.debug("events.hydrate: meta snapshot is not a table for instance=%s", instance_id)
      return
    end

    winbar.hydrate(instance_id, snapshot)
  end)
end

---Bump the chat snapshot page size by `step` (default 100) and
---re-hydrate so older transcript items appear above the existing
---view. No-op when the daemon already reported `hasMore == false`
---for the current page.
---@param instance_id string
---@param opts? { step?: integer }
---@param callback? fun(err: hyprpilot.client.RpcError?): nil
function M.load_older(instance_id, opts, callback)
  local state = render.state_for(instance_id)
  if state == nil then
    log.warn("events.load_older: no state for instance=%s", tostring(instance_id))
    if callback ~= nil then
      callback({ message = "no state for instance" })
    end
    return
  end

  if not state.has_more then
    log.debug("events.load_older: instance=%s reports no more older items", instance_id)
    if callback ~= nil then
      callback(nil)
    end
    return
  end

  local step = (opts or {}).step or 100
  state.snapshot_limit = state.snapshot_limit + step

  log.debug("events.load_older: instance=%s new limit=%d", instance_id, state.snapshot_limit)

  M.hydrate(instance_id, state.bufnr, callback)
end

---Drop the local listener + reset the subscribed flag. Used on
---disconnect or test reset.
function M._reset()
  if unsubscribe ~= nil then
    unsubscribe()

    unsubscribe = nil
  end

  subscribed = false
end

--- Full re-init after a reconnect. Wipes every per-instance UI
--- store that could have drifted while disconnected (the daemon
--- may have resolved permissions, finished tools, changed mode /
--- model / state, or shut down the instance entirely while we
--- weren't watching), then re-subscribes to the daemon stream and
--- re-hydrates each tracked instance's chat + meta snapshots.
---
--- Called automatically from the `client.on_state_change` listener
--- below when the connection comes back after a disconnect — without
--- this, `subscribed = true` survives and `events/subscribe` is
--- never re-fired, so zero events arrive on the new connection
--- (silent failure mode the captain hit repeatedly).
function M.full_reset()
  log.info("events.full_reset: re-initialising after reconnect")

  -- Local listener + flag — without this `ensure_subscribed` would
  -- skip the re-subscribe and we'd be tied to a dead daemon-side
  -- channel.
  M._reset()

  -- Wipe per-instance UI stores that may carry stale assumptions:
  -- permission-row queue (daemon may have resolved while down),
  -- attention markers (same), header name cache (fresh fetch on
  -- next render), winbar meta (mode/model/usage drift), per-instance
  -- activity (frozen at disconnect; turn_ended that fired while down
  -- never demoted to idle).
  pcall(function()
    require("hyprpilot.chat.permission-row").reset()
  end)

  -- Walk the union of `window._instances` (registered keyset) AND
  -- `render._states` so a meta-only instance (registered but never
  -- emitted a transcript yet) doesn't keep stale per-instance state
  -- past reconnect. Render-state-only iteration would miss those.
  local known_ids = {}
  for instance_id, _ in pairs(require("hyprpilot.chat.window")._instances) do
    known_ids[instance_id] = true
  end
  for instance_id, _ in pairs(require("hyprpilot.chat.render")._states) do
    known_ids[instance_id] = true
  end
  for instance_id, _ in pairs(known_ids) do
    pcall(function()
      require("hyprpilot.chat.header").forget(instance_id)
    end)
    pcall(function()
      require("hyprpilot.chat.winbar").forget(instance_id)
    end)
    pcall(function()
      require("hyprpilot.status").forget(instance_id)
    end)
    pcall(function()
      require("hyprpilot.notification.attention")._clear_instance(instance_id)
    end)
  end

  -- Re-subscribe to the daemon stream + re-hydrate every tracked
  -- instance. The hydrate calls re-render the buffer in place so
  -- the captain's cursor / scroll position survives — they just
  -- see fresh content as the daemon's snapshots replay.
  M.ensure_subscribed()
  require("hyprpilot.chat.render").iter_states(function(instance_id, st)
    M.hydrate(instance_id, st.bufnr)
  end)
end

-- Wire the reconnect listener once at module load. The "was
-- previously connected" guard avoids double-firing on the very
-- first connect (initial setup() flow already hydrates explicitly
-- via window.show / instances.spawn callbacks).
local _was_connected = false
require("hyprpilot.client").on_state_change(function(state)
  if state == "connected" then
    if _was_connected then
      M.full_reset()
    end
    _was_connected = true
  elseif state == "disconnected" then
    -- Drop the subscribed flag immediately so a manual
    -- ensure_subscribed() between disconnect + reconnect doesn't
    -- skip the re-subscribe.
    M._reset()
  end
end)

return M
