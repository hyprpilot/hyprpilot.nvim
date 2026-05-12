--- Palette modules — `vim.ui.select`-driven pickers for the daemon's
--- per-instance switchable axes (instances / modes / models / effort
--- / sessions). One module per axis under `lua/hyprpilot/palettes/`;
--- captains wire keybinds against `require("hyprpilot.palettes.X").open()`.
---
--- Why `vim.ui.select` and not a custom palette UI:
---   - Native primitive — works out of the box with no extra deps.
---   - Picker integrations (telescope, snacks, dressing, fzf-lua,
---     mini.pick) all override `vim.ui.select` and route through the
---     `kind` field. Every palette here passes
---     `kind = "hyprpilot.<axis>"` so a captain that wires a custom
---     selector for one of those kinds gets a richer view (preview
---     pane, fuzzy filter, etc.) without us touching the picker
---     library directly.
---   - Plays nicely with the rest of the plugin's "no third-party
---     deps" rule (CLAUDE.md).
---
--- Each palette returns a module with `open(opts?)`. Opts shape is
--- per-palette but always includes an optional `instance_id` to
--- target a non-active instance.

local M = {}

-- Lazy require so a captain who only loads one palette doesn't pay
-- for the others. Each `M.<axis>` short-circuits to the lazy load
-- the first time it's accessed.
setmetatable(M, {
  __index = function(_, key)
    local ok, mod = pcall(require, "hyprpilot.palettes." .. key)
    if ok then
      return mod
    end
    return nil
  end,
})

return M
