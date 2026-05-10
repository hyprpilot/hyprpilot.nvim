local M = {}

--- Configures the hyprpilot.nvim plugin.
---@param config hyprpilot.Config
function M.setup(config)
  local c = require("hyprpilot.config").setup(config)

  require("hyprpilot.log").setup({ level = c.log_level })
end

-- ── Window ─────────────────────────────────────────────────────────

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

-- ── Instances ──────────────────────────────────────────────────────

--- List every live instance the daemon knows about.
---@param callback hyprpilot.InstancesCallback
function M.instances(callback)
  require("hyprpilot.instances").list(callback)
end

--- Fetch one instance's metadata. Defaults to the active instance.
---@param instance_id string?
---@param callback hyprpilot.InstanceCallback
function M.info(instance_id, callback)
  require("hyprpilot.instances").info(instance_id, callback)
end

--- Spawn a new instance. Defaults `cwd = vim.fn.getcwd()` and
--- `show = true`. Pass `name` to use focus-with-ensure under the hood.
---@param opts hyprpilot.SpawnOpts?
---@param callback hyprpilot.InstanceCallback?
function M.spawn(opts, callback)
  require("hyprpilot.instances").spawn(opts, callback)
end

--- Focus an instance by id-or-slug. With `ensure = true`, spawns +
--- renames when the slug doesn't resolve.
---@param instance_id string
---@param opts hyprpilot.FocusOpts?
---@param callback hyprpilot.InstanceCallback?
function M.focus(instance_id, opts, callback)
  require("hyprpilot.instances").focus(instance_id, opts, callback)
end

--- Restart an instance daemon-side. Defaults to the active instance.
---@param instance_id string?
---@param callback hyprpilot.InstanceCallback?
function M.restart(instance_id, callback)
  require("hyprpilot.instances").restart(instance_id, callback)
end

--- Shut down a daemon-side instance. Local buffer stays put — call
--- `close` to also wipe the buffer. Defaults to the active instance.
---@param instance_id string?
---@param callback hyprpilot.InstanceCallback?
function M.shutdown(instance_id, callback)
  require("hyprpilot.instances").shutdown(instance_id, callback)
end

--- Rename an instance daemon-side.
---@param instance_id string
---@param name string
---@param callback hyprpilot.InstanceCallback?
function M.rename(instance_id, name, callback)
  require("hyprpilot.instances").rename(instance_id, name, callback)
end

return M
