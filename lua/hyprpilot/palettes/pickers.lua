--- Palette picker adapter — `vim.ui.select` ↔ `Snacks.picker.pick`.
---
--- Every palette flows through `M.open(opts)`; this module resolves
--- the backend and translates our unified opts shape to whichever
--- picker the captain configured (or `"auto"` detected).
---
--- Resolution rules:
---   - `config.palettes.picker = "snacks"` → force snacks (log.warn if
---     snacks isn't available, then fall back so the picker still
---     opens — better than a hard crash on a misconfigured captain).
---   - `config.palettes.picker = "vim.ui.select"` → force vim.ui.select.
---   - `config.palettes.picker = "auto"` (default) → snacks when
---     `require("snacks.picker")` succeeds, otherwise vim.ui.select.
---
--- The unified `opts.preview` is a function `fun(item) -> string[] |
--- {lines, ft?}` that returns either a plain line list or a record
--- with a filetype for syntax highlight. Snacks renders it in the
--- preview pane; vim.ui.select ignores it (raw vim.ui.select doesn't
--- support previews — captain who wants previews uses snacks).

local config = require("hyprpilot.config")
local log = require("hyprpilot.log")

local M = {}

---@class hyprpilot.palettes.PickerAction
---@field key string | string[]                             -- one or more key sequences mapped to the action (snacks `<C-d>` etc.)
---@field handler fun(item: any): nil                       -- runs against the highlighted row; picker auto-closes after

---@class hyprpilot.palettes.PickerOpts
---@field items any[]                                       -- picker rows
---@field title string                                      -- picker prompt
---@field kind string                                       -- `vim.ui.select` kind namespace (e.g. "hyprpilot.modes")
---@field format_item fun(item: any): string                -- row → display label
---@field preview? fun(item: any): string[] | { lines: string[], ft?: string }  -- snacks-only; ignored by vim.ui.select
---@field on_pick fun(item: any): nil                       -- called with the chosen row; nil on cancel → no-op
---@field actions? table<string, hyprpilot.palettes.PickerAction>  -- snacks-only side actions (e.g. `delete = { key = "<C-d>", handler = ... }`)
---@field picker? "auto" | "snacks" | "vim.ui.select"       -- per-call override of config.palettes.picker

---Decide which backend to actually use given the requested setting.
---@param requested? "auto" | "snacks" | "vim.ui.select"
---@return "snacks" | "vim.ui.select"
local function resolve_backend(requested)
  local setting = requested or (config.options.palettes or {}).picker or "auto"
  if setting == "vim.ui.select" then
    return "vim.ui.select"
  end

  local has_snacks = pcall(require, "snacks.picker")
  if setting == "snacks" then
    if has_snacks then
      return "snacks"
    end
    log.warn("palettes: picker=snacks but snacks.nvim isn't available; falling back to vim.ui.select")
    return "vim.ui.select"
  end

  -- "auto" (or any other value — treat as auto).
  if has_snacks then
    return "snacks"
  end
  return "vim.ui.select"
end

---Normalise the result of a `preview()` call to `{ lines, ft }`.
---@param result any
---@return { lines: string[], ft?: string }
local function normalise_preview(result)
  if type(result) == "table" and result.lines ~= nil then
    return { lines = result.lines, ft = result.ft }
  end
  if type(result) == "table" then
    return { lines = result }
  end
  return { lines = { tostring(result or "") } }
end

---Open via vim.ui.select. Discards `preview` — raw vim.ui.select has
---no preview surface.
---@param opts hyprpilot.palettes.PickerOpts
local function open_ui_select(opts)
  vim.ui.select(opts.items, {
    prompt = opts.title,
    format_item = opts.format_item,
    kind = opts.kind,
  }, function(choice)
    if choice == nil then
      return
    end
    opts.on_pick(choice)
  end)
end

---Open via `Snacks.picker.pick`. Each item gets a synthetic `text`
---field (used for fuzzy filtering) plus our format/preview hooks.
---@param opts hyprpilot.palettes.PickerOpts
local function open_snacks(opts)
  local snacks_picker = require("snacks.picker")

  -- Snacks filters on `item.text`; we synthesise it from format_item
  -- so the fuzzy match works on the same string the captain sees.
  local items = {}
  for i, raw in ipairs(opts.items) do
    table.insert(items, {
      idx = i,
      text = opts.format_item(raw),
      raw = raw,
    })
  end

  -- Translate the unified `opts.actions` shape into snacks' two
  -- separate `actions` (named handlers) + `win.input.keys` (key →
  -- action name) tables. Each action runs in normal & insert modes
  -- since snacks pickers default to insert-mode focus.
  local snacks_actions = {}
  local snacks_keys = {}
  if type(opts.actions) == "table" then
    for name, action in pairs(opts.actions) do
      snacks_actions[name] = function(picker, item)
        picker:close()
        if item ~= nil and type(action.handler) == "function" then
          action.handler(item.raw)
        end
      end
      local keys = action.key
      if type(keys) == "string" then
        keys = { keys }
      end
      if type(keys) == "table" then
        for _, key in ipairs(keys) do
          snacks_keys[key] = { name, mode = { "n", "i" } }
        end
      end
    end
  end

  snacks_picker.pick({
    source = opts.kind,
    items = items,
    title = opts.title,
    format = function(item)
      -- Snacks expects an array of `{text, hl_group?}` chunks. A
      -- single neutral chunk is fine for our case; captain can
      -- restyle by overriding the format per-source in their snacks
      -- config.
      return { { item.text } }
    end,
    preview = opts.preview and function(ctx)
      local preview = normalise_preview(opts.preview(ctx.item.raw))
      ctx.preview:set_lines(preview.lines)
      if preview.ft ~= nil then
        ctx.preview:highlight({ ft = preview.ft })
      end
    end or nil,
    confirm = function(picker, item)
      picker:close()
      if item ~= nil then
        opts.on_pick(item.raw)
      end
    end,
    actions = snacks_actions,
    win = { input = { keys = snacks_keys } },
  })
end

---Open a picker. Dispatches to snacks or vim.ui.select per config.
---@param opts hyprpilot.palettes.PickerOpts
function M.open(opts)
  local backend = resolve_backend(opts.picker)
  if backend == "snacks" then
    return open_snacks(opts)
  end
  return open_ui_select(opts)
end

return M
