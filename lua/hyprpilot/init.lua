local M = {}

--- Configures the hyprpilot.nvim plugin.
---@param config hyprpilot.Config
function M.setup(config)
  local c = require("hyprpilot.config").setup(config)

  require("hyprpilot.log").setup({ level = c.log_level })
end

--- Toggle the chat side split: hide if visible, show otherwise.
function M.toggle()
  require("hyprpilot.chat.window").toggle()
end

--- Show the chat side split, optionally switching to `instance_id`.
---@param instance_id string?
function M.show(instance_id)
  require("hyprpilot.chat.window").show(instance_id)
end

--- Hide the chat side split. Buffers persist for resume.
function M.hide()
  require("hyprpilot.chat.window").hide()
end

--- Wipe a per-instance buffer (defaults to the active instance).
---@param instance_id string?
function M.close(instance_id)
  require("hyprpilot.chat.window").close(instance_id)
end

--- Switch the chat window to a different instance's buffer.
---@param instance_id string
function M.switch(instance_id)
  require("hyprpilot.chat.window").switch(instance_id)
end

--- Currently-active instance id, or `nil` when none.
---@return string?
function M.active_instance()
  return require("hyprpilot.chat.window").active_instance()
end

return M
