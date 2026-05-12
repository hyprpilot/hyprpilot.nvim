--- Effort palette — picker over the active instance's effort
--- config category (claude-agent-acp 0.21+ adaptive thinking).

local instances = require("hyprpilot.instances")
local log = require("hyprpilot.log")
local pickers = require("hyprpilot.palettes.pickers")
local window = require("hyprpilot.chat.window")

local M = {}

local CATEGORY_ID = "effort"

---@class hyprpilot.palettes.effort.Opts
---@field instance_id? string
---@field picker? "auto" | "snacks" | "vim.ui.select"

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

    pickers.open({
      items = category.options,
      title = category.name or "effort",
      kind = "hyprpilot.effort",
      picker = opts.picker,
      format_item = function(item)
        local prefix = item.value == current and "* " or "  "
        return prefix .. (item.name or item.value)
      end,
      preview = function(item)
        local lines = { "# " .. (item.name or item.value), "" }
        if item.description ~= nil and item.description ~= "" then
          for _, l in ipairs(vim.split(tostring(item.description), "\n", { plain = true })) do
            table.insert(lines, l)
          end
        else
          table.insert(lines, "_(no description advertised)_")
        end
        return { lines = lines, ft = "markdown" }
      end,
      on_pick = function(choice)
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
      end,
    })
  end)
end

return M
