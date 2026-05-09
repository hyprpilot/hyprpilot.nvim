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

local function check_plenary()
  local ok = pcall(require, "plenary")

  if ok then
    health.ok("`plenary.nvim` is installed")
  else
    health.error("`plenary.nvim` is not installed", { "Install `nvim-lua/plenary.nvim` and add it as a dependency." })
  end
end

local function check_socket()
  local config = require("hyprpilot.config").options
  local socket = config.socket or default_socket_path()

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

function M.check()
  health.start("hyprpilot.nvim")

  check_nvim_version()
  check_plenary()
  check_socket()
end

return M
