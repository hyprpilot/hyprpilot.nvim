--- Thin wrapper over the daemon's `completion/{query,resolve,cancel}`
--- RPCs. Keeps the camelCase ↔ snake_case translation + parameter
--- shaping in one place so multiple per-completion-engine adapters
--- can share the same wire contract.
---
--- Wire shapes mirror `agent-client-protocol-schema` /
--- `src-tauri/src/completion/dispatch.rs`:
---   completion/query   → { requestId, sourceId, replacementRange, items }
---   completion/resolve → { documentation }
---   completion/cancel  → { cancelled }

local client = require("hyprpilot.client")
local config = require("hyprpilot.config")
local log = require("hyprpilot.log")

local M = {}

---@class hyprpilot.completion.QueryParams
---@field text string                       -- prefix the cursor sits in (composer line)
---@field cursor integer                    -- byte offset into `text`
---@field cwd? string                       -- working directory (default: vim.fn.getcwd())
---@field manual? boolean                   -- captain-triggered (true) vs typing (false)
---@field sources? string[]                 -- override `config.completion.sources`
---@field associated? hyprpilot.completion.AssociatedBuffer
--- Captain's "real" working buffer — the file they were editing
--- before opening the chat. Forwards to daemon-side sources so a
--- ripgrep / file source can scope its search to the captain's
--- current file rather than `cwd`-wide. Mirrors codecompanion's
--- `chat.buffer_context.bufnr` concept.

---@class hyprpilot.completion.AssociatedBuffer
---@field path? string         -- absolute path of the buffer the captain was in
---@field filetype? string     -- buffer filetype (helps daemon pick a parser / scope)

---@class hyprpilot.completion.Item
---@field label string
---@field detail? string
---@field kind? string                      -- "path" | "skills" | etc
---@field replacement table                 -- { range = { start, end }, text }
---@field resolve_id? string                -- token to round-trip through `completion/resolve`

---@class hyprpilot.completion.Response
---@field request_id string
---@field source_id? string
---@field replacement_range? { start: integer, ["end"]: integer }
---@field items hyprpilot.completion.Item[]

---@param wire table
---@return hyprpilot.completion.Item
local function item_from_wire(wire)
  return {
    label = wire.label,
    detail = wire.detail,
    kind = wire.kind,
    replacement = wire.replacement,
    resolve_id = wire.resolveId,
  }
end

---@param wire table
---@return hyprpilot.completion.Response
local function response_from_wire(wire)
  return {
    request_id = wire.requestId,
    source_id = wire.sourceId,
    replacement_range = wire.replacementRange,
    items = type(wire.items) == "table" and vim.tbl_map(item_from_wire, wire.items) or {},
  }
end

---Fire `completion/query`. `callback` gets `(err, response)`.
---@param params hyprpilot.completion.QueryParams
---@param callback fun(err: hyprpilot.client.RpcError?, response: hyprpilot.completion.Response?): nil
function M.query(params, callback)
  local sources = params.sources or (config.options.completion or {}).sources or { "skills" }

  -- Resolve associated-buffer context lazily when the caller didn't
  -- pass one — `chat.window.associated_bufnr()` returns the captain's
  -- last working buffer. Sources that don't need it (the daemon's
  -- skills source, etc.) ignore the field.
  local associated = params.associated
  if associated == nil then
    local ok, window = pcall(require, "hyprpilot.chat.window")
    if ok then
      local bufnr = window.associated_bufnr and window.associated_bufnr() or nil
      if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
        associated = {
          path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p"),
          filetype = vim.bo[bufnr].filetype,
        }
        if associated.path == "" then
          associated = nil
        end
      end
    end
  end

  local payload = {
    text = params.text,
    cursor = params.cursor,
    cwd = params.cwd or vim.fn.getcwd(),
    manual = params.manual == true,
    sources = sources,
  }
  if associated ~= nil then
    payload.associated = associated
  end

  client.request("completion/query", payload, nil, function(err, result)
    if err ~= nil then
      callback(err, nil)
      return
    end
    callback(nil, response_from_wire(result or {}))
  end)
end

---Fire `completion/resolve`. Returns the lazy documentation for a
---previously-queried item. `callback` gets `(err, documentation)`.
---@param resolve_id string
---@param source_id? string
---@param callback fun(err: hyprpilot.client.RpcError?, documentation: string?): nil
function M.resolve(resolve_id, source_id, callback)
  client.request(
    "completion/resolve",
    {
      resolveId = resolve_id,
      sourceId = source_id,
    },
    nil,
    function(err, result)
      if err ~= nil then
        callback(err, nil)
        return
      end
      callback(nil, (result and result.documentation) or "")
    end
  )
end

---Fire `completion/cancel`. Best-effort; daemon returns false when
---the request_id is unknown or already finished.
---@param request_id string
---@param callback? fun(err: hyprpilot.client.RpcError?, cancelled: boolean?): nil
function M.cancel(request_id, callback)
  client.request("completion/cancel", { requestId = request_id }, nil, function(err, result)
    if callback == nil then
      if err ~= nil then
        log.debug("completion.cancel: %s", err.message)
      end
      return
    end
    if err ~= nil then
      callback(err, nil)
      return
    end
    callback(nil, result and result.cancelled == true)
  end)
end

return M
