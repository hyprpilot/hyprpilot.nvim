--- Terminal bell — opt-in audible / visual notification on attention
--- adds. Subscribes to `notification.attention` and rings the
--- terminal's BEL (`\007`) when the attention list grows.
---
--- Single dial: `config.notification.bell.enabled`. The "which
--- events ring" decision is delegated to the attention list itself
--- so the bell and the picker stay in lockstep (no parallel configs
--- that can disagree).

local config = require("hyprpilot.config")
local log = require("hyprpilot.log")

local M = {}

local listeners_wired = false
local last_count = 0
local unsubscribe = nil ---@type fun()?

---Ring the terminal bell. Writes BEL to stderr — works in any
---non-GUI terminal nvim host. GUI hosts may ignore it; that's a
---host concern, not ours.
function M.ring()
  local tty = vim.uv.new_tty(2, false)
  if tty == nil then
    return
  end
  pcall(function()
    tty:write("\007")
  end)
  pcall(function()
    tty:close()
  end)
end

---Wire the attention subscriber that rings on adds. Called once
---from `setup()`. No-op when `config.notification.bell.enabled` is
---not true (default).
function M.ensure_listeners()
  if listeners_wired then
    return
  end

  local cfg = (config.options.notification or {}).bell or {}
  if cfg.enabled ~= true then
    log.debug("notification.bell: disabled — not wiring")
    return
  end

  listeners_wired = true

  local attention = require("hyprpilot.notification.attention")
  -- Seed `last_count` from the current snapshot so a setup() during
  -- live operation doesn't ring on pre-existing entries.
  last_count = #attention.list()

  unsubscribe = attention.on_change(function(snapshot)
    local now = #snapshot
    if now > last_count then
      -- Defer the ring one event-loop tick. Auto-resolved
      -- permissions arrive as `permission_request` +
      -- `permission_resolved` in the same socket burst — both
      -- `on_change` callbacks fire synchronously before vim
      -- schedules anything. By deferring here, if the list
      -- already shrank back below its pre-add count by the
      -- time the scheduled function runs, we skip the ring.
      -- Manually-pending permissions (captain needs to decide)
      -- are still in the list at schedule time → ring. Turn-
      -- ended entries are never removed automatically → ring.
      local count_before = last_count
      vim.schedule(function()
        if #attention.list() > count_before then
          M.ring()
        end
      end)
    end
    last_count = now
  end)

  log.debug("notification.bell: enabled, listening for attention adds")
end

---Test-only reset hook. Drops the subscription, resets the
---wired flag, and clears the count tracker so a follow-on
---`ensure_listeners()` rebinds cleanly.
function M._reset()
  if unsubscribe ~= nil then
    unsubscribe()
    unsubscribe = nil
  end
  listeners_wired = false
  last_count = 0
end

return M
