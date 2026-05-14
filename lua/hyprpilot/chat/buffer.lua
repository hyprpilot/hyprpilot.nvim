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
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "# hyprpilot",
      "",
      "No instances. Spawn one via `require('hyprpilot.instances').spawn({})`.",
    })
  end)

  _placeholder_bufnr = bufnr

  return bufnr
end

---Buffer-level opt-out markers for third-party UI plugins that hook
---`BufEnter` / `BufRead` and decorate every buffer they see (sign
---column scribbles, blame virt_text, diagnostic icons, edge
---adoption). Our chat / permission row / queue strip / header /
---composer surfaces are pure UI — they don't want gitsigns hunks,
---LSP diagnostics, or edgy adoption fighting them. Each marker
---lookup follows the upstream plugin's documented opt-out shape.
---Idempotent; safe to call from `apply_options` and from the
---per-window paths each module owns.
---@param bufnr integer
function M.suppress_external_ui(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  -- gitsigns: disables every gitsigns decoration on the buffer.
  vim.b[bufnr].gitsigns_disable = true
  -- edgy.nvim: keeps it from adopting the buffer into a managed
  -- edge slot. The captain who explicitly registers our filetypes
  -- with edgy can override per-buffer with `vim.b[bufnr].edgy_disable
  -- = false`.
  vim.b[bufnr].edgy_disable = true
  -- nvim-lint / null-ls / linters: don't lint our render buffers.
  vim.b[bufnr].lint_disabled = true
  -- mini.indentscope draws guide lines on every indent depth — busy
  -- noise on our markdown-shaped UI.
  vim.b[bufnr].miniindentscope_disable = true
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
  -- Empty statusline + winbar → the global status / external
  -- statuslines (lualine etc.) skip us. A single space is
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
