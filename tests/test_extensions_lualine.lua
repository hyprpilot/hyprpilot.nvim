--- Behavioural tests for the lualine extension. We bypass lualine
--- itself (not a hard dep) and exercise the format helper plus the
--- autocmd wiring directly.

local T = MiniTest.new_set()

T["format renders a connected pill with no instance / activity"] = function()
  local lualine = require("hyprpilot.extensions.lualine")
  local out = lualine.format({ connection = "connected", activity = { kind = "idle" } })

  MiniTest.expect.equality(out:find("hyprpilot", 1, true) ~= nil, true)
  MiniTest.expect.equality(out:find("●", 1, true) ~= nil, true)
end

T["format includes the active instance when set"] = function()
  local lualine = require("hyprpilot.extensions.lualine")
  local out = lualine.format({
    connection = "connected",
    active_instance = "main",
    activity = { kind = "idle" },
  })

  MiniTest.expect.equality(out:find("main", 1, true) ~= nil, true)
end

T["format surfaces the active tool name"] = function()
  local lualine = require("hyprpilot.extensions.lualine")
  local out = lualine.format({
    connection = "connected",
    activity = { kind = "tool", tool_name = "bash" },
  })

  MiniTest.expect.equality(out:find("tool · bash", 1, true) ~= nil, true)
end

T["format surfaces awaiting-permission activity"] = function()
  local lualine = require("hyprpilot.extensions.lualine")
  local out = lualine.format({
    connection = "connected",
    activity = { kind = "awaiting_permission" },
  })

  MiniTest.expect.equality(out:find("permission?", 1, true) ~= nil, true)
end

T["format glyph reflects disconnect"] = function()
  local lualine = require("hyprpilot.extensions.lualine")
  local out = lualine.format({ connection = "disconnected", activity = { kind = "idle" } })

  -- Open circle for disconnected.
  MiniTest.expect.equality(out:find("○", 1, true) ~= nil, true)
end

T["calling the module returns a non-empty string"] = function()
  local lualine = require("hyprpilot.extensions.lualine")
  local out = lualine()

  MiniTest.expect.equality(type(out), "string")
  MiniTest.expect.equality(#out > 0, true)
end

T["calling the module installs the User Hyprpilot* autocmd group"] = function()
  local lualine = require("hyprpilot.extensions.lualine")
  lualine()

  local autocmds = vim.api.nvim_get_autocmds({ group = "HyprpilotLualine" })
  MiniTest.expect.equality(#autocmds > 0, true)
end

return T
