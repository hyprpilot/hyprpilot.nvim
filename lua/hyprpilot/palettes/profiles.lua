--- Profiles palette — pick a profile from the daemon's catalog;
--- on pick, either spawn a fresh instance under that profile
--- (`open()`) or re-bootstrap the active instance under the picked
--- profile so the captain can browse THAT profile's session
--- history (`set()`). Captain keybinds:
---
---   vim.keymap.set("n", "<leader>cN",
---     require("hyprpilot.palettes.profiles").open)   -- spawn new
---   vim.keymap.set("n", "<leader>mp",
---     require("hyprpilot.palettes.profiles").set)    -- re-bootstrap active under another profile

local hp_instances = require("hyprpilot.rpc.instances")
local hp_profiles = require("hyprpilot.rpc.profiles")
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

---@class hyprpilot.palettes.profiles.SetOpts
---@field picker? "auto" | "snacks" | "vim.ui.select"

---Open the profile picker against the daemon-singleton selected
---profile. Picking a row fires `profile/set` — daemon mutates its
---`selected_profile_id`, broadcasts `acp:profile-changed`, and
---every connected frontend syncs. No mid-flight teardown of any
---running instance; the selection is a daemon-scope pointer
---separate from per-instance profile_ids (a live instance keeps
---running under whatever profile it was spawned with).
---
---Captain workflow: pick profile → `sessions/list` reflects the
---new profile's history → captain picks a session → `sessions/load`
---mints an actor under the picked profile.
---@param opts? hyprpilot.palettes.profiles.SetOpts
function M.set(opts)
  opts = opts or {}

  -- Fetch the catalog + the daemon-selected profile in parallel so
  -- the picker can mark the current row + skip the no-op self-set.
  hp_profiles.list(function(err, items)
    if err ~= nil then
      log.warn("palettes.profiles.set: profiles/list failed: %s", err.message)
      return
    end
    items = items or {}
    if #items == 0 then
      log.warn("palettes.profiles.set: daemon advertises no profiles")
      return
    end

    hp_profiles.get_selected(function(get_err, current)
      if get_err ~= nil then
        log.warn("palettes.profiles.set: profile/get failed: %s", get_err.message)
        return
      end

      pickers.open({
        items = items,
        title = "select profile (daemon-singleton)",
        kind = "hyprpilot.profiles.set",
        picker = opts.picker,
        format_item = function(item)
          -- Mark the currently-selected profile with `*` (mirrors
          -- the modes / models / effort palettes' shape) so the
          -- captain reads at a glance "which one am I on".
          local prefix = item.id == current and "* " or "  "
          local meta_parts = { item.agent_id }
          if item.model ~= nil and item.model ~= "" then
            table.insert(meta_parts, item.model)
          end
          return prefix .. item.id .. " · " .. table.concat(meta_parts, " · ")
        end,
        preview = format_preview,
        on_pick = function(choice)
          if choice.id == current then
            log.debug("palettes.profiles.set: chose current profile (%s) — no-op", tostring(current))
            return
          end
          hp_profiles.set_selected(choice.id, function(set_err)
            if set_err ~= nil then
              log.warn("palettes.profiles.set: profile/set failed: %s", set_err.message)
              return
            end
          end)
        end,
      })
    end)
  end)
end

M.format_item = format_item
M.format_preview = format_preview

return M
