--- Wire event subscription + dispatcher.
---
--- One `events/subscribe` per nvim process (no instance filter so every
--- chat buffer receives its share). Notifications arrive as
--- `events/changed` payloads with an `event` discriminator; we route
--- them to `chat.render` based on the kind.

local client = require("hyprpilot.client")
local log = require("hyprpilot.log")
local render = require("hyprpilot.chat.render")
local winbar = require("hyprpilot.chat.winbar")

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
  elseif event.event == "turn_started" then
    render.handle_turn_started(event)
  elseif event.event == "turn_ended" then
    render.handle_turn_ended(event)
  elseif event.event == "permission_request" then
    render.handle_permission_request(event)
  elseif event.event == "permission_resolved" then
    render.handle_permission_resolved(event)
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
