--- Composer — separate input buffer in a sub-split below the chat
--- window. One composer buffer per instance so drafts persist across
--- instance switching.
---
--- Public surface (re-exported via `init.lua`):
---   `composer_open()` / `composer_close()` / `composer_toggle()`
---   `submit(text?, opts?)` — defaults `text` to the composer's contents
---   `cancel()` — sends `prompts/cancel` to the active instance

local client = require("hyprpilot.client")
local config = require("hyprpilot.config")
local log = require("hyprpilot.log")
local window = require("hyprpilot.chat.window")

local M = {}

---@type table<string, integer>
local buffers = {}

---@type integer?
M._winid = nil

---Resolve the configured composer height to a concrete line count.
---@return integer
local function resolve_height()
  local raw = (config.options.composer or {}).height

  if type(raw) == "function" then
    local ok, value = pcall(raw, vim.o.lines)

    if ok and type(value) == "number" then
      return math.max(1, math.floor(value))
    end

    log.warn("composer: height function returned %s; falling back to 5", vim.inspect(value))

    return 5
  end

  if type(raw) == "number" then
    return math.max(1, math.floor(raw))
  end

  return 5
end

---Get-or-create the per-instance composer buffer.
---@param instance_id string
---@return integer bufnr
local function ensure_buffer(instance_id)
  local existing = buffers[instance_id]

  if existing ~= nil and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end

  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_name(bufnr, "hyprpilot://composer/" .. instance_id)
  vim.bo[bufnr].filetype = "hyprpilot_input"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false

  vim.keymap.set({ "n", "i" }, "<C-CR>", function()
    M.submit()
  end, { buffer = bufnr, desc = "hyprpilot: submit prompt" })

  vim.keymap.set("n", "<C-c>", function()
    M.cancel()
  end, { buffer = bufnr, desc = "hyprpilot: cancel in-flight" })

  vim.keymap.set("n", "<Esc><Esc>", function()
    M.close()
  end, { buffer = bufnr, desc = "hyprpilot: close composer" })

  buffers[instance_id] = bufnr

  return bufnr
end

---True when the composer split is currently open.
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

---Open the composer split below the chat window. No-op when no instance
---is active or when the chat window isn't visible (open it first).
---Focuses the composer buffer and enters insert mode.
function M.open()
  local instance_id = window.active_instance()

  if instance_id == nil then
    log.warn("composer.open: no active instance")

    return
  end

  if not window.is_visible() then
    log.warn("composer.open: chat window not visible; toggle the chat first")

    return
  end

  if M.is_visible() then
    vim.api.nvim_set_current_win(M._winid)
    vim.cmd("startinsert")

    return
  end

  local bufnr = ensure_buffer(instance_id)

  vim.api.nvim_set_current_win(window._winid)
  vim.cmd(string.format("belowright %dsplit", resolve_height()))

  M._winid = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(M._winid, bufnr)
  vim.wo[M._winid].number = false
  vim.wo[M._winid].relativenumber = false
  vim.wo[M._winid].signcolumn = "no"
  vim.wo[M._winid].wrap = true
  vim.wo[M._winid].linebreak = true

  vim.cmd("startinsert")
end

---Close the composer split. The buffer persists for next open.
function M.close()
  if not M.is_visible() then
    return
  end

  pcall(vim.api.nvim_win_close, M._winid, true)
  M._winid = nil
end

---Toggle the composer.
function M.toggle()
  if M.is_visible() then
    M.close()
  else
    M.open()
  end
end

---Submit the composer's contents (or `text` when provided) to the
---active instance. Clears the composer buffer on success.
---@param text string?
---@param opts { instance_id?: string }?
function M.submit(text, opts)
  local instance_id = (opts or {}).instance_id or window.active_instance()

  if instance_id == nil then
    log.warn("composer.submit: no active instance")

    return
  end

  local bufnr = buffers[instance_id]

  if text == nil then
    if bufnr == nil then
      log.warn("composer.submit: no composer buffer for %s", instance_id)

      return
    end

    text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  end

  text = text:gsub("^%s+", ""):gsub("%s+$", "")

  if text == "" then
    return
  end

  client.request("prompts/send", { instanceId = instance_id, text = text }, nil, function(err, _result)
    if err ~= nil then
      log.error("composer.submit: %s", err.message)

      return
    end

    if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end
  end)
end

---Cancel the in-flight turn on the active instance.
---@param instance_id string?
function M.cancel(instance_id)
  local id = instance_id or window.active_instance()

  if id == nil then
    log.warn("composer.cancel: no active instance")

    return
  end

  client.notify("prompts/cancel", { instanceId = id })
end

---Wipe the composer buffer for a given instance. Used when the
---instance is closed daemon-side.
---@param instance_id string
function M.wipe(instance_id)
  local bufnr = buffers[instance_id]

  if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end

  buffers[instance_id] = nil
end

return M
