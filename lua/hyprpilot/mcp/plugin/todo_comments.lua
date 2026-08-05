--- `plugin_todo_*` MCP tools — the captain's TODO / FIXME index. Wire
--- from your config:
---
---     require("hyprpilot.mcp.plugin.todo_comments").register()
---
--- `editor_grep` could find these too, but only if the agent guessed
--- the captain's keyword set and comment pattern correctly. This drives
--- todo-comments' own configured regex instead, so the results match
--- what the captain sees highlighted in their buffers.

local plugin = require("hyprpilot.mcp.plugin")

local M = {}

M.tools = {}

M.tools.search = {
  name = "plugin_todo_search",
  description = "Search the workspace for TODO / FIXME / HACK style comments using todo-comments' own configured keywords and pattern. Returns each hit with path, 0-indexed line, keyword, and text.",
  schema = {
    type = "object",
    properties = {
      keywords = {
        type = "array",
        items = { type = "string" },
        description = "Restrict to these keywords (e.g. `FIX`, `TODO`, `HACK`). Omit for every configured keyword.",
      },
      cwd = {
        type = "string",
        description = "Directory to search. Defaults to the editor's cwd.",
      },
      max_results = {
        type = "integer",
        description = "Cap on hits returned. Default 200.",
      },
    },
    additionalProperties = false,
  },
  handler = function(args)
    local search = require("todo-comments.search")

    -- The search shells out through plenary's Job and reports via
    -- callback, so the handler waits on the result rather than
    -- returning an empty list the agent would read as "none found".
    local results, done = nil, false
    search.search(function(found)
      results = found
      done = true
    end, {
      keywords = type(args.keywords) == "table" and #args.keywords > 0 and args.keywords or nil,
      cwd = args.cwd,
      disable_not_found_warnings = true,
    })

    if not vim.wait(5000, function()
      return done
    end, 25) then
      return plugin.err("todo-comments search timed out after 5s")
    end

    local cap = (type(args.max_results) == "number" and args.max_results >= 1) and math.floor(args.max_results) or 200
    local todos = {}
    for _, hit in ipairs(results or {}) do
      table.insert(todos, {
        path = hit.filename,
        line = hit.lnum ~= nil and (hit.lnum - 1) or nil, -- 0-indexed, matching editor_grep
        character = hit.col ~= nil and math.max(0, hit.col - 1) or nil,
        keyword = hit.tag,
        text = hit.text,
      })
    end

    return {
      json = {
        todos = vim.list_slice(todos, 1, cap),
        count = math.min(#todos, cap),
        truncated = #todos > cap,
      },
    }
  end,
}

M.register = plugin.registrar(M.tools, "todo-comments")

return M
