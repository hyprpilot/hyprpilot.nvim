--- Effort palette — `vim.ui.select` over the active instance's
--- adapter-advertised `effort` config option (claude-agent-acp 0.21+
--- adaptive thinking: low / medium / high / xhigh / max). Reads the
--- shape from `meta.config_options[*]` matching `id == "effort"` and
--- routes the commit through `instances.set_option(id, "effort", v)`.
---
--- Future per-vendor toggles (other category ids the daemon may
--- advertise) can use the same `palettes/option.lua` factory once
--- it lands; for now `effort` is the first concrete consumer so it
--- gets its own thin wrapper.

local instances = require("hyprpilot.instances")
local log = require("hyprpilot.log")
local window = require("hyprpilot.chat.window")

local M = {}

local CATEGORY_ID = "effort"

---@class hyprpilot.palettes.effort.Opts
---@field instance_id? string

---@param opts? hyprpilot.palettes.effort.Opts
function M.open(opts)
  opts = opts or {}
  local instance_id = opts.instance_id or window.active_instance()

  if instance_id == nil then
    log.warn("palettes.effort: no active instance")
    return
  end

  instances.meta(instance_id, function(err, meta)
    if err ~= nil then
      log.warn("palettes.effort: meta fetch failed: %s", err.message)
      return
    end

    local categories = (meta and meta.config_options) or {}
    local category
    for _, c in ipairs(categories) do
      if c.id == CATEGORY_ID then
        category = c
        break
      end
    end

    if category == nil or type(category.options) ~= "table" or #category.options == 0 then
      log.warn("palettes.effort: instance advertises no effort options")
      return
    end

    local current = category.currentValue
    local format_item = function(item)
      local prefix = item.value == current and "* " or "  "
      return prefix .. (item.name or item.value)
    end

    vim.ui.select(category.options, {
      prompt = category.name or "effort",
      format_item = format_item,
      kind = "hyprpilot.effort",
    }, function(choice)
      if choice == nil then
        return
      end
      if choice.value == current then
        log.debug("palettes.effort: chose current value (%s) — no-op", current)
        return
      end

      instances.set_option(instance_id, CATEGORY_ID, choice.value, function(set_err)
        if set_err ~= nil then
          log.warn("palettes.effort: setOption failed: %s", set_err.message)
        else
          log.debug("palettes.effort: set %s=%s on instance=%s", CATEGORY_ID, choice.value, instance_id)
        end
      end)
    end)
  end)
end

return M
