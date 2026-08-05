--- Behavioural tests for `hyprpilot.mcp.lsp`. These exercise the
--- tool-spec shape (name / schema / register wiring) and the
--- non-LSP-dependent paths (diagnostics_get reads from
--- `vim.diagnostic`, ensure_loaded uses `bufadd` + `bufload`).
---
--- Round-trip LSP requests aren't exercised — the test environment
--- has no language servers attached. The handlers' early-return
--- "no client supports method" path IS exercised, which is the
--- concrete observable behaviour an agent would hit if it asked
--- for a definition in a buffer with no LSP.

local T = MiniTest.new_set()

T["register: every tool in M.tools lands in the registry"] = function()
  local mcp = require("hyprpilot.mcp")
  local lsp = require("hyprpilot.mcp.lsp")
  mcp._reset()

  lsp.register()

  local listed = mcp.list()
  -- Every tool name is `lsp_*` or `diagnostics_*`. There must be at
  -- least one of each prefix.
  local seen_lsp, seen_diag = false, false
  for _, t in ipairs(listed) do
    if t.name:sub(1, 4) == "lsp_" then
      seen_lsp = true
    end
    if t.name:sub(1, 12) == "diagnostics_" then
      seen_diag = true
    end
  end
  MiniTest.expect.equality(seen_lsp, true)
  MiniTest.expect.equality(seen_diag, true)
  MiniTest.expect.equality(#listed, vim.tbl_count(lsp.tools))

  mcp._reset()
end

T["every tool has a non-empty description and a well-formed schema"] = function()
  local lsp = require("hyprpilot.mcp.lsp")
  for key, tool in pairs(lsp.tools) do
    MiniTest.expect.equality(type(tool.name), "string", key .. ": name must be a string")
    MiniTest.expect.equality(type(tool.description), "string", key .. ": description must be a string")
    MiniTest.expect.equality(tool.description ~= "", true, key .. ": description must not be empty")
    MiniTest.expect.equality(tool.schema.type, "object", key .. ": schema.type must be 'object'")
  end
end

T["lsp_definition: no LSP client → clean is_error result"] = function()
  -- Stand up a real readable file in /tmp so `ensure_loaded` succeeds
  -- and we exercise the no-client branch.
  local path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "local x = 1", "return x" }, path)

  local lsp = require("hyprpilot.mcp.lsp")
  local result = lsp.tools.definition.handler({ path = path, line = 0, character = 6 })

  MiniTest.expect.equality(result.is_error, true)
  MiniTest.expect.equality(result.text:find("definition", 1, true) ~= nil, true)

  vim.fn.delete(path)
end

T["lsp_ensure_loaded: returns bufnr for readable file, error for missing"] = function()
  local good = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "return 1" }, good)
  local missing = vim.fn.tempname() .. "-does-not-exist.lua"

  local lsp = require("hyprpilot.mcp.lsp")
  local result = lsp.tools.ensure_loaded.handler({ paths = { good, missing } })

  MiniTest.expect.equality(#result.json.loaded, 2)
  MiniTest.expect.equality(type(result.json.loaded[1].bufnr), "number")
  MiniTest.expect.equality(result.json.loaded[2].error ~= nil, true)

  vim.fn.delete(good)
end

T["diagnostics_get: returns empty list when no diagnostics on a fresh buffer"] = function()
  local path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "return 1" }, path)

  local lsp = require("hyprpilot.mcp.lsp")
  local result = lsp.tools.diagnostics_get.handler({ path = path })

  MiniTest.expect.equality(type(result.json.diagnostics), "table")
  MiniTest.expect.equality(#result.json.diagnostics, 0)

  vim.fn.delete(path)
end

T["diagnostics_get: bad severity → is_error result, doesn't throw"] = function()
  local lsp = require("hyprpilot.mcp.lsp")
  local result = lsp.tools.diagnostics_get.handler({ severity = "kaboom" })

  MiniTest.expect.equality(result.is_error, true)
  MiniTest.expect.equality(result.text:find("severity", 1, true) ~= nil, true)
end

T["lsp_rename: bad new_name (empty) → is_error result"] = function()
  local lsp = require("hyprpilot.mcp.lsp")
  local result = lsp.tools.rename.handler({ path = "/tmp/x.lua", line = 0, character = 0, new_name = "" })

  MiniTest.expect.equality(result.is_error, true)
end

T["the position tools name their own wire method when no client supports it"] = function()
  local path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "local x = 1", "return x" }, path)

  -- Each tool built from the shared factories must report the method it
  -- actually asked for; a copy-paste error there sends the agent looking
  -- at the wrong capability.
  local lsp = require("hyprpilot.mcp.lsp")
  for key, method in pairs({
    type_definition = "typeDefinition",
    implementation = "implementation",
    incoming_calls = "prepareCallHierarchy",
    outgoing_calls = "prepareCallHierarchy",
  }) do
    local result = lsp.tools[key].handler({ path = path, line = 0, character = 6 })
    MiniTest.expect.equality(result.is_error, true, key .. ": expected a no-client error")
    MiniTest.expect.equality(result.text:find(method, 1, true) ~= nil, true, key .. ": error should name " .. method)
  end

  vim.fn.delete(path)
end

T["lsp_document_symbols / lsp_workspace_symbols advertise max_results"] = function()
  local lsp = require("hyprpilot.mcp.lsp")
  MiniTest.expect.equality(lsp.tools.document_symbols.schema.properties.max_results.type, "integer")
  MiniTest.expect.equality(lsp.tools.document_symbols.schema.properties.kinds.type, "array")
  MiniTest.expect.equality(lsp.tools.workspace_symbols.schema.properties.max_results.type, "integer")
end

return T
