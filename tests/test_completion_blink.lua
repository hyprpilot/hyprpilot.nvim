--- Behavioural tests for the blink.cmp completion source. We stub
--- `client.request` to capture the wire calls + drive synthetic
--- responses, then drive the provider's `get_completions` /
--- `resolve` lifecycle the way blink.cmp does at runtime.

local T = MiniTest.new_set()

---@param replies table<string, { err?: table, result?: any }>
---@return fun(), table[]
local function stub_client_with(replies)
  local client = require("hyprpilot.client")
  local original = client.request
  local calls = {}

  client.request = function(method, params, _opts, callback)
    table.insert(calls, { method = method, params = params })
    local r = replies[method]
    if r == nil then
      callback({ kind = "transport", message = "unstubbed RPC: " .. method }, nil)
      return
    end
    callback(r.err, r.result)
  end

  return function()
    client.request = original
  end, calls
end

---Force the current buffer's filetype to satisfy the provider's
---default `enabled()` gate (composer-buffer only).
---@return fun()
local function stub_composer_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].filetype = "hyprpilot_input"
  local prev_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  return function()
    if vim.api.nvim_buf_is_valid(prev_buf) then
      vim.api.nvim_set_current_buf(prev_buf)
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
end

T["completion.blink: get_completions fires completion/query with composer cursor state"] = function()
  local restore_buf = stub_composer_buffer()
  local restore_client, calls = stub_client_with({
    ["completion/query"] = {
      result = {
        requestId = "req-1",
        sourceId = "skills",
        items = {
          {
            label = "git-commit",
            detail = "conventional commits",
            kind = "skills",
            replacement = { range = { start = 0, ["end"] = 4 }, text = "git-commit" },
            resolveId = "git-commit",
          },
          { label = "git-push", kind = "skills", replacement = { range = { start = 0, ["end"] = 4 }, text = "git-push" } },
        },
      },
    },
  })

  local Provider = require("hyprpilot.completion.blink")
  local source = Provider.new()

  local result
  source:get_completions({
    line = "git ",
    cursor = { 1, 4 },
    trigger = { kind = "trigger_character" },
  }, function(r)
    result = r
  end)

  -- One query RPC fired; default sources from config came through.
  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].method, "completion/query")
  MiniTest.expect.equality(calls[1].params.text, "git ")
  MiniTest.expect.equality(calls[1].params.cursor, 4)
  MiniTest.expect.equality(calls[1].params.manual, false)
  MiniTest.expect.equality(calls[1].params.sources[1], "skills")

  -- Items mapped: label preserved, kind translated to LSP enum,
  -- textEdit synthesised from replacement.range for the first item.
  MiniTest.expect.equality(#result.items, 2)
  MiniTest.expect.equality(result.items[1].label, "git-commit")
  MiniTest.expect.equality(result.items[1].kind, 14) -- Keyword (skills mapping)
  MiniTest.expect.equality(result.items[1].textEdit.newText, "git-commit")
  MiniTest.expect.equality(result.items[1].textEdit.range.start.character, 0)
  MiniTest.expect.equality(result.items[1].textEdit.range["end"].character, 4)
  -- resolve_id forwarded onto data so :resolve can round-trip.
  MiniTest.expect.equality(result.items[1].data.resolve_id, "git-commit")
  MiniTest.expect.equality(result.items[1].data.source_id, "skills")

  restore_client()
  restore_buf()
end

T["completion.blink: query failure → empty items, no crash"] = function()
  local restore_buf = stub_composer_buffer()
  local restore_client = stub_client_with({
    ["completion/query"] = { err = { kind = "transport", message = "boom" } },
  })

  local Provider = require("hyprpilot.completion.blink")
  local source = Provider.new()

  local result
  source:get_completions({
    line = "x",
    cursor = { 1, 1 },
  }, function(r)
    result = r
  end)

  MiniTest.expect.equality(#result.items, 0)

  restore_client()
  restore_buf()
end

T["completion.blink: enabled() is false outside the composer buffer"] = function()
  -- Default (no `enabled` override): provider only fires when the
  -- current buffer's filetype is `hyprpilot_input`.
  local Provider = require("hyprpilot.completion.blink")
  local source = Provider.new()

  -- We're in a vanilla buffer — gate must be off.
  MiniTest.expect.equality(source:enabled(), false)
end

T["completion.blink: opts.sources overrides config.completion.sources"] = function()
  local restore_buf = stub_composer_buffer()
  local restore_client, calls = stub_client_with({
    ["completion/query"] = { result = { requestId = "req", items = {} } },
  })

  local Provider = require("hyprpilot.completion.blink")
  local source = Provider.new({ sources = { "skills", "commands" } })

  source:get_completions({
    line = "@",
    cursor = { 1, 1 },
    trigger = { kind = "trigger_character" },
  }, function() end)

  MiniTest.expect.equality(calls[1].params.sources[1], "skills")
  MiniTest.expect.equality(calls[1].params.sources[2], "commands")

  restore_client()
  restore_buf()
end

T["completion.blink: resolve fires completion/resolve and attaches markdown documentation"] = function()
  local restore_client, calls = stub_client_with({
    ["completion/resolve"] = { result = { documentation = "**git-commit**\n\nConventional commits skill." } },
  })

  local Provider = require("hyprpilot.completion.blink")
  local source = Provider.new()

  local resolved
  source:resolve({
    label = "git-commit",
    data = { resolve_id = "git-commit", source_id = "skills" },
  }, function(r)
    resolved = r
  end)

  MiniTest.expect.equality(calls[1].method, "completion/resolve")
  MiniTest.expect.equality(calls[1].params.resolveId, "git-commit")
  MiniTest.expect.equality(calls[1].params.sourceId, "skills")
  MiniTest.expect.equality(resolved.documentation.kind, "markdown")
  MiniTest.expect.equality(resolved.documentation.value, "**git-commit**\n\nConventional commits skill.")

  restore_client()
end

T["completion.blink: resolve passes through when item has no resolve_id"] = function()
  local restore_client, calls = stub_client_with({})

  local Provider = require("hyprpilot.completion.blink")
  local source = Provider.new()

  local resolved
  source:resolve({ label = "no-resolve", data = {} }, function(r)
    resolved = r
  end)

  MiniTest.expect.equality(#calls, 0)
  MiniTest.expect.equality(resolved.label, "no-resolve")

  restore_client()
end

return T
