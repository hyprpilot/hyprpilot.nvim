--- Opt-in lualine component for `hyprpilot.nvim`.
---
--- The module returns a callable: lualine treats string component
--- entries as `require(string)`-then-call, so a captain wires it as:
---
--- ```lua
--- require("lualine").setup({
---   sections = {
---     lualine_x = { "hyprpilot.extensions.lualine" },
---   },
--- })
--- ```
---
--- The callable pulls from `hyprpilot.status.get()` and the first
--- invocation registers `User Hyprpilot*` autocmds that nudge lualine
--- to refresh — without them the bar would only re-paint on lualine's
--- own polling timer, lagging behind connection / instance / activity
--- transitions by up to a second.

local status = require("hyprpilot.status")

local M = {}

---@param connection hyprpilot.client.State
---@return string
local function connection_glyph(connection)
  if connection == "connected" then
    return "●"
  elseif connection == "connecting" then
    return "…"
  end
  return "○"
end

---@param activity hyprpilot.Activity
---@return string?
local function activity_label(activity)
  local kind = activity.kind

  if kind == "idle" or kind == nil then
    return nil
  elseif kind == "tool" then
    return activity.tool_name ~= nil and ("tool · " .. activity.tool_name) or "tool"
  elseif kind == "awaiting_permission" then
    return "permission?"
  end

  return kind
end

---Compose the statusline pill from a status snapshot.
---@param snapshot hyprpilot.Status
---@return string
function M.format(snapshot)
  local parts = { connection_glyph(snapshot.connection) .. " hyprpilot" }

  if snapshot.active_instance ~= nil then
    table.insert(parts, snapshot.active_instance)
  end

  local activity = activity_label(snapshot.activity)
  if activity ~= nil then
    table.insert(parts, activity)
  end

  return table.concat(parts, " · ")
end

local refresh_wired = false

---Wire the `User Hyprpilot*` autocmds to lualine's refresh hook on
---first call. Idempotent.
local function ensure_refresh_wired()
  if refresh_wired then
    return
  end
  refresh_wired = true

  local group = vim.api.nvim_create_augroup("HyprpilotLualine", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = {
      "HyprpilotConnected",
      "HyprpilotDisconnected",
      "HyprpilotInstanceChanged",
      "HyprpilotActivityChanged",
    },
    callback = function()
      local ok, lualine = pcall(require, "lualine")
      if ok then
        pcall(lualine.refresh)
      end
    end,
  })
end

return setmetatable(M, {
  __call = function()
    ensure_refresh_wired()
    return M.format(status.get())
  end,
})
