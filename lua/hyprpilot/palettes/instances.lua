--- Instances palette — `vim.ui.select` over every live instance the
--- daemon advertises via `instances/list`. Pick a row, the chat
--- window switches to that instance's buffer (`chat.window.switch`).
---
--- Headline column shape: `<name?> <agent_id> <profile_id?>`. The
--- name takes precedence when the captain has renamed the instance;
--- otherwise the agent id (claude-code / opencode / etc.) acts as
--- the headline so the captain still has a recognisable handle.

local hp_instances = require("hyprpilot.instances")
local log = require("hyprpilot.log")
local window = require("hyprpilot.chat.window")

local M = {}

---@class hyprpilot.palettes.instances.Opts
---@field on_pick? fun(instance_id: string): nil  -- override commit (default: chat.window.switch)

---Compose the row display string. Active instance gets a `* `
---prefix so it's visible in pickers without a "selected" indicator.
---@param item hyprpilot.Instance
---@param active_id? string
---@return string
local function format_item(item, active_id)
  local prefix = item.id == active_id and "* " or "  "
  local headline = item.name or item.agent_id or item.id

  local meta_parts = {}
  if item.agent_id ~= nil and item.agent_id ~= headline then
    table.insert(meta_parts, item.agent_id)
  end
  if item.profile_id ~= nil then
    table.insert(meta_parts, item.profile_id)
  end
  if item.cwd ~= nil and item.cwd ~= "" then
    table.insert(meta_parts, item.cwd)
  end

  if #meta_parts == 0 then
    return prefix .. headline
  end
  return prefix .. headline .. " · " .. table.concat(meta_parts, " · ")
end

---@param opts? hyprpilot.palettes.instances.Opts
function M.open(opts)
  opts = opts or {}

  hp_instances.list(function(err, items)
    if err ~= nil then
      log.warn("palettes.instances: list failed: %s", err.message)
      return
    end

    items = items or {}
    if #items == 0 then
      log.warn("palettes.instances: no instances — spawn one with `instances.spawn({})`")
      return
    end

    local active_id = window.active_instance()
    local commit = opts.on_pick or function(id)
      window.switch(id)
    end

    vim.ui.select(items, {
      prompt = "instances",
      format_item = function(item)
        return format_item(item, active_id)
      end,
      kind = "hyprpilot.instances",
    }, function(choice)
      if choice == nil then
        return
      end
      if choice.id == active_id and opts.on_pick == nil then
        log.debug("palettes.instances: chose active instance (%s) — no-op", active_id)
        return
      end
      commit(choice.id)
    end)
  end)
end

-- Exported for tests + custom selector integrations that want to
-- reuse the row formatter.
M.format_item = format_item

return M
