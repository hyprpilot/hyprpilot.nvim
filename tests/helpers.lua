--- Shared test helpers. Each helper exists so the test files can
--- focus on the behaviour under test, not the boilerplate around it.

local M = {}

local id_counter = 0

---Mint a unique instance id per test so the buffer registry stays
---untangled across cases (mini.test runs them in one nvim process).
---@return string
function M.unique_id()
  id_counter = id_counter + 1
  return "test-instance-" .. tostring(id_counter)
end

---Drop the per-instance state and wipe the chat buffer the test
---created. Idempotent; safe to call from `post_case` hooks.
---@param instance_id string
function M.cleanup_instance(instance_id)
  local instances = require("hyprpilot.instances")
  local window_state = instances.get(instance_id)
  if window_state ~= nil and vim.api.nvim_buf_is_valid(window_state.bufnr) then
    pcall(vim.api.nvim_buf_delete, window_state.bufnr, { force = true })
  end
  instances.forget(instance_id)

  local render = require("hyprpilot.chat.render")
  local state = render._states[instance_id]

  if state ~= nil and vim.api.nvim_buf_is_valid(state.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
  end

  render.forget(instance_id)
end

---Open a temporary split window pointing at `bufnr` with the chat
---window's fold settings. Returns the winid; tests close it via
---`close_window` to keep the window list clean between cases.
---@param bufnr integer
---@return integer
function M.open_chat_window(bufnr)
  vim.cmd("vsplit")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.wo[winid].foldmethod = "manual"
  vim.wo[winid].foldenable = true
  vim.wo[winid].foldlevel = 99
  return winid
end

---Close a window opened via `open_chat_window`. Survives the window
---already being closed (e.g. nvim closed it during a quit).
---@param winid integer
function M.close_window(winid)
  if vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end
end

---Stub `hyprpilot.permissions.respond` to record calls instead of
---hitting the daemon. Returns `(restore, calls)` — `restore()` puts
---the original implementation back, `calls` accumulates `{request_id,
---option_id}` tuples.
---@return fun(), table[]
function M.stub_permissions_respond()
  local public = require("hyprpilot.rpc.permissions")
  local original = public.respond
  local calls = {}

  public.respond = function(request_id, option_id, callback)
    table.insert(calls, { request_id = request_id, option_id = option_id })
    if callback ~= nil then
      callback(nil, { resolved = true })
    end
  end

  return function()
    public.respond = original
  end, calls
end

---Stub `hyprpilot.client.request` with a method → reply table. Each
---reply is `{ err?, result? }`; an absent method returns a transport
---error so a stray RPC can't pass silently. Captures every call as
---`{ method, params }`. The more general successor of
---`stub_client_request` — pass `replies = {}` for "no-op every call".
---@param replies? table<string, { err?: table, result?: any }>
---@return fun(), table[]
function M.stub_client_with(replies)
  replies = replies or {}
  local client = require("hyprpilot.client")
  local original = client.request
  local calls = {}

  client.request = function(method, params, _opts, callback)
    table.insert(calls, { method = method, params = params })
    local r = replies[method]
    if r == nil then
      if callback ~= nil then
        callback({ kind = "transport", message = "unstubbed RPC: " .. method }, nil)
      end
      return
    end
    if callback ~= nil then
      callback(r.err, r.result)
    end
  end

  return function()
    client.request = original
  end, calls
end

---Legacy stub: every call records + immediately fires the callback
---with `(nil, {})` — a permissive "everything succeeds" pattern. New
---tests should prefer `stub_client_with({ method = { result = ... } })`
---so per-method shaping is explicit; this alias is kept for the
---composer attachment tests that were written against the old shape.
---@return fun(), table[]
function M.stub_client_request()
  local client = require("hyprpilot.client")
  local original = client.request
  local calls = {}

  client.request = function(method, params, opts, callback)
    table.insert(calls, { method = method, params = params, opts = opts })
    if callback ~= nil then
      callback(nil, {})
    end
  end

  return function()
    client.request = original
  end, calls
end

---Force `chat.window.active_instance` to return a known id (or nil)
---for the duration of a test. Returns the restore closure.
---@param instance_id string?
---@return fun()
function M.stub_active_instance(instance_id)
  local window = require("hyprpilot.chat.window")
  local original = window.active_instance
  window.active_instance = function()
    return instance_id
  end
  return function()
    window.active_instance = original
  end
end

---Stub `vim.ui.select` to drive a picker programmatically. The
---supplied `pick_fn(items, opts)` chooses the row (return `nil` to
---simulate the captain cancelling). Captures every invocation's
---`{ items, opts }` pair for assertion.
---@param pick_fn fun(items: any[], opts: table): any?
---@return fun(), table[]
function M.stub_ui_select(pick_fn)
  local original = vim.ui.select
  local invocations = {}

  vim.ui.select = function(items, opts, callback)
    table.insert(invocations, { items = items, opts = opts })
    local choice = pick_fn(items, opts)
    callback(choice)
  end

  return function()
    vim.ui.select = original
  end, invocations
end

---True when any line in `lines` exactly matches `needle`.
---@param lines string[]
---@param needle string
---@return boolean
function M.has_line(lines, needle)
  for _, l in ipairs(lines) do
    if l == needle then
      return true
    end
  end
  return false
end

---True when any line in `lines` contains `needle` as a substring.
---@param lines string[]
---@param needle string
---@return boolean
function M.has_line_containing(lines, needle)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

return M
