--- Built-in `lsp_*` MCP tools (plus `diagnostics_get`, since
--- diagnostics is a sibling concern of LSP). Captain wires what
--- they want from their config:
---
---     require("hyprpilot.mcp.lsp").register()
---
---     -- or a subset:
---     require("hyprpilot.mcp.lsp").register({
---       items = { "definition", "hover", "diagnostics_get" },
---     })
---
--- Why these tools live as registered tools and not Python-side
--- bridge primitives: agent profiles need allow / deny / auto-allow
--- discrimination per tool name (`lsp_hover` is read-only,
--- `lsp_rename` mutates), and the captain owns that policy on the
--- daemon side. Shipping them as registry entries on the Lua side
--- keeps the policy granularity intact.
---
--- API choices vetted against Neovim 0.11+:
---   * Per-client `client:request_sync(method, params, timeout, bufnr)`
---     — `vim.lsp.buf_request_sync` is soft-deprecated.
---   * `make_text_document_params(bufnr)` + manual `position` —
---     `make_position_params()` ignores `bufnr` and uses the
---     current window, which is the wrong file when an MCP call
---     names a different one.
---   * `client.offset_encoding` carried into every position-shaping
---     and result-shaping helper — different clients on the same
---     buffer can disagree (e.g. pyright = utf-16, clangd = utf-8).
---   * `vim.fn.bufadd` + `vim.fn.bufload` only — let core's
---     `BufReadPost` autocmd attach configured clients via
---     `vim.lsp.start`. No manual `didOpen` plumbing.

local log = require("hyprpilot.log")
local mcp = require("hyprpilot.mcp")

local M = {}

-- Tool names this category currently has in the registry. `register`
-- overrides against this so a re-register with a smaller `items` list
-- drops the tools that fell out of the selection.
local registered = {}

-- LSP client names the tools skip when servicing a request, configured
-- via `register({ disabled_lsps = ... })`. Empty by default.
local disabled_lsps = {}

local DEFAULT_TIMEOUT_MS = 2000

-- How long the first request against a freshly loaded buffer waits for
-- a client to finish attaching before giving up on it.
local ATTACH_TIMEOUT_MS = 2000

-- Buffers this module loaded whose LSP attach may still be in flight.
-- Cleared the first time a request looks them up, so the wait is paid
-- at most once per buffer.
local pending_attach = {}

---@param msg string
---@return hyprpilot.mcp.RichResult
local function err(msg)
  return { is_error = true, text = msg }
end

---Resolve a file path to a buffer number, loading the file if it's
---not already in a buffer. Used by every position-bearing tool so
---the agent can name a file by path without the captain having to
---open it first.
---@param path string
---@return integer? bufnr, string? err_msg
local function ensure_loaded(path)
  if type(path) ~= "string" or path == "" then
    return nil, "path must be a non-empty string"
  end
  local resolved = vim.fs.normalize(path)
  if resolved:sub(1, 1) ~= "/" then
    resolved = vim.fs.normalize(vim.fn.getcwd() .. "/" .. resolved)
  end
  if vim.fn.filereadable(resolved) ~= 1 then
    return nil, "file not readable: " .. resolved
  end
  -- `bufadd` is idempotent — returns the existing bufnr when one
  -- already holds the file. `bufload` is the trigger that fires
  -- `BufReadPost` so configured LSP clients auto-attach.
  local bufnr = vim.fn.bufadd(resolved)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
    -- The attach this fires is asynchronous; mark the buffer so the
    -- first request against it is willing to wait for a client.
    pending_attach[bufnr] = true
  end
  return bufnr, nil
end

---Get LSP clients supporting `method`, scoped to `bufnr` when one is
---given and session-wide when it isn't. Empty list when no client
---advertises the capability — caller surfaces a clean error instead
---of silently round-tripping nothing.
---@param bufnr integer? nil for workspace-wide methods
---@param method string
---@return vim.lsp.Client[]
local function clients_for(bufnr, method)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
  if #disabled_lsps == 0 then
    return clients
  end

  return vim.tbl_filter(function(client)
    return not vim.tbl_contains(disabled_lsps, client.name)
  end, clients)
end

---Wait for a client supporting `method` to attach to `bufnr`. Loading
---a file fires the attach but doesn't finish it, so the first request
---against a freshly adopted buffer used to report "no LSP client
---attached" while the second — issued moments later — worked.
---
---Only a buffer this module just loaded is worth waiting on, and only
---once: `vim.wait` runs the main loop, so an unconditional wait would
---freeze the captain's editor on every request against a filetype that
---has no configured server at all.
---@param bufnr integer
---@param method string
---@return vim.lsp.Client[]
local function await_clients(bufnr, method)
  local clients = clients_for(bufnr, method)
  if #clients > 0 or not pending_attach[bufnr] then
    pending_attach[bufnr] = nil
    return clients
  end
  vim.wait(ATTACH_TIMEOUT_MS, function()
    clients = clients_for(bufnr, method)
    return #clients > 0
  end, 50)
  pending_attach[bufnr] = nil

  return clients
end

---Build the `textDocument/<method>` position params for `bufnr` +
---`{ line, character }` (0-indexed). Per-client construction kept
---as the call shape (rather than building once outside the loop)
---so future callers that need `client.offset_encoding`-aware
---column re-encoding have a place to plug it in.
---@param _client vim.lsp.Client
---@param bufnr integer
---@param line integer
---@param character integer
---@return table
local function position_params(_client, bufnr, line, character)
  return {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = line, character = character },
  }
end

---Run a sync LSP request across every capability-supporting client.
---Concatenates list-shaped results (definition, references,
---documentSymbol, codeAction). Per-client errors are logged at
---`debug` and skipped — the agent gets the union of what worked.
---@param bufnr integer? nil for workspace-wide methods, which look up
---clients session-wide instead of per buffer
---@param method string
---@param build_params fun(client: vim.lsp.Client): table
---@param timeout_ms? integer
---@return table[] results, integer client_count
local function request_all_sync(bufnr, method, build_params, timeout_ms)
  local results = {}
  local clients
  if bufnr == nil then
    clients = clients_for(nil, method)
  else
    clients = await_clients(bufnr, method)
  end
  for _, client in ipairs(clients) do
    local response, request_err = client:request_sync(method, build_params(client), timeout_ms or DEFAULT_TIMEOUT_MS, bufnr)
    if request_err ~= nil then
      log.debug("mcp.lsp: %s on %s failed: %s", method, client.name, request_err)
    elseif response ~= nil then
      if response.err ~= nil then
        log.debug("mcp.lsp: %s on %s rpc error: %s", method, client.name, vim.inspect(response.err))
      elseif response.result ~= nil then
        table.insert(results, { client = client, result = response.result })
      end
    end
  end
  return results, #clients
end

---Clip a symbol list to the caller's cap. A malformed `max_results`
---degrades to the default rather than throwing out of the handler —
---`mcp.call` doesn't wrap handlers, so a raw comparison error would
---reach the agent as a Lua traceback.
---@param symbols table[]
---@param max_results any
---@return table
local function capped(symbols, max_results)
  local cap = (type(max_results) == "number" and max_results >= 1) and math.floor(max_results) or 200

  return { symbols = vim.list_slice(symbols, 1, cap), count = math.min(#symbols, cap), truncated = #symbols > cap }
end

---Flatten a list of `{ client, result }` LSP location hits to the
---quickfix-friendly `{ filename, lnum, col, text }` shape. Uses each
---client's offset encoding so multi-encoding setups don't
---mis-translate columns.
---@param hits { client: vim.lsp.Client, result: any }[]
---@return table[]
local function locations_to_items(hits)
  local items = {}
  for _, hit in ipairs(hits) do
    vim.list_extend(items, vim.lsp.util.locations_to_items(vim.islist(hit.result) and hit.result or { hit.result }, hit.client.offset_encoding))
  end
  return items
end

----------------------------------------------------------------------
-- Tool definitions
----------------------------------------------------------------------

M.tools = {}

M.tools.ensure_loaded = {
  name = "lsp_ensure_loaded",
  description = "Open one or more files in hidden buffers so their configured LSP clients attach. Returns the resolved path and bufnr per file.",
  schema = {
    type = "object",
    properties = {
      paths = {
        type = "array",
        items = { type = "string" },
        description = "Absolute or cwd-relative paths to load.",
      },
    },
    required = { "paths" },
    additionalProperties = false,
  },
  handler = function(args)
    if type(args.paths) ~= "table" or #args.paths == 0 then
      return err("paths must be a non-empty array of strings")
    end
    local loaded = {}
    for _, path in ipairs(args.paths) do
      local bufnr, load_err = ensure_loaded(path)
      if bufnr ~= nil then
        table.insert(loaded, { path = vim.api.nvim_buf_get_name(bufnr), bufnr = bufnr })
      else
        table.insert(loaded, { path = path, error = load_err })
      end
    end
    return { json = { loaded = loaded } }
  end,
}

local POSITION_SCHEMA = {
  path = {
    type = "string",
    description = "File the cursor is in (absolute or cwd-relative). Loaded into a hidden buffer if not already open.",
  },
  line = {
    type = "integer",
    description = "0-indexed line number.",
  },
  character = {
    type = "integer",
    description = "0-indexed character offset within the line.",
  },
}

M.tools.definition = {
  name = "lsp_definition",
  description = "Return the definition site(s) for the symbol at `path:line:character`. Aggregates results across every attached LSP client.",
  schema = {
    type = "object",
    properties = POSITION_SCHEMA,
    required = { "path", "line", "character" },
    additionalProperties = false,
  },
  handler = function(args)
    local bufnr, load_err = ensure_loaded(args.path)
    if bufnr == nil then
      return err(load_err)
    end
    local hits, client_count = request_all_sync(bufnr, "textDocument/definition", function(client)
      return position_params(client, bufnr, args.line, args.character)
    end)
    if client_count == 0 then
      return err("no LSP client attached to buffer with textDocument/definition support")
    end
    return { json = { definitions = locations_to_items(hits) } }
  end,
}

M.tools.references = {
  name = "lsp_references",
  description = "Return every reference to the symbol at `path:line:character`, including its declaration.",
  schema = {
    type = "object",
    properties = POSITION_SCHEMA,
    required = { "path", "line", "character" },
    additionalProperties = false,
  },
  handler = function(args)
    local bufnr, load_err = ensure_loaded(args.path)
    if bufnr == nil then
      return err(load_err)
    end
    local hits, client_count = request_all_sync(bufnr, "textDocument/references", function(client)
      local params = position_params(client, bufnr, args.line, args.character)
      params.context = { includeDeclaration = true }
      return params
    end)
    if client_count == 0 then
      return err("no LSP client attached to buffer with textDocument/references support")
    end
    return { json = { references = locations_to_items(hits) } }
  end,
}

M.tools.hover = {
  name = "lsp_hover",
  description = "Return the hover text (signature, doc) for the symbol at `path:line:character`. Markdown-flavoured.",
  schema = {
    type = "object",
    properties = POSITION_SCHEMA,
    required = { "path", "line", "character" },
    additionalProperties = false,
  },
  handler = function(args)
    local bufnr, load_err = ensure_loaded(args.path)
    if bufnr == nil then
      return err(load_err)
    end
    local hits, client_count = request_all_sync(bufnr, "textDocument/hover", function(client)
      return position_params(client, bufnr, args.line, args.character)
    end)
    if client_count == 0 then
      return err("no LSP client attached to buffer with textDocument/hover support")
    end
    -- Concatenate per-client hover sections (separated by `---` so
    -- the agent reads them as distinct documents).
    local parts = {}
    for _, hit in ipairs(hits) do
      if type(hit.result) == "table" and hit.result.contents ~= nil then
        local lines = vim.lsp.util.convert_input_to_markdown_lines(hit.result.contents)
        if type(lines) == "table" and #lines > 0 then
          if #parts > 0 then
            vim.list_extend(parts, { "", "---", "" })
          end
          vim.list_extend(parts, lines)
        end
      end
    end
    if #parts == 0 then
      return { text = "" }
    end
    return { text = table.concat(parts, "\n") }
  end,
}

M.tools.document_symbols = {
  name = "lsp_document_symbols",
  description = "Return the symbol tree for `path` (functions, classes, methods, variables) flattened to a list with kind labels.",
  schema = {
    type = "object",
    properties = {
      path = POSITION_SCHEMA.path,
      kinds = {
        type = "array",
        items = { type = "string" },
        description = "Symbol kinds to keep (`Function`, `Method`, `Class`, …). Empty = every kind.",
      },
      max_results = {
        type = "integer",
        description = "Cap on symbols returned. Default 200.",
      },
    },
    required = { "path" },
    additionalProperties = false,
  },
  handler = function(args)
    local bufnr, load_err = ensure_loaded(args.path)
    if bufnr == nil then
      return err(load_err)
    end
    local hits, client_count = request_all_sync(bufnr, "textDocument/documentSymbol", function(_client)
      return { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
    end)
    if client_count == 0 then
      return err("no LSP client attached to buffer with textDocument/documentSymbol support")
    end
    -- The LSP wire returns either `DocumentSymbol[]` (recursive,
    -- includes a `range` field) or `SymbolInformation[]` (flat,
    -- references a `location`). `symbols_to_items` handles both.
    local symbols = {}
    for _, hit in ipairs(hits) do
      vim.list_extend(symbols, vim.lsp.util.symbols_to_items(hit.result or {}, bufnr, hit.client.offset_encoding))
    end
    if type(args.kinds) == "table" and #args.kinds > 0 then
      symbols = vim.tbl_filter(function(symbol)
        return vim.tbl_contains(args.kinds, symbol.kind)
      end, symbols)
    end
    return { json = capped(symbols, args.max_results) }
  end,
}

M.tools.workspace_symbols = {
  name = "lsp_workspace_symbols",
  description = "Search every attached LSP server for symbols matching `query`. Empty query returns the server's idea of the full symbol catalogue (usually rate-limited).",
  schema = {
    type = "object",
    properties = {
      query = {
        type = "string",
        description = "Symbol name fragment to search for. Empty string returns everything the server's willing to report.",
      },
      max_results = {
        type = "integer",
        description = "Cap on symbols returned. Default 200.",
      },
    },
    required = { "query" },
    additionalProperties = false,
  },
  handler = function(args)
    if type(args.query) ~= "string" then
      return err("query must be a string")
    end
    -- Session-wide, not current-buffer: the captain's focus is usually
    -- a terminal or picker with no client attached, and scoping the
    -- lookup there reported "no client" while their language server sat
    -- attached to every source buffer in the workspace.
    local hits, client_count = request_all_sync(nil, "workspace/symbol", function()
      return { query = args.query }
    end)
    if client_count == 0 then
      return err("no LSP client supports workspace/symbol")
    end
    local symbols = {}
    for _, hit in ipairs(hits) do
      vim.list_extend(symbols, vim.lsp.util.symbols_to_items(hit.result or {}, nil, hit.client.offset_encoding))
    end
    return { json = capped(symbols, args.max_results) }
  end,
}

M.tools.code_actions = {
  name = "lsp_code_actions",
  description = "Return the code actions available for the line at `path:line` (refactor / quickfix / source). Doesn't apply them — agent inspects + asks the captain.",
  schema = {
    type = "object",
    properties = {
      path = POSITION_SCHEMA.path,
      line = POSITION_SCHEMA.line,
    },
    required = { "path", "line" },
    additionalProperties = false,
  },
  handler = function(args)
    local bufnr, load_err = ensure_loaded(args.path)
    if bufnr == nil then
      return err(load_err)
    end
    local line_text = vim.api.nvim_buf_get_lines(bufnr, args.line, args.line + 1, false)[1] or ""
    local hits, client_count = request_all_sync(bufnr, "textDocument/codeAction", function(_client)
      return {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
        range = {
          start = { line = args.line, character = 0 },
          ["end"] = { line = args.line, character = #line_text },
        },
        context = {
          diagnostics = vim.lsp.diagnostic.from(vim.diagnostic.get(bufnr, { lnum = args.line })),
        },
      }
    end)
    if client_count == 0 then
      return err("no LSP client attached to buffer with textDocument/codeAction support")
    end
    local actions = {}
    for _, hit in ipairs(hits) do
      for _, action in ipairs(hit.result or {}) do
        table.insert(actions, {
          title = action.title,
          kind = action.kind,
          is_preferred = action.isPreferred == true,
          client = hit.client.name,
        })
      end
    end
    return { json = { code_actions = actions } }
  end,
}

M.tools.rename = {
  name = "lsp_rename",
  description = "Rename the symbol at `path:line:character` to `new_name` across every file the LSP server touches. Mutates buffers; the captain's profile policy decides whether to auto-allow.",
  schema = {
    type = "object",
    properties = {
      path = POSITION_SCHEMA.path,
      line = POSITION_SCHEMA.line,
      character = POSITION_SCHEMA.character,
      new_name = {
        type = "string",
        description = "The replacement name. Must be a valid identifier in the source language.",
      },
    },
    required = { "path", "line", "character", "new_name" },
    additionalProperties = false,
  },
  handler = function(args)
    if type(args.new_name) ~= "string" or args.new_name == "" then
      return err("new_name must be a non-empty string")
    end
    local bufnr, load_err = ensure_loaded(args.path)
    if bufnr == nil then
      return err(load_err)
    end
    -- One client only — applying the same WorkspaceEdit twice would
    -- double-edit. Pick the first client that advertises rename.
    local clients = clients_for(bufnr, "textDocument/rename")
    if #clients == 0 then
      return err("no LSP client attached to buffer with textDocument/rename support")
    end
    local client = clients[1]
    local response, request_err = client:request_sync("textDocument/rename", {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position = { line = args.line, character = args.character },
      newName = args.new_name,
    }, DEFAULT_TIMEOUT_MS, bufnr)
    if request_err ~= nil then
      return err("rename request failed: " .. request_err)
    end
    if response == nil or response.err ~= nil then
      return err("rename rpc error: " .. (response and vim.inspect(response.err) or "no response"))
    end
    if response.result == nil then
      return { text = "no rename edits returned" }
    end
    vim.lsp.util.apply_workspace_edit(response.result, client.offset_encoding)
    -- Count touched files for the agent's report.
    local touched = vim.tbl_count(response.result.changes or {}) + #(response.result.documentChanges or {})
    return { json = { renamed = true, touched_files = touched, client = client.name } }
  end,
}

local SEVERITY_NAMES = {
  [vim.diagnostic.severity.ERROR] = "error",
  [vim.diagnostic.severity.WARN] = "warn",
  [vim.diagnostic.severity.INFO] = "info",
  [vim.diagnostic.severity.HINT] = "hint",
}

M.tools.diagnostics_get = {
  name = "diagnostics_get",
  description = "Return diagnostics for `path` (or every loaded buffer when omitted). Optional `severity` (`error` / `warn` / `info` / `hint`) filters the result.",
  schema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "File path. Omit to query every loaded buffer.",
      },
      severity = {
        type = "string",
        enum = { "error", "warn", "info", "hint" },
        description = "Lower bound on severity to return. Omit for all.",
      },
    },
    additionalProperties = false,
  },
  handler = function(args)
    local opts = {}
    if type(args.severity) == "string" then
      local lookup = {
        error = vim.diagnostic.severity.ERROR,
        warn = vim.diagnostic.severity.WARN,
        info = vim.diagnostic.severity.INFO,
        hint = vim.diagnostic.severity.HINT,
      }
      local sev = lookup[args.severity:lower()]
      if sev == nil then
        return err("unknown severity: " .. tostring(args.severity))
      end
      opts.severity = { min = sev }
    end

    local bufnr = nil
    if type(args.path) == "string" and args.path ~= "" then
      local loaded, load_err = ensure_loaded(args.path)
      if loaded == nil then
        return err(load_err)
      end
      bufnr = loaded
    end

    local out = vim.tbl_map(function(d)
      return {
        path = vim.api.nvim_buf_get_name(d.bufnr),
        line = d.lnum,
        character = d.col,
        end_line = d.end_lnum,
        end_character = d.end_col,
        severity = SEVERITY_NAMES[d.severity] or tostring(d.severity),
        message = d.message,
        source = d.source,
        code = d.code,
      }
    end, vim.diagnostic.get(bufnr, opts))
    return { json = { diagnostics = out } }
  end,
}

---Register the LSP tools against the central `mcp` registry.
---Idempotent — each name overwrites any prior entry.
---
---     require("hyprpilot.mcp.lsp").register()
---     require("hyprpilot.mcp.lsp").register({
---       items = { "definition", "hover" },
---       disabled_lsps = { "copilot", "null-ls" },
---     })
---
---@class hyprpilot.mcp.lsp.RegisterOpts
---@field items? string[]          -- `M.tools` keys to register; all when omitted
---@field disabled_lsps? string[]  -- LSP client names the tools skip when servicing a request
---@param opts? hyprpilot.mcp.lsp.RegisterOpts
function M.register(opts)
  opts = opts or {}

  disabled_lsps = opts.disabled_lsps or {}

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
        log.warn("mcp.lsp.register: unknown tool %q", name)
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
