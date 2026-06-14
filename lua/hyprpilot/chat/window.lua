local buffer = require("hyprpilot.chat.buffer")
local config = require("hyprpilot.config")
local instances = require("hyprpilot.instances")
local log = require("hyprpilot.log")

local M = {}

---@type integer?
M._winid = nil

---@type string?
M._last_active_id = nil

--- The captain's last "real" working buffer — the one they were in
--- right before opening the chat. Captured on every `M.show()` call
--- and kept fresh by a `BufEnter` autocmd. Sources for completion
--- (file / grep / buffer pickers running INSIDE the composer) prefer
--- this over `nvim_get_current_buf()` (which is always the composer
--- itself once the chat is open). Codecompanion calls the same
--- concept `chat.buffer_context.bufnr`.
---@type integer?
M._associated_bufnr = nil

--- Lock to prevent two rapid `M.show()` calls on an empty registry
--- from kicking off two parallel `instances/spawn` requests. Cleared
--- in the spawn callback so the next `show()` either hits the freshly-
--- spawned instance OR re-locks for a follow-on auto-spawn.
local _auto_spawn_in_flight = false

--- Re-entry guard for `M.show()`. The lifecycle restore cascade
--- (header / queue-strip / permission-row / composer) fires a chain
--- of `WinEnter` / `BufWinEnter` / `BufEnter` autocmds — if a peer
--- plugin's autocmd reacts by calling our focus / show paths
--- (layout managers retrying adoption, file-explorer rebinding,
--- a captain wiring a `User HyprpilotInstanceChanged` autocmd that
--- re-shows), the second `M.show()` re-enters mid-cascade and we
--- re-run every step on the half-built layout. Symptom the captain
--- saw: "infinite loop of trying to restore it." The guard makes
--- the second call a no-op; the first call's cascade finishes
--- cleanly.
local _show_in_progress = false

-- Shared gate (`buffer.layout_manager_active`) — every plugin
-- surface uses the same predicate to decide whether to set its own
-- `winfixwidth` / `winfixheight` / `nvim_win_set_height`. Edgy
-- patches `nvim_win_set_height` and re-asserts on every layout
-- tick; doing the work just makes the layout race visibly
-- flicker.
local layout_manager_active = buffer.layout_manager_active

---Coerce a numeric width into a concrete column count. Mirrors
---edgy's convention so the same width function works across both
---surfaces: values `< 1` are treated as a fraction of the total
---column count (`0.5` → 50% of `vim.o.columns`); values `>= 1`
---are absolute columns. Without the fraction handling, a captain
---returning `0.5` would get `math.floor(0.5) = 0` → clamp-to-1
---column = a one-column chat surface.
---@param value number
---@param columns integer
---@return integer
local function coerce_width(value, columns)
  if value < 1 then
    return math.max(1, math.floor(value * columns))
  end
  return math.max(1, math.floor(value))
end

---Resolve the configured width to a concrete column count.
---@param ui hyprpilot.ConfigUi
---@return integer
local function resolve_width(ui)
  local raw = ui.width
  local columns = vim.o.columns

  if type(raw) == "function" then
    local ok, value = pcall(raw, columns)

    if ok and type(value) == "number" then
      return coerce_width(value, columns)
    end

    log.warn("window: width function returned %s; falling back to 80", vim.inspect(value))

    return math.min(80, columns - 1)
  end

  if type(raw) == "number" then
    return coerce_width(raw, columns)
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
---throws (third-party markdown / treesitter decorators can fault
---when the parser can't be resolved for the registered alias).
---Callers that follow `focus()` with `vim.cmd("split")` should
---bail on `false` to keep one bad autocmd from cascading through
---our event dispatch.
---@return boolean
function M.focus()
  if not M.is_visible() then
    return false
  end
  return buffer.safe_set_current_win(M._winid)
end

---Register an instance state entry. Used by `instances.spawn` /
---`focus` / `sessions/load` callbacks to publish a freshly-minted
---buffer.
---
---By default `register` does NOT promote the new instance to "active".
---That keeps a background spawn (e.g. `instances.spawn({ show = false })`
---fired from a palette while the captain is mid-conversation in
---another instance) from silently flipping `_last_active_id` and
---rerouting the next composer submit. Pass `opts.activate = true`
---when the caller WANTS the new instance to become active (the
---attach() helper does this when `show_after = true`).
---
---First registration always promotes — there's nothing else to flip
---to and the captain expects the first spawn to land on screen.
---@param state hyprpilot.InstanceState
---@param opts? { activate?: boolean }
function M.register(state, opts)
  opts = opts or {}
  local previous = M._last_active_id
  instances.register(state)

  local activate = opts.activate or previous == nil
  if activate then
    M._last_active_id = state.instance_id
  end

  if activate and previous ~= state.instance_id then
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

  local state = instances.get(id)

  if state == nil then
    return
  end

  buffer.wipe(state.bufnr)
  instances.forget(id)

  require("hyprpilot.chat.render").forget(id)
  require("hyprpilot.chat.winbar").forget(id)
  require("hyprpilot.composer").wipe(id)
  require("hyprpilot.chat.permission-row").drop_for_instance(id)
  -- Daemon owns the queue now; just drop our local mirror cache.
  require("hyprpilot.chat.queue-strip").forget(id)
  require("hyprpilot.notification.attention")._clear_instance(id)
  -- Drop activity for the closed instance so a stale "tool" / "thinking"
  -- doesn't surface on a future header read for the same instance id.
  require("hyprpilot.status").forget(id)
  -- Header keeps an `_name_fetched[id]` flag so we don't refire
  -- `instances/info` on every re-render. Clearing it lets a daemon
  -- that reuses the id on resume re-fetch the name fresh.
  pcall(function()
    require("hyprpilot.chat.header").forget(id)
  end)
  -- Diff preview holds a reference to the instance via `M._state` —
  -- if the captain closes the instance whose preview is open, the
  -- natural auto-close paths (`HyprpilotPermissionResolved`,
  -- `HyprpilotInstanceStateChanged`) don't fire and the preview
  -- lingers with a dead instance + bufnr.
  pcall(function()
    require("hyprpilot.ui.diff-preview").forget(id)
  end)

  if M._last_active_id == id then
    M._last_active_id = instances.first_id()
  end

  log.debug("window.close: instance=%s", id)
end

---Resolve which buffer the side split should display.
---@param instance_id string?
---@return integer bufnr
local function resolve_target_buffer(instance_id)
  if instance_id ~= nil then
    local state = instances.get(instance_id)

    if state ~= nil and vim.api.nvim_buf_is_valid(state.bufnr) then
      return state.bufnr
    end
  end

  if M._last_active_id ~= nil then
    local state = instances.get(M._last_active_id)

    if state ~= nil and vim.api.nvim_buf_is_valid(state.bufnr) then
      return state.bufnr
    end
  end

  return buffer.placeholder()
end

---Apply the chat window's fold setup. Idempotent — safe to call on
---every `BufWinEnter` / `WinEnter` so a layout manager (edgy) re-
---adopting the window doesn't strand us with the manager's defaults
---(`foldenable = true`, `foldmethod = "manual"`, `foldlevel = 99` —
---the values `:N,Mfold` callers from `chat/render.lua` rely on to
---auto-collapse tool calls / thoughts on `turn_ended`).
---@param winid integer
function M.apply_fold_setup(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return
  end
  -- Manual folds: render.lua programmatically calls `:N,Mfold` when
  -- a turn ends or a block reaches a terminal state. Foldexpr would
  -- recompute on every motion and clobber fold open/closed state we
  -- care about (a closed t1 fold should stay closed when t3 ends).
  vim.wo[winid].foldmethod = "manual"
  vim.wo[winid].foldenable = true
  vim.wo[winid].foldlevel = 99
  vim.wo[winid].foldcolumn = "0"
  -- Custom foldtext renders the head row of each fold as-is (icon +
  -- status + title) instead of Neovim's default `+-- N lines:` chrome.
  vim.wo[winid].foldtext = "v:lua.require'hyprpilot.chat.render'.foldtext()"
  if not (vim.wo[winid].fillchars or ""):match("fold:") then
    vim.wo[winid].fillchars = vim.wo[winid].fillchars .. ",fold: "
  end
end

---Open the side split (idempotent — returns early when already visible).
---@param ui hyprpilot.ConfigUi
---@param bufnr integer
local function open_split(ui, bufnr)
  vim.cmd(string.format("%s vertical %dnew", ui.position == "left" and "topleft" or "botright", resolve_width(ui)))

  M._winid = vim.api.nvim_get_current_win()

  buffer.safe_win_set_buf(M._winid, bufnr)
  buffer.clean_window_chrome(M._winid)
  vim.wo[M._winid].wrap = true
  vim.wo[M._winid].linebreak = true
  -- When a layout manager (folke/edgy.nvim) is loaded, defer width to
  -- its slot config — `winfixwidth = true` would lock the window at
  -- the plugin's resolved width and edgy could never reach its
  -- configured `size = 0.4 / 180`. Without a layout manager we keep
  -- the pin so `<C-W>=` doesn't redistribute column space onto our
  -- sidebar.
  if not layout_manager_active() then
    vim.wo[M._winid].winfixwidth = true
  end
  M.apply_fold_setup(M._winid)

  -- Header info lives in a pinned 1-row split above the chat (see
  -- `chat.header`). The winbar architecture was abandoned because it
  -- only painted while the chat window itself held focus; dropping
  -- into the composer below made the bar vanish, hiding mode / model /
  -- activity exactly when the captain wanted them visible.
end

---True when no per-instance entry has been registered yet — the
---captain has nothing live and we'd otherwise show the placeholder
---buffer plus a "spawn one" instruction.
---@return boolean
local function has_no_instances()
  return instances.is_empty()
end

---Snapshot the captain's "associated" buffer — the working file they
---were sitting in before opening the chat. Skips chat-owned buffers
---(`hyprpilot*` filetypes) and unloaded buffers so a previously-
---captured buffer doesn't get clobbered by a re-entrant `show()`
---from the auto-spawn callback (which fires from inside our chat
---window). Idempotent — call as often as you want.
local function capture_associated_buffer()
  local cur = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_loaded(cur) then
    return
  end
  local ft = vim.bo[cur].filetype
  -- Iterate dotted components so the composer's
  -- `hyprpilot_composer.markdown` ft also matches `hyprpilot_composer`.
  for component in (ft or ""):gmatch("[^.]+") do
    if
      component == "hyprpilot"
      or component == "hyprpilot_composer"
      or component == "hyprpilot_header"
      or component == "hyprpilot_permission_row"
      or component == "hyprpilot_queue_strip"
    then
      return
    end
  end
  M._associated_bufnr = cur
end

---Return the captain's last working buffer if it's still loaded, else
---nil. Completion sources read this when they want to scan the file
---the captain was editing rather than the composer they're typing in
---(matches codecompanion's `chat.buffer_context.bufnr`).
---@return integer?
function M.associated_bufnr()
  local b = M._associated_bufnr
  if b == nil or not vim.api.nvim_buf_is_loaded(b) or not vim.api.nvim_buf_is_valid(b) then
    M._associated_bufnr = nil
    return nil
  end
  return b
end

---Show the chat window, switching to `instance_id` (or the last active).
---Hydrates the buffer from the daemon's snapshot + ensures the live
---event stream is wired. When the captain has no instances at all
---and no specific `instance_id` was requested, kicks off a default
---`instances.spawn({})` and re-runs `show()` from the spawn callback
---— the captain never has to manually spawn before opening the chat.
---@param instance_id string?
function M.show(instance_id)
  if _show_in_progress then
    log.debug("window.show: re-entry blocked (instance_id=%s)", tostring(instance_id))
    return
  end
  _show_in_progress = true
  local ok, err = pcall(function()
    M._show_inner(instance_id)
  end)
  _show_in_progress = false
  if not ok then
    log.warn("window.show: inner threw: %s", tostring(err))
  end
end

---@param instance_id string?
function M._show_inner(instance_id)
  -- Capture the captain's working buffer BEFORE we steal focus into
  -- the chat. The associated buffer is what completion sources scan
  -- against; once the chat is open `nvim_get_current_buf()` is the
  -- composer (empty / wrong target).
  capture_associated_buffer()

  -- Auto-spawn path: no specific instance requested + no instances
  -- registered yet → spin up a default one and reroute. The async
  -- spawn callback re-enters `M.show(new_id)` once the daemon is
  -- ready, so the captain's keybind lands them in a populated chat
  -- on the first call. Lock prevents two rapid show() calls from
  -- spawning two instances in parallel.
  if instance_id == nil and has_no_instances() then
    if _auto_spawn_in_flight then
      log.debug("window.show: auto-spawn already in flight, skipping")
      return
    end
    _auto_spawn_in_flight = true
    log.debug("window.show: no instances registered, auto-spawning default")
    require("hyprpilot.rpc.instances").spawn({}, function(err, info)
      _auto_spawn_in_flight = false
      if err ~= nil then
        log.warn("window.show: auto-spawn failed: %s", err.message)
        return
      end
      if type(info) == "table" and type(info.id) == "string" then
        M.show(info.id)
      end
    end)
    return
  end

  -- Reject unknown instance_id rather than silently rendering the
  -- placeholder buffer with a stale `_last_active_id` — the old code
  -- left the UI lying about which instance was active and composer
  -- submits would dispatch to the wrong instance.
  if instance_id ~= nil and instances.get(instance_id) == nil then
    log.warn("window.show: unknown instance=%s — refusing to silently render placeholder", instance_id)
    return
  end

  local previous = M._last_active_id
  local bufnr = resolve_target_buffer(instance_id)

  if M.is_visible() then
    if not buffer.safe_win_set_buf(M._winid, bufnr) then
      -- Window or buffer went invalid mid-call (e.g., concurrent
      -- close cascade). The plugin can't safely chain show/focus
      -- on a wedged window; bail rather than crash downstream.
      return
    end
    -- Use the pcall-wrapped focus helper instead of a raw
    -- `nvim_set_current_win` — same BufEnter / treesitter risk class
    -- as the auxiliary windows have on their open paths.
    M.focus()
  else
    open_split(config.options.ui or {}, bufnr)
  end

  local resolved_id = nil

  if instance_id ~= nil and instances.get(instance_id) ~= nil then
    M._last_active_id = instance_id
    resolved_id = instance_id
  elseif M._last_active_id ~= nil and instances.get(M._last_active_id) ~= nil then
    resolved_id = M._last_active_id
  end

  if resolved_id ~= nil then
    require("hyprpilot.chat.events").hydrate(resolved_id, bufnr)
  end

  require("hyprpilot.chat.render").apply_pending_folds(bufnr)

  if M._last_active_id ~= previous then
    require("hyprpilot.status").emit_instance_changed(M._last_active_id)
  end

  -- Auxiliary surfaces. Each step is pcall-wrapped so a single
  -- failing module (third-party autocmd throwing on the chat
  -- buffer, treesitter parser miss, edgy adoption race) doesn't
  -- cascade and leave the captain with half the chrome open.
  -- Sequencing: header first (carries instance-state pill the
  -- other surfaces read), queue-strip next (so permission-row's
  -- `refresh_if_queued` sees the latest items), composer last
  -- (focuses by default, captain lands ready to type).
  pcall(function()
    require("hyprpilot.chat.header").ensure_listeners()
    require("hyprpilot.chat.header").open()
  end)
  pcall(function()
    require("hyprpilot.chat.queue-strip").ensure_listeners()
    if resolved_id ~= nil then
      require("hyprpilot.chat.queue-strip").hydrate(resolved_id)
    end
    require("hyprpilot.chat.queue-strip").refresh()
  end)
  pcall(function()
    require("hyprpilot.chat.permission-row").refresh_if_queued()
  end)
  if resolved_id ~= nil then
    pcall(function()
      require("hyprpilot.composer").open()
    end)
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
    require("hyprpilot.composer").close()
  end)
  pcall(function()
    require("hyprpilot.chat.queue-strip").close()
  end)
  pcall(function()
    require("hyprpilot.chat.header").close()
  end)
  pcall(function()
    require("hyprpilot.chat.permission-row").close()
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

-- One augroup for window-level autocmds: the WinClosed teardown plus
-- a BufEnter listener that keeps `_associated_bufnr` fresh so
-- completion sources (which run inside the composer) always have a
-- correct pointer to the captain's last working buffer.
local _window_augroup = vim.api.nvim_create_augroup("HyprpilotChatWindow", { clear = true })

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
  group = _window_augroup,
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

-- Track the captain's last "real" working buffer. Mirrors
-- codecompanion's `chat.buffer_context` refresh on `BufEnter` —
-- as the captain navigates between files, this keeps pointing at
-- whichever non-plugin buffer they were just in. Sources for
-- completion (file/grep/buffer pickers running INSIDE the
-- composer) read `M.associated_bufnr()` to scan the right file
-- instead of the composer they're typing in.
vim.api.nvim_create_autocmd("BufEnter", {
  group = _window_augroup,
  callback = function(args)
    local bufnr = args.buf
    if not vim.api.nvim_buf_is_loaded(bufnr) then
      return
    end
    if buffer.is_plugin_buffer(bufnr) then
      return
    end
    local ft = vim.bo[bufnr].filetype
    -- Skip unnamed scratch buffers (filetype empty + no name) — they
    -- have nothing useful to scan against. The previous association
    -- stays valid until the captain enters a real file.
    if vim.api.nvim_buf_get_name(bufnr) == "" and ft == "" then
      return
    end
    M._associated_bufnr = bufnr
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
---
---Critical: the new instance's auxiliary surfaces (header, queue
---strip, permission row) all need to re-paint against the
---switched-to instance — `M.show()` did this implicitly, but the
---old `M.switch()` skipped it, leaving stale queue counts and
---hidden permission rows after a peek-switch. We delegate the same
---refresh dance to keep the two paths consistent.
---
---Permission row entries for OTHER instances are preserved
---(`drop_for_instance(previous)` instead of the previous
---`reset()`). The daemon's resolution slot for B's permission still
---exists when the captain peeks at A, so wiping B's row entry meant
---the captain had to wait for the daemon to re-emit; now switching
---back to B surfaces the row immediately.
---@param instance_id string
function M.switch(instance_id)
  local state = instances.get(instance_id)

  if state == nil then
    log.warn("window.switch: unknown instance=%s", instance_id)

    return
  end

  local previous = M._last_active_id
  M._last_active_id = instance_id

  if M.is_visible() then
    if not buffer.safe_win_set_buf(M._winid, state.bufnr) then
      -- Switched-to buffer / chat window invalidated mid-call. Bail
      -- so we don't chain hydrate + permission_row refresh on a
      -- wedged window.
      return
    end

    -- Re-hydrate the switched-to instance's meta snapshot — it may
    -- have drifted (mode change, usage update, daemon-side rename)
    -- while it was off-screen.
    require("hyprpilot.chat.events").hydrate(instance_id, state.bufnr)
    require("hyprpilot.chat.render").apply_pending_folds(state.bufnr)

    -- Permission row: every instance's pending entries stay in the
    -- shared queue — `permission-row.head_for(active_id)` filters
    -- the rendered head to the active instance. So switching is a
    -- pure re-render: previous-instance entries persist (their
    -- daemon-side resolution slot is still live; switching back
    -- surfaces them intact), the row's head flips to the new
    -- active instance's first pending entry (or hides if none).
    require("hyprpilot.chat.permission-row").refresh_if_queued()

    -- Queue strip: hydrate the daemon snapshot for the new
    -- instance so the strip reflects current daemon-side state
    -- (the QueueChanged listener catches mutations going forward;
    -- this one-shot covers the gap if we joined mid-queue).
    require("hyprpilot.chat.queue-strip").hydrate(instance_id)
    require("hyprpilot.chat.queue-strip").refresh()

    -- Composer.open() is idempotent: when the composer's already
    -- visible it swaps its buffer to the new instance's draft.
    -- `focus = false` keeps the captain's cursor where it was —
    -- switch is a peek-at-the-other-instance gesture, not an "I'm
    -- about to type" gesture.
    require("hyprpilot.composer").open({ focus = false })

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
  local state = instances.get(instance_id)
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

---Trim old rendered lines from the local chat buffer. Defaults to the
---active instance and `chat.trim.keep_lines`; does not mutate daemon
---transcript history.
---@param instance_id? string | { keep_lines?: integer }
---@param opts? { keep_lines?: integer }
---@return { removed: integer, kept: integer }?
function M.trim(instance_id, opts)
  if type(instance_id) == "table" then
    opts = instance_id
    instance_id = nil
  end

  local id = instance_id or M._last_active_id
  if id == nil then
    log.warn("window.trim: no active instance")
    return nil
  end

  local state = require("hyprpilot.chat.render").state_for(id)
  if state == nil then
    log.warn("window.trim: no render state for instance=%s", id)
    return nil
  end

  return require("hyprpilot.chat.render").trim(state, opts)
end

-- Re-assert the chat window's fold setup whenever a chat buffer
-- becomes visible. A layout manager (edgy) that adopts the window
-- after `open_split` ran will reset window-local options on
-- adoption — including foldmethod / foldenable — and the auto-
-- collapse-on-turn-end behaviour silently dies. Plain BufWinEnter /
-- WinEnter on the chat ft is enough; the helper is idempotent.
do
  local group = vim.api.nvim_create_augroup("HyprpilotChatFolds", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "FileType" }, {
    group = group,
    pattern = "hyprpilot",
    callback = function(args)
      local bufnr = args.buf
      if bufnr == nil or bufnr == 0 then
        bufnr = vim.api.nvim_get_current_buf()
      end
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local winid = vim.fn.bufwinid(bufnr)
      if winid == -1 then
        return
      end
      M.apply_fold_setup(winid)
    end,
  })
end

return M
