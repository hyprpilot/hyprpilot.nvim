--- Attention palette — picker over `notification.attention.list()`.
--- Pick a row, the chat switches to that instance and the cursor
--- jumps into the chat (read-only side, so the captain can scroll /
--- read the agent's output that needs their attention).

local attention = require("hyprpilot.notification.attention")
local log = require("hyprpilot.log")
local pickers = require("hyprpilot.palettes.pickers")
local window = require("hyprpilot.chat.window")

local M = {}

---@class hyprpilot.palettes.attention.Opts
---@field on_pick? fun(entry: hyprpilot.notification.attention.Entry): nil
---@field picker? "auto" | "snacks" | "vim.ui.select"

---@param item hyprpilot.notification.attention.Entry
---@return string
local function format_item(item)
  local kind_label = item.kind == "permission" and "perm" or "turn"
  return string.format("[%s] %s", kind_label, item.instance_id)
end

---@param item hyprpilot.notification.attention.Entry
---@return { lines: string[], ft: string }
local function format_preview(item)
  local lines = { "# " .. item.instance_id, "" }
  table.insert(lines, string.format("- **kind:** `%s`", item.kind))
  if item.bufnr ~= nil then
    table.insert(lines, string.format("- **bufnr:** `%d`", item.bufnr))
  end
  if item.request_id ~= nil then
    table.insert(lines, string.format("- **request id:** `%s`", item.request_id))
  end
  return { lines = lines, ft = "markdown" }
end

---@param opts? hyprpilot.palettes.attention.Opts
function M.open(opts)
  opts = opts or {}

  local items = attention.list()
  if #items == 0 then
    log.warn("palettes.attention: nothing needs attention")
    return
  end

  local commit = opts.on_pick or function(entry)
    window.switch(entry.instance_id)
    require("hyprpilot.ui.window").focus({ target = "chat" })
  end

  pickers.open({
    items = items,
    title = "needs attention",
    kind = "hyprpilot.attention",
    picker = opts.picker,
    format_item = format_item,
    preview = format_preview,
    on_pick = function(choice)
      commit(choice)
    end,
  })
end

M.format_item = format_item
M.format_preview = format_preview

return M
