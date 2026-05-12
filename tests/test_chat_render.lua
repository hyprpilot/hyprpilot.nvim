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
  MiniTest.expect.equality(helpers.has_line(lines, "## captain"), true)

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
  -- Single-field, single-line, execute-shaped tool → renders as a
  -- fenced ` ```bash ` block, not a `command: ls -la` line.
  MiniTest.expect.equality(helpers.has_line(lines_running, "````bash"), true)
  MiniTest.expect.equality(helpers.has_line(lines_running, "ls -la"), true)

  render.handle_tool_call_update(id, {
    id = "tc-1",
    toolKind = "execute",
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
  -- Output landed inside the same block as a ` ```console ` block.
  MiniTest.expect.equality(helpers.has_line(lines_done, "total 8"), true)
  MiniTest.expect.equality(helpers.has_line(lines_done, "````console"), true)

  helpers.cleanup_instance(id)
end

T["tool_call with formatted.diff renders a fenced diff block (skips Shiki-marker description)"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  -- Daemon-side `feat(formatter): add plain git-diff field alongside
  -- Shiki-marker description` (PR #44) ships both surfaces on Edit /
  -- Write / MultiEdit. We must prefer the unified `diff` field and
  -- skip the description (which carries Shiki `[!code ++]` markers
  -- meant for the desktop overlay's transformer pipeline).
  render.hydrate(state, {
    items = {
      {
        turnId = "t1",
        item = {
          kind = "tool_call",
          id = "tc-1",
          toolKind = "edit",
          title = "Edit src/main.rs",
          state = "completed",
          formatted = {
            title = "Edit src/main.rs",
            stats = {},
            fields = {},
            description = "```rust\n// [!code --]\nold line\n// [!code ++]\nnew line\n```",
            diff = "diff --git a/src/main.rs b/src/main.rs\n--- a/src/main.rs\n+++ b/src/main.rs\n@@ -1,1 +1,1 @@\n-old line\n+new line",
          },
        },
      },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- The diff fence opens + closes with 4-backtick `diff` fences.
  MiniTest.expect.equality(helpers.has_line(lines, "````diff"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "````"), true)
  -- Patch payload survived line-split.
  MiniTest.expect.equality(helpers.has_line(lines, "diff --git a/src/main.rs b/src/main.rs"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "-old line"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "+new line"), true)
  -- The Shiki marker from `description` did NOT land in the buffer
  -- (would surface as raw text under markdown, ugly).
  MiniTest.expect.equality(helpers.has_line_containing(lines, "[!code"), false)

  helpers.cleanup_instance(id)
end

T["tool_call falls through to description when formatted.diff is absent"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  -- A tool that doesn't ship `diff` (Bash, Grep, Glob, etc.) still
  -- renders its plain `description` text the way it always has.
  render.hydrate(state, {
    items = {
      {
        turnId = "t1",
        item = {
          kind = "tool_call",
          id = "tc-2",
          toolKind = "fetch",
          title = "fetch https://example.com",
          state = "completed",
          formatted = {
            title = "fetch",
            stats = {},
            fields = {},
            description = "Fetched 200 OK in 132ms",
          },
        },
      },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line(lines, "Fetched 200 OK in 132ms"), true)
  -- No spurious empty diff fence when there was no diff payload.
  MiniTest.expect.equality(helpers.has_line(lines, "````diff"), false)

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

T["agent_thought renders header + body bracketed by --- separators"] = function()
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
  MiniTest.expect.equality(helpers.has_line(lines, "---"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "step 1"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "step 2"), true)

  helpers.cleanup_instance(id)
end

T["permission_request never lands in the chat buffer (handled by permission_row)"] = function()
  local render = require("hyprpilot.chat.render")
  local permission_row = require("hyprpilot.chat.permission_row")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  render.state(id, bufnr)
  permission_row.reset()

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

  -- Chat buffer must remain free of permission chrome — the row owns
  -- the entire interaction surface.
  local chat_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line_containing(chat_lines, "permission"), false)
  MiniTest.expect.equality(helpers.has_line_containing(chat_lines, "[> Allow <]"), false)

  -- The row module's queue, however, should now hold the request.
  MiniTest.expect.equality(#permission_row._queue, 1)
  MiniTest.expect.equality(permission_row._queue[1].request_id, "req-1")

  permission_row.reset()
  helpers.cleanup_instance(id)
end

T["pilot turn aggregates plan/thought/tool into ### sections in priority order with prose below"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  -- Drive the items in arrival-order opposite to canonical section
  -- priority (tools first, then thought, then plan) — the canonical
  -- order tasks → thoughts → tools should still emerge in the buffer.
  -- Prose lands at the very end regardless of arrival order, even
  -- though more sections show up after it.
  render.hydrate(state, {
    items = {
      { turnId = "t1", item = { kind = "agent_text", text = "early prose" } },
      {
        turnId = "t1",
        item = {
          kind = "tool_call",
          id = "tc-1",
          toolKind = "execute",
          title = "ls",
          state = "completed",
          formatted = { title = "ls", stats = {}, fields = { { label = "command", value = "ls" } } },
        },
      },
      { turnId = "t1", item = { kind = "agent_thought", text = "thinking" } },
      {
        turnId = "t1",
        item = {
          kind = "plan",
          steps = { { content = "A", status = "completed" } },
        },
      },
      { turnId = "t1", item = { kind = "agent_text", text = " continued" } },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local function index_of(predicate)
    for i, l in ipairs(lines) do
      if predicate(l) then
        return i
      end
    end
    return nil
  end

  local pilot = index_of(function(l)
    return l == "## pilot"
  end)
  -- Section headers carry a `[N <unit>]` chip after the first item
  -- lands, so match by prefix rather than exact string.
  local tasks = index_of(function(l)
    return l:find("^### tasks") ~= nil
  end)
  local thoughts = index_of(function(l)
    return l:find("^### thoughts") ~= nil
  end)
  local tools = index_of(function(l)
    return l:find("^### tools") ~= nil
  end)
  local prose = index_of(function(l)
    return l:find("early prose", 1, true) ~= nil
  end)
  local prose_tail = index_of(function(l)
    return l:find("continued", 1, true) ~= nil
  end)

  MiniTest.expect.equality(pilot ~= nil, true)
  MiniTest.expect.equality(tasks ~= nil, true)
  MiniTest.expect.equality(thoughts ~= nil, true)
  MiniTest.expect.equality(tools ~= nil, true)
  MiniTest.expect.equality(prose ~= nil, true)
  MiniTest.expect.equality(prose_tail ~= nil, true)
  -- Canonical order: pilot < tasks < thoughts < tools < prose < prose_tail.
  MiniTest.expect.equality(pilot < tasks, true)
  MiniTest.expect.equality(tasks < thoughts, true)
  MiniTest.expect.equality(thoughts < tools, true)
  MiniTest.expect.equality(tools < prose, true)
  MiniTest.expect.equality(prose < prose_tail, true)

  helpers.cleanup_instance(id)
end

T["permission_resolved drops the request from the row queue"] = function()
  local render = require("hyprpilot.chat.render")
  local permission_row = require("hyprpilot.chat.permission_row")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  render.state(id, bufnr)
  permission_row.reset()

  render.handle_permission_request({
    instanceId = id,
    requestId = "req-x",
    tool = "Bash",
    options = { { optionId = "allow", name = "Allow" }, { optionId = "reject", name = "Reject" } },
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  MiniTest.expect.equality(#permission_row._queue, 1)

  render.handle_permission_resolved({ instanceId = id, requestId = "req-x", optionId = "allow" })

  MiniTest.expect.equality(#permission_row._queue, 0)

  helpers.cleanup_instance(id)
end

T["pilot header repaints with usage / elapsed chips on live updates"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  render.state(id, bufnr)

  -- Wall-clock start + later end so the elapsed chip is meaningful;
  -- we just want SOME duration in the header, not the exact value.
  local start_ms = (os.time() - 5) * 1000
  render.handle_turn_started({ instanceId = id, turnId = "t1", startedAt = start_ms })
  render.handle_transcript({ instanceId = id, turnId = "t1", item = { kind = "agent_text", text = "hello" } })

  -- Usage_update fires; pilot header should grow `120k/200k` + `$0.74` chips.
  render.handle_usage_update({
    instanceId = id,
    used = 120000,
    size = 200000,
    cost = { amount = 0.74, currency = "USD" },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local pilot_line
  for _, l in ipairs(lines) do
    if l:find("^## pilot") then
      pilot_line = l
      break
    end
  end

  MiniTest.expect.equality(pilot_line ~= nil, true)
  MiniTest.expect.equality(pilot_line:find("[120k/200k]", 1, true) ~= nil, true)
  MiniTest.expect.equality(pilot_line:find("[$0.74]", 1, true) ~= nil, true)

  helpers.cleanup_instance(id)
end

T["section headers carry `[N <unit>]` chips that grow with item_count"] = function()
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
          title = "ls",
          state = "completed",
          formatted = { title = "ls", stats = {}, fields = { { label = "command", value = "ls" } } },
        },
      },
      {
        turnId = "t1",
        item = {
          kind = "tool_call",
          id = "tc-2",
          toolKind = "execute",
          title = "echo",
          state = "completed",
          formatted = { title = "echo hi", stats = {}, fields = { { label = "command", value = "echo hi" } } },
        },
      },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tools_line
  for _, l in ipairs(lines) do
    if l:find("^### tools") then
      tools_line = l
      break
    end
  end

  MiniTest.expect.equality(tools_line ~= nil, true)
  -- Two tool_calls registered → `[2 calls]` chip.
  MiniTest.expect.equality(tools_line:find("[2 calls]", 1, true) ~= nil, true)

  helpers.cleanup_instance(id)
end

T["agent_attachment lands in ### attachments section after tools"] = function()
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
          title = "ls",
          state = "completed",
          formatted = { title = "ls", stats = {}, fields = { { label = "command", value = "ls" } } },
        },
      },
      { turnId = "t1", item = { kind = "agent_attachment", title = "report.pdf", mime = "application/pdf", path = "/tmp/report.pdf" } },
      { turnId = "t1", item = { kind = "agent_attachment", title = "diagram.png", mime = "image/png", path = "/tmp/diagram.png" } },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local function index_of(predicate)
    for i, l in ipairs(lines) do
      if predicate(l) then
        return i
      end
    end
    return nil
  end

  local tools = index_of(function(l)
    return l:find("^### tools") ~= nil
  end)
  local attachments = index_of(function(l)
    return l:find("^### attachments") ~= nil
  end)
  local first_attachment = index_of(function(l)
    return l:find("@ report.pdf", 1, true) ~= nil
  end)
  local second_attachment = index_of(function(l)
    return l:find("@ diagram.png", 1, true) ~= nil
  end)

  MiniTest.expect.equality(tools ~= nil, true)
  MiniTest.expect.equality(attachments ~= nil, true)
  MiniTest.expect.equality(first_attachment ~= nil, true)
  MiniTest.expect.equality(second_attachment ~= nil, true)
  -- Order: tools section header < attachments section header < both attachments.
  MiniTest.expect.equality(tools < attachments, true)
  MiniTest.expect.equality(attachments < first_attachment, true)
  MiniTest.expect.equality(first_attachment < second_attachment, true)
  -- Header chip should reflect the count.
  local attach_line = lines[attachments]
  MiniTest.expect.equality(attach_line:find("[2 files]", 1, true) ~= nil, true)

  helpers.cleanup_instance(id)
end

T["replay with shared turn_id across multiple user_prompts splits into separate exchanges"] = function()
  -- Regression for the session-replay bug: during `instance/snapshot/chat`
  -- replay the daemon ships a single synthetic turn_id for the whole
  -- replay window (no TurnStarted boundaries fire between historical
  -- turns). Without exchange-based partitioning, every user_prompt
  -- and every agent response collapsed under one ## captain / ## pilot
  -- header pair. The fix bumps an exchange counter on each
  -- user_prompt → agent role transition and namespaces the daemon
  -- turn_id under that counter.
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  render.hydrate(state, {
    items = {
      -- Three exchanges, ALL keyed to the same synthetic turn_id
      -- the way a session replay actually arrives from the daemon.
      { turnId = "synthetic-x", item = { kind = "user_prompt", text = "first prompt" } },
      { turnId = "synthetic-x", item = { kind = "agent_text", text = "first reply" } },
      { turnId = "synthetic-x", item = { kind = "user_prompt", text = "second prompt" } },
      { turnId = "synthetic-x", item = { kind = "agent_text", text = "second reply" } },
      { turnId = "synthetic-x", item = { kind = "user_prompt", text = "third prompt" } },
      { turnId = "synthetic-x", item = { kind = "agent_text", text = "third reply" } },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Count `## captain` / `## pilot` (allowing the stat-chip suffix
  -- the pilot header may carry, so we match on the prefix only).
  local captain_headers = 0
  local pilot_headers = 0
  for _, l in ipairs(lines) do
    if l == "## captain" then
      captain_headers = captain_headers + 1
    elseif l:find("^## pilot") then
      pilot_headers = pilot_headers + 1
    end
  end

  MiniTest.expect.equality(captain_headers, 3)
  MiniTest.expect.equality(pilot_headers, 3)

  -- All three prompt + reply bodies still landed in order.
  MiniTest.expect.equality(helpers.has_line(lines, "first prompt"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "first reply"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "second prompt"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "second reply"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "third prompt"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "third reply"), true)

  helpers.cleanup_instance(id)
end

T["replay with distinct turn_ids per turn still produces one header per turn"] = function()
  -- Live-flow happy path — make sure the exchange-namespacing
  -- doesn't double-count when the daemon DOES ship distinct
  -- turn_ids (post-session-load, when TurnStarted boundaries
  -- arrive between turns). Two prompts, two distinct turn ids,
  -- expect exactly two captain + two pilot headers.
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  render.hydrate(state, {
    items = {
      { turnId = "turn-a", item = { kind = "user_prompt", text = "p1" } },
      { turnId = "turn-a", item = { kind = "agent_text", text = "r1" } },
      { turnId = "turn-b", item = { kind = "user_prompt", text = "p2" } },
      { turnId = "turn-b", item = { kind = "agent_text", text = "r2" } },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local captain_headers, pilot_headers = 0, 0
  for _, l in ipairs(lines) do
    if l == "## captain" then
      captain_headers = captain_headers + 1
    elseif l:find("^## pilot") then
      pilot_headers = pilot_headers + 1
    end
  end
  MiniTest.expect.equality(captain_headers, 2)
  MiniTest.expect.equality(pilot_headers, 2)

  helpers.cleanup_instance(id)
end

T["empty agent_thought drops the event (no placeholder, no section)"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  render.hydrate(state, {
    items = {
      { turnId = "t1", item = { kind = "agent_text", text = "hello" } },
      { turnId = "t1", item = { kind = "agent_thought", text = "" } },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- No `### thoughts` header, no `* (empty thought)` placeholder, no
  -- vestigial `* thought` line. The empty event was a no-op.
  MiniTest.expect.equality(helpers.has_line_containing(lines, "### thoughts"), false)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "thought"), false)
  -- The agent_text that came WITH the empty thought still landed.
  MiniTest.expect.equality(helpers.has_line(lines, "hello"), true)

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
