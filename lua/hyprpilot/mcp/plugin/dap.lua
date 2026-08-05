--- `plugin_dap_*` MCP tools — the debugger's live state. Wire from
--- your config:
---
---     require("hyprpilot.mcp.plugin.dap").register()
---
--- Reads only what the session already holds. `nvim-dap` is
--- callback-driven throughout, and an MCP handler is synchronous, so
--- these tools report the cached thread / frame state rather than
--- issuing fresh requests to the adapter and waiting on them.

local plugin = require("hyprpilot.mcp.plugin")

local M = {}

---Shape one `dap.StackFrame` into the location shape the rest of the
---server returns, so an agent can feed it straight to `editor_jump`.
---@param frame table
---@return table
local function frame_item(frame)
  local source = frame.source or {}

  return {
    id = frame.id,
    name = frame.name,
    path = source.path,
    line = frame.line ~= nil and (frame.line - 1) or nil, -- 0-indexed, matching the LSP tools
    character = frame.column ~= nil and math.max(0, frame.column - 1) or nil,
    presentation_hint = frame.presentationHint,
  }
end

M.tools = {}

M.tools.status = {
  name = "plugin_dap_status",
  description = "Report whether a debug session is live, what it is debugging, and whether it is stopped at a breakpoint. Cheap orientation call before asking for a stack.",
  schema = { type = "object", additionalProperties = false },
  handler = function()
    local dap = require("dap")
    local session = dap.session()
    if session == nil then
      return { json = { active = false } }
    end

    local frame = session.current_frame
    return {
      json = {
        active = true,
        id = session.id,
        filetype = session.filetype,
        adapter = session.config ~= nil and session.config.type or nil,
        configuration = session.config ~= nil and session.config.name or nil,
        stopped = session.stopped_thread_id ~= nil,
        stopped_thread_id = session.stopped_thread_id,
        current_frame = frame ~= nil and frame_item(frame) or nil,
        session_count = vim.tbl_count(dap.sessions()),
      },
    }
  end,
}

M.tools.stack = {
  name = "plugin_dap_stack",
  description = "Return the threads of the live debug session and the stack frames the debugger has already reported, each with a 0-indexed file position. Empty frames mean the thread is running, not that it has none.",
  schema = {
    type = "object",
    properties = {
      thread_id = {
        type = "integer",
        description = "Report one thread only. Defaults to every known thread.",
      },
    },
    additionalProperties = false,
  },
  handler = function(args)
    local session = require("dap").session()
    if session == nil then
      return plugin.err("no debug session is running")
    end

    local threads = {}
    for id, thread in pairs(session.threads or {}) do
      if args.thread_id == nil or args.thread_id == id then
        local frames = {}
        for _, frame in ipairs(thread.frames or {}) do
          table.insert(frames, frame_item(frame))
        end
        table.insert(threads, {
          id = id,
          name = thread.name,
          stopped = thread.stopped == true,
          frames = frames,
        })
      end
    end
    if #threads == 0 and args.thread_id ~= nil then
      return plugin.err("no such thread in the current session: " .. tostring(args.thread_id))
    end

    return { json = { threads = threads, stopped_thread_id = session.stopped_thread_id } }
  end,
}

M.register = plugin.registrar(M.tools, "dap")

return M
