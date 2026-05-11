--- Pinned 1-row permission strip between the chat and the composer.
---
--- Surfaces pending permission prompts so the captain doesn't have to
--- scroll up into the chat to find the inline button group. Auto-
--- shows when at least one permission is pending, auto-hides when
--- the queue drains. The chat-buffer inline rendering remains the
--- source of truth (history + keymap routing); the row is a status
--- mirror that says "permission: <tool> · g allow · d deny".
---
--- Keymaps installed on the row buffer route `g` / `d` / `<CR>` /
--- `<Tab>` to the first pending request, so the captain can answer
--- without leaving the composer.

local buffer = require("hyprpilot.chat.buffer")
local log = require("hyprpilot.log")
local window = require("hyprpilot.chat.window")

local M = {}

local BUFFER_NAME = "hyprpilot://permission_row"
local NS = vim.api.nvim_create_namespace("hyprpilot.chat.permission_row")

---@class hyprpilot.chat.permission_row.Entry
---@field instance_id string
---@field request_id string
---@field tool string
---@field options table[]

---@type hyprpilot.chat.permission_row.Entry[]
M._queue = {}

---@type integer?
M._winid = nil

---@type integer?
M._bufnr = nil

---True when the row window exists + is valid.
---@return boolean
function M.is_visible()
  if M._winid == nil then
    return false
  end
  if not vim.api.nvim_win_is_valid(M._winid) then
    M._winid = nil
    return false
  end
  return true
end

---Get-or-create the shared row buffer.
---@return integer
local function ensure_buffer()
  if M._bufnr ~= nil and vim.api.nvim_buf_is_valid(M._bufnr) then
    return M._bufnr
  end

  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_name(bufnr, BUFFER_NAME)
  vim.bo[bufnr].filetype = "hyprpilot_permission_row"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].modifiable = false

  M._bufnr = bufnr
  return bufnr
end

---Resolve the active entry (head of queue).
---@return hyprpilot.chat.permission_row.Entry?
local function head()
  return M._queue[1]
end

---Find the first option whose id or name matches a `^prefix`
---(case-insensitive). Mirrors `ui.permissions.smart_match`.
---@param options table[]
---@param patterns string[]
---@return table?
local function match_option(options, patterns)
  for _, opt in ipairs(options) do
    local id = string.lower(tostring(opt.optionId or ""))
    local name = string.lower(tostring(opt.name or ""))
    for _, pattern in ipairs(patterns) do
      if id:match(pattern) ~= nil or name:match(pattern) ~= nil then
        return opt
      end
    end
  end
  return nil
end

---Compose the row line for the head entry. Returns an empty string
---when the queue is empty (caller should hide the window).
---@return string
local function compose()
  local entry = head()
  if entry == nil then
    return ""
  end

  local extra = #M._queue > 1 and string.format(" (+%d more)", #M._queue - 1) or ""

  return string.format(" permission · %s · <CR>/g allow · d deny%s", entry.tool or "tool", extra)
end

---Re-paint the row line.
function M.refresh()
  if M._bufnr == nil or not vim.api.nvim_buf_is_valid(M._bufnr) then
    return
  end

  buffer.with_buffer(M._bufnr, function()
    vim.api.nvim_buf_set_lines(M._bufnr, 0, -1, false, { compose() })
    vim.api.nvim_buf_clear_namespace(M._bufnr, NS, 0, -1)
    if head() ~= nil then
      vim.api.nvim_buf_set_extmark(M._bufnr, NS, 0, 0, { line_hl_group = "HyprpilotPermissionRow" })
    end
  end)
end

---Install the row keymaps once per buffer.
---@param bufnr integer
local function install_keymaps(bufnr)
  local function respond(patterns)
    local entry = head()
    if entry == nil then
      return
    end

    local opt = match_option(entry.options, patterns)
    if opt == nil then
      log.debug("permission_row: no option matching %s", vim.inspect(patterns))
      return
    end

    require("hyprpilot.permissions").respond(entry.request_id, opt.optionId, function(err)
      if err ~= nil then
        log.warn("permission_row.respond: %s (%s/%s)", err.message, entry.request_id, opt.optionId)
      else
        log.debug("permission_row.respond: ok %s/%s", entry.request_id, opt.optionId)
      end
    end)
  end

  vim.keymap.set("n", "<CR>", function()
    respond({ "^allow", "^accept", "^proceed" })
  end, { buffer = bufnr, silent = true, desc = "hyprpilot: allow pending permission" })

  vim.keymap.set("n", "g", function()
    respond({ "^allow", "^accept", "^proceed" })
  end, { buffer = bufnr, silent = true, desc = "hyprpilot: allow pending permission" })

  vim.keymap.set("n", "d", function()
    respond({ "^reject", "^deny", "^abort", "^cancel" })
  end, { buffer = bufnr, silent = true, desc = "hyprpilot: deny pending permission" })
end

---Open the row window below the chat split.
local function open_window()
  if not window.is_visible() or head() == nil then
    return
  end

  if M.is_visible() then
    M.refresh()
    return
  end

  local previous_win = vim.api.nvim_get_current_win()

  vim.api.nvim_set_current_win(window._winid)
  vim.cmd("belowright 1split")

  M._winid = vim.api.nvim_get_current_win()
  local bufnr = ensure_buffer()
  vim.api.nvim_win_set_buf(M._winid, bufnr)
  install_keymaps(bufnr)

  vim.wo[M._winid].number = false
  vim.wo[M._winid].relativenumber = false
  vim.wo[M._winid].signcolumn = "no"
  vim.wo[M._winid].foldcolumn = "0"
  vim.wo[M._winid].wrap = false
  vim.wo[M._winid].winfixheight = true
  vim.wo[M._winid].cursorline = false
  vim.wo[M._winid].winhighlight = "Normal:HyprpilotPermissionRow"

  vim.api.nvim_win_set_height(M._winid, 1)

  if vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end

  M.refresh()
end

---Close the row window (queue stays — re-opens on next request).
function M.close()
  if not M.is_visible() then
    return
  end

  pcall(vim.api.nvim_win_close, M._winid, true)
  M._winid = nil
end

---Enqueue a permission request. Auto-opens the row if not already
---visible. Called from `chat.render.render_permission_request` after
---the inline block lands.
---@param instance_id string
---@param request_id string
---@param tool string
---@param options table[]
function M.enqueue(instance_id, request_id, tool, options)
  for _, entry in ipairs(M._queue) do
    if entry.request_id == request_id then
      return
    end
  end

  table.insert(M._queue, {
    instance_id = instance_id,
    request_id = request_id,
    tool = tool,
    options = options,
  })

  if M.is_visible() then
    M.refresh()
  else
    open_window()
  end
end

---Drop a resolved permission from the queue. Auto-closes the row when
---the queue drains.
---@param request_id string
function M.resolve(request_id)
  for i, entry in ipairs(M._queue) do
    if entry.request_id == request_id then
      table.remove(M._queue, i)
      break
    end
  end

  if #M._queue == 0 then
    M.close()
  elseif M.is_visible() then
    M.refresh()
  end
end

---Wipe state (used on full hide / hydrate).
function M.reset()
  M._queue = {}
  M.close()
end

return M
