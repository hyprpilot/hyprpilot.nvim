local log = require("hyprpilot.log")

local M = {}

---@class hyprpilot.InstanceState
---@field bufnr integer
---@field instance_id string
---@field name? string

local BUFFER_PREFIX = "hyprpilot://"

---@type integer?
local _placeholder_bufnr = nil

---Open the buffer for write, run `fn`, restore read-only state.
---
---Errors INSIDE `fn` are now logged + swallowed instead of re-raised.
---The previous behaviour bubbled the throw out through the
---`events.dispatch` autocmd chain and stalled every later handler in
---the same tick — one render-side nil-deref on a half-built turn
---took down sibling handlers (winbar updates, status emissions, etc.)
---across every instance. Catching here keeps the UI in a recoverable
---state: the buffer's read-only flag is restored, the bad render
---logs, and the next event continues to fire.
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
    log.warn("with_buffer: bufnr=%s render fn errored: %s", bufnr, tostring(err))
  end
end

---Apply the standard chat-buffer options to `bufnr`.
---@param bufnr integer
---@param name string                    -- buffer name (used for `:ls` and addressability)
local function apply_options(bufnr, name)
  vim.api.nvim_buf_set_name(bufnr, name)
  -- Dotted alias: bare component is what our autocmd patterns +
  -- equality checks match (vim ft pattern matching iterates dotted
  -- components). Second component pulls in markdown's ftplugin +
  -- treesitter parser for free, matching the composer's surface.
  vim.bo[bufnr].filetype = "hyprpilot.markdown"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  M.suppress_external_ui(bufnr)
end

---Look up the first valid buffer whose name matches `name` exactly.
---Returns `nil` when no live buffer carries that name. Used by every
---plugin-managed buffer site (header / permission_row / composer /
---per-instance chat / placeholder) to adopt a buffer that survived
---a shutdown → setup hot-reload cycle, instead of crashing E95
---("Buffer with this name already exists") on a fresh
---`nvim_buf_set_name` call.
---@param name string
---@return integer? bufnr
function M.find_by_name(name)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
      return bufnr
    end
  end
  return nil
end

---Create (or return existing) per-instance buffer.
---@param instance_id string
---@return integer bufnr
function M.create(instance_id)
  local name = BUFFER_PREFIX .. instance_id

  local existing = M.find_by_name(name)
  if existing ~= nil then
    return existing
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  apply_options(bufnr, name)

  -- Buffer-local chat keymaps (gf, future ones). Wired here so every
  -- per-instance chat buffer gets them at mint time — the placeholder
  -- path mints via `M.placeholder` and doesn't need them.
  require("hyprpilot.chat.keymaps").attach(bufnr)

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

  -- Adopt an existing placeholder buffer when the module-level
  -- reference was cleared but Neovim still holds the buffer alive
  -- (post-`shutdown()` hot-reload, etc.) — otherwise the
  -- `apply_options` → `nvim_buf_set_name` call raises E95.
  local name = "hyprpilot://placeholder"
  local existing = M.find_by_name(name)
  if existing ~= nil then
    _placeholder_bufnr = existing
    return existing
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  apply_options(bufnr, name)

  M.with_buffer(bufnr, function()
    -- Passive placeholder: no captain-facing instructions because
    -- `chat.window.M.show()` auto-spawns a default instance when
    -- none exists. The captain only ever sees this buffer for the
    -- single tick between the spawn RPC firing and the daemon
    -- replying with the new instance id.
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "# hyprpilot",
      "",
      "starting…",
    })
  end)

  _placeholder_bufnr = bufnr

  return bufnr
end

---Buffer-level opt-out markers for the well-known buffer-local
---keys third-party UI plugins look for when they hook
---`BufEnter` / `BufRead` and decorate every buffer they see (sign
---column scribbles, blame virt_text, diagnostic icons,
---indent-guide lines, diff hunks). Each key follows the upstream
---convention — set the marker, the plugin skips us. Idempotent;
---safe to call from `apply_options` and from the per-window paths
---each module owns.
---
---NOT included on purpose: layout-manager opt-out keys. Captains
---who want a layout manager (any plugin that adopts windows by
---filetype into a managed sidebar) to handle hyprpilot register
---our filetypes (`hyprpilot`, `hyprpilot_composer`,
---`hyprpilot_header`, `hyprpilot_queue_strip`,
---`hyprpilot_permission_row`) in that plugin's config and we get
---adoption for free. Captains who DON'T want adoption set the
---layout manager's opt-out marker themselves in a `FileType
---hyprpilot*` autocmd.
---@param bufnr integer
function M.suppress_external_ui(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  -- Suppress git-sign / hunk decorations on the buffer.
  vim.b[bufnr].gitsigns_disable = true
  -- Don't lint our render buffers.
  vim.b[bufnr].lint_disabled = true
  -- Suppress indent-guide line drawing — busy noise on our
  -- markdown-shaped UI.
  vim.b[bufnr].miniindentscope_disable = true
end

---True when a layout manager (folke/edgy.nvim today; could expand)
---is loaded. Multiple plugin surfaces gate their own
---window-management — `winfixheight` / `winfixwidth` pins,
---`nvim_win_set_height` resizes — on this so we don't fight the
---layout manager's `apply_size` pass. Edgy patches
---`nvim_win_set_height` globally and re-asserts its own computed
---heights on every layout tick; our resize calls visibly flicker
---and lose every race against it.
---@return boolean
function M.layout_manager_active()
  return package.loaded["edgy"] ~= nil
end

---Strip Neovim's stock chrome off a plugin window: hide the
---statusline (set to a single space — Neovim renders nothing
---visible), suppress numbers / fold column / sign column, and
---remap the `EndOfBuffer` `~` glyphs to invisible so a short
---surface doesn't show fill rows. Does NOT touch `winhighlight` —
---callers that need a custom Normal: group set it themselves.
---@param winid integer
function M.clean_window_chrome(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return
  end
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].cursorline = false
  vim.wo[winid].cursorcolumn = false
  vim.wo[winid].colorcolumn = ""
  vim.wo[winid].spell = false
  vim.wo[winid].list = false
  -- Empty statusline + winbar → the global status / any
  -- external statusline plugin skips us. A single space is
  -- universally rendered as blank without breaking the global
  -- `laststatus` setting.
  vim.wo[winid].statusline = " "
  vim.wo[winid].winbar = ""
  -- Suppress the `~` end-of-buffer glyphs by remapping them to a
  -- space via fillchars; cheap visual cleanup for the small
  -- auxiliary surfaces.
  local existing = vim.wo[winid].fillchars or ""
  if not existing:match("eob:") then
    vim.wo[winid].fillchars = (existing == "" and "" or existing .. ",") .. "eob: "
  end
end

-- Re-apply window chrome cleanup whenever a plugin-owned buffer
-- becomes visible. A peer plugin that re-hooks `WinEnter` may reset
-- window-local options (signcolumn, statusline, etc.) after our
-- open-time setup, letting things like gitsigns / mini.diff / lsp
-- signs leak `+`, `>`, `~` glyphs onto the chat surface. Re-
-- applying on `BufWinEnter` + `WinEnter` is cheap and idempotent —
-- captures every adoption / focus path without us having to know
-- which peer reset the option.
--
-- IMPORTANT: when a layout manager (folke/edgy.nvim) is loaded we
-- back off and let it own the chrome. Edgy applies its own
-- `winbar`, `winhighlight`, `signcolumn`, etc. on adopted windows;
-- our re-apply was stripping those right after edgy set them, so
-- the captain's edgy setup looked like "hyprpilot windows ignore
-- edgy styling". The non-edgy setups (no layout manager) still
-- get the original gitsigns-leak protection.
--- Dotted-filetype-aware membership check. The composer buffer's
--- filetype is `hyprpilot_composer.markdown` (dotted alias so
--- ftplugin/markdown.* + cmp/snippet sources keyed to "markdown"
--- apply); equality `vim.bo.filetype == "hyprpilot_composer"`
--- would miss it. Iterate the dot-separated components and match
--- the bare ft name. Public so consumers (composer.is_buffer,
--- completion.blink) call through the same predicate.
---@param bufnr integer
---@param ft string
---@return boolean
function M.has_filetype(bufnr, ft)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local raw = vim.bo[bufnr].filetype
  if type(raw) ~= "string" or raw == "" then
    return false
  end
  for component in raw:gmatch("[^.]+") do
    if component == ft then
      return true
    end
  end
  return false
end

--- Plugin-owned filetypes — the bare names. The composer surfaces
--- `hyprpilot_composer.markdown` (see `composer/init.lua`); the
--- bare component is what BufWinEnter / FileType autocmd patterns
--- match against. Vim's autocmd ft pattern matching iterates the
--- dotted components on its own.
local plugin_filetypes = {
  "hyprpilot",
  "hyprpilot_composer",
  "hyprpilot_header",
  "hyprpilot_permission_row",
  "hyprpilot_queue_strip",
}

---True when `bufnr`'s filetype matches one of the plugin-owned
---surfaces (chat / composer / header / permission row / queue
---strip). Dotted-aware via `has_filetype` so the composer's
---`hyprpilot_composer.markdown` alias is recognised.
---@param bufnr integer
---@return boolean
function M.is_plugin_buffer(bufnr)
  for _, ft in ipairs(plugin_filetypes) do
    if M.has_filetype(bufnr, ft) then
      return true
    end
  end
  return false
end

---True when `winid` shows a plugin-owned buffer.
---@param winid integer
---@return boolean
function M.is_plugin_window(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  return M.is_plugin_buffer(vim.api.nvim_win_get_buf(winid))
end

---First currently-visible window whose buffer is NOT plugin-owned.
---Used by tool-driven navigation (editor_file_open / jump / select)
---to route file ops away from the chat / composer when the captain
---has focus on one of our surfaces. Returns nil when every visible
---window is plugin-owned (caller decides whether to spawn a new
---split or error out).
---@return integer?
function M.find_editor_winid()
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and not M.is_plugin_window(winid) then
      -- Ignore floating windows — those are popups (snacks picker,
      -- diff preview, telescope, etc.), not the captain's editor.
      local config = vim.api.nvim_win_get_config(winid)
      if config.relative == nil or config.relative == "" then
        return winid
      end
    end
  end
  return nil
end

do
  local group = vim.api.nvim_create_augroup("HyprpilotBufferChrome", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "FileType" }, {
    group = group,
    pattern = plugin_filetypes,
    callback = function(args)
      -- Skip everything when a layout manager is present — it owns
      -- window-local options on the adopted window. Captain's
      -- styling came through `edgy`'s slot config; we shouldn't
      -- fight that.
      if package.loaded["edgy"] ~= nil then
        return
      end
      -- BufWinEnter / FileType pass `args.buf`; WinEnter doesn't
      -- (it's a window event). For WinEnter we look up the bufnr
      -- from the current window.
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
      M.clean_window_chrome(winid)
    end,
  })
end

---@class hyprpilot.chat.buffer.AuxSplitOpts
---@field direction string                       -- ex-cmd suffix, e.g. `"belowright 1split"` / `"aboveleft 1split"`
---@field bufnr integer                          -- buffer to attach to the new split
---@field after? fun(winid: integer): nil        -- optional setup callback called with the new winid (after the buffer is attached)

---Open an auxiliary split anchored relative to the chat window.
---Used by every plugin surface that lives around the chat (header
---above, queue strip + permission row + composer below) — collapses
---the otherwise-byte-identical "stash previous winid → focus chat
---→ pcall the split → grab new winid → attach buf → restore
---previous winid" choreography that was duplicated across four
---files.
---
---Returns the new window id on success or nil + a short error
---string when the chat window can't be focused or the split fails
---(callers log the err themselves so the message names the
---surface). Caller is responsible for window-local options
---(`winfixheight` / `winfixwidth` / etc.) — pass them inside the
---`after` callback.
---@param opts hyprpilot.chat.buffer.AuxSplitOpts
---@return integer? winid, string? err
function M.open_aux_split(opts)
  local window = require("hyprpilot.chat.window")
  local previous_win = vim.api.nvim_get_current_win()

  if not window.focus() then
    return nil, "chat window not focusable"
  end

  local ok_split, split_err = pcall(vim.cmd, opts.direction)
  if not ok_split then
    if vim.api.nvim_win_is_valid(previous_win) then
      pcall(vim.api.nvim_set_current_win, previous_win)
    end
    return nil, tostring(split_err or opts.direction .. " failed")
  end

  -- Once the split lands, every subsequent step is in pcall. The
  -- helper advertises a `(winid, err)` contract; an `nvim_win_set_buf`
  -- race or an `after` callback throw must not leak a dangling
  -- split, and must surface as a clean err string instead of
  -- escaping the caller's `if winid == nil` guard.
  local winid = vim.api.nvim_get_current_win()

  local function unwind(err_msg)
    if vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
    if vim.api.nvim_win_is_valid(previous_win) then
      pcall(vim.api.nvim_set_current_win, previous_win)
    end
    return nil, err_msg
  end

  local ok_buf, buf_err = pcall(vim.api.nvim_win_set_buf, winid, opts.bufnr)
  if not ok_buf then
    return unwind("nvim_win_set_buf failed: " .. tostring(buf_err))
  end

  M.clean_window_chrome(winid)

  -- Force a layout-manager re-scan AFTER the buffer swap. The
  -- aux-split open path is `<dir>split` (creates a scratch window
  -- with empty filetype) → `nvim_win_set_buf` (swap to our
  -- pre-typed buffer). Edgy's `BufWinEnter` listener fires on the
  -- scratch buffer with empty ft → no view matches → edgy may
  -- unhook the window. The post-swap `BufWinEnter` sometimes
  -- doesn't trigger a fresh layout pass, leaving the now-correctly-
  -- typed window floating in the editor area instead of in edgy's
  -- right column. Forcing `layout()` here closes that race so
  -- adoption happens reliably (verified via `views[i].wins` going
  -- from 0 to 1 after this call for the header view).
  if M.layout_manager_active() then
    pcall(function()
      require("edgy.layout").layout()
    end)
  end

  if opts.after ~= nil then
    local ok_after, after_err = pcall(opts.after, winid)
    if not ok_after then
      return unwind("after callback failed: " .. tostring(after_err))
    end
  end

  if vim.api.nvim_win_is_valid(previous_win) then
    pcall(vim.api.nvim_set_current_win, previous_win)
  end

  return winid, nil
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
