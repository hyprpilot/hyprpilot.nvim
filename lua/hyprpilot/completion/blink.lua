--- blink.cmp source provider for hyprpilot daemon completions.
---
--- Captain wires:
---
---   require("blink.cmp").setup({
---     sources = {
---       default = { "hyprpilot", "lsp", "buffer" },
---       providers = {
---         hyprpilot = {
---           name = "hyprpilot",
---           module = "hyprpilot.completion.blink",
---           score_offset = 100,                    -- blink.cmp-native provider boost
---           opts = {
---             sources = { "skills" },              -- optional source filter
---             score_offset = 100,                  -- per-item boost (default: 100)
---           },
---         },
---       },
---     },
---   })
---
--- The source only completes inside the composer buffer (filetype
--- `hyprpilot_composer`) — other buffers should keep their native LSP /
--- path / buffer providers as the source of truth. Captain can
--- widen the activation predicate via `opts.enabled`.
---
--- Two priority knobs cooperate to keep hyprpilot items above peer
--- providers (LSP / buffer / path) when both match the captain's
--- prefix:
---   - `opts.score_offset` (default 100): added to every item we hand
---     back. Wins cross-provider ranking in the merged result list.
---     Pass `0` to opt out.
---   - `score_offset` on the blink.cmp provider entry: the engine-
---     native knob; relevant for grouped menu layouts
---     (`completion.menu.draw.grouped`) where per-item offsets don't
---     change cross-provider grouping.
---
--- Wire RPCs flow through `completion.wire` so future per-engine
--- adapters can share the same contract.

local config = require("hyprpilot.config")
local log = require("hyprpilot.log")
local wire = require("hyprpilot.completion.wire")

---@class hyprpilot.completion.blink.Provider
---@field opts hyprpilot.completion.blink.Opts
local Provider = {}
Provider.__index = Provider

---@class hyprpilot.completion.blink.Opts
---@field sources? string[]                       -- override config.completion.sources for this provider
---@field enabled? fun(): boolean                 -- override default `filetype == "hyprpilot_composer"` gate
---@field manual_only? boolean                    -- only emit completions when blink invokes us with `manual` context
---@field score_offset? integer                   -- per-item score boost (default 100); set to 0 to rank by raw fuzzy score

-- blink.cmp's CompletionItemKind enum. Map our wire `kind` string
-- onto a sensible LSP kind so blink can render its icon column.
-- `Text` is the safe default for anything we don't recognise.
local KIND = {
  text = 1,
  path = 17, -- File
  file = 17,
  folder = 19,
  skills = 14, -- Keyword (no first-class "skill" kind in LSP)
  skill = 14,
  command = 8, -- Function
  snippet = 15,
}

---Build a fresh provider. blink.cmp calls this once per source entry
---in `sources.providers`.
---@param opts hyprpilot.completion.blink.Opts?
---@return hyprpilot.completion.blink.Provider
function Provider.new(opts)
  return setmetatable({ opts = opts or {} }, Provider)
end

---Default gate: only fire inside the hyprpilot composer buffer.
---Captain overrides via `opts.enabled`.
---@return boolean
function Provider:enabled()
  if self.opts.enabled ~= nil then
    return self.opts.enabled()
  end
  local bufnr = vim.api.nvim_get_current_buf()
  -- Dotted-aware: composer's ft is `hyprpilot_composer.markdown`
  -- (alias so cmp/snippet sources keyed to "markdown" inherit).
  -- Plain `==` comparison would miss the composer entirely.
  return require("hyprpilot.chat.buffer").has_filetype(bufnr, "hyprpilot_composer")
end

---blink.cmp asks for completions. `ctx` carries cursor + line state;
---`callback` accepts a result table the source produced. We round-
---trip through `completion/query` and translate the wire `items[]`
---to blink's expected shape.
---@param ctx table  -- blink context (line, cursor, trigger.kind)
---@param callback fun(result: { items: table[], is_incomplete_forward?: boolean, is_incomplete_backward?: boolean })
function Provider:get_completions(ctx, callback)
  if self.opts.manual_only and ctx.trigger and ctx.trigger.kind ~= "manual" then
    callback({ items = {} })
    return
  end

  -- ctx.line is the current line; ctx.cursor[2] is the 0-indexed
  -- byte column. The daemon's `text`/`cursor` contract matches
  -- (full line + byte offset).
  local line = ctx.line or vim.api.nvim_get_current_line()
  local cursor_col = (ctx.cursor and ctx.cursor[2]) or vim.fn.col(".") - 1

  wire.query({
    text = line,
    cursor = cursor_col,
    manual = ctx.trigger and ctx.trigger.kind == "manual" or false,
    sources = self.opts.sources or (config.options.completion or {}).sources,
  }, function(err, response)
    if err ~= nil then
      log.debug("completion.blink: query failed: %s", err.message)
      callback({ items = {} })
      return
    end

    local source_id = response and response.source_id
    local score_offset = self.opts.score_offset or 100
    local items = {}
    for _, wire_item in ipairs((response and response.items) or {}) do
      local replacement = wire_item.replacement or {}
      local range = replacement.range
      local item = {
        label = wire_item.label,
        kind = KIND[(wire_item.kind or ""):lower()] or KIND.text,
        detail = wire_item.detail,
        -- Pin hyprpilot items above peer providers (LSP / buffer /
        -- path) in the merged result list. Captain opts out with
        -- `opts = { score_offset = 0 }`.
        score_offset = score_offset,
        -- Carry the resolveId on the item so `:resolve` can fetch
        -- the lazy documentation. Blink passes the same item back.
        data = {
          resolve_id = wire_item.resolve_id,
          source_id = source_id,
        },
      }
      -- When the daemon ships a replacement range, translate to
      -- blink's `textEdit` so the snippet replaces the right span
      -- (e.g. the `@skill-` partial the captain has typed so far).
      if range ~= nil then
        local row = ctx.cursor and (ctx.cursor[1] - 1) or vim.fn.line(".") - 1
        item.textEdit = {
          newText = replacement.text or wire_item.label,
          range = {
            start = { line = row, character = range.start },
            ["end"] = { line = row, character = range["end"] },
          },
        }
      else
        item.insertText = replacement.text or wire_item.label
      end
      table.insert(items, item)
    end

    callback({ items = items })
  end)
end

---blink.cmp asks for resolved item documentation. Round-trip through
---`completion/resolve` when the item carries a `data.resolve_id`.
---@param item table
---@param callback fun(resolved: table)
function Provider:resolve(item, callback)
  local data = item.data or {}
  if data.resolve_id == nil then
    callback(item)
    return
  end

  wire.resolve(data.resolve_id, data.source_id, function(err, documentation)
    if err ~= nil then
      log.debug("completion.blink: resolve failed: %s", err.message)
      callback(item)
      return
    end
    item.documentation = {
      kind = "markdown",
      value = documentation or "",
    }
    callback(item)
  end)
end

return Provider
