--- Behavioural tests for local chat-buffer trimming. The daemon
--- transcript is not involved here; trim only mutates the rendered
--- Neovim buffer and the extmark-backed render state.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

---@param count integer
---@param live_tail boolean?
---@return string id, integer bufnr, table state
local function hydrate_turns(count, live_tail)
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)
  local items = {}

  for i = 1, count do
    local turn_id = "t" .. tostring(i)
    table.insert(items, { turnId = turn_id, item = { kind = "user_prompt", text = "prompt " .. tostring(i) } })
    table.insert(items, { turnId = turn_id, item = { kind = "agent_text", text = "answer " .. tostring(i) } })
  end

  render.hydrate(state, { items = items, hasMore = false })

  local ended_count = live_tail and count - 1 or count
  for i = 1, ended_count do
    render.handle_turn_ended({ instanceId = id, turnId = "t" .. tostring(i), stopReason = "end_turn" })
  end

  return id, bufnr, state
end

T["trim keeps the rendered tail and drops old local lines"] = function()
  local id, bufnr, state = hydrate_turns(12)
  local before = vim.api.nvim_buf_line_count(bufnr)

  local result = require("hyprpilot.chat.render").trim(state, { keep_lines = 20 })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(result.removed > 0, true)
  MiniTest.expect.equality(#lines < before, true)
  MiniTest.expect.equality(#lines <= 20, true)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "prompt 1"), false)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "answer 12"), true)
  MiniTest.expect.equality(state.has_more, true)

  helpers.cleanup_instance(id)
end

T["window trim defaults to the active instance"] = function()
  local id, bufnr, _ = hydrate_turns(8)
  require("hyprpilot.chat.window").register({ bufnr = bufnr, instance_id = id }, { activate = true })

  local result = require("hyprpilot.chat.window").trim({ keep_lines = 12 })
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  MiniTest.expect.equality(result.removed > 0, true)
  MiniTest.expect.equality(#lines <= 12, true)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "answer 8"), true)

  helpers.cleanup_instance(id)
end

T["trim preserves a live tail even when keep_lines is tiny"] = function()
  local id, bufnr, state = hydrate_turns(6, true)

  local result = require("hyprpilot.chat.render").trim(state, { keep_lines = 1 })
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  MiniTest.expect.equality(result.removed > 0, true)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "prompt 6"), true)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "answer 6"), true)
  MiniTest.expect.equality(state.current_turn, "t6")

  helpers.cleanup_instance(id)
end

return T
