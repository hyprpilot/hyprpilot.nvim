--- Built-in `editor_*` MCP tools — buffer state, workspace
--- discovery, cursor context. Captain wires what they want from
--- their config:
---
---     require("hyprpilot.mcp.editor").register()
---
---     -- a subset, plus windows navigation should route around:
---     require("hyprpilot.mcp.editor").register({
---       items = { "cursor", "read" },
---       disabled_filetypes = { "neo-tree", "qf" },
---       disabled_buffer_types = { "terminal" },
---     })

local log = require("hyprpilot.log")
local mcp = require("hyprpilot.mcp")

local M = {}

-- Windows the agent's navigation should route around, configured via
-- `register({ disabled_filetypes = ..., disabled_buffer_types = ... })`.
-- Empty by default; the captain typically feeds their editor-wide
-- exclusion lists (file explorers, terminals, quickfix, etc.).
local disabled_filetypes = {}
local disabled_buffer_types = {}

-- Tool names this category currently has in the registry. `register`
-- overrides against this so a re-register with a smaller `items` list
-- drops the tools that fell out of the selection.
local registered = {}

---@param winid integer
---@return boolean
local function is_floating(winid)
  local config = vim.api.nvim_win_get_config(winid)
  return config.relative ~= nil and config.relative ~= ""
end

---True when `winid` shows a buffer whose filetype or buftype is on the
---configured exclusion lists — a file op there would clobber a surface
---the captain doesn't treat as an editor window.
---@param winid integer
---@return boolean
local function is_disabled(winid)
  local bufnr = vim.api.nvim_win_get_buf(winid)
  return vim.tbl_contains(disabled_filetypes, vim.bo[bufnr].filetype) or vim.tbl_contains(disabled_buffer_types, vim.bo[bufnr].buftype)
end

---A window suitable for file navigation: the current one unless it's a
---floating popup (snacks picker, diff preview, telescope) or on the
---disabled lists, in which case the first window that is neither. nil
---when no such window is visible.
---@return integer?
local function editor_winid()
  local current = vim.api.nvim_get_current_win()
  if not is_floating(current) and not is_disabled(current) then
    return current
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and not is_floating(winid) and not is_disabled(winid) then
      return winid
    end
  end
  return nil
end

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
    local winid = editor_winid()
    if winid == nil then
      return { json = { available = false, reason = "no editor window visible — only floating windows open" } }
    end
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local cursor = vim.api.nvim_win_get_cursor(winid)
    return {
      json = {
        available = true,
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

---Resolve the buffer the action should target. Search order:
---  1. `bufnr` (if provided + valid)
---  2. `path` (open / adopt by absolute path)
---  3. The editor window's buffer (skipping floating popups)
---  4. Current buffer (last-resort fallback when only floats are open)
---Returns `(bufnr, err)`.
---@param args { bufnr?: integer, path?: string }
---@return integer?, string?
local function resolve_target_bufnr(args)
  if type(args.bufnr) == "number" and vim.api.nvim_buf_is_valid(args.bufnr) then
    return args.bufnr, nil
  end
  if type(args.path) == "string" and args.path ~= "" then
    local resolved = abs_path(args.path)
    local existing = vim.fn.bufnr(resolved)
    if existing ~= -1 then
      return existing, nil
    end
    -- Adopt-by-add: bufadd creates a hidden buffer for the path
    -- without focusing it. The caller's "open / focus" verbs run
    -- their own `nvim_set_current_buf` afterward.
    if vim.fn.filereadable(resolved) ~= 1 then
      return nil, "file not readable: " .. resolved
    end
    local bufnr = vim.fn.bufadd(resolved)
    if not vim.api.nvim_buf_is_loaded(bufnr) then
      vim.fn.bufload(bufnr)
    end
    return bufnr, nil
  end
  local winid = editor_winid()
  if winid ~= nil then
    return vim.api.nvim_win_get_buf(winid), nil
  end
  return vim.api.nvim_get_current_buf(), nil
end

M.tools.status = {
  name = "editor_status",
  description = "Captain's full editor snapshot: current mode, focused buffer (path / filetype / cursor / line count / modified), and every loaded listed buffer. One round-trip to orient the agent before any read / jump.",
  schema = {
    type = "object",
    properties = {
      include_unlisted = {
        type = "boolean",
        description = "Include unlisted buffers in the `buffers` list. Defaults to false.",
      },
    },
    additionalProperties = false,
  },
  handler = function(args)
    local include_unlisted = args.include_unlisted == true
    local winid = editor_winid()
    local focused
    if winid ~= nil then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local cursor = vim.api.nvim_win_get_cursor(winid)
      focused = {
        bufnr = bufnr,
        path = vim.api.nvim_buf_get_name(bufnr),
        filetype = vim.bo[bufnr].filetype,
        modified = vim.bo[bufnr].modified,
        line = cursor[1] - 1,
        character = cursor[2],
        line_count = vim.api.nvim_buf_line_count(bufnr),
      }
    end

    local buffers = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        local listed = vim.bo[b].buflisted
        local buftype = vim.bo[b].buftype
        if (listed or include_unlisted) and buftype == "" then
          table.insert(buffers, {
            bufnr = b,
            path = vim.api.nvim_buf_get_name(b),
            filetype = vim.bo[b].filetype,
            modified = vim.bo[b].modified,
            visible = vim.fn.bufwinid(b) ~= -1,
          })
        end
      end
    end

    return {
      json = {
        mode = vim.api.nvim_get_mode().mode,
        cwd = vim.fn.getcwd(),
        focused = focused,
        buffers = buffers,
      },
    }
  end,
}

---Center the cursor on screen + open any folds that hide the row.
---Mirror of the `zz` mapping the captain reaches for after a jump.
---@param winid integer
local function center_cursor(winid)
  vim.api.nvim_win_call(winid, function()
    pcall(vim.cmd, "normal! zvzz")
  end)
end

---Resolve the window the agent's navigation should land in. Routes
---away from floating popups so an `editor_file_open` fired while a
---picker or completion float is focused doesn't hijack the popup.
---Search order:
---  1. Current window, if not floating.
---  2. First non-floating window in the tab.
---  3. New `:topleft new` split (last resort — only floats were open).
---Caller is responsible for `nvim_win_set_buf` afterward; we return
---the winid only.
---@return integer
local function resolve_editor_winid()
  local found = editor_winid()
  if found ~= nil then
    return found
  end
  -- Only floating windows visible — open a real one. `topleft new`
  -- lands the new split at the top of the editor area; the agent's
  -- `nvim_win_set_buf` then swaps the empty unnamed buffer for the
  -- requested file.
  vim.cmd("topleft new")
  return vim.api.nvim_get_current_win()
end

M.tools.file_open = {
  name = "editor_file_open",
  description = "Open a file in the captain's window. Reuses an existing buffer if the path is already loaded; loads + focuses otherwise. Optional `line` (1-indexed) + `character` (0-indexed) jump the cursor on arrival.",
  schema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Absolute or cwd-relative file path.",
      },
      line = {
        type = "integer",
        description = "1-indexed line to jump to. Clamped to the file's line count. Optional.",
      },
      character = {
        type = "integer",
        description = "0-indexed column to jump to. Defaults to 0. Ignored without `line`.",
      },
    },
    required = { "path" },
    additionalProperties = false,
  },
  handler = function(args)
    local target, why = resolve_target_bufnr({ path = args.path })
    if target == nil then
      return err(why or "could not resolve target buffer")
    end

    local winid = resolve_editor_winid()
    pcall(vim.api.nvim_win_set_buf, winid, target)

    local jumped_line, jumped_col
    if type(args.line) == "number" then
      local max_lines = vim.api.nvim_buf_line_count(target)
      jumped_line = math.max(1, math.min(args.line, max_lines))
      jumped_col = math.max(0, args.character or 0)
      pcall(vim.api.nvim_win_set_cursor, winid, { jumped_line, jumped_col })
      center_cursor(winid)
    end

    return {
      json = {
        bufnr = target,
        path = vim.api.nvim_buf_get_name(target),
        line = jumped_line and (jumped_line - 1) or nil,
        character = jumped_col,
      },
    }
  end,
}

M.tools.jump = {
  name = "editor_jump",
  description = "Move the cursor to a line / column in a buffer. Defaults to the current buffer; `path` or `bufnr` overrides. Doesn't load files that aren't already buffers (use `editor_file_open` for that).",
  schema = {
    type = "object",
    properties = {
      line = {
        type = "integer",
        description = "1-indexed line. Clamped to the buffer's line count.",
      },
      character = {
        type = "integer",
        description = "0-indexed column. Defaults to 0.",
      },
      path = {
        type = "string",
        description = "Target by file path (absolute or cwd-relative). Optional.",
      },
      bufnr = {
        type = "integer",
        description = "Target by bufnr. Takes precedence over `path` when both are given.",
      },
    },
    required = { "line" },
    additionalProperties = false,
  },
  handler = function(args)
    local target, why = resolve_target_bufnr(args)
    if target == nil then
      return err(why or "could not resolve target buffer")
    end

    local winid = resolve_editor_winid()
    if vim.api.nvim_win_get_buf(winid) ~= target then
      pcall(vim.api.nvim_win_set_buf, winid, target)
    end

    local max_lines = vim.api.nvim_buf_line_count(target)
    local line = math.max(1, math.min(args.line, max_lines))
    local col = math.max(0, args.character or 0)
    pcall(vim.api.nvim_win_set_cursor, winid, { line, col })
    center_cursor(winid)

    return {
      json = {
        bufnr = target,
        path = vim.api.nvim_buf_get_name(target),
        line = line - 1,
        character = col,
      },
    }
  end,
}

M.tools.select = {
  name = "editor_select",
  description = "Visually select an inclusive range of lines (line-wise visual mode). Defaults to the current buffer; `path` or `bufnr` overrides.",
  schema = {
    type = "object",
    properties = {
      start_line = {
        type = "integer",
        description = "1-indexed first line of the selection.",
      },
      end_line = {
        type = "integer",
        description = "1-indexed last line of the selection (inclusive).",
      },
      path = {
        type = "string",
        description = "Target by file path. Optional.",
      },
      bufnr = {
        type = "integer",
        description = "Target by bufnr. Takes precedence over `path` when both are given.",
      },
    },
    required = { "start_line", "end_line" },
    additionalProperties = false,
  },
  handler = function(args)
    local target, why = resolve_target_bufnr(args)
    if target == nil then
      return err(why or "could not resolve target buffer")
    end

    local winid = resolve_editor_winid()
    if vim.api.nvim_win_get_buf(winid) ~= target then
      pcall(vim.api.nvim_win_set_buf, winid, target)
    end

    local max_lines = vim.api.nvim_buf_line_count(target)
    local start_line = math.max(1, math.min(args.start_line, max_lines))
    local end_line = math.max(start_line, math.min(args.end_line, max_lines))

    -- Drive line-wise visual selection from the start row, then
    -- extend down to the end row INSIDE the same normal-mode
    -- command — `V<end_line>Gzv` enters visual mode and jumps to
    -- `end_line` as the selection's other anchor in one keystroke.
    -- The previous shape (`V` followed by `nvim_win_set_cursor`)
    -- exited visual mode the moment the cursor moved, leaving the
    -- captain with the wrong (single-line) selection.
    vim.api.nvim_win_call(winid, function()
      pcall(vim.api.nvim_win_set_cursor, winid, { start_line, 0 })
      local ok, cmd_err = pcall(vim.cmd, string.format("normal! V%dGzv", end_line))
      if not ok then
        log.warn("editor_select: visual extend failed (bufnr=%s, range=%d-%d): %s", target, start_line, end_line, tostring(cmd_err))
      end
    end)

    return {
      json = {
        bufnr = target,
        path = vim.api.nvim_buf_get_name(target),
        start_line = start_line - 1,
        end_line = end_line - 1,
      },
    }
  end,
}

M.tools.format = {
  name = "editor_format",
  description = "Format a buffer via attached LSP (`vim.lsp.buf.format`, synchronous). Defaults to the current buffer; `path` or `bufnr` overrides. No-op when no LSP client supports formatting on the buffer.",
  schema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Target by file path. Optional.",
      },
      bufnr = {
        type = "integer",
        description = "Target by bufnr. Takes precedence over `path` when both are given.",
      },
      timeout_ms = {
        type = "integer",
        description = "Format request timeout in milliseconds. Default 2000.",
      },
    },
    additionalProperties = false,
  },
  handler = function(args)
    local target, why = resolve_target_bufnr(args)
    if target == nil then
      return err(why or "could not resolve target buffer")
    end

    -- Synchronous format — `async = false` so the response we return
    -- reflects the post-format state of the buffer. Captures any
    -- formatter throw via pcall so a misconfigured LSP doesn't take
    -- the bridge down.
    local ok, format_err = pcall(vim.lsp.buf.format, {
      bufnr = target,
      async = false,
      timeout_ms = args.timeout_ms or 2000,
    })
    if not ok then
      return err("format failed: " .. tostring(format_err))
    end

    return {
      json = {
        bufnr = target,
        path = vim.api.nvim_buf_get_name(target),
        modified = vim.bo[target].modified,
      },
    }
  end,
}

---Register the editor tools and configure window routing. Idempotent —
---re-registering overwrites, so this doubles as a setup entry point.
---
---     -- everything:
---     require("hyprpilot.mcp.editor").register()
---
---     -- a subset + route around the captain's non-editor surfaces:
---     require("hyprpilot.mcp.editor").register({
---       items = { "cursor", "read", "file_open" },
---       disabled_filetypes = { "neo-tree", "qf", "help" },
---       disabled_buffer_types = { "terminal", "prompt" },
---     })
---
---@class hyprpilot.mcp.editor.RegisterOpts
---@field items? string[]                    -- `M.tools` keys to register; all when omitted
---@field disabled_filetypes? string[]       -- filetypes whose windows navigation skips
---@field disabled_buffer_types? string[]    -- buftypes whose windows navigation skips
---@param opts? hyprpilot.mcp.editor.RegisterOpts
function M.register(opts)
  opts = opts or {}

  disabled_filetypes = opts.disabled_filetypes or {}
  disabled_buffer_types = opts.disabled_buffer_types or {}

  ---@type table<string, hyprpilot.mcp.Tool>
  local desired = {}
  if opts.items == nil then
    for _, tool in pairs(M.tools) do
      desired[tool.name] = tool
    end
  else
    for _, name in ipairs(opts.items) do
      local tool = M.tools[name]
      if tool == nil then
        log.warn("mcp.editor.register: unknown tool %q", name)
      else
        desired[tool.name] = tool
      end
    end
  end

  -- Override: drop tools we registered before that fell out of the
  -- selection, then (re)register the desired set (overwrite by name).
  local live = mcp._registry()
  for name in pairs(registered) do
    if desired[name] == nil and live[name] ~= nil then
      mcp.unregister(name)
    end
  end

  registered = {}
  for name, tool in pairs(desired) do
    mcp.register(tool)
    registered[name] = true
  end
end

return M
