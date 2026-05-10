--- Behavioural tests for the chat fold UX. Each case opens a real
--- window so `:N,Mfold` actually creates a manual fold (foldclose is
--- a no-op when no window backs the buffer); we verify by reading
--- `foldclosed(line)` afterwards.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

local function fold_starts_at(winid, lnum)
  local out
  vim.api.nvim_win_call(winid, function()
    out = vim.fn.foldclosed(lnum)
  end)
  return out
end

T["hydrate folds older turns, keeps the most recent open"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)
  local winid = helpers.open_chat_window(bufnr)

  render.hydrate(state, {
    items = {
      { turnId = "t1", item = { kind = "user_prompt", text = "first" } },
      { turnId = "t1", item = { kind = "agent_text", text = "first reply" } },
      { turnId = "t2", item = { kind = "user_prompt", text = "second" } },
      { turnId = "t2", item = { kind = "agent_text", text = "second reply" } },
    },
  })

  -- L1 belongs to the oldest turn (t1) which should be folded.
  MiniTest.expect.equality(fold_starts_at(winid, 1) > 0, true)

  -- The latest turn's last line stays visible (foldclosed = -1).
  local last = vim.api.nvim_buf_line_count(bufnr)
  MiniTest.expect.equality(fold_starts_at(winid, last), -1)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

T["turn_ended folds the matching turn"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  render.state(id, bufnr)
  local winid = helpers.open_chat_window(bufnr)

  render.handle_turn_started({ instanceId = id, turnId = "t1" })
  render.handle_transcript({
    instanceId = id,
    turnId = "t1",
    item = { kind = "agent_text", text = "live reply" },
  })

  -- Active turn is open while streaming.
  local last_active = vim.api.nvim_buf_line_count(bufnr)
  MiniTest.expect.equality(fold_starts_at(winid, last_active), -1)

  render.handle_turn_ended({ instanceId = id, turnId = "t1", stopReason = "end_turn" })

  -- After end_turn, every line of t1 sits inside a closed fold.
  MiniTest.expect.equality(fold_starts_at(winid, last_active) > 0, true)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

T["tool_call_update completed folds the inner block"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  render.state(id, bufnr)
  local winid = helpers.open_chat_window(bufnr)

  render.handle_turn_started({ instanceId = id, turnId = "t1" })
  render.handle_transcript({
    instanceId = id,
    turnId = "t1",
    item = {
      kind = "tool_call",
      id = "tc-1",
      toolKind = "execute",
      title = "ls",
      state = "running",
      formatted = { title = "ls", stats = {}, fields = {} },
    },
  })

  -- Inner block is open while running.
  local before_lines = vim.api.nvim_buf_line_count(bufnr)
  MiniTest.expect.equality(fold_starts_at(winid, before_lines) > 0, false)

  render.handle_tool_call_update(id, {
    id = "tc-1",
    state = "completed",
    formatted = { title = "ls", stats = {}, fields = {}, output = "a\nb\nc" },
  })

  -- After completion the body is hidden behind a fold; the head row
  -- stays visible (it's the closed-fold display row), at least one
  -- inner row sits inside the closed fold.
  local total = vim.api.nvim_buf_line_count(bufnr)
  local found_closed = false
  for lnum = 1, total do
    if fold_starts_at(winid, lnum) > 0 then
      found_closed = true
      break
    end
  end
  MiniTest.expect.equality(found_closed, true)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

T["pending fold queue flushes when window appears"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  -- No window yet → fold operations should queue, not error.
  render.handle_turn_started({ instanceId = id, turnId = "t1" })
  render.handle_transcript({
    instanceId = id,
    turnId = "t1",
    item = { kind = "agent_text", text = "queued reply" },
  })
  render.handle_turn_ended({ instanceId = id, turnId = "t1", stopReason = "end_turn" })

  MiniTest.expect.equality(#state.pending_fold_rows > 0, true)

  -- Open the window + flush the queue.
  local winid = helpers.open_chat_window(bufnr)
  render.apply_pending_folds(bufnr)

  MiniTest.expect.equality(#state.pending_fold_rows, 0)

  local total = vim.api.nvim_buf_line_count(bufnr)
  local found_closed = false
  for lnum = 1, total do
    if fold_starts_at(winid, lnum) > 0 then
      found_closed = true
      break
    end
  end
  MiniTest.expect.equality(found_closed, true)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

return T
