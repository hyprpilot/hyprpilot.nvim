--- Models palette — `vim.ui.select` over the active instance's
--- `available_models`. Mirrors `palettes/modes.lua` exactly with
--- `setModel` instead of `setMode` (the daemon's per-axis split is
--- ACP-spec, not us being clever — the agent advertises mode and
--- model as two distinct closed sets).

local instances = require("hyprpilot.instances")
local log = require("hyprpilot.log")
local window = require("hyprpilot.chat.window")

local M = {}

---@class hyprpilot.palettes.models.Opts
---@field instance_id? string

---@param opts? hyprpilot.palettes.models.Opts
function M.open(opts)
  opts = opts or {}
  local instance_id = opts.instance_id or window.active_instance()

  if instance_id == nil then
    log.warn("palettes.models: no active instance")
    return
  end

  instances.meta(instance_id, function(err, meta)
    if err ~= nil then
      log.warn("palettes.models: meta fetch failed: %s", err.message)
      return
    end

    local available = (meta and meta.available_models) or {}
    if #available == 0 then
      log.warn("palettes.models: instance advertises no models")
      return
    end

    local current = meta.current_model_id
    local format_item = function(item)
      local prefix = item.id == current and "* " or "  "
      return prefix .. (item.name or item.id)
    end

    vim.ui.select(available, {
      prompt = "models",
      format_item = format_item,
      kind = "hyprpilot.models",
    }, function(choice)
      if choice == nil then
        return
      end
      if choice.id == current then
        log.debug("palettes.models: chose current model (%s) — no-op", current)
        return
      end

      instances.set_model(instance_id, choice.id, function(set_err)
        if set_err ~= nil then
          log.warn("palettes.models: setModel failed: %s", set_err.message)
        else
          log.debug("palettes.models: set model=%s on instance=%s", choice.id, instance_id)
        end
      end)
    end)
  end)
end

return M
