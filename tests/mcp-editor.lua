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

T["editor_status: returns mode + focused buffer + buffer list"] = function()
  vim.cmd("new")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buflisted = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "alpha", "beta" })
  vim.api.nvim_win_set_cursor(0, { 2, 1 })

  local result = require("hyprpilot.mcp.editor").tools.status.handler({})

  MiniTest.expect.equality(result.json.focused.bufnr, bufnr)
  MiniTest.expect.equality(result.json.focused.line, 1) -- 0-indexed
  MiniTest.expect.equality(result.json.focused.character, 1)
  MiniTest.expect.equality(result.json.focused.line_count, 2)
  MiniTest.expect.equality(type(result.json.mode), "string")

  local saw = false
  for _, b in ipairs(result.json.buffers) do
    if b.bufnr == bufnr then
      saw = true
    end
  end
  MiniTest.expect.equality(saw, true)

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

T["editor_jump: clamps line + moves cursor in current buffer"] = function()
  vim.cmd("new")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three" })

  local result = require("hyprpilot.mcp.editor").tools.jump.handler({ line = 99 })

  -- 99 clamps to 3 (1-indexed line count); response is 0-indexed.
  MiniTest.expect.equality(result.json.line, 2)
  MiniTest.expect.equality(result.json.bufnr, bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  MiniTest.expect.equality(cursor[1], 3)

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

T["editor_select: enters line-wise visual over the requested range"] = function()
  vim.cmd("new")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b", "c", "d" })

  local result = require("hyprpilot.mcp.editor").tools.select.handler({
    start_line = 2,
    end_line = 3,
  })

  MiniTest.expect.equality(result.json.start_line, 1) -- 0-indexed
  MiniTest.expect.equality(result.json.end_line, 2)
  local cursor = vim.api.nvim_win_get_cursor(0)
  MiniTest.expect.equality(cursor[1], 3)

  -- Exit visual mode so we don't pollute later tests.
  pcall(vim.cmd, "stopinsert")
  pcall(vim.cmd, "normal! \027")
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

T["editor_file_open: missing file returns is_error"] = function()
  local result = require("hyprpilot.mcp.editor").tools.file_open.handler({
    path = "/tmp/hyprpilot-mcp-editor-does-not-exist-" .. tostring(vim.uv.hrtime()),
  })
  MiniTest.expect.equality(result.is_error, true)
end

--- Helpers for the "captain has focus on a plugin window" tests
--- below. We don't reach for the live composer module — just stamp
--- the well-known plugin filetype onto a scratch buffer and shove it
--- into a split so `find_editor_winid` / `is_plugin_window` see it.
local function open_plugin_window(ft)
  vim.cmd("new")
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = ft
  vim.bo[bufnr].buftype = "nofile"
  return winid, bufnr
end

T["editor_cursor: when focus is on a plugin window, reroutes to the editor window"] = function()
  vim.cmd("only")
  vim.cmd("new") -- editor split
  local editor_bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(editor_bufnr, 0, -1, false, { "alpha", "beta", "gamma" })
  vim.api.nvim_win_set_cursor(0, { 2, 1 })

  -- Now drop into a composer-flavoured window so the cursor handler
  -- sees current = plugin and has to walk to the editor split.
  local plugin_winid, plugin_bufnr = open_plugin_window("hyprpilot_composer.markdown")

  local result = require("hyprpilot.mcp.editor").tools.cursor.handler({})

  MiniTest.expect.equality(result.json.available, true)
  MiniTest.expect.equality(result.json.bufnr, editor_bufnr)
  MiniTest.expect.equality(result.json.line, 1)

  pcall(vim.api.nvim_win_close, plugin_winid, true)
  pcall(vim.api.nvim_buf_delete, plugin_bufnr, { force = true })
  pcall(vim.api.nvim_buf_delete, editor_bufnr, { force = true })
end

T["editor_cursor: when every visible window is a plugin surface, reports unavailable"] = function()
  -- Collapse to one window, then turn that window's buffer into a
  -- plugin surface — `:only` can't leave us with zero windows, so
  -- this is the cleanest "only plugin windows visible" setup.
  vim.cmd("only")
  local sole_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[sole_bufnr].filetype = "hyprpilot_composer.markdown"
  vim.api.nvim_win_set_buf(0, sole_bufnr)

  local result = require("hyprpilot.mcp.editor").tools.cursor.handler({})
  MiniTest.expect.equality(result.json.available, false)

  -- Restore a normal scratch buffer so later cases don't inherit
  -- the plugin filetype on the sole remaining window.
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
  pcall(vim.api.nvim_buf_delete, sole_bufnr, { force = true })
end

T["editor_jump: when focus is on a plugin window, lands the cursor in the editor window (not the plugin one)"] = function()
  vim.cmd("only")
  vim.cmd("new")
  local editor_winid = vim.api.nvim_get_current_win()
  local editor_bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(editor_bufnr, 0, -1, false, { "one", "two", "three", "four" })

  local plugin_winid, plugin_bufnr = open_plugin_window("hyprpilot_composer.markdown")

  -- Jump targeting the editor buffer explicitly (so we don't need the
  -- default-target heuristic too).
  require("hyprpilot.mcp.editor").tools.jump.handler({ bufnr = editor_bufnr, line = 3 })

  -- Composer window's buffer must NOT have changed.
  MiniTest.expect.equality(vim.api.nvim_win_get_buf(plugin_winid), plugin_bufnr)
  -- Editor window now shows the editor buffer at line 3.
  MiniTest.expect.equality(vim.api.nvim_win_get_buf(editor_winid), editor_bufnr)
  local cursor = vim.api.nvim_win_get_cursor(editor_winid)
  MiniTest.expect.equality(cursor[1], 3)

  pcall(vim.api.nvim_win_close, plugin_winid, true)
  pcall(vim.api.nvim_buf_delete, plugin_bufnr, { force = true })
  pcall(vim.api.nvim_buf_delete, editor_bufnr, { force = true })
end

T["editor_format: no-LSP buffer returns ok (no-op)"] = function()
  vim.cmd("new")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "no LSP attached here" })

  local result = require("hyprpilot.mcp.editor").tools.format.handler({})

  -- Without an attached formatter LSP, vim.lsp.buf.format is a no-op
  -- (no error). Tool should return success with the bufnr echoed.
  MiniTest.expect.equality(result.json.bufnr, bufnr)
  MiniTest.expect.equality(result.is_error, nil)

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

return T
