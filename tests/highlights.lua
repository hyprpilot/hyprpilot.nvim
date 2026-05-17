--- Behavioural tests for the highlight wiring. We assert that each
--- rendered block kind tags its rows with the expected
--- `line_hl_group` extmark — that's the contract a colorscheme or a
--- custom statusline-aware theme reads off, and it shifts visibly if
--- a future change drops the call by accident.

local helpers = require("tests.helpers")

-- Pin the badge glyphs to ASCII so the row-lookup assertions below
-- match (defaults are nerd-font glyphs). See `test_chat_render.lua`
-- for the same overlay.
require("hyprpilot.config").setup({
  icons = {
    tool_status = { completed = "[ok]", failed = "[fail]", pending = "[wait]", running = "[run]" },
    task_status = { pending = "[ ]", in_progress = "[~]", completed = "[x]" },
    turn_status = { ok = "", cancelled = "", error = "" },
  },
})

local T = MiniTest.new_set()

local HL_NS = vim.api.nvim_create_namespace("hyprpilot.render.hl")

---@param bufnr integer
---@param row integer
---@return string?
local function line_hl(bufnr, row)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, HL_NS, { row, 0 }, { row, -1 }, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details and details.line_hl_group then
      return details.line_hl_group
    end
  end
  return nil
end

---@param bufnr integer
---@param needle string
---@return integer?
local function row_of(bufnr, needle)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) ~= nil then
      return i - 1
    end
  end
  return nil
end

T["highlights.setup registers each Hyprpilot* group"] = function()
  require("hyprpilot.ui.highlights").setup()

  for name, _ in pairs(require("hyprpilot.ui.highlights").LINKS) do
    local hl = vim.api.nvim_get_hl(0, { name = name })
    MiniTest.expect.equality(hl ~= nil, true)
  end
end

T["tool_call applies status-driven header highlight + body highlight"] = function()
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
          state = "running",
          formatted = { title = "ls", stats = {}, fields = { { label = "command", value = "ls" } } },
        },
      },
    },
  })

  local header_row = row_of(bufnr, "[run]")
  MiniTest.expect.equality(header_row ~= nil, true)
  MiniTest.expect.equality(line_hl(bufnr, header_row), "HyprpilotToolStatusRunning")
  -- Body has no line_hl_group on purpose: markdown highlighter
  -- handles ` ```bash ` / ` ```console ` fenced blocks.
  MiniTest.expect.equality(line_hl(bufnr, header_row + 1), nil)

  -- Updating to completed flips the header highlight.
  render.handle_tool_call_update(id, {
    id = "tc-1",
    state = "completed",
    formatted = { title = "ls", stats = {}, fields = { { label = "command", value = "ls" } } },
  })

  local new_header_row = row_of(bufnr, "[ok]")
  MiniTest.expect.equality(new_header_row ~= nil, true)
  MiniTest.expect.equality(line_hl(bufnr, new_header_row), "HyprpilotToolStatusOk")

  helpers.cleanup_instance(id)
end

T["plan applies header + per-step highlights"] = function()
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
            { content = "A", status = "completed" },
            { content = "B", status = "in_progress" },
            { content = "C", status = "pending" },
          },
        },
      },
    },
  })

  -- The plan block dropped the `# plan` row entirely — the
  -- `### tasks [N/M done]` section header now carries the
  -- checklist stats. Per-step highlights remain on each step body
  -- row (highlighted by status).
  MiniTest.expect.equality(line_hl(bufnr, row_of(bufnr, "[x] A")), "HyprpilotPlanStepDone")
  MiniTest.expect.equality(line_hl(bufnr, row_of(bufnr, "[~] B")), "HyprpilotPlanStepInProgress")
  MiniTest.expect.equality(line_hl(bufnr, row_of(bufnr, "[ ] C")), "HyprpilotPlanStepPending")

  helpers.cleanup_instance(id)
end

T["permission_row enqueue paints the header/button highlights on its own buffer"] = function()
  local permission_row = require("hyprpilot.chat.permission-row")
  permission_row.reset()

  -- Permission row now filters its rendered head by active
  -- instance (multi-instance isolation). Ensure inst-1 is active
  -- so the enqueued request is the one that renders.
  local restore_active = helpers.stub_active_instance("inst-1")

  permission_row.enqueue("inst-1", {
    request_id = "req-1",
    tool = "Bash",
    options = {
      { optionId = "allow-once", name = "Allow" },
      { optionId = "reject-once", name = "Reject" },
    },
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  -- enqueue without the chat window visible only stages the queue;
  -- force a refresh to populate the row buffer for inspection.
  permission_row.refresh()

  local row_bufnr = permission_row._bufnr
  MiniTest.expect.equality(row_bufnr ~= nil, true)

  -- Permission row owns its own namespace; lookup directly there.
  local row_ns = vim.api.nvim_create_namespace("hyprpilot.chat.permission-row")
  local function row_line_hl(row)
    local marks = vim.api.nvim_buf_get_extmarks(row_bufnr, row_ns, { row, 0 }, { row, -1 }, { details = true })
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details and details.line_hl_group then
        return details.line_hl_group
      end
    end
    return nil
  end

  -- Header is now a markdown `#` line containing the tool name; the
  -- old `permission ·` prefix was retired in favour of the icon-led
  -- format. Locate it by the tool name "Bash".
  MiniTest.expect.equality(row_line_hl(row_of(row_bufnr, "Bash")), "HyprpilotPermissionHeader")
  MiniTest.expect.equality(row_line_hl(row_of(row_bufnr, "[> Allow <]")), "HyprpilotPermissionButton")

  permission_row.reset()
  restore_active()
end

T["agent_thought applies header + body highlights"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  render.hydrate(state, {
    items = {
      { turnId = "t1", item = { kind = "agent_thought", text = "first\nsecond" } },
    },
  })

  -- Thoughts now stream into a single block (no `* thought`
  -- per-chunk subheader) — find the body row directly via the
  -- streamed text. The first body line gets HyprpilotThoughtBody;
  -- subsequent body lines stay plain (markdown highlighter handles
  -- them).
  local body_row = row_of(bufnr, "first")
  MiniTest.expect.equality(line_hl(bufnr, body_row), "HyprpilotThoughtBody")
  MiniTest.expect.equality(line_hl(bufnr, body_row + 1), nil)

  helpers.cleanup_instance(id)
end

return T
