--- Instances palette — picker over every live instance the daemon
--- advertises via `instances/list`. Pick a row, the chat window
--- switches to that instance's buffer.

local hp_instances = require("hyprpilot.instances")
local log = require("hyprpilot.log")
local pickers = require("hyprpilot.palettes.pickers")
local window = require("hyprpilot.chat.window")

local M = {}

---@class hyprpilot.palettes.instances.Opts
---@field on_pick? fun(instance_id: string): nil  -- override commit (default: chat.window.switch)
---@field picker? "auto" | "snacks" | "vim.ui.select"

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
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
    for _, l in ipairs(tail) do
      table.insert(lines, l)
    end
  end

  return { lines = lines, ft = "markdown" }
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
            require("hyprpilot.instances").shutdown(item.id)
            require("hyprpilot.chat.window").close(item.id)
          end,
        },
      },
    })
  end)
end

M.format_item = format_item
M.format_preview = format_preview

return M
