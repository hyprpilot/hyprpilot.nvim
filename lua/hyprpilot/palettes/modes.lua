--- Modes palette — picker over the active instance's `available_modes`.
--- Pick a row, the daemon's `instances/setMode` RPC commits.

local instances = require("hyprpilot.instances")
local log = require("hyprpilot.log")
local pickers = require("hyprpilot.palettes.pickers")
local window = require("hyprpilot.chat.window")

local M = {}

---@class hyprpilot.palettes.modes.Opts
---@field instance_id? string
---@field picker? "auto" | "snacks" | "vim.ui.select"

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

    pickers.open({
      items = available,
      title = "modes",
      kind = "hyprpilot.modes",
      picker = opts.picker,
      format_item = function(item)
        local prefix = item.id == current and "* " or "  "
        return prefix .. (item.name or item.id)
      end,
      -- Snacks preview: mode name (heading) + description (body).
      -- The agent (claude-agent-acp / opencode) is the source of
      -- truth for the description string; we render it markdown so
      -- bold / lists / code spans in the description survive.
      preview = function(item)
        local lines = { "# " .. (item.name or item.id), "" }
        if item.description ~= nil and item.description ~= "" then
          for _, l in ipairs(vim.split(tostring(item.description), "\n", { plain = true })) do
            table.insert(lines, l)
          end
        else
          table.insert(lines, "_(no description advertised by the agent)_")
        end
        return { lines = lines, ft = "markdown" }
      end,
      on_pick = function(choice)
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
      end,
    })
  end)
end

return M
