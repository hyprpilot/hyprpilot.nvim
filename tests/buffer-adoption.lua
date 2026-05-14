--- Regression tests for E95 — `nvim_buf_set_name` raising "Buffer
--- with this name already exists" when a plugin-managed buffer
--- survives a `shutdown()` (or any lifecycle that drops the
--- module-level reference) but Neovim still keeps the buffer
--- alive (bufhidden=hide). Every `ensure_buffer` / `create` site
--- must adopt the existing buffer instead of trying to create + name
--- a fresh one.

local T = MiniTest.new_set()

---Mint a buffer with the given name and apply the same shape the
---plugin's ensure_buffer flow would, then return its bufnr. Drops
---the module-level reference (or doesn't set one) so the next
---ensure_buffer call has to adopt this one.
---@param name string
---@return integer
local function spawn_ghost_buffer(name)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  return bufnr
end

T["permission_row.refresh adopts the existing `hyprpilot://permission_row` buffer"] = function()
  local pr = require("hyprpilot.chat.permission-row")
  if pr._bufnr and vim.api.nvim_buf_is_valid(pr._bufnr) then
    pcall(vim.api.nvim_buf_delete, pr._bufnr, { force = true })
  end
  pr._bufnr = nil

  local ghost = spawn_ghost_buffer("hyprpilot://permission_row")

  local ok = pcall(pr.refresh)
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(pr._bufnr, ghost)

  pcall(vim.api.nvim_buf_delete, ghost, { force = true })
  pr._bufnr = nil
end

T["buffer.placeholder adopts the existing `hyprpilot://placeholder` buffer"] = function()
  -- Spawn a ghost first, then call placeholder() — it should pick
  -- the ghost up rather than crash on E95.
  local ghost = spawn_ghost_buffer("hyprpilot://placeholder")

  local buffer = require("hyprpilot.chat.buffer")
  local ok, got = pcall(buffer.placeholder)
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(got, ghost)

  pcall(vim.api.nvim_buf_delete, ghost, { force = true })
end

return T
