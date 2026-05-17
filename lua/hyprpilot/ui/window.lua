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

--- The captain's most recent non-hyprpilot window. Maintained by a
--- `WinLeave` autocmd so it stays fresh regardless of how the
--- captain navigated (focus keybind, `<C-w>w`, telescope picker,
--- etc.). Read by `focus`'s toggle-back path. Vim's native
--- `winnr("#")` is the immediate-previous window which is no good
--- for us — chrome-to-chrome moves (chat → composer) clobber it,
--- so toggle-back would bounce to chat instead of the editor.
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
---@field target? "composer" | "chat" | "permission"  -- default: composer (where the captain types)

---Resolve the winid to focus on for `target_name`. Composer is the
---default but may not exist yet (no active instance, placeholder
---buffer, post-hide reopen) — fall back to chat in that case.
---`permission` resolves only when the permission row is currently
---visible (it auto-opens on `permission_request` events; nothing for
---us to focus when no permission is pending).
---@param target_name "composer" | "chat" | "permission"
---@return integer? target_winid, integer? composer_winid
local function resolve_target_winid(target_name)
  local composer_winid = (package.loaded["hyprpilot.composer"] or {})._winid

  if target_name == "chat" then
    return chat_window._winid, composer_winid
  end

  if target_name == "permission" then
    local permission_winid = (package.loaded["hyprpilot.chat.permission-row"] or {})._winid
    if permission_winid ~= nil and vim.api.nvim_win_is_valid(permission_winid) then
      return permission_winid, composer_winid
    end
    return nil, composer_winid
  end

  if composer_winid ~= nil and vim.api.nvim_win_is_valid(composer_winid) then
    return composer_winid, composer_winid
  end
  return chat_window._winid, composer_winid
end

---Jump the cursor to `target_winid`; enter insert mode when that
---happens to be the composer (so the captain lands ready to type).
---Returns false when the focus call bailed — caller can short-circuit
---instead of charging into a wedged state.
---@param target_winid integer
---@param composer_winid integer?
---@return boolean ok
local function jump_to(target_winid, composer_winid)
  if not require("hyprpilot.chat.buffer").safe_set_current_win(target_winid) then
    return false
  end
  if target_winid == composer_winid then
    pcall(vim.cmd, "startinsert")
  end
  return true
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
    -- `_prev_winid` is maintained by the WinLeave autocmd below —
    -- when `chat_window.show()` jumps focus into the chat split,
    -- the autocmd fires for the leaving (editor) window and
    -- records it. No explicit stash needed here.
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

  -- Toggle-back fires only when the captain is ALREADY in the
  -- target window (e.g., focus(composer) while in composer). Being
  -- in a different hyprpilot surface (e.g., focus(composer) while
  -- in chat, or focus(permission) while in composer) means the
  -- captain wants to JUMP to the target, not bounce back to the
  -- stale `_prev_winid`. The earlier shape conflated all hyprpilot
  -- windows and ate a chunk of captain navigations: manually
  -- moving into chat / queue strip / etc. and then asking for
  -- composer focus sent them back to the editor instead.
  if current == target_winid then
    if M._prev_winid ~= nil and vim.api.nvim_win_is_valid(M._prev_winid) then
      require("hyprpilot.chat.buffer").safe_set_current_win(M._prev_winid)
    else
      log.debug("ui.window.focus: no previous window stashed; staying put")
    end
    return
  end

  jump_to(target_winid, composer_winid)
end

-- Track the captain's most recent NON-hyprpilot window via
-- `WinLeave`. This replaces the previous "stash on focus()" shape
-- so toggle-back stays accurate even when the captain navigated
-- with `<C-w>w` / `<C-w>h` / a picker / etc. instead of the focus
-- keybind. The `clear = true` group is hot-reload safe.
do
  local group = vim.api.nvim_create_augroup("HyprpilotUiWindowPrev", { clear = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      local leaving = vim.api.nvim_get_current_win()
      if not vim.api.nvim_win_is_valid(leaving) then
        return
      end
      -- Skip floating windows (popups, telescope, snacks picker) —
      -- they're transient and would clobber the real editor handle
      -- the captain wants to return to.
      local cfg = vim.api.nvim_win_get_config(leaving)
      if cfg.relative ~= nil and cfg.relative ~= "" then
        return
      end
      if is_hyprpilot_window(leaving) then
        return
      end
      M._prev_winid = leaving
    end,
  })
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

---Show the chat window (if hidden), focus it, and scroll to the
---last line so the captain sees the most recent transcript content
---without manually `G`-ing inside the read-only chat buffer.
---Mirror of `focus({ target = "chat" })` plus a cursor jump — the
---captain can scroll back up afterwards if they want; this is the
---"jump me to the live tail" action, distinct from the focus toggle.
---No toggle-back semantics: a second press re-asserts the bottom
---view (cheap; idempotent) instead of jumping back.
function M.scroll_to_end()
  if not chat_window.is_visible() then
    M._prev_winid = vim.api.nvim_get_current_win()
    chat_window.show()
  end

  local chat_winid = chat_window._winid
  if chat_winid == nil or not vim.api.nvim_win_is_valid(chat_winid) then
    log.warn("ui.window.scroll_to_end: no chat window to scroll (no active instance?)")
    return
  end

  local ok_focus, focus_err = pcall(vim.api.nvim_set_current_win, chat_winid)
  if not ok_focus then
    log.warn("ui.window.scroll_to_end: nvim_set_current_win failed: %s", focus_err)
    return
  end

  -- Jump to the last buffer line. `G` (Goto last) handles the
  -- scroll-into-view automatically; `zb` would push the line to the
  -- bottom of the viewport which fights captains running with
  -- `scrolloff`. Stick with vim's stock G for the most-natural feel.
  local bufnr = vim.api.nvim_win_get_buf(chat_winid)
  local last_line = vim.api.nvim_buf_line_count(bufnr)
  pcall(vim.api.nvim_win_set_cursor, chat_winid, { last_line, 0 })
  vim.api.nvim_win_call(chat_winid, function()
    -- Open any folds covering the tail so the latest content actually
    -- shows — common when the captain scrolled back into a folded
    -- turn and then hit "go to end" expecting to see the live agent
    -- output, not a closed `### tools` section.
    pcall(vim.cmd, "normal! zv")
  end)
end

return M
