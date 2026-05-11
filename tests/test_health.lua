--- Behavioural tests for `:checkhealth hyprpilot`. We capture the
--- `vim.health.*` calls instead of running the real reporter so the
--- test suite can run without a TUI.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

local function capture_health(check_fn)
  local recorded = {}
  local original = {
    start = vim.health.start,
    ok = vim.health.ok,
    info = vim.health.info,
    warn = vim.health.warn,
    error = vim.health.error,
  }

  for level, _ in pairs(original) do
    vim.health[level] = function(msg, advice)
      table.insert(recorded, { level = level, msg = msg, advice = advice })
    end
  end

  local ok, err = pcall(check_fn)

  for level, fn in pairs(original) do
    vim.health[level] = fn
  end

  if not ok then
    error(err)
  end

  return recorded
end

local function find_message(records, level, substring)
  for _, r in ipairs(records) do
    if r.level == level and type(r.msg) == "string" and r.msg:find(substring, 1, true) ~= nil then
      return r
    end
  end
  return nil
end

T["check reports nvim version"] = function()
  local health_mod = require("hyprpilot.health")
  local records = capture_health(health_mod.check)

  MiniTest.expect.equality(find_message(records, "ok", "Neovim") ~= nil, true)
end

T["check warns when daemon socket missing"] = function()
  -- Override the configured socket to a path that definitely does
  -- not exist so the file-stat check fails predictably.
  local config = require("hyprpilot.config")
  local original_socket = config.options.socket
  config.options.socket = "/tmp/hyprpilot-nonexistent-" .. tostring(vim.uv.hrtime()) .. ".sock"

  local health_mod = require("hyprpilot.health")
  local records = capture_health(health_mod.check)

  config.options.socket = original_socket

  MiniTest.expect.equality(find_message(records, "warn", "Daemon socket not reachable") ~= nil, true)
end

T["check reports MCP info when no tools registered"] = function()
  -- The mcp registry persists across tests; clear it to be sure.
  local mcp = require("hyprpilot.mcp")
  if type(mcp._reset) == "function" then
    mcp._reset()
  end

  local health_mod = require("hyprpilot.health")
  local records = capture_health(health_mod.check)

  -- Either an `info` "no tools registered" or an `ok` with N tools is
  -- acceptable depending on whether earlier tests left registrations
  -- behind; the message must mention MCP either way.
  local mcp_record = find_message(records, "info", "MCP") or find_message(records, "ok", "MCP")
  MiniTest.expect.equality(mcp_record ~= nil, true)
end

T["check reports MCP disabled when config flag is false"] = function()
  local config = require("hyprpilot.config")
  local original = config.options.mcp
  config.options.mcp = { enabled = false }

  local health_mod = require("hyprpilot.health")
  local records = capture_health(health_mod.check)

  config.options.mcp = original

  MiniTest.expect.equality(find_message(records, "info", "MCP bridge disabled") ~= nil, true)
end

T["render does not insert an empty pilot header before a captain prompt"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  render.hydrate(state, {
    items = {
      { turnId = "t1", item = { kind = "user_prompt", text = "kick off" } },
      { turnId = "t1", item = { kind = "agent_text", text = "got it" } },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- The user (captain) prompt should appear BEFORE the agent (pilot)
  -- header. Find both positions and assert the order.
  local captain_idx, pilot_idx
  for i, l in ipairs(lines) do
    if l == "## captain" and captain_idx == nil then
      captain_idx = i
    elseif l == "## pilot" and pilot_idx == nil then
      pilot_idx = i
    end
  end

  MiniTest.expect.equality(captain_idx ~= nil, true)
  MiniTest.expect.equality(pilot_idx ~= nil, true)
  MiniTest.expect.equality(captain_idx < pilot_idx, true)

  helpers.cleanup_instance(id)
end

return T
