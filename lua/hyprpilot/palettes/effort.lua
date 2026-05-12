--- Effort palette — picker over the active instance's effort
--- config category (claude-agent-acp 0.21+ adaptive thinking).
--- The wire shape is nested (`meta.config_options[id="effort"]`)
--- rather than a flat list, so we feed `_meta_palette` a
--- `resolve_list` hook that walks the categories array.

local instances = require("hyprpilot.instances")
local meta_palette = require("hyprpilot.palettes._meta_palette")

local M = {}

local CATEGORY_ID = "effort"

---@class hyprpilot.palettes.effort.Opts
---@field instance_id? string
---@field picker? "auto" | "snacks" | "vim.ui.select"

M.open = meta_palette.build({
  title = "effort",
  kind = "hyprpilot.effort",
  log_label = "effort",
  item_id_field = "value",
  empty_message = "instance advertises no effort options",
  setter = function(instance_id, value, callback)
    instances.set_option(instance_id, CATEGORY_ID, value, callback)
  end,
  resolve_list = function(meta)
    local categories = (meta and meta.config_options) or {}
    for _, c in ipairs(categories) do
      if c.id == CATEGORY_ID then
        return c.options or {}, c.currentValue
      end
    end
    return {}, nil
  end,
})

return M
