--- Attachments palette — picker over the active (or named)
--- instance's staged composer attachments. Pick a row, the
--- attachment is detached from the composer.
---
--- Captain keybind:
---
---     vim.keymap.set("n", "<leader>cD",
---       require("hyprpilot.palettes.attachments").detach)

local composer = require("hyprpilot.composer")
local log = require("hyprpilot.log")
local pickers = require("hyprpilot.palettes.pickers")
local window = require("hyprpilot.chat.window")

local M = {}

---@class hyprpilot.palettes.attachments.Opts
---@field instance_id? string                                       -- defaults to active instance
---@field on_pick? fun(attachment: hyprpilot.composer.Attachment): nil  -- override commit (default: composer.detach)
---@field picker? "auto" | "snacks" | "vim.ui.select"

---@param item hyprpilot.composer.Attachment
---@return string
local function format_item(item)
  local title = item.title ~= nil and item.title ~= "" and item.title or item.slug
  if item.mime ~= nil and item.mime ~= "" then
    return string.format("%s · %s", title, item.mime)
  end
  return title
end

---@param item hyprpilot.composer.Attachment
---@return { lines: string[], ft: string }
local function format_preview(item)
  local lines = { "# " .. (item.title ~= nil and item.title ~= "" and item.title or item.slug), "" }
  local function field(label, value)
    if value ~= nil and value ~= "" then
      table.insert(lines, string.format("- **%s:** `%s`", label, value))
    end
  end
  field("slug", item.slug)
  field("path", item.path)
  field("mime", item.mime)
  if type(item.body) == "string" and item.body ~= "" then
    table.insert(lines, "")
    table.insert(lines, "```")
    -- Cap preview at first 200 lines so a giant attached file
    -- doesn't blow up the picker preview pane.
    local body_lines = vim.split(item.body, "\n", { plain = true })
    local n = math.min(#body_lines, 200)
    for i = 1, n do
      table.insert(lines, body_lines[i])
    end
    if #body_lines > n then
      table.insert(lines, ("…+%d more lines"):format(#body_lines - n))
    end
    table.insert(lines, "```")
  end
  return { lines = lines, ft = "markdown" }
end

---Detach picker — opens a picker over staged attachments and
---detaches the chosen one. Captain default.
---@param opts? hyprpilot.palettes.attachments.Opts
function M.detach(opts)
  opts = opts or {}
  local instance_id = opts.instance_id or window.active_instance()

  if instance_id == nil then
    log.warn("palettes.attachments: no active instance")
    return
  end

  local items = composer.attachments(instance_id)
  if #items == 0 then
    log.warn("palettes.attachments: nothing to detach")
    return
  end

  local commit = opts.on_pick or function(attachment)
    composer.detach(attachment.slug, { instance_id = instance_id })
  end

  pickers.open({
    items = items,
    title = "detach attachment",
    kind = "hyprpilot.attachments",
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
