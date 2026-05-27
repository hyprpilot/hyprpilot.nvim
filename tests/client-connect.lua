--- Behavioural tests for the daemon client's connection path.
--- Initial local-socket failures should fail fast: a missing socket can
--- mean a different daemon/session boundary, so we do not loop through
--- delayed retry attempts before frontend-side callers get their error.

local T = MiniTest.new_set()

T["connect: missing socket attempts sockconnect once and schedules no retry"] = function()
  local client = require("hyprpilot.client")
  local config = require("hyprpilot.config")
  local log = require("hyprpilot.log")

  client._reset()

  local original_sockconnect = vim.fn.sockconnect
  local original_defer_fn = vim.defer_fn
  local original_runtime = vim.env.XDG_RUNTIME_DIR
  local original_client = vim.deepcopy(config.options.client)
  local original_error = log.error

  local attempts = 0
  local scheduled = 0

  vim.env.XDG_RUNTIME_DIR = "/tmp/hyprpilot-nvim-missing"
  config.options.client = { timeout_ms = 5000, retry_delay_ms = 1 }
  vim.fn.sockconnect = function()
    attempts = attempts + 1
    return 0
  end
  vim.defer_fn = function()
    scheduled = scheduled + 1
  end
  log.error = function() end

  client.connect()

  MiniTest.expect.equality(attempts, 1)
  MiniTest.expect.equality(scheduled, 0)
  MiniTest.expect.equality(client.state(), "disconnected")

  vim.fn.sockconnect = original_sockconnect
  vim.defer_fn = original_defer_fn
  vim.env.XDG_RUNTIME_DIR = original_runtime
  config.options.client = original_client
  log.error = original_error
  client._reset()
end

return T
