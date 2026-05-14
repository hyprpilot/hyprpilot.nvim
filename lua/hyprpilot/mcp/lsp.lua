--- Built-in `lsp_*` MCP tools (plus `diagnostics_get`, since
--- diagnostics is a sibling concern of LSP). Captain wires what
--- they want from their config:
---
---     require("hyprpilot.mcp.lsp").register_all()
---
---     -- or selective:
---     local mcp = require("hyprpilot.mcp")
---     local lsp = require("hyprpilot.mcp.lsp").tools
---     mcp.register(lsp.definition)
---     mcp.register(lsp.hover)
---     mcp.register(lsp.diagnostics_get)
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

local DEFAULT_TIMEOUT_MS = 2000

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
  end
  return bufnr, nil
end

---Get LSP clients attached to `bufnr` that support `method`. Empty
---list when no client advertises the capability — caller surfaces
---a clean error instead of silently round-tripping nothing.
---@param bufnr integer
---@param method string
---@return vim.lsp.Client[]
local function clients_for(bufnr, method)
  return vim.lsp.get_clients({ bufnr = bufnr, method = method })
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
---@param bufnr integer
---@param method string
---@param build_params fun(client: vim.lsp.Client): table
---@param timeout_ms? integer
---@return table[] results, integer client_count
local function request_all_sync(bufnr, method, build_params, timeout_ms)
  local results = {}
  local clients = clients_for(bufnr, method)
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

---Flatten a list of `{ client, result }` LSP location hits to the
---quickfix-friendly `{ filename, lnum, col, text }` shape. Uses each
---client's offset encoding so multi-encoding setups don't
---mis-translate columns.
---@param hits { client: vim.lsp.Client, result: any }[]
---@return table[]
local function locations_to_items(hits)
  local items = {}
  for _, hit in ipairs(hits) do
    local converted = vim.lsp.util.locations_to_items(vim.islist(hit.result) and hit.result or { hit.result }, hit.client.offset_encoding)
    for _, item in ipairs(converted) do
      table.insert(items, item)
    end
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
            table.insert(parts, "")
            table.insert(parts, "---")
            table.insert(parts, "")
          end
          for _, line in ipairs(lines) do
            table.insert(parts, line)
          end
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
      local converted = vim.lsp.util.symbols_to_items(hit.result or {}, bufnr, hit.client.offset_encoding)
      for _, item in ipairs(converted) do
        table.insert(symbols, item)
      end
    end
    return { json = { symbols = symbols } }
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
    },
    required = { "query" },
    additionalProperties = false,
  },
  handler = function(args)
    if type(args.query) ~= "string" then
      return err("query must be a string")
    end
    local bufnr = vim.api.nvim_get_current_buf()
    local hits, client_count = request_all_sync(bufnr, "workspace/symbol", function()
      return { query = args.query }
    end)
    if client_count == 0 then
      return err("no LSP client supports workspace/symbol")
    end
    local symbols = {}
    for _, hit in ipairs(hits) do
      for _, item in ipairs(vim.lsp.util.symbols_to_items(hit.result or {}, nil, hit.client.offset_encoding)) do
        table.insert(symbols, item)
      end
    end
    return { json = { symbols = symbols } }
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
    local touched = 0
    for _ in pairs(response.result.changes or {}) do
      touched = touched + 1
    end
    for _ in ipairs(response.result.documentChanges or {}) do
      touched = touched + 1
    end
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

    local diagnostics = vim.diagnostic.get(bufnr, opts)
    local out = {}
    for _, d in ipairs(diagnostics) do
      table.insert(out, {
        path = vim.api.nvim_buf_get_name(d.bufnr),
        line = d.lnum,
        character = d.col,
        end_line = d.end_lnum,
        end_character = d.end_col,
        severity = SEVERITY_NAMES[d.severity] or tostring(d.severity),
        message = d.message,
        source = d.source,
        code = d.code,
      })
    end
    return { json = { diagnostics = out } }
  end,
}

---Register every tool in `M.tools` against the central `mcp`
---registry. Idempotent — each name overwrites any prior entry.
function M.register_all()
  for _, tool in pairs(M.tools) do
    mcp.register(tool)
  end
end

return M
