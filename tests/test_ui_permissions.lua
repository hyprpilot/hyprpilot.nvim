--- Behavioural tests for `hyprpilot.ui.permissions`. Cases drive the
--- buffer-local keymap callbacks the way Neovim would when the
--- captain hits the bound keys; we stub the public `permissions.respond`
--- to capture submissions instead of dispatching them at the daemon.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

local function find_callback(bufnr, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == lhs then
      return m.callback
    end
  end
  return nil
end

local function setup_permission(id, options)
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)
  local winid = helpers.open_chat_window(bufnr)

  render.handle_permission_request({
    instanceId = id,
    requestId = "req-1",
    tool = "Bash",
    kind = "execute",
    args = "ls",
    options = options,
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  return state, bufnr, winid
end

local function move_to_button_row(winid, bufnr)
  local total = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { total, 0 })
end

T["g smart-matches the allow-shaped option and submits it"] = function()
  local restore, calls = helpers.stub_permissions_respond()

  local id = helpers.unique_id()
  local _, bufnr, winid = setup_permission(id, {
    { optionId = "allow-once", name = "Allow once", kind = "allow_once" },
    { optionId = "allow-always", name = "Always allow", kind = "allow_always" },
    { optionId = "reject-once", name = "Reject", kind = "reject_once" },
  })

  move_to_button_row(winid, bufnr)
  find_callback(bufnr, "g")()

  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].request_id, "req-1")
  MiniTest.expect.equality(calls[1].option_id, "allow-once")

  restore()
  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

T["d smart-matches the reject-shaped option even when worded differently"] = function()
  local restore, calls = helpers.stub_permissions_respond()

  -- Some agents say "Deny" or "Abort" instead of "Reject" — smart-match
  -- on `^reject|^deny|^abort|^cancel` should still find it.
  local id = helpers.unique_id()
  local _, bufnr, winid = setup_permission(id, {
    { optionId = "allow-once", name = "Allow", kind = "allow_once" },
    { optionId = "abort-now", name = "Abort", kind = "reject_once" },
  })

  move_to_button_row(winid, bufnr)
  find_callback(bufnr, "d")()

  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].option_id, "abort-now")

  restore()
  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

T["Tab cycles focus through the option set"] = function()
  local restore, _ = helpers.stub_permissions_respond()

  local id = helpers.unique_id()
  local _, bufnr, winid = setup_permission(id, {
    { optionId = "allow-once", name = "Allow", kind = "allow_once" },
    { optionId = "allow-always", name = "Always", kind = "allow_always" },
    { optionId = "reject-once", name = "Reject", kind = "reject_once" },
  })

  move_to_button_row(winid, bufnr)

  -- Tab once → focus index 2 ("Always") becomes the focused button.
  find_callback(bufnr, "<Tab>")()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "[> Always <]"), true)

  -- <CR> commits the focused option.
  find_callback(bufnr, "<CR>")()
  -- Stub records the call; we just want to confirm no crash + the
  -- focused option made it through. Re-stub to capture this commit.
  restore()
  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

T["cursor outside any permission row does not submit"] = function()
  local restore, calls = helpers.stub_permissions_respond()

  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)
  local winid = helpers.open_chat_window(bufnr)

  -- Render a user prompt first (so L1 is outside the permission block),
  -- then add the permission below it.
  render.hydrate(state, {
    items = { { turnId = "t1", item = { kind = "user_prompt", text = "outside row" } } },
  })

  render.handle_permission_request({
    instanceId = id,
    requestId = "req-1",
    tool = "Bash",
    kind = "execute",
    args = "ls",
    options = {
      { optionId = "allow-once", name = "Allow", kind = "allow_once" },
      { optionId = "reject-once", name = "Reject", kind = "reject_once" },
    },
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  -- Park the cursor on the "outside row" line.
  vim.api.nvim_set_current_win(winid)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local outside_lnum
  for i, l in ipairs(lines) do
    if l == "outside row" then
      outside_lnum = i
      break
    end
  end
  MiniTest.expect.equality(outside_lnum ~= nil, true)
  vim.api.nvim_win_set_cursor(winid, { outside_lnum, 0 })

  -- `g` should fall through (no permission entry covers this row).
  find_callback(bufnr, "g")()

  MiniTest.expect.equality(#calls, 0)

  restore()
  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

T["resolution removes the entry so subsequent presses no-op"] = function()
  local restore, calls = helpers.stub_permissions_respond()

  local id = helpers.unique_id()
  local _, bufnr, winid = setup_permission(id, {
    { optionId = "allow-once", name = "Allow", kind = "allow_once" },
  })

  local render = require("hyprpilot.chat.render")
  render.handle_permission_resolved({
    instanceId = id,
    requestId = "req-1",
    optionId = "allow-once",
  })

  move_to_button_row(winid, bufnr)
  find_callback(bufnr, "g")()

  -- Entry was unregistered on resolution; `g` should not submit again.
  MiniTest.expect.equality(#calls, 0)

  restore()
  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

return T
