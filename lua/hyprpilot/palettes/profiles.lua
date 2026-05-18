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
local window = require("hyprpilot.chat.window")

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
---@field instance_id? string                              -- default: active
---@field picker? "auto" | "snacks" | "vim.ui.select"

---Open the profile picker against a LIVE instance — picking a row
---fires `instances/setProfile`. The daemon tears down the actor +
---re-spawns under the new profile in `Bootstrap::ListOnly`: the
---agent process is alive and `sessions/list` serves the new
---profile's history, but no session is bound. Natural follow-on
---is the sessions palette so the captain picks a session under
---the new profile.
---
---Plugin / overlay chrome keyed by `instance_id` (chat buffer,
---window, queue strip, permission row) stays addressable across
---the switch.
---@param opts? hyprpilot.palettes.profiles.SetOpts
function M.set(opts)
  opts = opts or {}
  local instance_id = opts.instance_id or window.active_instance()
  if instance_id == nil then
    log.warn("palettes.profiles.set: no active instance")
    return
  end

  -- Fetch the catalog + the active instance's current profile_id
  -- in parallel so the picker can mark the current row + skip the
  -- no-op self-set. `instances.meta` is the same source the
  -- header pill reads from.
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

    hp_instances.meta(instance_id, function(meta_err, meta)
      if meta_err ~= nil then
        log.warn("palettes.profiles.set: meta fetch failed: %s", meta_err.message)
        return
      end
      local current = (meta or {}).profile_id

      pickers.open({
        items = items,
        title = "re-bootstrap active instance under another profile",
        kind = "hyprpilot.profiles.set",
        picker = opts.picker,
        format_item = function(item)
          -- Mark the current profile with `*` (mirrors the
          -- modes / models / effort palettes' shape) so the
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
          hp_instances.set_profile(instance_id, choice.id, nil, function(set_err)
            if set_err ~= nil then
              log.warn("palettes.profiles.set: setProfile failed: %s", set_err.message)
              return
            end
            log.debug("palettes.profiles.set: instance=%s profile=%s — opening sessions palette for the new profile's history", instance_id, choice.id)
            -- Auto-chain into the sessions palette so the
            -- captain can bind a session under the new profile
            -- (the daemon booted Bootstrap::ListOnly — agent is
            -- alive, nothing bound yet, prompts will reject
            -- until a session is loaded). Captain can ESC out
            -- if they'd rather start fresh.
            pcall(function()
              require("hyprpilot.palettes.sessions").open({ instance_id = instance_id })
            end)
          end)
        end,
      })
    end)
  end)
end

M.format_item = format_item
M.format_preview = format_preview

return M
