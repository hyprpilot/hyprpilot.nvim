--- `:checkhealth hyprpilot` — captain's first stop when something is
--- off. Each check is a stand-alone function so individual failures
--- never short-circuit the rest of the report.

local health = vim.health

local M = {}

local MIN_NVIM_VERSION = { 0, 10, 0 }

---@return string
local function default_socket_path()
  local runtime_dir = vim.env.XDG_RUNTIME_DIR

  if runtime_dir == nil or runtime_dir == "" then
    return ""
  end

  return runtime_dir .. "/hyprpilot.sock"
end

local function check_nvim_version()
  local v = vim.version()
  local current = { v.major, v.minor, v.patch }
  local min = MIN_NVIM_VERSION

  local ok = current[1] > min[1] or (current[1] == min[1] and (current[2] > min[2] or (current[2] == min[2] and current[3] >= min[3])))

  local label = string.format("Neovim %d.%d.%d", current[1], current[2], current[3])

  if ok then
    health.ok(label .. string.format(" (>= %d.%d.%d required)", min[1], min[2], min[3]))
  else
    health.error(label .. string.format(" is below the required %d.%d.%d", min[1], min[2], min[3]))
  end
end

---@return string
local function resolved_socket_path()
  local cfg = require("hyprpilot.config").options.socket

  if type(cfg) == "string" and cfg ~= "" then
    return cfg
  end

  return default_socket_path()
end

local function check_socket()
  local socket = resolved_socket_path()

  if socket == "" then
    health.warn("Could not resolve daemon socket path", {
      "Set `socket` in `setup({})` or export `XDG_RUNTIME_DIR`.",
    })
    return
  end

  local stat = vim.uv.fs_stat(socket)

  if stat == nil then
    health.warn(string.format("Daemon socket not reachable at `%s`", socket), {
      "Start the `hyprpilot` daemon, or override `socket` in `setup({})`.",
    })
    return
  end

  health.ok(string.format("Daemon socket reachable at `%s`", socket))
end

---Try `daemon/version` over the configured socket. Blocks the editor
---for up to ~1.2s during the check; runs synchronously since
---`vim.health` reports as it goes.
local function check_daemon_version()
  local socket = resolved_socket_path()

  if socket == "" or vim.uv.fs_stat(socket) == nil then
    -- Socket-level failure already reported by check_socket; don't
    -- emit a confusing follow-up.
    return
  end

  local client = require("hyprpilot.client")
  local got

  client.request("daemon/version", nil, { timeout_ms = 1000 }, function(err, result)
    got = { err = err, result = result }
  end)

  local arrived = vim.wait(1200, function()
    return got ~= nil
  end, 25)

  if not arrived then
    health.warn("`daemon/version` timed out", {
      "Daemon may be starting up; rerun `:checkhealth hyprpilot` in a moment.",
    })
    return
  end

  if got.err ~= nil then
    health.warn(string.format("`daemon/version` failed: %s", got.err.message or vim.inspect(got.err)))
    return
  end

  local version = got.result and got.result.version
  if type(version) ~= "string" or version == "" then
    health.warn("Daemon responded but did not report a version", { vim.inspect(got.result) })
    return
  end

  health.ok(string.format("Daemon v%s", version))
end

local function check_listen_socket()
  local servername = vim.v.servername

  if servername == nil or servername == "" then
    health.warn("Neovim is not listening on a socket", {
      "Start nvim with `--listen <path>` or set `vim.fn.serverstart()` in your config.",
      "Without a listen socket the MCP bridge cannot attach to this nvim instance.",
    })
    return
  end

  health.ok(string.format("Neovim listen socket: `%s`", servername))

  local env = vim.env.NVIM_LISTEN_ADDRESS

  if env == nil or env == "" then
    health.info("`NVIM_LISTEN_ADDRESS` is unset — set it in your shell so MCP `mcps.json` can reference the same path.")
    return
  end

  if env ~= servername then
    health.warn(string.format("`NVIM_LISTEN_ADDRESS=%s` does not match the actual listen socket `%s`", env, servername), {
      "MCP entries that interpolate `$NVIM_LISTEN_ADDRESS` (or copies of the value into `mcps.json`) will hit the wrong nvim.",
      "Either restart nvim with `--listen $NVIM_LISTEN_ADDRESS` or update the env var to match `:echo v:servername`.",
    })
    return
  end

  health.ok("`NVIM_LISTEN_ADDRESS` matches the listen socket")
end

local function check_mcp()
  local ok, mcp = pcall(require, "hyprpilot.mcp")
  if not ok then
    health.warn("`hyprpilot.mcp` failed to load: " .. tostring(mcp))
    return
  end

  local tools_ok, tools = pcall(mcp.list)
  if not tools_ok then
    health.warn("`hyprpilot.mcp.list()` raised: " .. tostring(tools))
    return
  end

  local count = type(tools) == "table" and #tools or 0

  if count == 0 then
    health.info("MCP bridge enabled but no tools registered (use `require('hyprpilot.mcp').register({...})`).")
  else
    health.ok(string.format("MCP bridge enabled with %d tool%s registered", count, count == 1 and "" or "s"))
  end
end

function M.check()
  health.start("hyprpilot.nvim")

  check_nvim_version()
  check_socket()
  check_daemon_version()
  check_listen_socket()
  check_mcp()
end

return M
