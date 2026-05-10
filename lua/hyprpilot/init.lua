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

-- ── Composer ───────────────────────────────────────────────────────

--- Open the composer split below the chat window.
function M.composer_open()
  require("hyprpilot.ui.composer").open()
end

--- Close the composer split. Buffer persists for next open.
function M.composer_close()
  require("hyprpilot.ui.composer").close()
end

--- Toggle the composer split.
function M.composer_toggle()
  require("hyprpilot.ui.composer").toggle()
end

--- Submit the composer's contents (or `text` when provided) to the
--- active instance.
---@param text string?
---@param opts { instance_id?: string }?
function M.submit(text, opts)
  require("hyprpilot.ui.composer").submit(text, opts)
end

--- Cancel the in-flight turn on the active instance.
---@param instance_id string?
function M.cancel(instance_id)
  require("hyprpilot.ui.composer").cancel(instance_id)
end

return M
