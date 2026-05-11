--- Pinned single-line header buffer above the chat split.
---
--- Replaces the per-window `winbar` (which only painted while the
--- chat window held focus — the moment the captain dropped into the
--- composer below, the bar disappeared). The header lives in its own
--- 1-row split sized via `winfixheight` and shows the same meta the
--- winbar used to: instance state · mode · model · usage · mcps ·
--- activity.
---
--- Public surface:
---   `open()`       — open the header above the chat window
---   `close()`      — tear down the header window (buffer persists)
---   `is_visible()` — split is open + valid
---   `refresh()`    — re-render the header line for the active instance

local buffer = require("hyprpilot.chat.buffer")
local log = require("hyprpilot.log")
local winbar = require("hyprpilot.chat.winbar")
local window = require("hyprpilot.chat.window")

local M = {}

local BUFFER_NAME = "hyprpilot://header"
local NS = vim.api.nvim_create_namespace("hyprpilot.chat.header")

---@type integer?
M._winid = nil

---@type integer?
M._bufnr = nil

---Get-or-create the shared header buffer (one buffer reused across
---instance switches; content is just a single-line string).
---@return integer
local function ensure_buffer()
  if M._bufnr ~= nil and vim.api.nvim_buf_is_valid(M._bufnr) then
    return M._bufnr
  end

  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_name(bufnr, BUFFER_NAME)
  vim.bo[bufnr].filetype = "hyprpilot_header"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].modifiable = false

  M._bufnr = bufnr
  return bufnr
end

---True when the header window exists + is valid.
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

---Compose the header text for the currently active instance. Mirrors
---`winbar.render` but routes through the shared `winbar._meta` so we
---don't duplicate the meta store. Returns an empty string when there's
---no active instance (header collapses to nothing visible).
---@return string
local function compose()
  local instance_id = window.active_instance()
  if instance_id == nil then
    return " hyprpilot · (no instance)"
  end

  local meta = winbar._meta[instance_id]
  local activity = require("hyprpilot.status").get().activity

  local parts = { "hyprpilot" }

  if meta ~= nil and meta.instance_state ~= nil and meta.instance_state ~= "running" then
    table.insert(parts, meta.instance_state)
  end

  if meta ~= nil then
    local function display_name(id, available)
      if id == nil or id == "" then
        return nil
      end
      if type(available) == "table" then
        for _, entry in ipairs(available) do
          if type(entry) == "table" and entry.id == id then
            return tostring(entry.name or entry.id)
          end
        end
      end
      return id
    end

    local mode = display_name(meta.current_mode_id, meta.available_modes)
    if mode ~= nil then
      table.insert(parts, mode)
    end

    local model = display_name(meta.current_model_id, meta.available_models)
    if model ~= nil then
      table.insert(parts, model)
    end

    if meta.usage ~= nil and (meta.usage.size or 0) > 0 then
      local used = meta.usage.used or 0
      local size = meta.usage.size or 0
      local function compact(n)
        if type(n) ~= "number" or n < 1000 then
          return tostring(n or 0)
        end
        if n < 1000000 then
          return string.format("%.1fk", n / 1000)
        end
        return string.format("%.1fM", n / 1000000)
      end
      table.insert(parts, string.format("%s/%s tok", compact(used), compact(size)))
    end

    if (meta.mcps_count or 0) > 0 then
      table.insert(parts, string.format("+%d mcps", meta.mcps_count))
    end
  end

  if activity ~= nil and activity.kind ~= nil and activity.kind ~= "idle" then
    if activity.kind == "tool" then
      table.insert(parts, activity.tool_name ~= nil and ("tool · " .. activity.tool_name) or "tool")
    elseif activity.kind == "awaiting_permission" then
      table.insert(parts, "permission?")
    else
      table.insert(parts, activity.kind)
    end
  end

  return " " .. table.concat(parts, " · ")
end

---Re-render the header line. Cheap; called whenever meta / activity /
---active instance changes. No-op when the header isn't visible.
function M.refresh()
  if M._bufnr == nil or not vim.api.nvim_buf_is_valid(M._bufnr) then
    return
  end

  local line = compose()

  buffer.with_buffer(M._bufnr, function()
    vim.api.nvim_buf_set_lines(M._bufnr, 0, -1, false, { line })
    vim.api.nvim_buf_clear_namespace(M._bufnr, NS, 0, -1)
    vim.api.nvim_buf_set_extmark(M._bufnr, NS, 0, 0, { line_hl_group = "HyprpilotHeader" })
  end)
end

---Open the header window above the chat split. Idempotent: if already
---visible, just refreshes the line.
function M.open()
  if not window.is_visible() then
    log.debug("header.open: chat window not visible, skipping")
    return
  end

  local bufnr = ensure_buffer()

  if M.is_visible() then
    if vim.api.nvim_win_get_buf(M._winid) ~= bufnr then
      vim.api.nvim_win_set_buf(M._winid, bufnr)
    end
    M.refresh()
    return
  end

  local previous_win = vim.api.nvim_get_current_win()

  vim.api.nvim_set_current_win(window._winid)
  vim.cmd("aboveleft 1split")

  M._winid = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(M._winid, bufnr)
  vim.wo[M._winid].number = false
  vim.wo[M._winid].relativenumber = false
  vim.wo[M._winid].signcolumn = "no"
  vim.wo[M._winid].foldcolumn = "0"
  vim.wo[M._winid].wrap = false
  vim.wo[M._winid].winfixheight = true
  vim.wo[M._winid].cursorline = false
  vim.wo[M._winid].winhighlight = "Normal:HyprpilotHeader"

  -- Lock the height to one row; `winfixheight` keeps `<C-W>=` from
  -- redistributing space onto it.
  vim.api.nvim_win_set_height(M._winid, 1)

  -- Drop back to wherever the captain was — the header is a pinned
  -- display, never a focus target.
  if vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end

  M.refresh()
end

---Close the header window. Buffer persists for next open.
function M.close()
  if not M.is_visible() then
    return
  end

  pcall(vim.api.nvim_win_close, M._winid, true)
  M._winid = nil
end

local listeners_wired = false

---Wire the autocmds that drive `refresh()` (idempotent).
function M.ensure_listeners()
  if listeners_wired then
    return
  end
  listeners_wired = true

  local group = vim.api.nvim_create_augroup("HyprpilotHeader", { clear = true })

  for _, pattern in ipairs({
    "HyprpilotInstanceChanged",
    "HyprpilotInstanceMetaChanged",
    "HyprpilotActivityChanged",
  }) do
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = pattern,
      callback = function()
        M.refresh()
      end,
    })
  end
end

return M
