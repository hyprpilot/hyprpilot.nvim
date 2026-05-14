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
    package.loaded["hyprpilot.chat.permission-row"],
    package.loaded["hyprpilot.chat.queue-strip"],
    package.loaded["hyprpilot.composer"],
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

---Resolve the winid to focus on for `target_name`. Composer is the
---default but may not exist yet (no active instance, placeholder
---buffer, post-hide reopen) — fall back to chat in that case.
---@param target_name "composer" | "chat"
---@return integer? target_winid, integer? composer_winid
local function resolve_target_winid(target_name)
  local composer_winid = (package.loaded["hyprpilot.composer"] or {})._winid

  if target_name == "chat" then
    return chat_window._winid, composer_winid
  end

  if composer_winid ~= nil and vim.api.nvim_win_is_valid(composer_winid) then
    return composer_winid, composer_winid
  end
  return chat_window._winid, composer_winid
end

---Jump the cursor to `target_winid`; enter insert mode when that
---happens to be the composer (so the captain lands ready to type).
---@param target_winid integer
---@param composer_winid integer?
local function jump_to(target_winid, composer_winid)
  vim.api.nvim_set_current_win(target_winid)
  if target_winid == composer_winid then
    vim.cmd("startinsert")
  end
end

---Toggle the captain's focus between a hyprpilot chrome window and
---wherever they came from:
---
---  - chat hidden       → show the split + jump to target
---  - chat visible, out → stash prev + jump to target
---  - chat visible, in  → jump back to the stashed prev
---
---Default target is the composer (typing surface); `target = "chat"`
---steers to the read-only chat for scrolling.
---@param opts? hyprpilot.ui.window.FocusOpts
function M.focus(opts)
  opts = opts or {}
  local target_name = opts.target or "composer"

  -- Show-then-focus path. `chat_window.show()` already mints the
  -- composer split and lands the cursor inside it; we then steer to
  -- the explicit target so `target = "chat"` actually wins over
  -- composer's auto-focus, and the stashed prev points at the
  -- captain's original window (not the chrome show() left us in).
  if not chat_window.is_visible() then
    M._prev_winid = vim.api.nvim_get_current_win()
    chat_window.show()

    local target_winid, composer_winid = resolve_target_winid(target_name)
    if target_winid == nil or not vim.api.nvim_win_is_valid(target_winid) then
      log.warn("ui.window.focus: show() left no focusable window (no active instance?)")
      return
    end
    jump_to(target_winid, composer_winid)
    return
  end

  -- chat visible — in/out toggle.
  local target_winid, composer_winid = resolve_target_winid(target_name)
  if target_winid == nil or not vim.api.nvim_win_is_valid(target_winid) then
    log.warn("ui.window.focus: no target window available")
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
  jump_to(target_winid, composer_winid)
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
