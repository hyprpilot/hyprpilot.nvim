--- Effort palette — picker over the active instance's first-class
--- effort RPC surface (`instances/listEfforts` / `setEffort`).

local instances = require("hyprpilot.rpc.instances")
local log = require("hyprpilot.log")
local pickers = require("hyprpilot.palettes.pickers")
local window = require("hyprpilot.chat.window")

local M = {}

---@class hyprpilot.palettes.effort.Opts
---@field instance_id? string
---@field picker? "auto" | "snacks" | "vim.ui.select"

---@param item table
---@param current? string
---@return string
local function format_item(item, current)
  local value = item.value or item.id
  local prefix = value == current and "* " or "  "
  return prefix .. tostring(item.name or value)
end

---@param item table
---@return { lines: string[], ft: string }
local function preview(item)
  local headline = item.name or item.value or item.id or "(unnamed)"
  local lines = { "# " .. headline, "" }
  if type(item.description) == "string" and item.description ~= "" then
    vim.list_extend(lines, vim.split(item.description, "\n", { plain = true }))
  else
    table.insert(lines, "_(no description advertised by the agent)_")
  end
  return { lines = lines, ft = "markdown" }
end

---@param opts? hyprpilot.palettes.effort.Opts
function M.open(opts)
  opts = opts or {}
  local instance_id = opts.instance_id or window.active_instance()

  if instance_id == nil then
    log.warn("palettes.effort: no active instance")
    return
  end

  instances.list_efforts(instance_id, function(err, result)
    if err ~= nil then
      log.warn("palettes.effort: efforts fetch failed: %s", err.message)
      return
    end

    local items = (result and result.efforts) or {}
    local current = result and result.effort_id or nil
    if type(items) ~= "table" or #items == 0 then
      log.warn("palettes.effort: instance advertises no effort options")
      return
    end

    pickers.open({
      items = items,
      title = "effort",
      kind = "hyprpilot.effort",
      picker = opts.picker,
      format_item = function(item)
        return format_item(item, current)
      end,
      preview = preview,
      on_pick = function(choice)
        local value = choice.value or choice.id
        if value == current then
          log.debug("palettes.effort: chose current value (%s) — no-op", tostring(current))
          return
        end
        instances.set_effort(instance_id, value, function(set_err)
          if set_err ~= nil then
            log.warn("palettes.effort: setEffort failed: %s", set_err.message)
          else
            log.debug("palettes.effort: set value=%s on instance=%s", tostring(value), instance_id)
          end
        end)
      end,
    })
  end)
end

return M
