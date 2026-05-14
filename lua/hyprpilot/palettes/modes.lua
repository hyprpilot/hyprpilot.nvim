--- Modes palette — picker over the active instance's `available_modes`.
--- Pick a row, the daemon's `instances/setMode` RPC commits.
--- Concrete config; orchestration lives in `_meta_palette`.

local instances = require("hyprpilot.instances")
local meta_palette = require("hyprpilot.palettes._meta-palette")

local M = {}

---@class hyprpilot.palettes.modes.Opts
---@field instance_id? string
---@field picker? "auto" | "snacks" | "vim.ui.select"

M.open = meta_palette.build({
  title = "modes",
  kind = "hyprpilot.modes",
  log_label = "modes",
  meta_field = "available_modes",
  current_field = "current_mode_id",
  item_id_field = "id",
  empty_message = "instance advertises no modes",
  setter = function(instance_id, value, callback)
    instances.set_mode(instance_id, value, callback)
  end,
})

return M
