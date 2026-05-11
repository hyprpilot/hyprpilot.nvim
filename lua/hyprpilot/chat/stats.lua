--- Generic stat-pill formatting for the chat surface.
---
--- Centralises the formatting rules so every consumer (turn header,
--- section header, tool block header) renders pills the same way:
---
---   `[120k/200k] [$0.74] [3s]`
---
--- Each pill is its own bracketed token; pills are joined with one
--- ASCII space. The renderers all flow through `M.format_pills` so a
--- visual tweak (e.g. switching `[]` to `()` or adding a separator)
--- happens in exactly one place.

local M = {}

---Format an integer token count using k/M suffixes for compactness.
---  120  → `"120"`
---  1234 → `"1.2k"`
---  120000 → `"120k"`
---  1500000 → `"1.5M"`
---@param n integer?
---@return string?
function M.format_tokens(n)
  if type(n) ~= "number" or n < 0 then
    return nil
  end

  if n < 1000 then
    return tostring(math.floor(n))
  end

  if n < 1000000 then
    if n < 10000 then
      return string.format("%.1fk", n / 1000)
    end
    return string.format("%dk", math.floor(n / 1000))
  end

  return string.format("%.1fM", n / 1000000)
end

---Format a millisecond duration. `<1s` shows ms; `<60s` shows
---seconds with one decimal; longer shows `Nm Ss`.
---  234 → `"234ms"`
---  3500 → `"3.5s"`
---  89000 → `"1m29s"`
---@param ms integer?
---@return string?
function M.format_duration(ms)
  if type(ms) ~= "number" or ms < 0 then
    return nil
  end

  if ms < 1000 then
    return string.format("%dms", math.floor(ms))
  end

  if ms < 60000 then
    return string.format("%.1fs", ms / 1000)
  end

  local minutes = math.floor(ms / 60000)
  local seconds = math.floor((ms % 60000) / 1000)
  return string.format("%dm%ds", minutes, seconds)
end

---Format a cost record as `<symbol><amount>` with two decimals.
---Currency mapping: USD → `$`, EUR → `€`; anything else falls through
---as the ISO code so the captain still sees the value.
---@param cost { amount?: number, currency?: string }?
---@return string?
function M.format_cost(cost)
  if type(cost) ~= "table" then
    return nil
  end
  local amount = tonumber(cost.amount)
  if amount == nil then
    return nil
  end

  local symbol = cost.currency
  if symbol == "USD" then
    symbol = "$"
  elseif symbol == "EUR" then
    symbol = "€"
  elseif type(symbol) ~= "string" then
    symbol = ""
  end

  return string.format("%s%.2f", symbol, amount)
end

---Format a `formatted.stats[]` entry from the daemon's wire payload.
---Mirrors the Tauri UI's `ToolPillStats` rendering: text → raw value,
---diff → `+N -M` (skipping zero sides), duration → `format_duration`.
---Returns a list of pill labels (multiple for diffs).
---@param stat table
---@return string[]
function M.format_wire_stat(stat)
  if type(stat) ~= "table" or type(stat.kind) ~= "string" then
    return {}
  end

  if stat.kind == "text" then
    local value = tostring(stat.value or "")
    if value == "" then
      return {}
    end
    return { value }
  elseif stat.kind == "diff" then
    local out = {}
    if (stat.added or 0) > 0 then
      table.insert(out, string.format("+%d", stat.added))
    end
    if (stat.removed or 0) > 0 then
      table.insert(out, string.format("-%d", stat.removed))
    end
    return out
  elseif stat.kind == "duration" then
    local label = M.format_duration(stat.ms)
    return label and { label } or {}
  end

  return {}
end

---Convert an array of `formatted.stats[]` wire entries to a flat list
---of pill labels.
---@param wire_stats table[]?
---@return string[]
function M.from_wire_stats(wire_stats)
  if type(wire_stats) ~= "table" then
    return {}
  end

  local labels = {}
  for _, stat in ipairs(wire_stats) do
    for _, label in ipairs(M.format_wire_stat(stat)) do
      table.insert(labels, label)
    end
  end
  return labels
end

---Build the pill list for a pilot-turn header from the turn's
---accumulated metadata. Order: tokens, cost, elapsed — matches the
---Tauri UI's Turn.vue header chip order.
---@param turn { started_at_ms?: integer, ended_at_ms?: integer, now_ms?: integer, usage?: { used?: integer, size?: integer, cost?: table } }
---@return string[]
function M.turn_pills(turn)
  local labels = {}

  local usage = turn.usage
  if type(usage) == "table" and (usage.size or 0) > 0 then
    local used = M.format_tokens(usage.used) or "0"
    local size = M.format_tokens(usage.size) or "?"
    table.insert(labels, string.format("%s/%s", used, size))
  end

  local cost = type(usage) == "table" and usage.cost or nil
  local cost_label = M.format_cost(cost)
  if cost_label ~= nil then
    table.insert(labels, cost_label)
  end

  if type(turn.started_at_ms) == "number" then
    local end_ms = turn.ended_at_ms or turn.now_ms
    if type(end_ms) == "number" and end_ms >= turn.started_at_ms then
      local elapsed = M.format_duration(end_ms - turn.started_at_ms)
      if elapsed ~= nil then
        table.insert(labels, elapsed)
      end
    end
  end

  return labels
end

---Render a list of pill labels as a single line suffix, e.g.
---  `{ "120k/200k", "$0.74", "3s" }` → `" [120k/200k] [$0.74] [3s]"`
---Returns an empty string when there are no labels (caller appends
---it to a header line unconditionally).
---@param labels string[]?
---@return string
function M.format_pills(labels)
  if type(labels) ~= "table" or #labels == 0 then
    return ""
  end

  local parts = {}
  for _, label in ipairs(labels) do
    table.insert(parts, "[" .. label .. "]")
  end

  return " " .. table.concat(parts, " ")
end

return M
