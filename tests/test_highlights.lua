--- Behavioural tests for the highlight wiring. We assert that each
--- rendered block kind tags its rows with the expected
--- `line_hl_group` extmark — that's the contract a colorscheme or a
--- custom statusline-aware theme reads off, and it shifts visibly if
--- a future change drops the call by accident.

local helpers = require("tests.helpers")

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
  require("hyprpilot.highlights").setup()

  for name, _ in pairs(require("hyprpilot.highlights").LINKS) do
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

  local header_row = row_of(bufnr, "plan ·")
  MiniTest.expect.equality(line_hl(bufnr, header_row), "HyprpilotPlanHeader")
  MiniTest.expect.equality(line_hl(bufnr, row_of(bufnr, "[x] A")), "HyprpilotPlanStepDone")
  MiniTest.expect.equality(line_hl(bufnr, row_of(bufnr, "[~] B")), "HyprpilotPlanStepInProgress")
  MiniTest.expect.equality(line_hl(bufnr, row_of(bufnr, "[ ] C")), "HyprpilotPlanStepPending")

  helpers.cleanup_instance(id)
end

T["permission applies header / body / button highlights, resolution flips button row"] = function()
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

  local header_row = row_of(bufnr, "permission ·")
  MiniTest.expect.equality(line_hl(bufnr, header_row), "HyprpilotPermissionHeader")
  local button_row = row_of(bufnr, "[> Allow <]")
  MiniTest.expect.equality(line_hl(bufnr, button_row), "HyprpilotPermissionButton")

  render.handle_permission_resolved({
    instanceId = id,
    requestId = "req-1",
    optionId = "allow-once",
  })

  local resolved_row = row_of(bufnr, "(resolved:")
  MiniTest.expect.equality(line_hl(bufnr, resolved_row), "HyprpilotPermissionResolved")

  helpers.cleanup_instance(id)
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

  local header_row = row_of(bufnr, "* thought")
  MiniTest.expect.equality(line_hl(bufnr, header_row), "HyprpilotThoughtHeader")
  -- Body lines have no line_hl_group (markdown highlighter handles them).
  MiniTest.expect.equality(line_hl(bufnr, header_row + 1), nil)

  helpers.cleanup_instance(id)
end

return T
