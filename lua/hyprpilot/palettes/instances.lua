--- Instances palette — picker over every live instance the daemon
--- advertises via `instances/list`. Pick a row, the chat window
--- switches to that instance's buffer.

local hp_instances = require("hyprpilot.rpc.instances")
local log = require("hyprpilot.log")
local pickers = require("hyprpilot.palettes.pickers")
local window = require("hyprpilot.chat.window")

local M = {}

---@class hyprpilot.palettes.instances.Opts
---@field on_pick? fun(instance_id: string): nil  -- override commit (default: chat.window.switch)
---@field picker? "auto" | "snacks" | "vim.ui.select"
---@field cwd? string | false                       -- filter by cwd; default `vim.fn.getcwd()`; `false` disables (every instance). Mirrors `palettes/sessions.lua`.

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

---Tail of `bufnr`'s contents (last `count` non-empty lines) for the
---preview pane. Returns an empty list when no buffer exists or it's
---empty.
---@param bufnr integer?
---@param count integer
---@return string[]
local function buffer_tail(bufnr, count)
  if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  if total == 0 then
    return {}
  end
  local start = math.max(0, total - count)
  return vim.api.nvim_buf_get_lines(bufnr, start, total, false)
end

---Compose preview lines for an instance. Shows headline + the
---structured fields (agent / profile / mode / cwd / session) as a
---markdown definition list, followed by a tail of the live chat
---buffer so the captain can recognise the instance from its
---most-recent transcript content (more useful than the wire-side
---metadata alone). We don't round-trip `instance/snapshot/chat` per
---highlight — that would hammer the daemon on every cursor move in
---the picker.
---@param item hyprpilot.Instance
---@param active_id? string
---@return { lines: string[], ft: string }
local function format_preview(item, active_id)
  local lines = { "# " .. (item.name or item.agent_id or item.id), "" }
  if item.id == active_id then
    table.insert(lines, "**active instance**")
    table.insert(lines, "")
  end
  local function field(label, value)
    if value ~= nil and value ~= "" then
      table.insert(lines, string.format("- **%s:** `%s`", label, value))
    end
  end
  field("instance id", item.id)
  field("agent", item.agent_id)
  field("profile", item.profile_id)
  field("mode", item.mode)
  field("cwd", item.cwd)
  field("session", item.session_id)

  local bufnr = require("hyprpilot.chat.window").get_bufnr(item.id)
  local tail = buffer_tail(bufnr, 40)
  if #tail > 0 then
    vim.list_extend(lines, { "", "---", "" })
    vim.list_extend(lines, tail)
  end

  return { lines = lines, ft = "markdown" }
end

---Resolve the cwd filter. Mirrors `palettes/sessions.lua`:
---  `opts.cwd == false` → no filter (every instance)
---  `opts.cwd == nil`   → filter by `vim.fn.getcwd()` (default)
---  `opts.cwd == "<p>"` → filter by that path
---@param opts hyprpilot.palettes.instances.Opts
---@return string?
local function resolve_cwd_filter(opts)
  if opts.cwd == false then
    return nil
  end
  if opts.cwd == nil then
    return vim.fn.getcwd()
  end
  return opts.cwd
end

---@param opts? hyprpilot.palettes.instances.Opts
function M.open(opts)
  opts = opts or {}

  local cwd_filter = resolve_cwd_filter(opts)

  hp_instances.list(function(err, items)
    if err ~= nil then
      log.warn("palettes.instances: list failed: %s", err.message)
      return
    end

    items = items or {}

    -- Cwd filter against the wire payload's `item.cwd`. The daemon
    -- ships cwd on every `instances/list` row (`InstanceListEntry.cwd`
    -- — added in the daemon's matching PR; until that lands every
    -- item carries `cwd = nil` and the default filter shows nothing,
    -- which is the right signal "you need to upgrade the daemon").
    -- Captains who explicitly pass `cwd = false` opt out of the
    -- filter entirely.
    if cwd_filter ~= nil then
      items = vim.tbl_filter(function(item)
        return item.cwd == cwd_filter
      end, items)
    end

    if #items == 0 then
      if cwd_filter ~= nil then
        log.warn("palettes.instances: no instances under cwd=%s — pass `{ cwd = false }` to see every instance", cwd_filter)
      else
        log.warn("palettes.instances: no instances — spawn one with `instances.spawn({})`")
      end
      return
    end

    local active_id = window.active_instance()
    -- Default commit is `instances.attach` (NOT `window.switch`)
    -- so the picker handles BOTH known-local AND daemon-only
    -- instances. After a plugin restart / re-source the local
    -- registry is empty but the daemon still has instances
    -- running; picking one should mint a fresh local buffer +
    -- hydrate from the daemon's snapshot — exactly what attach
    -- does. For locally-known ids it falls through to
    -- `window.show` which is the existing switch behaviour.
    local commit = opts.on_pick or function(id)
      hp_instances.attach(id)
    end

    pickers.open({
      items = items,
      title = "instances",
      kind = "hyprpilot.instances",
      picker = opts.picker,
      format_item = function(item)
        return format_item(item, active_id)
      end,
      preview = function(item)
        return format_preview(item, active_id)
      end,
      on_pick = function(choice)
        if choice.id == active_id and opts.on_pick == nil then
          log.debug("palettes.instances: chose active instance (%s) — no-op", active_id)
          return
        end
        commit(choice.id)
      end,
      actions = {
        -- `<C-d>` shuts down the highlighted instance (daemon-side
        -- `instances/shutdown` + local close cascade via `hp.close`).
        -- Closes the picker; captain re-opens to delete another.
        delete = {
          key = "<C-d>",
          handler = function(item)
            require("hyprpilot.rpc.instances").shutdown(item.id)
            require("hyprpilot.chat.window").close(item.id)
          end,
        },
      },
    })
  end)
end

---@class hyprpilot.palettes.instances.AttachedOpts
---@field on_pick? fun(instance_id: string): nil  -- override commit (default: chat.window.switch)
---@field picker? "auto" | "snacks" | "vim.ui.select"

---Local-only variant of `M.open`: picker over instances the plugin
---has ALREADY attached to (chat buffer minted + state registered
---in `chat.window._instances`). No `instances/list` round-trip, no
---`cwd` filter — just "jump to one of these N tabs I already
---have open." Pick → `chat.window.switch` (cheap local buffer swap)
---instead of `instances.attach` (RPC + hydrate).
---
---Use when the captain wants a fast switcher across THEIR live
---instances. `M.open` is still the right call when the captain
---wants to see every instance the daemon knows about (including
---ones spawned from the desktop overlay / a sibling nvim that
---this session hasn't attached to yet).
---@param opts? hyprpilot.palettes.instances.AttachedOpts
function M.open_attached(opts)
  opts = opts or {}

  local active_id = window.active_instance()
  local items = {}
  for id, state in pairs(window._instances) do
    -- Project the local state into the same shape `format_item` /
    -- `format_preview` consume so we reuse the existing renderers.
    -- Meta fields (agent / profile / cwd / mode) come from the
    -- winbar cache when available — captain might not have meta
    -- yet for a freshly-attached instance, in which case we ship
    -- nil and the renderer just skips the field.
    local meta = (package.loaded["hyprpilot.chat.winbar"] or {})._meta or {}
    local m = meta[id] or {}
    table.insert(items, {
      id = id,
      name = state.name or m.name,
      agent_id = m.agent_id,
      profile_id = m.profile_id,
      mode = m.current_mode_id,
      cwd = m.cwd,
      session_id = m.session_id,
    })
  end

  if #items == 0 then
    log.warn("palettes.instances.open_attached: no attached instances — use `palettes.instances.open()` to attach one")
    return
  end

  local commit = opts.on_pick or function(id)
    window.switch(id)
  end

  pickers.open({
    items = items,
    title = "attached instances",
    kind = "hyprpilot.instances.attached",
    picker = opts.picker,
    format_item = function(item)
      return format_item(item, active_id)
    end,
    preview = function(item)
      return format_preview(item, active_id)
    end,
    on_pick = function(choice)
      if choice.id == active_id and opts.on_pick == nil then
        log.debug("palettes.instances.open_attached: chose active instance (%s) — no-op", active_id)
        return
      end
      commit(choice.id)
    end,
    actions = {
      -- Mirror the `<C-d>` shutdown action on `M.open` so the
      -- captain has the same delete affordance regardless of
      -- which picker variant they opened.
      delete = {
        key = "<C-d>",
        handler = function(item)
          require("hyprpilot.rpc.instances").shutdown(item.id)
          require("hyprpilot.chat.window").close(item.id)
        end,
      },
    },
  })
end

M.format_item = format_item
M.format_preview = format_preview

return M
