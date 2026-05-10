local buffer = require("hyprpilot.chat.buffer")
local config = require("hyprpilot.config")
local log = require("hyprpilot.log")

local M = {}

---@type integer?
M._winid = nil

---@type table<string, hyprpilot.InstanceState>
M._instances = {}

---@type string?
M._last_active_id = nil

---Resolve the configured width to a concrete column count.
---@param ui hyprpilot.ConfigUi
---@return integer
local function resolve_width(ui)
  local raw = ui.width
  local columns = vim.o.columns

  if type(raw) == "function" then
    local ok, value = pcall(raw, columns)

    if ok and type(value) == "number" then
      return math.max(1, math.floor(value))
    end

    log.warn("window: width function returned %s; falling back to 80", vim.inspect(value))

    return math.min(80, columns - 1)
  end

  if type(raw) == "number" then
    return math.max(1, math.floor(raw))
  end

  return math.min(80, columns - 1)
end

---True when our window exists and shows a chat (or placeholder) buffer.
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

---Register an instance state entry. Used by future spawn() to declare a buffer.
---@param state hyprpilot.InstanceState
function M.register(state)
  M._instances[state.instance_id] = state
  M._last_active_id = state.instance_id
end

---Wipe a per-instance buffer + drop the registry entry.
---@param instance_id string?
function M.close(instance_id)
  local id = instance_id or M._last_active_id

  if id == nil then
    return
  end

  local state = M._instances[id]

  if state == nil then
    return
  end

  buffer.wipe(state.bufnr)
  M._instances[id] = nil

  if M._last_active_id == id then
    M._last_active_id = next(M._instances)
  end

  log.debug("window.close: instance=%s", id)
end

---Resolve which buffer the side split should display.
---@param instance_id string?
---@return integer bufnr
local function resolve_target_buffer(instance_id)
  if instance_id ~= nil then
    local state = M._instances[instance_id]

    if state ~= nil and vim.api.nvim_buf_is_valid(state.bufnr) then
      return state.bufnr
    end
  end

  if M._last_active_id ~= nil then
    local state = M._instances[M._last_active_id]

    if state ~= nil and vim.api.nvim_buf_is_valid(state.bufnr) then
      return state.bufnr
    end
  end

  return buffer.placeholder()
end

---Open the side split (idempotent — returns early when already visible).
---@param ui hyprpilot.ConfigUi
---@param bufnr integer
local function open_split(ui, bufnr)
  local position = ui.position == "left" and "topleft" or "botright"
  local width = resolve_width(ui)

  vim.cmd(string.format("%s vertical %dnew", position, width))

  M._winid = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(M._winid, bufnr)
  vim.wo[M._winid].number = false
  vim.wo[M._winid].relativenumber = false
  vim.wo[M._winid].signcolumn = "no"
  vim.wo[M._winid].wrap = true
  vim.wo[M._winid].linebreak = true
end

---Show the chat window, switching to `instance_id` (or the last active).
---@param instance_id string?
function M.show(instance_id)
  local ui = config.options.ui or {}
  local bufnr = resolve_target_buffer(instance_id)

  if M.is_visible() then
    vim.api.nvim_win_set_buf(M._winid, bufnr)
    vim.api.nvim_set_current_win(M._winid)
  else
    open_split(ui, bufnr)
  end

  if instance_id ~= nil and M._instances[instance_id] ~= nil then
    M._last_active_id = instance_id
  end

  log.debug("window.show: instance=%s bufnr=%s", instance_id or "<placeholder>", bufnr)
end

---Hide the chat window. Buffers persist for resume.
function M.hide()
  if not M.is_visible() then
    return
  end

  pcall(vim.api.nvim_win_close, M._winid, true)
  M._winid = nil

  log.debug("window.hide")
end

---Toggle the chat window: hide if visible, otherwise show.
function M.toggle()
  if M.is_visible() then
    M.hide()
  else
    M.show()
  end
end

---Switch the chat window's buffer to `instance_id` without (re)opening.
---@param instance_id string
function M.switch(instance_id)
  local state = M._instances[instance_id]

  if state == nil then
    log.warn("window.switch: unknown instance=%s", instance_id)

    return
  end

  M._last_active_id = instance_id

  if M.is_visible() then
    vim.api.nvim_win_set_buf(M._winid, state.bufnr)
  end

  log.debug("window.switch: instance=%s", instance_id)
end

---The currently-active instance id (sync, may be nil before any spawn).
---@return string?
function M.active_instance()
  return M._last_active_id
end

return M
