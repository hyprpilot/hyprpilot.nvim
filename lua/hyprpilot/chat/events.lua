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

---Translate a `transcript` event's item into an activity update.
---No-op for non-agent kinds.
---@param item table
local function activity_for_transcript(item)
  if type(item) ~= "table" or type(item.kind) ~= "string" then
    return
  end

  local kind = item.kind

  if kind == "agent_text" or kind == "agent_thought" then
    status.set_activity({ kind = "streaming" })
  elseif kind == "tool_call" then
    status.set_activity({ kind = "tool", tool_name = tool_label(item) })
  elseif kind == "tool_call_update" then
    if item.state == "completed" or item.state == "failed" then
      status.set_activity({ kind = "streaming" })
    else
      status.set_activity({ kind = "tool", tool_name = tool_label(item) })
    end
  end
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

  if event.event == "transcript" then
    render.handle_transcript(event)
    activity_for_transcript(event.item)
  elseif event.event == "turn_started" then
    render.handle_turn_started(event)
    status.set_activity({ kind = "thinking", started_at_ms = vim.uv.now() })
    emit("TurnStarted", {
      instance_id = event.instanceId,
      turn_id = event.turnId,
      started_at = event.startedAt or event.started_at,
    })
  elseif event.event == "turn_ended" then
    render.handle_turn_ended(event)
    status.set_activity({ kind = "idle" })
    emit("TurnEnded", {
      instance_id = event.instanceId,
      turn_id = event.turnId,
      ended_at = event.endedAt or event.ended_at,
      stop_reason = event.stopReason,
      error = event.error,
    })
  elseif event.event == "permission_request" then
    render.handle_permission_request(event)
    status.set_activity({ kind = "awaiting_permission", permission_request_id = event.requestId })
    emit("PermissionRequested", {
      instance_id = event.instanceId,
      request_id = event.requestId,
      tool = event.tool,
      tool_kind = event.toolKind,
      options = event.options,
    })
  elseif event.event == "permission_resolved" then
    render.handle_permission_resolved(event)
    status.set_activity({ kind = "streaming" })
    emit("PermissionResolved", {
      instance_id = event.instanceId,
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
  elseif event.event == "usage_update" then
    winbar.update_usage(event.instanceId, event.used, event.size, event.cost)
    render.handle_usage_update(event)
  elseif event.event == "session_info_update" then
    winbar.update_session(event.instanceId, event.title)
  elseif event.event == "state" then
    winbar.update_meta(event.instanceId, { instance_state = event.state })
    emit("InstanceStateChanged", {
      instance_id = event.instanceId,
      state = event.state,
    })
  elseif event.event == "terminal" then
    render.handle_terminal(event)
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

return M
