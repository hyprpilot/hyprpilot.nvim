--- Modes palette — `vim.ui.select` over the active instance's
--- `available_modes`. Pick a row, the daemon's `instances/setMode`
--- RPC commits.
---
--- Reads the meta off `instances.meta(id)` (which calls
--- `instance/snapshot/meta`) on every open instead of caching —
--- `availableModes` can shift mid-session as the agent advertises
--- new capabilities, and the daemon's per-instance lock is the only
--- authoritative source.

local instances = require("hyprpilot.instances")
local log = require("hyprpilot.log")
local window = require("hyprpilot.chat.window")

local M = {}

---@class hyprpilot.palettes.modes.Opts
---@field instance_id? string  -- defaults to active instance

---Open the modes picker. Resolves `instance_id` lazily so a keybind
---bound at startup picks up whichever instance is active when fired.
---@param opts? hyprpilot.palettes.modes.Opts
function M.open(opts)
  opts = opts or {}
  local instance_id = opts.instance_id or window.active_instance()

  if instance_id == nil then
    log.warn("palettes.modes: no active instance")
    return
  end

  instances.meta(instance_id, function(err, meta)
    if err ~= nil then
      log.warn("palettes.modes: meta fetch failed: %s", err.message)
      return
    end

    local available = (meta and meta.available_modes) or {}
    if #available == 0 then
      log.warn("palettes.modes: instance advertises no modes")
      return
    end

    local current = meta.current_mode_id
    -- Prefix the current mode with `* ` so the captain can tell the
    -- active row apart in pickers that don't render a "selected"
    -- indicator (raw vim.ui.select / fzf-lua's bare interface, etc).
    local format_item = function(item)
      local prefix = item.id == current and "* " or "  "
      return prefix .. (item.name or item.id)
    end

    vim.ui.select(available, {
      prompt = "modes",
      format_item = format_item,
      kind = "hyprpilot.modes",
    }, function(choice)
      if choice == nil then
        return
      end
      if choice.id == current then
        log.debug("palettes.modes: chose current mode (%s) — no-op", current)
        return
      end

      instances.set_mode(instance_id, choice.id, function(set_err)
        if set_err ~= nil then
          log.warn("palettes.modes: setMode failed: %s", set_err.message)
        else
          log.debug("palettes.modes: set mode=%s on instance=%s", choice.id, instance_id)
        end
      end)
    end)
  end)
end

return M
