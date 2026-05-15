--- Window-state RPC handlers. Daemon-side notifications under the
--- `nvim/*` namespace map to `ui.window` operations on the plugin
--- side so the daemon (or another tool over the socket) can drive
--- the chat split remotely.
---
--- Method surface (notifications, no reply):
---   `nvim/focus`   — `{ target?: "composer" | "chat" }`
---   `nvim/toggle`  — no params
---   `nvim/show`    — `{ instanceId?: string }`
---   `nvim/hide`    — no params

local client = require("hyprpilot.client")
local log = require("hyprpilot.log")

local M = {}

---@type table<string, fun(params: any): nil>
local HANDLERS = {
  ["nvim/focus"] = function(params)
    require("hyprpilot.ui.window").focus(type(params) == "table" and params or nil)
  end,
  ["nvim/toggle"] = function()
    require("hyprpilot.ui.window").toggle()
  end,
  ["nvim/show"] = function(params)
    local instance_id = type(params) == "table" and params.instanceId or nil
    require("hyprpilot.ui.window").show(instance_id)
  end,
  ["nvim/hide"] = function()
    require("hyprpilot.ui.window").hide()
  end,
}

--- Track per-`register()` unsubscribe closures so a hot-reload
--- (`shutdown()` → `setup()`) drops the prior listeners before
--- re-subscribing. Without this, every captain re-call of
--- `setup()` doubles up `client.on_notification` handlers and a
--- single `nvim/show` would fire N show paths.
local _unsubscribers = {}

---Drop every previously-registered handler. Idempotent.
function M.unregister()
  for _, unsub in ipairs(_unsubscribers) do
    pcall(unsub)
  end
  _unsubscribers = {}
end

---Subscribe every window-method handler. Wipes any prior
---registration first so re-runs of `setup()` don't accumulate.
function M.register()
  M.unregister()
  for method, handler in pairs(HANDLERS) do
    local unsub = client.on_notification(method, function(params)
      log.debug("rpc.window: %s params=%s", method, vim.inspect(params))
      handler(params)
    end)
    table.insert(_unsubscribers, unsub)
  end
end

return M
