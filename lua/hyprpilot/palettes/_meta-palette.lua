--- Factory for meta-driven palettes (modes / models / effort / any
--- future closed-set picker over an `instance/snapshot/meta` field).
---
--- Every modes-shaped palette walks the same path:
---   1. resolve active instance (or use opts.instance_id)
---   2. fetch instance.meta(...)
---   3. extract the relevant list + current-value from the meta
---   4. abort with a log.warn when the list is empty
---   5. open a picker via `palettes.pickers.open` with a per-row
---      preview + format
---   6. on commit, skip the no-op (chose-current), otherwise call
---      the setter RPC and log the outcome
---
--- The differences across modes/models/effort are tiny: which meta
--- field to read, the wire field name on each item (`id` vs
--- `value`), the setter callback, and the label text. This module
--- captures the shared scaffold; each concrete palette (modes.lua
--- etc.) becomes a 5-line config block.
---
--- `effort` reads from `meta.config_options[id="effort"]` (nested
--- shape), so the factory accepts a `resolve_list` hook that
--- returns `(items, current_value)` given the meta. Flat shapes
--- like modes/models use the default `(meta[meta_field],
--- meta[current_field])` resolver.

local instances = require("hyprpilot.rpc.instances")
local log = require("hyprpilot.log")
local pickers = require("hyprpilot.palettes.pickers")
local window = require("hyprpilot.chat.window")

local M = {}

---@class hyprpilot.palettes.MetaPaletteConfig
---@field title string                                          -- picker prompt text
---@field kind string                                           -- `vim.ui.select` kind namespace (e.g. "hyprpilot.modes")
---@field item_id_field string                                  -- field on each item that identifies it ("id" for modes/models, "value" for effort options)
---@field empty_message string                                  -- log.warn body when the list is empty
---@field log_label string                                      -- shorthand for log messages (e.g. "modes")
---@field setter fun(instance_id: string, value: string, callback?: fun(err: hyprpilot.client.RpcError?, result: any?): nil): nil
---@field resolve_list? fun(meta: hyprpilot.InstanceMeta): any[], string?  -- defaults to (meta[meta_field], meta[current_field])
---@field meta_field? string                                    -- when resolve_list is omitted: meta key for the list
---@field current_field? string                                 -- when resolve_list is omitted: meta key for the current value
---@field format_item? fun(item: any, current: string?): string -- defaults to "* <name>" / "  <name>"
---@field preview? fun(item: any): { lines: string[], ft?: string } | string[]?  -- optional snacks preview override

---@class hyprpilot.palettes.MetaPaletteOpts
---@field instance_id? string
---@field picker? "auto" | "snacks" | "vim.ui.select"

---Default formatter: `* <name>` for the active row, `  <name>`
---for the rest. The `item_id_field` config drives the equality
---check between item id/value and `current`.
---@param config hyprpilot.palettes.MetaPaletteConfig
---@param item any
---@param current string?
---@return string
local function default_format(config, item, current)
  local prefix = item[config.item_id_field] == current and "* " or "  "
  return prefix .. tostring(item.name or item[config.item_id_field])
end

---Default snacks preview: `# <name>` heading + description body,
---markdown filetype. When the agent didn't advertise a description
---we drop a parenthetical placeholder so the pane isn't empty.
---@param item any
---@return { lines: string[], ft: string }
local function default_preview(item)
  local headline = item.name or item.id or item.value or "(unnamed)"
  local lines = { "# " .. headline, "" }
  if type(item.description) == "string" and item.description ~= "" then
    vim.list_extend(lines, vim.split(item.description, "\n", { plain = true }))
  else
    table.insert(lines, "_(no description advertised by the agent)_")
  end
  return { lines = lines, ft = "markdown" }
end

---Build a palette `open(opts)` function from a config. Each
---concrete palette (modes / models / effort) creates one of these
---at module load + assigns it to `M.open`.
---@param config hyprpilot.palettes.MetaPaletteConfig
---@return fun(opts?: hyprpilot.palettes.MetaPaletteOpts): nil
function M.build(config)
  local resolve_list = config.resolve_list
  if resolve_list == nil then
    -- Default resolver: read flat `meta[meta_field]` for the list
    -- and `meta[current_field]` for the current value.
    local meta_field = assert(config.meta_field, "meta_palette: resolve_list OR meta_field required")
    local current_field = config.current_field
    resolve_list = function(meta)
      return (meta and meta[meta_field]) or {}, meta and current_field and meta[current_field] or nil
    end
  end

  local format_item = config.format_item or function(item, current)
    return default_format(config, item, current)
  end
  local preview = config.preview or default_preview

  return function(opts)
    opts = opts or {}
    local instance_id = opts.instance_id or window.active_instance()

    if instance_id == nil then
      log.warn("palettes.%s: no active instance", config.log_label)
      return
    end

    instances.meta(instance_id, function(err, meta)
      if err ~= nil then
        log.warn("palettes.%s: meta fetch failed: %s", config.log_label, err.message)
        return
      end

      local items, current = resolve_list(meta)
      if type(items) ~= "table" or #items == 0 then
        log.warn("palettes.%s: %s", config.log_label, config.empty_message)
        return
      end

      pickers.open({
        items = items,
        title = config.title,
        kind = config.kind,
        picker = opts.picker,
        format_item = function(item)
          return format_item(item, current)
        end,
        preview = preview,
        on_pick = function(choice)
          local choice_value = choice[config.item_id_field]
          if choice_value == current then
            log.debug("palettes.%s: chose current value (%s) — no-op", config.log_label, tostring(current))
            return
          end
          config.setter(instance_id, choice_value, function(set_err)
            if set_err ~= nil then
              log.warn("palettes.%s: setter failed: %s", config.log_label, set_err.message)
            else
              log.debug("palettes.%s: set value=%s on instance=%s", config.log_label, tostring(choice_value), instance_id)
            end
          end)
        end,
      })
    end)
  end
end

return M
