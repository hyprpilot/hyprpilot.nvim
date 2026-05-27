local M = {}

---@param value any
---@return string?
function M.classify(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  if type(value) == "table" and type(value.type) == "string" and value.type ~= "" then
    return value.type
  end

  return nil
end

---@param value any
---@return string?
function M.label(value)
  if type(value) == "table" and value.type == "mcp" then
    if type(value.server) == "string" and value.server ~= "" and type(value.tool) == "string" and value.tool ~= "" then
      return value.server .. "/" .. value.tool
    end
    if type(value.server) == "string" and value.server ~= "" then
      return value.server
    end
    if type(value.tool) == "string" and value.tool ~= "" then
      return value.tool
    end
  end

  return M.classify(value)
end

return M
