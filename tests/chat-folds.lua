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

T["hydrate does NOT fold turns (chat history stays scrollable)"] = function()
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

  -- Captain wants the conversation flow visible top-to-bottom.
  -- No turn-level folds — every line stays unfolded after hydrate.
  local total = vim.api.nvim_buf_line_count(bufnr)
  for lnum = 1, total do
    MiniTest.expect.equality(fold_starts_at(winid, lnum), -1)
  end

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

T["turn_ended folds plan/thought inner blocks but leaves the turn itself unfolded"] = function()
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
  render.handle_transcript({
    instanceId = id,
    turnId = "t1",
    item = { kind = "agent_thought", text = "let me think" },
  })
  render.handle_transcript({
    instanceId = id,
    turnId = "t1",
    item = {
      kind = "plan",
      steps = { { content = "step", status = "pending" } },
    },
  })

  -- Pre-end: nothing is folded.
  local total = vim.api.nvim_buf_line_count(bufnr)
  for lnum = 1, total do
    MiniTest.expect.equality(fold_starts_at(winid, lnum), -1)
  end

  render.handle_turn_ended({ instanceId = id, turnId = "t1", stopReason = "end_turn" })

  -- Some line is now inside a closed fold (the plan or thought
  -- block body), AND there's at least one line that's still
  -- visible (the agent_text under "## agent" — that's not in a
  -- foldable block).
  total = vim.api.nvim_buf_line_count(bufnr)
  local found_closed = false
  local found_open = false
  for lnum = 1, total do
    if fold_starts_at(winid, lnum) > 0 then
      found_closed = true
    else
      found_open = true
    end
  end
  MiniTest.expect.equality(found_closed, true)
  MiniTest.expect.equality(found_open, true)

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

  -- No window yet — folds triggered by completing a tool call queue
  -- onto state.pending_fold_rows instead of failing.
  render.handle_turn_started({ instanceId = id, turnId = "t1" })
  render.handle_transcript({
    instanceId = id,
    turnId = "t1",
    item = {
      kind = "tool_call",
      id = "tc-pending",
      toolKind = "execute",
      title = "ls",
      state = "running",
      formatted = { title = "ls", stats = {}, fields = {} },
    },
  })
  render.handle_tool_call_update(id, {
    id = "tc-pending",
    state = "completed",
    formatted = { title = "ls", stats = {}, fields = {}, output = "a" },
  })

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
