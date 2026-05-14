--- Built-in `editor_*` MCP tools — buffer state, workspace
--- discovery, cursor context. Captain wires what they want from
--- their config:
---
---     require("hyprpilot.mcp.editor").register_all()
---
---     -- or selective:
---     local mcp = require("hyprpilot.mcp")
---     local editor = require("hyprpilot.mcp.editor").tools
---     mcp.register(editor.cursor)
---     mcp.register(editor.read)

local mcp = require("hyprpilot.mcp")

local M = {}

---@param msg string
---@return hyprpilot.mcp.RichResult
local function err(msg)
  return { is_error = true, text = msg }
end

---Resolve a file path to an absolute path against `cwd`. Doesn't
---require the file to exist (so tools can return "not loaded"
---instead of crashing on `bufadd`).
---@param path string
---@return string
local function abs_path(path)
  local resolved = vim.fs.normalize(path)
  if resolved:sub(1, 1) ~= "/" then
    resolved = vim.fs.normalize(vim.fn.getcwd() .. "/" .. resolved)
  end
  return resolved
end

----------------------------------------------------------------------
-- Tools
----------------------------------------------------------------------

M.tools = {}

M.tools.cursor = {
  name = "editor_cursor",
  description = "Return what the captain is currently looking at: cursor position, buffer path / filetype, visible line range, window dimensions.",
  schema = { type = "object", additionalProperties = false },
  handler = function()
    local winid = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local cursor = vim.api.nvim_win_get_cursor(winid)
    return {
      json = {
        bufnr = bufnr,
        path = vim.api.nvim_buf_get_name(bufnr),
        filetype = vim.bo[bufnr].filetype,
        modified = vim.bo[bufnr].modified,
        line = cursor[1] - 1, -- 0-indexed for parity with LSP tools
        character = cursor[2],
        visible = {
          first_line = vim.fn.line("w0", winid) - 1,
          last_line = vim.fn.line("w$", winid) - 1,
          total_lines = vim.api.nvim_buf_line_count(bufnr),
        },
      },
    }
  end,
}

M.tools.buffers = {
  name = "editor_buffers",
  description = "List every loaded, listed buffer with its path, filetype, modified flag, and bufnr. Skips plugin / scratch buffers (`buftype != ''`).",
  schema = {
    type = "object",
    properties = {
      include_unlisted = {
        type = "boolean",
        description = "Include unlisted buffers (`buflisted = false`). Defaults to false.",
      },
    },
    additionalProperties = false,
  },
  handler = function(args)
    local include_unlisted = args.include_unlisted == true
    local out = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        local listed = vim.bo[bufnr].buflisted
        local buftype = vim.bo[bufnr].buftype
        if (listed or include_unlisted) and buftype == "" then
          table.insert(out, {
            bufnr = bufnr,
            path = vim.api.nvim_buf_get_name(bufnr),
            filetype = vim.bo[bufnr].filetype,
            modified = vim.bo[bufnr].modified,
            line_count = vim.api.nvim_buf_line_count(bufnr),
          })
        end
      end
    end
    return { json = { buffers = out } }
  end,
}

M.tools.read = {
  name = "editor_read",
  description = "Read the contents of a file from its open buffer (so unsaved changes are visible). Loads the file into a hidden buffer if not yet open. Optional `start_line` / `end_line` (0-indexed, inclusive) clip the range.",
  schema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "File path (absolute or cwd-relative).",
      },
      start_line = {
        type = "integer",
        description = "First line to return (0-indexed, inclusive). Default 0.",
      },
      end_line = {
        type = "integer",
        description = "Last line to return (0-indexed, inclusive). Default end-of-file.",
      },
    },
    required = { "path" },
    additionalProperties = false,
  },
  handler = function(args)
    local resolved = abs_path(args.path)
    if vim.fn.filereadable(resolved) ~= 1 then
      -- Maybe it's already a buffer with no on-disk file. Look for a
      -- live buffer with that name before failing.
      local existing = vim.fn.bufnr(resolved)
      if existing == -1 then
        return err("file not readable: " .. resolved)
      end
    end
    local bufnr = vim.fn.bufadd(resolved)
    if not vim.api.nvim_buf_is_loaded(bufnr) then
      vim.fn.bufload(bufnr)
    end
    local total = vim.api.nvim_buf_line_count(bufnr)
    local first = math.max(0, args.start_line or 0)
    local last = args.end_line ~= nil and (args.end_line + 1) or total
    last = math.min(total, last)
    if last <= first then
      return { json = { path = resolved, bufnr = bufnr, lines = {}, total_lines = total } }
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, first, last, false)
    return {
      json = {
        path = resolved,
        bufnr = bufnr,
        start_line = first,
        end_line = first + #lines - 1,
        total_lines = total,
        modified = vim.bo[bufnr].modified,
        text = table.concat(lines, "\n"),
      },
    }
  end,
}

---Resolve the grep command. Prefers ripgrep when available,
---fallbacks to vim's built-in `vimgrep` via `:vimgrep` so the
---tool still works on a captain who doesn't ship rg.
---@return string[]?, string?  -- argv-style command, or nil + reason
local function resolve_grep_cmd(pattern, glob, max_results)
  if vim.fn.executable("rg") == 1 then
    local cmd = {
      "rg",
      "--vimgrep",
      "--no-heading",
      "--smart-case",
      "--max-count=" .. tostring(max_results),
    }
    if glob ~= nil and glob ~= "" then
      table.insert(cmd, "--glob")
      table.insert(cmd, glob)
    end
    table.insert(cmd, pattern)
    return cmd, nil
  end
  return nil, "ripgrep (`rg`) not on PATH; install it for editor_grep / editor_files"
end

M.tools.grep = {
  name = "editor_grep",
  description = "Search the workspace (cwd) for `pattern` via ripgrep. Returns matches with `path`, `line`, `character`, and the matching line text. `glob` filters by path pattern; `max_results` caps total hits (default 200).",
  schema = {
    type = "object",
    properties = {
      pattern = {
        type = "string",
        description = "Regex (smart-case). Use `\\b` word boundaries for symbol search.",
      },
      glob = {
        type = "string",
        description = "Path glob filter (e.g. `**/*.lua`, `!**/node_modules/**`). Empty = no filter.",
      },
      max_results = {
        type = "integer",
        description = "Cap on total hits returned. Default 200.",
      },
    },
    required = { "pattern" },
    additionalProperties = false,
  },
  handler = function(args)
    if type(args.pattern) ~= "string" or args.pattern == "" then
      return err("pattern must be a non-empty string")
    end
    local max_results = args.max_results or 200
    local cmd, why = resolve_grep_cmd(args.pattern, args.glob, max_results)
    if cmd == nil then
      return err(why)
    end
    local result = vim.system(cmd, { text = true, cwd = vim.fn.getcwd() }):wait(5000)
    if result.code ~= 0 and result.code ~= 1 then -- 1 = no matches
      return err(string.format("rg exited %d: %s", result.code, (result.stderr or ""):sub(1, 500)))
    end
    local matches = {}
    for line in (result.stdout or ""):gmatch("[^\n]+") do
      -- rg --vimgrep: path:line:col:text
      local path, lnum, col, text = line:match("^([^:]+):(%d+):(%d+):(.*)$")
      if path ~= nil then
        table.insert(matches, {
          path = abs_path(path),
          line = tonumber(lnum) - 1,
          character = tonumber(col) - 1,
          text = text,
        })
        if #matches >= max_results then
          break
        end
      end
    end
    return { json = { matches = matches, count = #matches, truncated = #matches >= max_results } }
  end,
}

M.tools.files = {
  name = "editor_files",
  description = "List files in the workspace matching an optional glob. Uses ripgrep's file walker (respects `.gitignore`). Returns paths relative to cwd; cap via `max_results` (default 500).",
  schema = {
    type = "object",
    properties = {
      glob = {
        type = "string",
        description = "Path glob filter (e.g. `**/*.lua`). Empty = every tracked file.",
      },
      max_results = {
        type = "integer",
        description = "Cap on total paths returned. Default 500.",
      },
    },
    additionalProperties = false,
  },
  handler = function(args)
    if vim.fn.executable("rg") ~= 1 then
      return err("ripgrep (`rg`) not on PATH; install it for editor_files")
    end
    local max_results = args.max_results or 500
    local cmd = { "rg", "--files" }
    if type(args.glob) == "string" and args.glob ~= "" then
      table.insert(cmd, "--glob")
      table.insert(cmd, args.glob)
    end
    local result = vim.system(cmd, { text = true, cwd = vim.fn.getcwd() }):wait(5000)
    if result.code ~= 0 then
      return err(string.format("rg --files exited %d: %s", result.code, (result.stderr or ""):sub(1, 500)))
    end
    local paths = {}
    for path in (result.stdout or ""):gmatch("[^\n]+") do
      table.insert(paths, path)
      if #paths >= max_results then
        break
      end
    end
    return { json = { paths = paths, count = #paths, truncated = #paths >= max_results } }
  end,
}

---Register every tool in `M.tools`. Idempotent.
function M.register_all()
  for _, tool in pairs(M.tools) do
    mcp.register(tool)
  end
end

return M
