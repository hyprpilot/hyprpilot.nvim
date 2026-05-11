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

---@param event table
local function dispatch(event)
  if type(event) ~= "table" or type(event.event) ~= "string" then
    log.warn("events.dispatch: dropping malformed payload: %s", vim.inspect(event))

    return
  end

  if event.event == "transcript" then
    render.handle_transcript(event)
    activity_for_transcript(event.item)
  elseif event.event == "turn_started" then
    render.handle_turn_started(event)
    status.set_activity({ kind = "thinking", started_at_ms = vim.uv.now() })
  elseif event.event == "turn_ended" then
    render.handle_turn_ended(event)
    status.set_activity({ kind = "idle" })
  elseif event.event == "permission_request" then
    render.handle_permission_request(event)
    status.set_activity({ kind = "awaiting_permission", permission_request_id = event.requestId })
  elseif event.event == "permission_resolved" then
    render.handle_permission_resolved(event)
    status.set_activity({ kind = "streaming" })
  elseif event.event == "instance_meta" then
    winbar.update_meta(event.instanceId, {
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
  elseif event.event == "session_info_update" then
    winbar.update_session(event.instanceId, event.title)
  elseif event.event == "state" then
    winbar.update_meta(event.instanceId, { instance_state = event.state })
  elseif event.event == "terminal" then
    render.handle_terminal(event)
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
---ensure the live event stream is wired.
---@param instance_id string
---@param bufnr integer
function M.hydrate(instance_id, bufnr)
  M.ensure_subscribed()

  local state = render.state(instance_id, bufnr)

  log.debug("events.hydrate: requesting snapshots for instance=%s", instance_id)

  client.request("instance/snapshot/chat", { instanceId = instance_id }, nil, function(err, snapshot)
    if err ~= nil then
      log.warn("events.hydrate: chat snapshot failed for instance=%s: %s", instance_id, err.message)

      return
    end

    if type(snapshot) ~= "table" then
      log.warn("events.hydrate: chat snapshot is not a table for instance=%s (got %s)", instance_id, type(snapshot))

      return
    end

    render.hydrate(state, snapshot)
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
