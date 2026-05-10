--- NDJSON line-framing primitive.
---
--- Read callbacks from the daemon's pipe deliver arbitrary chunks; this
--- accumulates them and fires `on_line` once per complete `\n`-terminated
--- line, dropping the newline. Empty lines are passed through (the
--- caller decides whether to ignore them — JSON-RPC has no use for
--- empty lines, but the framing layer doesn't impose semantics).

local M = {}

---@class hyprpilot.client.LineBuffer
---@field buffer string

---@return hyprpilot.client.LineBuffer
function M.new()
  return { buffer = "" }
end

---Append `data`, fire `on_line(line)` for each complete line found.
---@param self hyprpilot.client.LineBuffer
---@param data string
---@param on_line fun(line: string): nil
function M.push(self, data, on_line)
  self.buffer = self.buffer .. data

  while true do
    local nl = self.buffer:find("\n", 1, true)

    if nl == nil then
      return
    end

    on_line(self.buffer:sub(1, nl - 1))
    self.buffer = self.buffer:sub(nl + 1)
  end
end

---Drop any pending data without firing callbacks. Used on disconnect
---to ensure the next connection starts with a clean accumulator.
---@param self hyprpilot.client.LineBuffer
function M.reset(self)
  self.buffer = ""
end

return M
