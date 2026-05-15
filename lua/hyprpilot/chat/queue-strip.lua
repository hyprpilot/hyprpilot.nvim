--- Pinned queue band between the permission row and the composer.
---
--- Mirrors the structural pattern of `chat/permission-row.lua`: a
--- shared 1-buffer / 1-window pinned strip that auto-shows when the
--- active instance has queued prompts, auto-resizes to fit content
--- (clamped via `config.queue_strip.max_height`), auto-hides on
--- empty queue.
---
--- Daemon-mirror model: the daemon owns the queue (single mailbox,
--- monotonic `enqueued_seq`, lock-protected). This module mirrors
--- the per-instance snapshot in a local cache (`M._items_by_instance`)
--- driven by:
---   - `instance/snapshot/queue` on chat-window show (hydrate)
---   - `acp:queue-changed` events (full-snapshot wholesale replace)
--- The strip's keymaps fire daemon `queue/*` RPCs; nothing here
--- pops or mutates locally.
---
--- Keymaps (configurable via `config.queue_strip.keymaps`):
---   send_head — `queue/dispatch` (no itemId = head)
---   drop_head — `queue/remove` of the head id
---   drop_all  — `queue/clear`
---   edit_head — pop the head into the composer for in-place edit
---     (composer's submit then calls `queue/edit` instead of
---     `prompts/send` — see `composer/init.lua` editing-slot path)

local buffer = require("hyprpilot.chat.buffer")
local config = require("hyprpilot.config")
local log = require("hyprpilot.log")
local rpc_queue = require("hyprpilot.rpc.queue")
local window = require("hyprpilot.chat.window")

local M = {}

local BUFFER_NAME = "hyprpilot://queue_strip"
local NS = vim.api.nvim_create_namespace("hyprpilot.chat.queue-strip")

---@type integer?
M._winid = nil

---@type integer?
M._bufnr = nil

--- Per-instance daemon-mirror cache. Wholesale-replaced on
--- QueueChanged events + snapshot hydrate. The strip reads from
--- this for rendering; all mutations come from the daemon.
---@type table<string, hyprpilot.QueueItem[]>
M._items_by_instance = {}

---@type string?
M._rendered_instance_id = nil

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

---Read the current cached queue for an instance. Returns an empty
---list when nothing's cached (instance never hydrated, or queue
---legitimately empty). Public so the composer can read the queue
---size to decide submit-vs-edit display hints.
---@param instance_id string?
---@return hyprpilot.QueueItem[]
function M.items(instance_id)
  if instance_id == nil then
    return {}
  end
  return M._items_by_instance[instance_id] or {}
end

---True when `instance_id` has at least one queued item.
---@param instance_id string?
---@return boolean
function M.has_items(instance_id)
  return instance_id ~= nil and #(M._items_by_instance[instance_id] or {}) > 0
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
  local items = M.items(instance_id)
  if #items == 0 then
    return nil, nil
  end

  local lines = { string.format(" %d queued · <C-CR> send head · dd drop head · D drop all", #items) }
  local header_row = 0

  for i, entry in ipairs(items) do
    -- Strip newlines + trim long entries to one row so the strip
    -- stays compact. Captain pops into the composer for the full
    -- text via the `edit_head` keymap.
    local preview = (entry.text or ""):gsub("\n", " ⏎ ")
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

---Repaint the strip with the active instance's cached queue.
---Closes the window when the queue is empty.
---
---Stamps `M._rendered_instance_id` on every successful refresh so
---keymap closures (send_head / drop_head / drop_all / edit_head)
---operate on the instance the strip was VISUALLY showing at the
---moment the captain pressed the key — not whatever
---`window.active_instance()` happens to return at fire time.
function M.refresh()
  ensure_buffer()

  local instance_id = window.active_instance()
  if instance_id == nil or not M.has_items(instance_id) then
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
    if buffer.layout_manager_active() then
      pcall(function()
        vim.w[M._winid].edgy_height = target
      end)
      pcall(function()
        require("edgy.layout").layout()
      end)
    elseif vim.api.nvim_win_get_height(M._winid) ~= target then
      pcall(vim.api.nvim_win_set_height, M._winid, target)
    end
  end
end

---Resolve the instance the strip's keymaps should operate on.
---@return string?
local function rendered_instance()
  return M._rendered_instance_id or window.active_instance()
end

---Send the head entry NOW: `queue/dispatch` (no itemId = head).
---Daemon pops the item, fires its prompt, broadcasts a new
---`QueueChanged` snapshot which our event listener will reflect.
local function send_head()
  local instance_id = rendered_instance()
  if instance_id == nil then
    return
  end
  rpc_queue.dispatch(instance_id, nil, function(err, result)
    if err ~= nil then
      log.warn("queue_strip.send_head: %s", err.message)
      return
    end
    log.debug("queue_strip.send_head: instance=%s accepted=%s", instance_id, tostring(result and result.accepted))
  end)
end

local function drop_head()
  local instance_id = rendered_instance()
  if instance_id == nil then
    return
  end
  local items = M.items(instance_id)
  local head = items[1]
  if head == nil then
    return
  end
  rpc_queue.remove(instance_id, head.id, function(err)
    if err ~= nil then
      log.warn("queue_strip.drop_head: %s", err.message)
    end
  end)
end

local function drop_all()
  local instance_id = rendered_instance()
  if instance_id == nil then
    return
  end
  rpc_queue.clear(instance_id, function(err, cleared)
    if err ~= nil then
      log.warn("queue_strip.drop_all: %s", err.message)
      return
    end
    log.debug("queue_strip.drop_all: instance=%s cleared=%d", instance_id, cleared or 0)
  end)
end

---Edit the head queued item in the composer. Item STAYS in the
---queue (no pop) — composer pre-fills with the item's text +
---attachments and stamps the editing-slot pointer so the next
---submit calls `queue/edit` (preserving the slot's id /
---enqueued_seq / enqueued_at) instead of `prompts/send`.
local function edit_head()
  local instance_id = rendered_instance()
  if instance_id == nil then
    return
  end
  local items = M.items(instance_id)
  local head = items[1]
  if head == nil then
    return
  end
  -- Composer's `set_text` accepts an editing-slot opt that stamps
  -- the per-instance state so the next submit routes through
  -- `queue/edit` instead of `prompts/send`.
  require("hyprpilot.composer").set_text(instance_id, head.text or "", {
    editing_queue_item_id = head.id,
    editing_queue_attachments = head.attachments,
  })
end

local apply_action = require("hyprpilot.ui.keymaps").apply_action

---@param bufnr integer
local function install_keymaps(bufnr)
  local keymaps = (config.options.queue_strip or {}).keymaps or {}
  apply_action(bufnr, keymaps.send_head, send_head, "send queued head now")
  apply_action(bufnr, keymaps.drop_head, drop_head, "drop queued head")
  apply_action(bufnr, keymaps.drop_all, drop_all, "drop entire queue")
  apply_action(bufnr, keymaps.edit_head, edit_head, "edit queued head in composer")
end

-- Test-only seam.
---@param bufnr integer
function M._install_keymaps_for_tests(bufnr)
  install_keymaps(bufnr)
end

---Open the strip below the chat split + above the composer. Sized
---to fit content (capped by `max_height`). No-op when the chat
---isn't visible OR the active instance has no queued items.
local function open_window()
  if not window.is_visible() then
    return
  end
  local instance_id = window.active_instance()
  if instance_id == nil or not M.has_items(instance_id) then
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
      if not buffer.layout_manager_active() then
        vim.wo[w].winfixheight = true
        vim.wo[w].winfixwidth = true
      end
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

---Wholesale replace the cached queue for `instance_id` with a
---fresh snapshot. Called from:
---  - `chat.events.dispatch` on `queue_changed` events (full-
---    snapshot replace; daemon never sends deltas)
---  - `M.hydrate` once on chat-window show (initial snapshot read)
---After replacement, repaints the strip if the active instance
---is the one we just updated.
---@param instance_id string
---@param items hyprpilot.QueueItem[]
function M.handle_queue_changed(instance_id, items)
  if type(instance_id) ~= "string" or instance_id == "" then
    return
  end
  M._items_by_instance[instance_id] = type(items) == "table" and items or {}
  -- Repaint when the change applies to whatever the strip is
  -- currently rendering (or could be rendering — the strip auto-
  -- shows for the active instance when items appear).
  if window.is_visible() then
    local active = window.active_instance()
    if active == instance_id then
      if M.has_items(active) then
        if M.is_visible() then
          M.refresh()
        else
          open_window()
        end
      else
        M.close()
      end
    end
  end
end

---Fire-and-forget snapshot read for `instance_id`. Replaces the
---local cache on success. Called from `chat.window.show` so the
---first chat-buffer mount carries the current daemon queue (the
---boot snapshot already includes it but a session re-show without
---a fresh boot needs this).
---@param instance_id string
function M.hydrate(instance_id)
  if type(instance_id) ~= "string" or instance_id == "" then
    return
  end
  rpc_queue.snapshot(instance_id, function(err, items)
    if err ~= nil then
      log.debug("queue_strip.hydrate: snapshot failed for %s: %s", instance_id, err.message)
      return
    end
    M.handle_queue_changed(instance_id, items or {})
  end)
end

---Drop the per-instance cache for `instance_id`. Called from
---`chat.window.close` when the instance is wiped.
---@param instance_id string
function M.forget(instance_id)
  if M._items_by_instance[instance_id] ~= nil then
    M._items_by_instance[instance_id] = nil
    if M._rendered_instance_id == instance_id then
      M._rendered_instance_id = nil
      M.close()
    end
  end
end

---Bootstrap. No autocmd subscribers anymore (the cache is updated
---directly from `chat/events.lua`'s `queue_changed` branch).
---Kept as a no-op so existing callers don't break; left as a
---hook for future test seams.
function M.ensure_listeners()
  -- Intentionally empty.
end

---Test-only reset.
function M._reset()
  M._items_by_instance = {}
  M._rendered_instance_id = nil
  M.close()
end

return M
