--- Behavioural tests for `hyprpilot.chat.render`.
---
--- Each case drives the public render entry points (`hydrate`,
--- `handle_*`) the same way live wire events would, then inspects the
--- resulting buffer text. We deliberately don't poke at extmark ids
--- or block table internals — those are means to an end; tests bind
--- to the visible output the captain reads.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["hydrate renders user prompt"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  render.hydrate(state, {
    items = { { turnId = "t1", item = { kind = "user_prompt", text = "ship it" } } },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line(lines, "ship it"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "## user"), true)

  helpers.cleanup_instance(id)
end

T["streaming agent_text chunks merge into one block"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  render.hydrate(state, {
    items = {
      { turnId = "t1", item = { kind = "user_prompt", text = "hi" } },
      { turnId = "t1", item = { kind = "agent_text", text = "Hello, " } },
      { turnId = "t1", item = { kind = "agent_text", text = "world!" } },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- The two chunks must coalesce onto one buffer line, not produce two
  -- separate "Hello, " and "world!" lines.
  MiniTest.expect.equality(helpers.has_line(lines, "Hello, world!"), true)

  helpers.cleanup_instance(id)
end

T["tool_call renders header + body, update patches the same block"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  render.hydrate(state, {
    items = {
      {
        turnId = "t1",
        item = {
          kind = "tool_call",
          id = "tc-1",
          toolKind = "execute",
          title = "bash",
          state = "running",
          formatted = {
            title = "ls -la",
            stats = {},
            fields = { { label = "command", value = "ls -la" } },
          },
        },
      },
    },
  })

  local lines_running = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line_containing(lines_running, "[run]"), true)
  MiniTest.expect.equality(helpers.has_line_containing(lines_running, "ls -la"), true)
  MiniTest.expect.equality(helpers.has_line(lines_running, "  command: ls -la"), true)

  render.handle_tool_call_update(id, {
    id = "tc-1",
    state = "completed",
    formatted = {
      title = "ls -la",
      stats = { { kind = "duration", ms = 234 } },
      fields = { { label = "command", value = "ls -la" } },
      output = "total 8",
    },
  })

  local lines_done = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Header flipped from running → ok and stats picked up the duration.
  MiniTest.expect.equality(helpers.has_line_containing(lines_done, "[ok]"), true)
  MiniTest.expect.equality(helpers.has_line_containing(lines_done, "234ms"), true)
  -- Output landed inside the same block (no duplicate "command:" line).
  MiniTest.expect.equality(helpers.has_line(lines_done, "  total 8"), true)

  local command_count = 0
  for _, l in ipairs(lines_done) do
    if l == "  command: ls -la" then
      command_count = command_count + 1
    end
  end
  MiniTest.expect.equality(command_count, 1)

  helpers.cleanup_instance(id)
end

T["plan renders checklist with done count"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  render.hydrate(state, {
    items = {
      {
        turnId = "t1",
        item = {
          kind = "plan",
          steps = {
            { content = "Read", status = "completed" },
            { content = "Write", status = "in_progress" },
            { content = "Test", status = "pending" },
          },
        },
      },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "1/3 done"), true)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "[x] Read"), true)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "[~] Write"), true)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "[ ] Test"), true)

  helpers.cleanup_instance(id)
end

T["agent_thought renders header + indented body"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  render.hydrate(state, {
    items = {
      { turnId = "t1", item = { kind = "agent_thought", text = "step 1\nstep 2" } },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line(lines, "* thought"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "  step 1"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "  step 2"), true)

  helpers.cleanup_instance(id)
end

T["permission_request renders button row, resolved replaces it"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  render.state(id, bufnr)

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

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Focused button gets `[> Allow <]`-style markers; unfocused get plain brackets.
  MiniTest.expect.equality(helpers.has_line_containing(lines, "[> Allow <]"), true)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "[ Reject ]"), true)

  render.handle_permission_resolved({
    instanceId = id,
    requestId = "req-1",
    optionId = "allow-once",
  })

  local lines_after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line_containing(lines_after, "(resolved: allow-once)"), true)
  -- The focused-button marker should be gone; the row was replaced.
  MiniTest.expect.equality(helpers.has_line_containing(lines_after, "[> Allow <]"), false)

  helpers.cleanup_instance(id)
end

T["unknown wire kind logs warn but doesn't crash render"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  -- Should not throw; the placeholder renderer absorbs unknown kinds.
  render.hydrate(state, {
    items = { { turnId = "t1", item = { kind = "unknown", wireKind = "future_thing" } } },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "future_thing"), true)

  helpers.cleanup_instance(id)
end

return T
