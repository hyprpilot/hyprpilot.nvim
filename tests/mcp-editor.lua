--- Behavioural tests for `hyprpilot.mcp.editor`. Covers the
--- read-only paths (cursor, buffers, read) end-to-end against a
--- real Neovim buffer; grep / files are exercised against a temp
--- directory when `rg` is on PATH, otherwise skipped.

local T = MiniTest.new_set()

T["register_all: every editor_* tool lands in the registry"] = function()
  local mcp = require("hyprpilot.mcp")
  local editor = require("hyprpilot.mcp.editor")
  mcp._reset()

  editor.register_all()

  local listed = mcp.list()
  MiniTest.expect.equality(#listed, vim.tbl_count(editor.tools))
  for _, t in ipairs(listed) do
    MiniTest.expect.equality(t.name:sub(1, 7), "editor_")
  end

  mcp._reset()
end

T["editor_cursor: returns cursor pos + buffer info for the active window"] = function()
  vim.cmd("new")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "first", "second", "third" })
  vim.api.nvim_win_set_cursor(0, { 2, 3 })

  local editor = require("hyprpilot.mcp.editor")
  local result = editor.tools.cursor.handler({})

  MiniTest.expect.equality(result.json.bufnr, bufnr)
  MiniTest.expect.equality(result.json.line, 1) -- 0-indexed
  MiniTest.expect.equality(result.json.character, 3)
  MiniTest.expect.equality(result.json.visible.total_lines, 3)

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

T["editor_buffers: lists loaded listed buffers, skips scratch by default"] = function()
  vim.cmd("new")
  local listed_buf = vim.api.nvim_get_current_buf()
  vim.bo[listed_buf].buflisted = true

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "nofile"

  local editor = require("hyprpilot.mcp.editor")
  local result = editor.tools.buffers.handler({})

  local saw_listed, saw_scratch = false, false
  for _, b in ipairs(result.json.buffers) do
    if b.bufnr == listed_buf then
      saw_listed = true
    end
    if b.bufnr == scratch then
      saw_scratch = true
    end
  end
  MiniTest.expect.equality(saw_listed, true)
  MiniTest.expect.equality(saw_scratch, false)

  pcall(vim.api.nvim_buf_delete, listed_buf, { force = true })
  pcall(vim.api.nvim_buf_delete, scratch, { force = true })
end

T["editor_read: returns buffer contents (with unsaved changes visible)"] = function()
  local path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "on disk" }, path)

  -- Load the file and modify the buffer in-memory; on-disk content
  -- is now stale. `editor_read` should see the in-memory state.
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "modified line 1", "modified line 2" })

  local editor = require("hyprpilot.mcp.editor")
  local result = editor.tools.read.handler({ path = path })

  MiniTest.expect.equality(result.json.text:find("modified line 1", 1, true) ~= nil, true)
  MiniTest.expect.equality(result.json.total_lines, 2)
  MiniTest.expect.equality(result.json.modified, true)

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  vim.fn.delete(path)
end

T["editor_read: respects start_line / end_line clipping"] = function()
  local path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "0", "1", "2", "3", "4" }, path)

  local editor = require("hyprpilot.mcp.editor")
  local result = editor.tools.read.handler({ path = path, start_line = 1, end_line = 3 })

  -- 0-indexed inclusive: lines 1..3 → "1\n2\n3"
  MiniTest.expect.equality(result.json.text, "1\n2\n3")

  vim.fn.delete(path)
end

T["editor_read: unreadable path → is_error result"] = function()
  local editor = require("hyprpilot.mcp.editor")
  local result = editor.tools.read.handler({ path = "/nonexistent/path/that/cannot/be/read.lua" })
  MiniTest.expect.equality(result.is_error, true)
end

return T
