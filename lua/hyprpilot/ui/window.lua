--- Captain-facing window UI helpers — `focus`, `toggle`, `show`,
--- `hide`. Lives under `ui/` so captain keymaps reach for one
--- namespace ("UI surface"); the actual visibility primitives stay
--- in `chat.window` (which manages buffer registry, header, queue
--- strip, etc.). This module is the thin captain-side facade plus a
--- focus helper that tracks the captain's previous window for
--- "jump in / jump back" toggling.

local chat_window = require("hyprpilot.chat.window")
local log = require("hyprpilot.log")

local M = {}

---@type integer?
M._prev_winid = nil

---True when `winid` is one of the plugin's chrome windows — chat,
---header, composer, queue strip, or permission row. We probe via
---`package.loaded` so an unloaded chrome module (header before
---first `show`, composer before first `open`) collapses to "not a
---hyprpilot window" instead of force-loading the module.
---@param winid integer
---@return boolean
local function is_hyprpilot_window(winid)
  if winid == nil or not vim.api.nvim_win_is_valid(winid) then
    return false
  end

  local probe = {
    chat_window,
    package.loaded["hyprpilot.chat.header"],
    package.loaded["hyprpilot.chat.permission_row"],
    package.loaded["hyprpilot.chat.queue_strip"],
    package.loaded["hyprpilot.ui.composer"],
  }

  for _, mod in pairs(probe) do
    if mod ~= nil and mod._winid == winid then
      return true
    end
  end

  return false
end

---@class hyprpilot.ui.window.FocusOpts
---@field target? "composer" | "chat"  -- default: composer (where the captain types)

---Toggle the captain's focus between a hyprpilot chrome window and
---wherever they came from. From outside, save the current window
---and jump to `opts.target` (default composer). From inside any
---chrome window, jump back to the saved previous window.
---
---Auto-opens the chat split when hidden — the captain's mental
---model is "go to hyprpilot", not "go to hyprpilot but only if
---it's already open".
---@param opts? hyprpilot.ui.window.FocusOpts
function M.focus(opts)
  opts = opts or {}
  local target_name = opts.target or "composer"

  if not chat_window.is_visible() then
    M._prev_winid = vim.api.nvim_get_current_win()
    chat_window.show()
  end

  local composer_winid = (package.loaded["hyprpilot.ui.composer"] or {})._winid
  local target_winid
  if target_name == "chat" then
    target_winid = chat_window._winid
  else
    target_winid = composer_winid
    -- Composer may not have minted its split yet (placeholder buffer,
    -- post-hide reopen, no active instance). Fall back to chat.
    if target_winid == nil or not vim.api.nvim_win_is_valid(target_winid) then
      target_winid = chat_window._winid
    end
  end

  if target_winid == nil or not vim.api.nvim_win_is_valid(target_winid) then
    log.warn("ui.window.focus: no target window available (chat_visible=%s)", tostring(chat_window.is_visible()))
    return
  end

  local current = vim.api.nvim_get_current_win()
  if is_hyprpilot_window(current) then
    if M._prev_winid ~= nil and vim.api.nvim_win_is_valid(M._prev_winid) then
      vim.api.nvim_set_current_win(M._prev_winid)
      M._prev_winid = nil
    else
      log.debug("ui.window.focus: no previous window stashed; staying put")
    end
    return
  end

  M._prev_winid = current
  vim.api.nvim_set_current_win(target_winid)

  if target_winid == composer_winid then
    vim.cmd("startinsert")
  end
end

---Toggle chat window visibility.
function M.toggle()
  chat_window.toggle()
end

---Show the chat window, optionally switching to `instance_id`.
---@param instance_id? string
function M.show(instance_id)
  chat_window.show(instance_id)
end

---Hide the chat window. Buffers persist for resume.
function M.hide()
  chat_window.hide()
end

return M
