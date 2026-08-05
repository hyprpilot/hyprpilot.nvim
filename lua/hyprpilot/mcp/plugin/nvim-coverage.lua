--- `plugin_nvim_coverage_*` MCP tools — parsed test coverage. Wire from
--- your config:
---
---     require("hyprpilot.mcp.plugin.nvim-coverage").register()
---
--- `nvim-coverage` already knows how to find and parse this project's
--- coverage file, whatever the format. Reading its cache means the
--- agent never has to know whether the project emits lcov, cobertura,
--- or a language-specific dialect.

local plugin = require("hyprpilot.mcp.plugin")

local M = {}

M.tools = {}

M.tools.report = {
  name = "plugin_nvim_coverage_report",
  description = "Return the parsed coverage report nvim-coverage holds — per-file line coverage in whatever shape the language's parser produced. Set `load` to parse the project's coverage file first when nothing is cached.",
  schema = {
    type = "object",
    properties = {
      load = {
        type = "boolean",
        description = "Parse the coverage file before reading, when no report is cached yet. Defaults to false — loading is asynchronous, so the first call may still come back empty.",
      },
    },
    additionalProperties = false,
  },
  handler = function(args)
    local report = require("coverage.report")

    if not report.is_cached() and args.load == true then
      -- `load` populates the cache through an async job; the agent gets
      -- an empty report this round and a full one next time rather than
      -- the handler blocking the editor waiting for it.
      pcall(function()
        require("coverage").load(false)
      end)
    end

    if not report.is_cached() then
      return {
        json = {
          cached = false,
          reason = "no coverage report loaded — run the project's coverage task, then call again with load = true",
        },
      }
    end

    return { json = { cached = true, language = report.language(), report = report.get() } }
  end,
}

M.register = plugin.registrar(M.tools, "coverage")

return M
