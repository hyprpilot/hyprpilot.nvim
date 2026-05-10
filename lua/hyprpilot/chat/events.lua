--- Wire event subscription + dispatcher.
---
--- One `events/subscribe` per nvim process (no instance filter so every
--- chat buffer receives its share). Notifications arrive as
--- `events/changed` payloads with an `event` discriminator; we route
--- them to `chat.render` based on the kind.

local client = require("hyprpilot.client")
local log = require("hyprpilot.log")
local render = require("hyprpilot.chat.render")
local window = require("hyprpilot.chat.window")

local M = {}

local SUBSCRIBE_METHOD = "events/subscribe"
local NOTIFICATION_METHOD = "events/changed"
local SNAPSHOT_METHOD = "instance/snapshot/chat"

local subscribed = false
local unsubscribe = nil ---@type fun()?

---@param event table
local function dispatch(event)
  if type(event) ~= "table" or type(event.event) ~= "string" then
    return
  end

  if event.event == "transcript" then
    render.handle_transcript(event)
  elseif event.event == "turn_started" then
    render.handle_turn_started(event)
  elseif event.event == "turn_ended" then
    render.handle_turn_ended(event)
  end
end

---Subscribe to the daemon's event stream once. Idempotent.
function M.ensure_subscribed()
  if subscribed then
    return
  end

  subscribed = true

  unsubscribe = client.on_notification(NOTIFICATION_METHOD, dispatch)

  client.request(SUBSCRIBE_METHOD, nil, nil, function(err, _result)
    if err ~= nil then
      subscribed = false

      if unsubscribe ~= nil then
        unsubscribe()

        unsubscribe = nil
      end

      log.warn("events.subscribe: %s", err.message)
    end
  end)
end

---Hydrate the per-instance buffer from `instance/snapshot/chat` then
---ensure the live event stream is wired.
---@param instance_id string
---@param bufnr integer
function M.hydrate(instance_id, bufnr)
  M.ensure_subscribed()

  local state = render.state(instance_id, bufnr)

  client.request(SNAPSHOT_METHOD, { instanceId = instance_id }, nil, function(err, snapshot)
    if err ~= nil then
      log.warn("events.hydrate: %s", err.message)

      return
    end

    if type(snapshot) ~= "table" then
      log.warn("events.hydrate: snapshot is not a table for instance=%s", instance_id)

      return
    end

    render.hydrate(state, snapshot)
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

---Listen for instance closure so render state gets cleaned up.
function M.setup_autocmds()
  vim.api.nvim_create_autocmd("User", {
    pattern = "HyprpilotInstanceClosed",
    callback = function(args)
      local instance_id = args.data and args.data.instance_id

      if type(instance_id) == "string" then
        render.forget(instance_id)
      end
    end,
  })
end

-- Suppress the unused-window warning while we wire window.show
-- integration in this same module's `hydrate` consumer below.
local _ = window

return M
