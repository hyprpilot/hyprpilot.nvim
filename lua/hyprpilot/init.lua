local M = {}

--- Configures the hyprpilot.nvim plugin.
---@param config hyprpilot.Config
function M.setup(config)
  local c = require("hyprpilot.config").setup(config)

  require("hyprpilot.log").setup({ level = c.log_level })

  -- Wire daemon→plugin notification handlers (window focus / toggle
  -- / show / hide today, more as the surface grows). Listeners
  -- accumulate in `client.on_notification`, so this is a one-shot
  -- registration per setup() call.
  require("hyprpilot.rpc").register()

  -- Attention list — subscribes to permission / turn-ended User
  -- autocmds and exposes `is_attention_needed()` plus an `on_change`
  -- subscription for the bell + palette + future status pills.
  require("hyprpilot.notification.attention").ensure_listeners()

  -- Terminal bell — opt-in via `notification.bell.enabled`; rings
  -- on every attention-list growth event.
  require("hyprpilot.notification.bell").ensure_listeners()

  -- Diff preview — subscribes to permission resolution + instance
  -- terminal-state events so an open preview auto-closes the moment
  -- it stops being meaningful. The preview itself is captain-opened
  -- via `<C-o>` on the permission row; this is just the cleanup
  -- side of the lifecycle.
  require("hyprpilot.ui.diff_preview").ensure_listeners()

  -- Graceful teardown on Neovim exit. `clear = true` on the group
  -- so a captain who re-calls `setup()` (hot reload, config swap)
  -- doesn't accumulate duplicate `VimLeavePre` listeners.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("HyprpilotShutdown", { clear = true }),
    callback = function()
      require("hyprpilot.shutdown").shutdown()
    end,
  })
end

--- Tear down the plugin's runtime state — close windows, drop the
--- event subscription, disconnect the client. Called automatically
--- on `VimLeavePre`; also exposed for manual hot-reload / a
--- captain-bound "stop everything" keymap.
function M.shutdown()
  require("hyprpilot.shutdown").shutdown()
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

return M
