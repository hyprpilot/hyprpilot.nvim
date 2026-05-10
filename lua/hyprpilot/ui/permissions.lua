--- Buffer-local keymap router for permission button groups.
---
--- Each chat buffer carries an entry in `M._buffers[bufnr]` while it
--- has at least one pending permission. Cursor rows that fall inside
--- a registered permission block route key presses (`<Tab>`, `<CR>`,
--- `g`, `d`, `<LeftMouse>`) to that block's option set; rows outside
--- fall through via `vim.api.nvim_feedkeys` so plain editing keys
--- still work.
---
--- The smart-match helpers turn `g` and `d` into "jump-to-allow" and
--- "jump-to-reject" by scanning option ids/names for `^allow|^accept`
--- and `^reject|^deny` prefixes — the daemon's wording drifts across
--- agents (`allow_once`, `accept once`, `proceed`), so we match
--- liberally.

local log = require("hyprpilot.log")

local M = {}

---@class hyprpilot.ui.permissions.Entry
---@field block hyprpilot.render.Block
---@field options table[]

---@type table<integer, table<string, hyprpilot.ui.permissions.Entry>>
M._buffers = {}

---@type table<integer, boolean>
M._installed = {}

---Find the permission entry whose block currently covers `row`.
---@param bufnr integer
---@param row integer
---@return hyprpilot.ui.permissions.Entry?
local function entry_at_row(bufnr, row)
  local entries = M._buffers[bufnr]
  if entries == nil then
    return nil
  end

  local block = require("hyprpilot.chat.render").block_at_row(bufnr, row)
  if block == nil or block.kind ~= "permission_request" or block.request_id == nil then
    return nil
  end

  return entries[block.request_id]
end

---Repaint the button line of an entry's block via the render module.
---@param bufnr integer
---@param entry hyprpilot.ui.permissions.Entry
local function repaint(bufnr, entry)
  local render = require("hyprpilot.chat.render")
  local state = render.state_for_bufnr(bufnr)
  if state == nil then
    return
  end

  render.update_permission_buttons(state, entry.block, entry.options, entry.block.focused_idx, nil)
end

---Submit `option_id` to the daemon for `request_id`.
---@param request_id string
---@param option_id string
local function submit(request_id, option_id)
  require("hyprpilot.permissions").respond(request_id, option_id, function(err)
    if err ~= nil then
      log.warn("permissions.submit: %s (%s/%s)", err.message, request_id, option_id)
    else
      log.debug("permissions.submit: ok %s/%s", request_id, option_id)
    end
  end)
end

---Find the first option whose id or name matches a `^prefix` pattern
---(case-insensitive). Returns the option index (1-based) or `nil`.
---@param options table[]
---@param patterns string[]
---@return integer?
local function smart_match(options, patterns)
  for i, opt in ipairs(options) do
    local id = string.lower(tostring(opt.optionId or ""))
    local name = string.lower(tostring(opt.name or ""))
    for _, pattern in ipairs(patterns) do
      if id:match(pattern) ~= nil or name:match(pattern) ~= nil then
        return i
      end
    end
  end

  return nil
end

---Cycle the focused button by `delta` (+1 / -1), wrapping at edges.
---@param entry hyprpilot.ui.permissions.Entry
---@param delta integer
local function cycle_focus(entry, delta)
  local count = #entry.options
  if count == 0 then
    return
  end

  local current = entry.block.focused_idx or 1
  local next_idx = ((current - 1 + delta) % count) + 1
  entry.block.focused_idx = next_idx
end

---Resolve the currently-focused option (if any) for an entry.
---@param entry hyprpilot.ui.permissions.Entry
---@return table?
local function focused_option(entry)
  return entry.options[entry.block.focused_idx or 1]
end

---Pass-through helper: feed the original keys back to Neovim. Used
---when the cursor is outside any permission block.
---@param keys string
local function feedkeys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
end

---Install the buffer-local keymaps once per chat buffer. Idempotent.
---@param bufnr integer
function M.install_keymaps(bufnr)
  if M._installed[bufnr] then
    return
  end

  M._installed[bufnr] = true

  local function bind(key, fallback, fn)
    vim.keymap.set("n", key, function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row = cursor[1] - 1
      local entry = entry_at_row(bufnr, row)
      if entry == nil then
        feedkeys(fallback)
        return
      end
      fn(entry)
    end, { buffer = bufnr, silent = true, nowait = true })
  end

  bind("<Tab>", "<Tab>", function(entry)
    cycle_focus(entry, 1)
    repaint(bufnr, entry)
  end)

  bind("<S-Tab>", "<S-Tab>", function(entry)
    cycle_focus(entry, -1)
    repaint(bufnr, entry)
  end)

  bind("<CR>", "<CR>", function(entry)
    local opt = focused_option(entry)
    if opt == nil then
      return
    end
    submit(entry.block.request_id, opt.optionId)
  end)

  bind("g", "g", function(entry)
    local idx = smart_match(entry.options, { "^allow", "^accept", "^proceed" })
    if idx == nil then
      log.debug("permissions: no allow-shaped option to bind 'g' to")
      return
    end
    entry.block.focused_idx = idx
    repaint(bufnr, entry)
    submit(entry.block.request_id, entry.options[idx].optionId)
  end)

  bind("d", "d", function(entry)
    local idx = smart_match(entry.options, { "^reject", "^deny", "^abort", "^cancel" })
    if idx == nil then
      log.debug("permissions: no reject-shaped option to bind 'd' to")
      return
    end
    entry.block.focused_idx = idx
    repaint(bufnr, entry)
    submit(entry.block.request_id, entry.options[idx].optionId)
  end)

  log.debug("permissions: installed keymaps on bufnr=%s", bufnr)
end

---Register a permission block on `bufnr`.
---@param bufnr integer
---@param block hyprpilot.render.Block
---@param options table[]
function M.register(bufnr, block, options)
  M.install_keymaps(bufnr)

  if M._buffers[bufnr] == nil then
    M._buffers[bufnr] = {}
  end

  if block.request_id == nil then
    log.warn("permissions.register: block missing request_id")
    return
  end

  M._buffers[bufnr][block.request_id] = { block = block, options = options }

  log.debug("permissions: registered request_id=%s on bufnr=%s with %d options", block.request_id, bufnr, #options)
end

---Drop a permission entry from `bufnr` (called when the daemon
---reports the request as resolved).
---@param bufnr integer
---@param request_id string
function M.unregister(bufnr, request_id)
  local entries = M._buffers[bufnr]
  if entries == nil then
    return
  end

  entries[request_id] = nil

  if next(entries) == nil then
    M._buffers[bufnr] = nil
  end
end

---Wipe all entries for `bufnr` (called by render.hydrate before
---replaying a fresh snapshot).
---@param bufnr integer
function M.reset(bufnr)
  M._buffers[bufnr] = nil
end

return M
