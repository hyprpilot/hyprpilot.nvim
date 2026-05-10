--- JSON-RPC 2.0 envelope builders + standard error codes + an
--- incrementing id generator. Pure data — no IO, no Neovim API.

local M = {}

---Standard JSON-RPC 2.0 error codes per the spec.
---@class hyprpilot.client.JsonRpcCodes
M.codes = {
  parse_error = -32700,
  invalid_request = -32600,
  method_not_found = -32601,
  invalid_params = -32602,
  internal_error = -32603,
}

---@class hyprpilot.client.IdGenerator
---@field next integer

---@return hyprpilot.client.IdGenerator
function M.id_generator()
  return { next = 1 }
end

---Allocate the next id. Mutates the generator.
---@param self hyprpilot.client.IdGenerator
---@return integer
function M.next_id(self)
  local id = self.next
  self.next = id + 1

  return id
end

---@class hyprpilot.client.RpcRequest
---@field jsonrpc "2.0"
---@field id integer
---@field method string
---@field params table?

---@class hyprpilot.client.RpcNotification
---@field jsonrpc "2.0"
---@field method string
---@field params table?

---@class hyprpilot.client.RpcSuccess
---@field jsonrpc "2.0"
---@field id integer
---@field result any

---@class hyprpilot.client.RpcErrorPayload
---@field code integer
---@field message string
---@field data any?

---@class hyprpilot.client.RpcErrorReply
---@field jsonrpc "2.0"
---@field id integer | vim.NIL
---@field error hyprpilot.client.RpcErrorPayload

---Build a JSON-RPC request envelope.
---@param method string
---@param params table?
---@param id integer
---@return hyprpilot.client.RpcRequest
function M.request(method, params, id)
  return {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params,
  }
end

---Build a JSON-RPC notification envelope (no `id`, no response expected).
---@param method string
---@param params table?
---@return hyprpilot.client.RpcNotification
function M.notification(method, params)
  return {
    jsonrpc = "2.0",
    method = method,
    params = params,
  }
end

---Build a JSON-RPC successful response envelope.
---@param id integer
---@param value any
---@return hyprpilot.client.RpcSuccess
function M.result(id, value)
  return {
    jsonrpc = "2.0",
    id = id,
    result = value,
  }
end

---Build a JSON-RPC error response envelope.
---@param id integer | vim.NIL
---@param code integer
---@param message string
---@param data any?
---@return hyprpilot.client.RpcErrorReply
function M.error(id, code, message, data)
  return {
    jsonrpc = "2.0",
    id = id,
    error = {
      code = code,
      message = message,
      data = data,
    },
  }
end

return M
