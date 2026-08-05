--- Behavioural tests for `hyprpilot.mcp.editor`. Covers the
--- read-only paths (cursor, buffers, read) end-to-end against a
--- real Neovim buffer; grep / files are exercised against a temp
--- directory when `rg` is on PATH, otherwise skipped.

local T = MiniTest.new_set()

T["register: every editor_* tool lands in the registry"] = function()
  local mcp = require("hyprpilot.mcp")
  local editor = require("hyprpilot.mcp.editor")
  mcp._reset()

  editor.register()

  local listed = mcp.list()
  MiniTest.expect.equality(#listed, vim.tbl_count(editor.tools))
  for _, t in ipairs(listed) do
    MiniTest.expect.equality(t.name:sub(1, 7), "editor_")
  end

  mcp._reset()
end

T["register: items registers only the named subset, unknown names skipped"] = function()
  local mcp = require("hyprpilot.mcp")
  local editor = require("hyprpilot.mcp.editor")
  mcp._reset()

  editor.register({ items = { "cursor", "read", "nope" } })

  local names = {}
  for _, t in ipairs(mcp.list()) do
    names[t.name] = true
  end
  MiniTest.expect.equality(names["editor_cursor"], true)
  MiniTest.expect.equality(names["editor_read"], true)
  MiniTest.expect.equality(names["editor_buffers"], nil)
  MiniTest.expect.equality(vim.tbl_count(names), 2)

  mcp._reset()
end

T["register: disabled_filetypes routes navigation away from matching windows"] = function()
  local editor = require("hyprpilot.mcp.editor")
  editor.register({ disabled_filetypes = { "myaux" } })

  vim.cmd("only")
  vim.cmd("new") -- editor split, holds the file we expect to land on
  local editor_bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(editor_bufnr, 0, -1, false, { "alpha", "beta", "gamma" })

  -- Drop focus into a disabled-filetype window; the cursor tool must
  -- walk to the editor split instead of reporting the aux buffer.
  vim.cmd("new")
  local aux_winid = vim.api.nvim_get_current_win()
  local aux_bufnr = vim.api.nvim_get_current_buf()
  vim.bo[aux_bufnr].filetype = "myaux"
  vim.bo[aux_bufnr].buftype = "nofile"

  local result = editor.tools.cursor.handler({})
  MiniTest.expect.equality(result.json.bufnr, editor_bufnr)

  -- Reset module state so later cases don't inherit the exclusion list.
  editor.register({ disabled_filetypes = {}, disabled_buffer_types = {} })
  pcall(vim.api.nvim_win_close, aux_winid, true)
  pcall(vim.api.nvim_buf_delete, aux_bufnr, { force = true })
  pcall(vim.api.nvim_buf_delete, editor_bufnr, { force = true })
end

T["register: pick_window picks the landing window and gets the exclusion lists"] = function()
  local editor = require("hyprpilot.mcp.editor")

  vim.cmd("only")
  local home_winid = vim.api.nvim_get_current_win()
  vim.cmd("vnew")
  local picked_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(home_winid)

  -- Target buffer isn't on screen anywhere, so the hook decides.
  local hidden = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(hidden, 0, -1, false, { "one", "two", "three" })

  local seen
  editor.register({
    disabled_filetypes = { "myaux" },
    disabled_buffer_types = { "terminal" },
    pick_window = function(filter)
      seen = filter
      return picked_winid
    end,
  })

  local result = editor.tools.jump.handler({ bufnr = hidden, line = 2 })

  MiniTest.expect.equality(result.json.bufnr, hidden)
  MiniTest.expect.equality(vim.api.nvim_win_get_buf(picked_winid), hidden)
  MiniTest.expect.equality(seen.filetype, { "myaux" })
  MiniTest.expect.equality(seen.buftype, { "terminal" })

  editor.register({})
  pcall(vim.api.nvim_win_close, picked_winid, true)
  pcall(vim.api.nvim_buf_delete, hidden, { force = true })
end

T["register: pick_window returning nil falls back to the built-in heuristic"] = function()
  local editor = require("hyprpilot.mcp.editor")

  vim.cmd("only")
  local winid = vim.api.nvim_get_current_win()
  local hidden = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(hidden, 0, -1, false, { "a", "b" })

  editor.register({
    pick_window = function()
      return nil -- picker cancelled
    end,
  })

  editor.tools.jump.handler({ bufnr = hidden, line = 1 })
  MiniTest.expect.equality(vim.api.nvim_win_get_buf(winid), hidden)

  editor.register({})
  pcall(vim.api.nvim_buf_delete, hidden, { force = true })
end

T["register: a throwing or unusable pick_window degrades to the heuristic"] = function()
  local editor = require("hyprpilot.mcp.editor")

  for _, hook in ipairs({
    function()
      error("picker blew up")
    end,
    function()
      return 999999 -- stale winid
    end,
    function()
      return 0 -- nvim reads 0 as "current window"; not a real pick
    end,
    function()
      return "not a winid"
    end,
  }) do
    vim.cmd("only")
    local winid = vim.api.nvim_get_current_win()
    local hidden = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(hidden, 0, -1, false, { "a", "b" })

    editor.register({ pick_window = hook })
    editor.tools.jump.handler({ bufnr = hidden, line = 1 })
    MiniTest.expect.equality(vim.api.nvim_win_get_buf(winid), hidden)

    pcall(vim.api.nvim_buf_delete, hidden, { force = true })
  end

  editor.register({})
end

T["register: non-function pick_window is rejected, navigation still works"] = function()
  local editor = require("hyprpilot.mcp.editor")

  vim.cmd("only")
  local winid = vim.api.nvim_get_current_win()
  local hidden = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(hidden, 0, -1, false, { "a", "b" })

  editor.register({ pick_window = "nope" })
  editor.tools.jump.handler({ bufnr = hidden, line = 1 })
  MiniTest.expect.equality(vim.api.nvim_win_get_buf(winid), hidden)

  editor.register({})
  pcall(vim.api.nvim_buf_delete, hidden, { force = true })
end

T["register: pick_window is skipped for on-screen targets and read-only tools"] = function()
  local editor = require("hyprpilot.mcp.editor")

  vim.cmd("only")
  vim.cmd("new")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b", "c" })

  local calls = 0
  editor.register({
    pick_window = function()
      calls = calls + 1
      return nil
    end,
  })

  editor.tools.cursor.handler({})
  editor.tools.status.handler({})
  editor.tools.jump.handler({ bufnr = bufnr, line = 2 })

  MiniTest.expect.equality(calls, 0)

  editor.register({})
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
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
  MiniTest.expect.equality(result.json.mode, "V")
  local cursor = vim.api.nvim_win_get_cursor(0)
  MiniTest.expect.equality(cursor[1], 3)

  -- Exit visual mode so we don't pollute later tests.
  pcall(vim.cmd, "stopinsert")
  pcall(vim.cmd, "normal! \027")
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

T["editor_select: selects for real when the captain is focused elsewhere"] = function()
  vim.cmd("only")
  vim.cmd("new")
  local target = vim.api.nvim_get_current_buf()
  local target_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(target, 0, -1, false, { "a", "b", "c", "d" })

  -- Focus a different window, the way a captain sitting in a terminal
  -- split does. Visual mode driven through `nvim_win_call` used to be
  -- discarded here, leaving a success result and no selection.
  vim.cmd("vnew")
  local elsewhere = vim.api.nvim_get_current_buf()

  local result = require("hyprpilot.mcp.editor").tools.select.handler({
    bufnr = target,
    start_line = 2,
    end_line = 3,
  })

  MiniTest.expect.equality(result.json.mode, "V")
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), target_winid)

  pcall(vim.cmd, "normal! \027")
  MiniTest.expect.equality(vim.api.nvim_buf_get_mark(target, "<")[1], 2)
  MiniTest.expect.equality(vim.api.nvim_buf_get_mark(target, ">")[1], 3)

  pcall(vim.api.nvim_buf_delete, elsewhere, { force = true })
  pcall(vim.api.nvim_buf_delete, target, { force = true })
end

T["editor_select: selects for real from terminal mode"] = function()
  vim.cmd("only")
  vim.cmd("new")
  local target = vim.api.nvim_get_current_buf()
  local target_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(target, 0, -1, false, { "a", "b", "c", "d" })

  -- The captain talks to the agent from a terminal split, so this is the
  -- common case, not an edge one. Terminal-insert pins focus: the window
  -- switch is undone on return to the main loop unless the handler
  -- leaves terminal mode first.
  --
  -- Headless can't reach terminal-INSERT (`startinsert` lands in `nt`,
  -- terminal-normal), so this asserts the weaker half — selecting out of
  -- a focused terminal window. The pinned `t` case is only reproducible
  -- against a live session.
  vim.cmd("vsplit")
  vim.cmd("terminal")
  local term = vim.api.nvim_get_current_buf()
  vim.cmd("startinsert")
  MiniTest.expect.equality(vim.bo[vim.api.nvim_get_current_buf()].buftype, "terminal")

  local result = require("hyprpilot.mcp.editor").tools.select.handler({
    bufnr = target,
    start_line = 2,
    end_line = 3,
  })

  MiniTest.expect.equality(result.is_error, nil)
  MiniTest.expect.equality(result.json.mode, "V")
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), target_winid)

  pcall(vim.cmd, "normal! \027")
  pcall(vim.api.nvim_buf_delete, term, { force = true })
  pcall(vim.api.nvim_buf_delete, target, { force = true })
end

T["editor_file_open: the opened file becomes a listed buffer"] = function()
  local path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "one", "two" }, path)
  vim.cmd("only")

  local editor = require("hyprpilot.mcp.editor")
  local result = editor.tools.file_open.handler({ path = path, line = 2 })

  -- `bufadd` adopts unlisted, so without the explicit flip the captain's
  -- tabline and `:bnext` never see a file the agent opened for them.
  MiniTest.expect.equality(vim.bo[result.json.bufnr].buflisted, true)

  local seen = false
  for _, b in ipairs(editor.tools.buffers.handler({}).json.buffers) do
    if b.bufnr == result.json.bufnr then
      seen = true
    end
  end
  MiniTest.expect.equality(seen, true)

  pcall(vim.api.nvim_buf_delete, result.json.bufnr, { force = true })
  vim.fn.delete(path)
end

T["editor_file_open: missing file returns is_error"] = function()
  local result = require("hyprpilot.mcp.editor").tools.file_open.handler({
    path = "/tmp/hyprpilot-mcp-editor-does-not-exist-" .. tostring(vim.uv.hrtime()),
  })
  MiniTest.expect.equality(result.is_error, true)
end

T["editor_quickfix_set: populates the list, converting 0-indexed positions"] = function()
  local path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "alpha", "beta", "gamma" }, path)

  local result = require("hyprpilot.mcp.editor").tools.quickfix_set.handler({
    items = {
      { path = path, line = 1, character = 2, text = "second line" },
      { path = path, line = 2, text = "third line" },
    },
    title = "agent findings",
  })

  MiniTest.expect.equality(result.json.count, 2)
  MiniTest.expect.equality(result.json.skipped, 0)
  MiniTest.expect.equality(result.json.opened, true)

  local list = vim.fn.getqflist()
  MiniTest.expect.equality(#list, 2)
  -- 0-indexed in, 1-indexed out — quickfix counts from one.
  MiniTest.expect.equality(list[1].lnum, 2)
  MiniTest.expect.equality(list[1].col, 3)
  MiniTest.expect.equality(list[1].text, "second line")
  MiniTest.expect.equality(list[2].lnum, 3)
  MiniTest.expect.equality(vim.fn.getqflist({ title = 0 }).title, "agent findings")

  -- Opening is the default: a list the captain never sees is worse than
  -- the paths it replaced.
  local qf_open = false
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(winid)].buftype == "quickfix" then
      qf_open = true
    end
  end
  MiniTest.expect.equality(qf_open, true)

  vim.cmd("cclose")
  vim.fn.setqflist({}, "r")
  vim.fn.delete(path)
end

T["editor_quickfix_set: open = false populates without touching the captain's windows"] = function()
  local path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "alpha", "beta" }, path)
  vim.cmd("only")

  local result = require("hyprpilot.mcp.editor").tools.quickfix_set.handler({
    items = { { path = path, line = 0, text = "quiet entry" } },
    open = false,
  })

  MiniTest.expect.equality(result.json.opened, false)
  MiniTest.expect.equality(#vim.fn.getqflist(), 1)
  MiniTest.expect.equality(#vim.api.nvim_list_wins(), 1)

  vim.fn.setqflist({}, "r")
  vim.fn.delete(path)
end

T["editor_quickfix_set: entries without a path are skipped, all-bad is an error"] = function()
  local editor = require("hyprpilot.mcp.editor")
  local path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "alpha" }, path)

  local mixed = editor.tools.quickfix_set.handler({
    items = { { path = path, line = 0 }, { text = "no path here" } },
  })
  MiniTest.expect.equality(mixed.json.count, 1)
  MiniTest.expect.equality(mixed.json.skipped, 1)

  MiniTest.expect.equality(editor.tools.quickfix_set.handler({ items = { { text = "nope" } } }).is_error, true)
  MiniTest.expect.equality(editor.tools.quickfix_set.handler({ items = "not a list" }).is_error, true)

  vim.fn.setqflist({}, "r")
  vim.fn.delete(path)
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
