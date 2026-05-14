--- Behavioural tests for `ui.diff_preview`. Cases exercise hunk
--- computation across the edit-tool variants the agent emits, then
--- drive `M.open` / `M.close` against real buffers with stubbed
--- file resolution and assert on extmark presence / cleanup.

local T = MiniTest.new_set()

local diff_preview = require("hyprpilot.ui.diff_preview")

---Build a fake permission-row entry shape that the preview API
---consumes. Caller fills in `raw_input`.
---@param raw any
---@param overrides? table
---@return hyprpilot.chat.permission_row.Entry
local function mk_entry(raw, overrides)
  local entry = {
    instance_id = "inst-x",
    request_id = "req-" .. tostring(vim.uv.hrtime()),
    tool = "Edit",
    tool_kind = "edit",
    options = {
      { optionId = "allow", name = "Allow" },
      { optionId = "reject", name = "Reject" },
    },
    focused_idx = 1,
    raw_input = raw,
  }
  if overrides ~= nil then
    for k, v in pairs(overrides) do
      entry[k] = v
    end
  end
  return entry
end

T["compute_new_lines: Edit single old/new replaces verbatim"] = function()
  local current = { "alpha", "old line", "beta" }
  local entry = mk_entry({ path = "/tmp/x.lua", old_string = "old line", new_string = "new line" })
  local new, reason = diff_preview._compute_new_lines(entry, current)
  MiniTest.expect.equality(reason, nil)
  MiniTest.expect.equality(new[1], "alpha")
  MiniTest.expect.equality(new[2], "new line")
  MiniTest.expect.equality(new[3], "beta")
end

T["compute_new_lines: Write content becomes the full proposed buffer"] = function()
  local entry = mk_entry({ path = "/tmp/new.lua", content = "line a\nline b" })
  local new, reason = diff_preview._compute_new_lines(entry, { "stale" })
  MiniTest.expect.equality(reason, nil)
  MiniTest.expect.equality(#new, 2)
  MiniTest.expect.equality(new[1], "line a")
  MiniTest.expect.equality(new[2], "line b")
end

T["compute_new_lines: MultiEdit applies edits SEQUENTIALLY (each sees prior result)"] = function()
  local current = { "AAA", "BBB", "CCC" }
  -- The second edit's old_string only exists after the first edit
  -- runs — sequential application is the only correct semantics.
  local entry = mk_entry({
    path = "/tmp/x",
    edits = {
      { old_string = "BBB", new_string = "BBB-then-DDD" },
      { old_string = "BBB-then-DDD", new_string = "DDD" },
    },
  })
  local new, reason = diff_preview._compute_new_lines(entry, current)
  MiniTest.expect.equality(reason, nil)
  MiniTest.expect.equality(new[2], "DDD")
end

T["compute_new_lines: old_string not in buffer returns a `reason`"] = function()
  local entry = mk_entry({ path = "/tmp/x", old_string = "nope not here", new_string = "x" })
  local _, reason = diff_preview._compute_new_lines(entry, { "alpha", "beta" })
  MiniTest.expect.equality(reason ~= nil, true)
end

T["compute_hunks: identical lines produce no hunks"] = function()
  local hunks = diff_preview._compute_hunks({ "a", "b" }, { "a", "b" })
  MiniTest.expect.equality(#hunks, 0)
end

T["compute_hunks: single-line replacement → one hunk with new_lines"] = function()
  local hunks = diff_preview._compute_hunks({ "a", "OLD", "c" }, { "a", "NEW", "c" })
  MiniTest.expect.equality(#hunks, 1)
  MiniTest.expect.equality(hunks[1].new_lines[1], "NEW")
end

T["resolve_path: picks path / file_path / notebook_path in order"] = function()
  MiniTest.expect.equality(diff_preview._resolve_path({ path = "/a" }), "/a")
  MiniTest.expect.equality(diff_preview._resolve_path({ file_path = "/b" }), "/b")
  MiniTest.expect.equality(diff_preview._resolve_path({ notebook_path = "/c.ipynb" }), "/c.ipynb")
  MiniTest.expect.equality(diff_preview._resolve_path({}), nil)
  MiniTest.expect.equality(diff_preview._resolve_path("not a table"), nil)
end

T["is_previewable: tool_kind=edit + path field → true"] = function()
  local entry = mk_entry({ path = "/tmp/x.lua", old_string = "a", new_string = "b" })
  MiniTest.expect.equality(diff_preview.is_previewable(entry), true)
end

T["is_previewable: non-edit tool_kind → false even when raw_input has path"] = function()
  local entry = mk_entry({ path = "/tmp/x.lua", content = "c" }, { tool_kind = "execute" })
  MiniTest.expect.equality(diff_preview.is_previewable(entry), false)
end

T["is_previewable: notebook_path short-circuits to false (v1 doesn't preview notebooks)"] = function()
  local entry = mk_entry({ notebook_path = "/tmp/x.ipynb", new_source = "print(1)" })
  MiniTest.expect.equality(diff_preview.is_previewable(entry), false)
end

T["is_previewable: edit tool with no path field → false"] = function()
  local entry = mk_entry({ old_string = "a", new_string = "b" })
  MiniTest.expect.equality(diff_preview.is_previewable(entry), false)
end

T["open: edit-shape against a temp file paints hunks + cleans up on close"] = function()
  diff_preview._reset()

  -- Mint a real on-disk file the preview can resolve.
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  local path = tmpdir .. "/sample.lua"
  local fh = assert(io.open(path, "w"))
  fh:write("alpha\nold line\nbeta\n")
  fh:close()

  -- Need a host window for the preview to land in.
  vim.cmd("split")
  local host_win = vim.api.nvim_get_current_win()
  require("hyprpilot.ui.window")._prev_winid = host_win

  local entry = mk_entry({ path = path, old_string = "old line", new_string = "new line" })
  diff_preview.open(entry)

  local open, request_id = diff_preview.is_open()
  MiniTest.expect.equality(open, true)
  MiniTest.expect.equality(request_id, entry.request_id)

  -- An extmark must exist in the diff_preview namespace on the target buffer.
  local target_bufnr = diff_preview._state.bufnr
  local ns = vim.api.nvim_get_namespaces()["hyprpilot.ui.diff_preview"]
  local marks = vim.api.nvim_buf_get_extmarks(target_bufnr, ns, 0, -1, {})
  MiniTest.expect.equality(#marks > 0, true)

  diff_preview.close()
  MiniTest.expect.equality(diff_preview.is_open(), false)

  local marks_after = vim.api.nvim_buf_get_extmarks(target_bufnr, ns, 0, -1, {})
  MiniTest.expect.equality(#marks_after, 0)

  pcall(vim.api.nvim_win_close, host_win, true)
  pcall(os.remove, path)
  pcall(vim.fn.delete, tmpdir, "rf")
end

T["open: out-of-sync old_string drops a warning pill instead of throwing"] = function()
  diff_preview._reset()

  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  local path = tmpdir .. "/sync.lua"
  local fh = assert(io.open(path, "w"))
  fh:write("totally different content\n")
  fh:close()

  vim.cmd("split")
  local host_win = vim.api.nvim_get_current_win()
  require("hyprpilot.ui.window")._prev_winid = host_win

  local entry = mk_entry({ path = path, old_string = "this string is not in the file", new_string = "ignored" })
  diff_preview.open(entry)

  local open = diff_preview.is_open()
  MiniTest.expect.equality(open, true)
  MiniTest.expect.equality(#diff_preview._state.hunks, 0)

  diff_preview.close()
  pcall(vim.api.nvim_win_close, host_win, true)
  pcall(os.remove, path)
  pcall(vim.fn.delete, tmpdir, "rf")
end

T["open: HyprpilotPermissionResolved closes the preview on the matching request"] = function()
  diff_preview._reset()
  diff_preview.ensure_listeners()

  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  local path = tmpdir .. "/resolve.lua"
  local fh = assert(io.open(path, "w"))
  fh:write("a\nold\nz\n")
  fh:close()

  vim.cmd("split")
  local host_win = vim.api.nvim_get_current_win()
  require("hyprpilot.ui.window")._prev_winid = host_win

  local entry = mk_entry({ path = path, old_string = "old", new_string = "new" })
  diff_preview.open(entry)
  MiniTest.expect.equality(diff_preview.is_open(), true)

  vim.api.nvim_exec_autocmds("User", {
    pattern = "HyprpilotPermissionResolved",
    data = { request_id = entry.request_id, instance_id = entry.instance_id },
  })

  MiniTest.expect.equality(diff_preview.is_open(), false)

  pcall(vim.api.nvim_win_close, host_win, true)
  pcall(os.remove, path)
  pcall(vim.fn.delete, tmpdir, "rf")
end

T["open: HyprpilotInstanceStateChanged with terminal state closes the preview"] = function()
  diff_preview._reset()
  diff_preview.ensure_listeners()

  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  local path = tmpdir .. "/crash.lua"
  local fh = assert(io.open(path, "w"))
  fh:write("a\nold\nz\n")
  fh:close()

  vim.cmd("split")
  local host_win = vim.api.nvim_get_current_win()
  require("hyprpilot.ui.window")._prev_winid = host_win

  local entry = mk_entry({ path = path, old_string = "old", new_string = "new" })
  diff_preview.open(entry)

  vim.api.nvim_exec_autocmds("User", {
    pattern = "HyprpilotInstanceStateChanged",
    data = { instance_id = entry.instance_id, state = "crashed" },
  })

  MiniTest.expect.equality(diff_preview.is_open(), false)

  pcall(vim.api.nvim_win_close, host_win, true)
  pcall(os.remove, path)
  pcall(vim.fn.delete, tmpdir, "rf")
end

return T
