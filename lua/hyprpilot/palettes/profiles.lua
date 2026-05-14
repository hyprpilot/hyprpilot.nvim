--- Profiles palette — pick a profile from the daemon's catalog;
--- on pick, spawn a fresh instance under that profile. Captain
--- keybind:
---
---   vim.keymap.set("n", "<leader>cN",
---     require("hyprpilot.palettes.profiles").open)

local hp_instances = require("hyprpilot.instances")
local hp_profiles = require("hyprpilot.profiles")
local log = require("hyprpilot.log")
local pickers = require("hyprpilot.palettes.pickers")

local M = {}

---@class hyprpilot.palettes.profiles.Opts
---@field on_pick? fun(profile: hyprpilot.Profile): nil  -- override commit; default fires `instances.spawn`
---@field picker? "auto" | "snacks" | "vim.ui.select"
---@field cwd? string                                     -- forwarded to spawn; default `vim.fn.getcwd()`
---@field show? boolean                                   -- forwarded to spawn; default true

---@param item hyprpilot.Profile
---@return string
local function format_item(item)
  local prefix = item.is_default and "* " or "  "
  local meta_parts = { item.agent_id }
  if item.model ~= nil and item.model ~= "" then
    table.insert(meta_parts, item.model)
  end
  return prefix .. item.id .. " · " .. table.concat(meta_parts, " · ")
end

---@param item hyprpilot.Profile
---@return { lines: string[], ft: string }
local function format_preview(item)
  local lines = { "# " .. item.id, "" }
  if item.is_default then
    table.insert(lines, "**default profile**")
    table.insert(lines, "")
  end
  local function field(label, value)
    if value ~= nil and value ~= "" then
      table.insert(lines, string.format("- **%s:** `%s`", label, value))
    end
  end
  field("agent", item.agent_id)
  field("model", item.model)
  return { lines = lines, ft = "markdown" }
end

---@param opts? hyprpilot.palettes.profiles.Opts
function M.open(opts)
  opts = opts or {}

  hp_profiles.list(function(err, items)
    if err ~= nil then
      return
    end

    items = items or {}
    if #items == 0 then
      log.warn("palettes.profiles: daemon advertises no profiles")
      return
    end

    local commit = opts.on_pick or function(profile)
      hp_instances.spawn({
        profile_id = profile.id,
        cwd = opts.cwd,
        show = opts.show,
      })
    end

    pickers.open({
      items = items,
      title = "new instance — pick a profile",
      kind = "hyprpilot.profiles",
      picker = opts.picker,
      format_item = format_item,
      preview = format_preview,
      on_pick = function(choice)
        commit(choice)
      end,
    })
  end)
end

M.format_item = format_item
M.format_preview = format_preview

return M
