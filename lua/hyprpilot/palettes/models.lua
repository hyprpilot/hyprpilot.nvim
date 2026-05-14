--- Models palette — mirrors `palettes/modes.lua` with `setModel` /
--- `available_models` instead. Concrete config; orchestration lives
--- in `_meta_palette`.

local instances = require("hyprpilot.rpc.instances")
local meta_palette = require("hyprpilot.palettes._meta-palette")

local M = {}

---@class hyprpilot.palettes.models.Opts
---@field instance_id? string
---@field picker? "auto" | "snacks" | "vim.ui.select"

M.open = meta_palette.build({
  title = "models",
  kind = "hyprpilot.models",
  log_label = "models",
  meta_field = "available_models",
  current_field = "current_model_id",
  item_id_field = "id",
  empty_message = "instance advertises no models",
  setter = function(instance_id, value, callback)
    instances.set_model(instance_id, value, callback)
  end,
})

return M
