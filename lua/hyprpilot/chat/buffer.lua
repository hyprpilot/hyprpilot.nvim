local log = require("hyprpilot.log")

local M = {}

---@class hyprpilot.InstanceState
---@field bufnr integer
---@field instance_id string
---@field name? string

local BUFFER_PREFIX = "hyprpilot://"
local PLACEHOLDER_NAME = "hyprpilot://placeholder"

---@type integer?
local _placeholder_bufnr = nil

---Open the buffer for write, run `fn`, restore read-only state.
---@param bufnr integer
---@param fn fun(): nil
function M.with_buffer(bufnr, fn)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    log.warn("with_buffer: invalid bufnr=%s", bufnr)

    return
  end

  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false

  local ok, err = pcall(fn)

  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  if not ok then
    error(err)
  end
end

---Apply the standard chat-buffer options to `bufnr`.
---@param bufnr integer
---@param name string                    -- buffer name (used for `:ls` and addressability)
local function apply_options(bufnr, name)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].filetype = "hyprpilot"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
end

---Create (or return existing) per-instance buffer.
---@param instance_id string
---@return integer bufnr
function M.create(instance_id)
  local name = BUFFER_PREFIX .. instance_id

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
      return bufnr
    end
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  apply_options(bufnr, name)

  log.debug("buffer.create: instance=%s bufnr=%s", instance_id, bufnr)

  return bufnr
end

---Destroy a per-instance buffer.
---@param bufnr integer
function M.wipe(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  log.debug("buffer.wipe: bufnr=%s", bufnr)

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

---Return the empty-state placeholder buffer, creating it on first call.
---@return integer bufnr
function M.placeholder()
  if _placeholder_bufnr ~= nil and vim.api.nvim_buf_is_valid(_placeholder_bufnr) then
    return _placeholder_bufnr
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  apply_options(bufnr, PLACEHOLDER_NAME)

  M.with_buffer(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "# hyprpilot",
      "",
      "No instances. Spawn one via `require('hyprpilot').spawn({})`.",
    })
  end)

  _placeholder_bufnr = bufnr

  return bufnr
end

---Returns true when `bufnr` is one of ours.
---@param bufnr integer
---@return boolean
function M.is_chat_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local name = vim.api.nvim_buf_get_name(bufnr)

  return name:sub(1, #BUFFER_PREFIX) == BUFFER_PREFIX
end

return M
