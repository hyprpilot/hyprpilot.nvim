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

---Switch focus to the chat window. Returns true on success, false
---when the window is invalid or a third-party `BufEnter` autocmd
---throws (markview / render-markdown can fault when treesitter
---can't resolve a parser for the registered alias). Callers that
---follow `focus()` with `vim.cmd("split")` should bail on `false`
---to keep one bad autocmd from cascading through our event
---dispatch.
---@return boolean
function M.focus()
  if not M.is_visible() then
    return false
  end

  local ok, err = pcall(vim.api.nvim_set_current_win, M._winid)
  if not ok then
    log.warn("window.focus: nvim_set_current_win failed: %s", err)
    return false
  end

  return true
end

---Register an instance state entry. Used by future spawn() to declare a buffer.
---@param state hyprpilot.InstanceState
function M.register(state)
  local previous = M._last_active_id
  M._instances[state.instance_id] = state
  M._last_active_id = state.instance_id

  if previous ~= state.instance_id then
    require("hyprpilot.status").emit_instance_changed(state.instance_id)
  end
end

---Wipe a per-instance buffer + drop the registry entry. Cascades
---through every per-instance state store the plugin maintains so a
---`hp.close(id)` after `instances.shutdown(id)` actually removes
---the instance's footprint:
---  - chat buffer (`hyprpilot://<id>`) — wiped via `buffer.wipe`.
---  - composer buffer (`hyprpilot://composer/<id>`) + staged
---    attachments — `composer.wipe(id)`.
---  - render state (`render._states[id]`) — `render.forget`.
---  - winbar meta (`winbar._meta[id]`) — `winbar.forget`.
---  - permission row queue entries belonging to this instance —
---    `permission_row.drop_for_instance(id)`.
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

  require("hyprpilot.chat.render").forget(id)
  require("hyprpilot.chat.winbar").forget(id)
  require("hyprpilot.ui.composer").wipe(id)
  require("hyprpilot.chat.permission_row").drop_for_instance(id)
  require("hyprpilot.composer_queue").reset(id)
  require("hyprpilot.notification.attention")._clear_instance(id)

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
  vim.cmd(string.format("%s vertical %dnew", ui.position == "left" and "topleft" or "botright", resolve_width(ui)))

  M._winid = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(M._winid, bufnr)
  vim.wo[M._winid].number = false
  vim.wo[M._winid].relativenumber = false
  vim.wo[M._winid].signcolumn = "no"
  vim.wo[M._winid].wrap = true
  vim.wo[M._winid].linebreak = true
  -- Manual folds: render.lua programmatically calls `:N,Mfold` when
  -- a turn ends or a block reaches a terminal state. Foldexpr would
  -- recompute on every motion and clobber fold open/closed state we
  -- care about (a closed t1 fold should stay closed when t3 ends).
  vim.wo[M._winid].foldmethod = "manual"
  vim.wo[M._winid].foldenable = true
  vim.wo[M._winid].foldlevel = 99
  vim.wo[M._winid].foldcolumn = "1"
  -- Custom foldtext renders the head row of each fold as-is (icon +
  -- status + title) instead of Neovim's default `+-- N lines:` chrome.
  vim.wo[M._winid].foldtext = "v:lua.require'hyprpilot.chat.render'.foldtext()"
  vim.wo[M._winid].fillchars = vim.wo[M._winid].fillchars .. ",fold: "

  -- Header info lives in a pinned 1-row split above the chat (see
  -- `chat.header`). The winbar architecture was abandoned because it
  -- only painted while the chat window itself held focus; dropping
  -- into the composer below made the bar vanish, hiding mode / model /
  -- activity exactly when the captain wanted them visible.
end

---Show the chat window, switching to `instance_id` (or the last active).
---Hydrates the buffer from the daemon's snapshot + ensures the live
---event stream is wired.
---@param instance_id string?
function M.show(instance_id)
  local previous = M._last_active_id
  local bufnr = resolve_target_buffer(instance_id)

  if M.is_visible() then
    vim.api.nvim_win_set_buf(M._winid, bufnr)
    -- Use the pcall-wrapped focus helper instead of a raw
    -- `nvim_set_current_win` — same BufEnter / treesitter risk class
    -- as the auxiliary windows have on their open paths.
    M.focus()
  else
    open_split(config.options.ui or {}, bufnr)
  end

  local resolved_id = nil

  if instance_id ~= nil and M._instances[instance_id] ~= nil then
    M._last_active_id = instance_id
    resolved_id = instance_id
  elseif M._last_active_id ~= nil and M._instances[M._last_active_id] ~= nil then
    resolved_id = M._last_active_id
  end

  if resolved_id ~= nil then
    require("hyprpilot.chat.events").hydrate(resolved_id, bufnr)
  end

  require("hyprpilot.chat.render").apply_pending_folds(bufnr)

  if M._last_active_id ~= previous then
    require("hyprpilot.status").emit_instance_changed(M._last_active_id)
  end

  -- Auxiliary windows around the chat — header above, composer below.
  -- Both are skipped for the placeholder (no instance to drive them).
  require("hyprpilot.chat.header").ensure_listeners()
  require("hyprpilot.chat.header").open()
  -- Queue strip auto-pops above the composer when the active
  -- instance has parked prompts. Subscriber wiring lives in
  -- `ensure_listeners`; the strip stays hidden when the queue is
  -- empty.
  require("hyprpilot.chat.queue_strip").ensure_listeners()
  require("hyprpilot.chat.queue_strip").refresh()

  if resolved_id ~= nil then
    require("hyprpilot.ui.composer").open()
  end

  log.debug("window.show: instance=%s bufnr=%s", resolved_id or "<placeholder>", bufnr)
end

---Tear down all child surfaces that live around the chat split.
---Used both when the captain explicitly hides the chat and when
---they close the chat window through stock Vim controls (`:q`,
---`<C-w>q`) — without this cascade, the header / queue strip /
---permission row / composer remain on screen with a stale
---`window._winid` pointing at the closed chat, which makes their
---next `open_window` reach for an invalid id.
local function close_children()
  -- Wrap each close in pcall: a child surface in a half-built
  -- state should not block teardown of its siblings.
  pcall(function()
    require("hyprpilot.ui.composer").close()
  end)
  pcall(function()
    require("hyprpilot.chat.queue_strip").close()
  end)
  pcall(function()
    require("hyprpilot.chat.header").close()
  end)
  pcall(function()
    require("hyprpilot.chat.permission_row").close()
  end)
end

---Hide the chat window. Buffers persist for resume. Closes the
---composer first since it lives in a sub-split below the chat.
function M.hide()
  if not M.is_visible() then
    return
  end

  close_children()

  pcall(vim.api.nvim_win_close, M._winid, true)
  M._winid = nil

  log.debug("window.hide")
end

-- When the chat window goes away through stock Vim controls
-- (`:q`, `<C-w>q`, layout collapse), our `M._winid` becomes a
-- stale handle and the auxiliary surfaces (header / queue strip
-- / permission row / composer) are orphaned with their own stale
-- `window._winid` references — the next `permission_row.enqueue`
-- (or any other open path) hits `nvim_set_current_win` on the
-- dead handle and crashes through the BufEnter autocmd chain.
-- Catching `WinClosed` here drains the children and resets state
-- the same way `M.hide()` would.
vim.api.nvim_create_autocmd("WinClosed", {
  group = vim.api.nvim_create_augroup("HyprpilotChatWindow", { clear = true }),
  callback = function(args)
    if M._winid == nil then
      return
    end

    if tonumber(args.match) ~= M._winid then
      return
    end

    M._winid = nil
    -- `WinClosed` fires *before* the window is actually gone, so
    -- defer the child teardown one tick to keep `nvim_win_close`
    -- from re-entering on a partially-collapsed layout.
    vim.schedule(close_children)

    log.debug("window: WinClosed cleanup for chat winid=%s", args.match)
  end,
})

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

  local previous = M._last_active_id
  M._last_active_id = instance_id

  if M.is_visible() then
    vim.api.nvim_win_set_buf(M._winid, state.bufnr)

    -- Drain the permission row queue. Pending permission requests
    -- belong to whichever instance the captain was looking at;
    -- carrying them over to the newly-switched-to instance would
    -- surface the wrong tool / kind / options for the wrong agent.
    -- The daemon still holds the resolution slot — captain can
    -- replay via `permissions/pending` after switching back if a
    -- pending request was lost from the row.
    require("hyprpilot.chat.permission_row").reset()

    -- Composer.open() is idempotent: when the composer's already
    -- visible it swaps its buffer to the new instance's draft.
    -- `focus = false` keeps the captain's cursor where it was —
    -- switch is a peek-at-the-other-instance gesture, not an "I'm
    -- about to type" gesture.
    require("hyprpilot.ui.composer").open({ focus = false })

    -- Header reads via active_instance() and emits its own update on
    -- HyprpilotInstanceChanged; the explicit refresh covers the case
    -- where this switch ran in between autocmd dispatches.
    require("hyprpilot.chat.header").refresh()
  end

  if previous ~= instance_id then
    require("hyprpilot.status").emit_instance_changed(instance_id)
  end

  log.debug("window.switch: instance=%s", instance_id)
end

---The currently-active instance id (sync, may be nil before any spawn).
---@return string?
function M.active_instance()
  return M._last_active_id
end

---Look up the chat buffer for `instance_id`. Returns nil when the
---instance hasn't been registered or its buffer is no longer valid.
---External code (status pickers, captain keymaps) uses this when
---they need a buffer outside the autocmd path, where the
---`data.bufnr` field on the event payload isn't available.
---@param instance_id string
---@return integer?
function M.get_bufnr(instance_id)
  local state = M._instances[instance_id]
  if state == nil then
    return nil
  end
  if not vim.api.nvim_buf_is_valid(state.bufnr) then
    return nil
  end
  return state.bufnr
end

---Bump the snapshot page size for the active (or named) instance and
---re-hydrate so older transcript items appear above the current view.
---Defaults to the active instance.
---@param instance_id? string
---@param opts? { step?: integer }
---@param callback? fun(err: hyprpilot.client.RpcError?): nil
function M.load_older(instance_id, opts, callback)
  local id = instance_id or M._last_active_id
  if id == nil then
    log.warn("window.load_older: no active instance")
    return
  end

  require("hyprpilot.chat.events").load_older(id, opts, callback)
end

return M
