--- Pinned queue band between the permission row and the composer.
---
--- Mirrors the structural pattern of `chat/permission-row.lua`: a
--- shared 1-buffer / 1-window pinned strip that auto-shows when the
--- active instance has queued prompts, auto-resizes to fit content
--- (clamped via `config.queue_strip.max_height`), auto-hides on
--- empty queue. Keymaps are configurable via
--- `config.queue_strip.keymaps`:
---
---   send_head — send the head entry now (dispatch through composer)
---   drop_head — drop the head entry without sending
---   drop_all  — clear the entire queue for this instance
---   edit_head — pop the head into the composer for editing
---
--- The strip displays:
---
---   N queued (cancel-flush on turn cancel)
---
---   1. <text preview>
---   2. <text preview>
---   ...
---
--- Head-line drainage matches the desktop overlay's
--- `QueueStrip.vue` — captain stays in explicit control. We don't
--- expose per-row actions in v1 (no cursor-driven focus); the
--- keymaps always target the head. Per-row actions are a follow-up
--- once captain wants it.

local buffer = require("hyprpilot.chat.buffer")
local composer_queue = require("hyprpilot.composer.queue")
local config = require("hyprpilot.config")
local log = require("hyprpilot.log")
local window = require("hyprpilot.chat.window")

local M = {}

local BUFFER_NAME = "hyprpilot://queue_strip"
local NS = vim.api.nvim_create_namespace("hyprpilot.chat.queue-strip")

---@type integer?
M._winid = nil

---@type integer?
M._bufnr = nil

---@type fun()?
local _unsubscribe = nil

---True when the strip window exists + is valid.
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

---@return integer
local function ensure_buffer()
  if M._bufnr ~= nil and vim.api.nvim_buf_is_valid(M._bufnr) then
    return M._bufnr
  end

  local existing = buffer.find_by_name(BUFFER_NAME)
  if existing ~= nil then
    M._bufnr = existing
    return existing
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, BUFFER_NAME)
  vim.bo[bufnr].filetype = "hyprpilot_queue_strip"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].modifiable = false
  buffer.suppress_external_ui(bufnr)

  M._bufnr = bufnr
  return bufnr
end

---Compose the strip's buffer content for the active instance.
---Returns `(lines, header_row)` so the caller paints the header
---line highlight; `nil, nil` when nothing's queued.
---@param instance_id string
---@return string[]?, integer?
local function compose(instance_id)
  local items = composer_queue.list(instance_id)
  if #items == 0 then
    return nil, nil
  end

  local lines = { string.format(" %d queued · <C-CR> send head · dd drop head · D drop all", #items) }
  local header_row = 0

  for i, entry in ipairs(items) do
    -- Strip newlines + trim long entries to one row so the strip
    -- stays compact. Captain can pop into the composer for the
    -- full text via the `edit_head` keymap.
    local preview = (entry.text or ""):gsub("\n", " ⏎ ")
    if #preview > 80 then
      preview = preview:sub(1, 77) .. "..."
    end
    table.insert(lines, string.format("  %d. %s", i, preview))
  end

  return lines, header_row
end

---Resolve the strip's height ceiling from config. Default: 40% of
---`vim.o.lines`, floor 3.
---@return integer
local function resolve_max_height()
  local raw = (config.options.queue_strip or {}).max_height
  if type(raw) == "function" then
    local ok, value = pcall(raw, vim.o.lines)
    if ok and type(value) == "number" then
      return math.max(1, math.floor(value))
    end
  end
  if type(raw) == "number" then
    return math.max(1, math.floor(raw))
  end
  return math.max(3, math.floor(vim.o.lines * 0.4))
end

---Repaint the strip with the current head-instance queue. Closes
---the window when the queue is empty.
---
---Stamps `M._rendered_instance_id` on every successful refresh so
---keymap closures (send_head / drop_head / drop_all / edit_head)
---operate on the instance the strip was VISUALLY showing at the
---moment the captain pressed the key — not whatever
---`window.active_instance()` happens to return at fire time. Without
---this, a fast switch between two instances with non-empty queues
---could pop B's queue against the strip's A-rendered display.
function M.refresh()
  ensure_buffer()

  local instance_id = window.active_instance()
  if instance_id == nil or not composer_queue.has_items(instance_id) then
    -- Queue empty / no active instance → close the window if open;
    -- the buffer persists for next show. Clear the rendered binding
    -- so a stale instance id doesn't linger.
    M._rendered_instance_id = nil
    M.close()
    return
  end

  local lines, header_row = compose(instance_id)
  if lines == nil then
    M._rendered_instance_id = nil
    M.close()
    return
  end

  M._rendered_instance_id = instance_id

  buffer.with_buffer(M._bufnr, function()
    vim.api.nvim_buf_set_lines(M._bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(M._bufnr, NS, 0, -1)
    if header_row ~= nil then
      vim.api.nvim_buf_set_extmark(M._bufnr, NS, header_row, 0, { line_hl_group = "HyprpilotQueueStripHeader" })
    end
  end)

  if M.is_visible() then
    local target = math.min(#lines, resolve_max_height())
    if vim.api.nvim_win_get_height(M._winid) ~= target then
      pcall(vim.api.nvim_win_set_height, M._winid, target)
    end
  end
end

---Resolve the instance the strip's keymaps should operate on. The
---strip displays exactly one instance's queue at a time; keymap
---callbacks must target THAT instance, not whatever
---`window.active_instance()` returns at fire time (a switch that
---hasn't repainted the strip yet would otherwise route the action
---to the wrong queue). Falls back to the active instance only when
---the strip hasn't rendered anything yet (early refresh path).
---@return string?
local function rendered_instance()
  return M._rendered_instance_id or window.active_instance()
end

---Send the head entry NOW: pop it from the queue + dispatch via
---composer.submit. Routes against the strip's currently-rendered
---instance.
local function send_head()
  local instance_id = rendered_instance()
  if instance_id == nil then
    return
  end
  local entry = composer_queue.pop_head(instance_id)
  if entry == nil then
    return
  end
  log.debug("queue_strip.send_head: instance=%s id=%s", instance_id, entry.id)
  -- `bypass_queue = true` so the composer fires the prompt
  -- straight to the daemon even if the agent is still working —
  -- the captain explicitly chose to drain, so the activity guard
  -- doesn't apply here.
  require("hyprpilot.composer").submit(entry.text, {
    instance_id = instance_id,
    attachments = entry.attachments,
    bypass_queue = true,
  })
end

local function drop_head()
  local instance_id = rendered_instance()
  if instance_id == nil then
    return
  end
  composer_queue.pop_head(instance_id)
end

local function drop_all()
  local instance_id = rendered_instance()
  if instance_id == nil then
    return
  end
  composer_queue.flush(instance_id)
end

local function edit_head()
  local instance_id = rendered_instance()
  if instance_id == nil then
    return
  end
  local entry = composer_queue.pop_head(instance_id)
  if entry == nil then
    return
  end
  -- Drop the popped entry's text into the composer buffer for
  -- editing — matches the desktop overlay's `onQueueEdit` behaviour
  -- (load + edit, no auto-dispatch). Captain hits submit (or the
  -- composer's <CR>) when they're ready; if the agent is still busy
  -- the prompt will naturally re-enqueue at the tail.
  -- TODO: preserve attachments — `composer.set_text` only carries
  -- text today; the staged attachment list on `entry.attachments` is
  -- dropped on edit. Once we expose a public attach-from-list API
  -- on the composer, restore them here.
  if entry.attachments ~= nil and #entry.attachments > 0 then
    log.warn("queue_strip.edit_head: dropping %d attachment(s) on edit (not yet supported)", #entry.attachments)
  end
  require("hyprpilot.composer").set_text(instance_id, entry.text)
end

local apply_action = require("hyprpilot.ui.keymaps").apply_action

---Install the strip keymaps for `bufnr`. Reads from
---`config.options.queue_strip.keymaps`.
---@param bufnr integer
local function install_keymaps(bufnr)
  local keymaps = (config.options.queue_strip or {}).keymaps or {}
  apply_action(bufnr, keymaps.send_head, send_head, "send queued head now")
  apply_action(bufnr, keymaps.drop_head, drop_head, "drop queued head")
  apply_action(bufnr, keymaps.drop_all, drop_all, "drop entire queue")
  apply_action(bufnr, keymaps.edit_head, edit_head, "edit queued head in composer")
end

-- Test-only seam: see `permission-row.lua` for rationale.
---@param bufnr integer
function M._install_keymaps_for_tests(bufnr)
  install_keymaps(bufnr)
end

---Open the strip below the chat split + above the composer. Sized
---to fit content (capped by `max_height`). No-op when the chat
---isn't visible OR the queue is empty.
local function open_window()
  if not window.is_visible() then
    return
  end
  local instance_id = window.active_instance()
  if instance_id == nil or not composer_queue.has_items(instance_id) then
    return
  end

  if M.is_visible() then
    M.refresh()
    return
  end

  local bufnr = ensure_buffer()
  local winid, err = buffer.open_aux_split({
    direction = "belowright 1split",
    bufnr = bufnr,
    after = function(w)
      install_keymaps(bufnr)
      vim.wo[w].wrap = false
      vim.wo[w].winfixheight = true
      vim.wo[w].winfixwidth = true
    end,
  })
  if winid == nil then
    log.warn("queue_strip.open: %s", err)
    return
  end

  M._winid = winid

  M.refresh()
end

---Close the strip window. Buffer persists for next open.
function M.close()
  if not M.is_visible() then
    return
  end
  pcall(vim.api.nvim_win_close, M._winid, true)
  M._winid = nil
end

---Bootstrap the strip: subscribe to queue-change notifications.
---Idempotent; called from `chat.window.show` after the chat split
---is up. The actual window pops in via `refresh()` when the queue
---has items.
function M.ensure_listeners()
  if _unsubscribe ~= nil then
    return
  end
  _unsubscribe = composer_queue.on_change(function(_instance_id)
    -- Repaint on every change so the strip auto-shows/hides as the
    -- queue grows/empties. Multi-instance: the strip always shows
    -- the active instance's queue, so refresh ignores its arg and
    -- re-resolves the active instance from `window.active_instance`.
    if window.is_visible() then
      local active = window.active_instance()
      if active ~= nil and composer_queue.has_items(active) then
        open_window()
      else
        M.close()
      end
    end
  end)
end

---Wipe listener + state. Used on shutdown teardown.
function M._reset()
  if _unsubscribe ~= nil then
    _unsubscribe()
    _unsubscribe = nil
  end
  M.close()
end

return M
