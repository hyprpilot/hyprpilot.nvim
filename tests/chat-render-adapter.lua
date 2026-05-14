--- Behavioural tests for the chat's `### adapter` section.
--- Drives `render.handle_current_mode_update` / `_config_options_update`
--- / `_system_prompt_injected` against a live pilot turn and asserts
--- the section + rows appear in the buffer with the expected
--- ordering (adapter ABOVE tasks / thoughts / tools).

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

---Mint a state with a pilot turn already hydrated so adapter notes
---have a layout to attach to.
---@return integer bufnr, string instance_id
local function fresh_turn(items)
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)
  render.hydrate(state, { items = items or {} })
  return bufnr, id, state
end

T["adapter: current_mode_update appends a `mode · <name>` row"] = function()
  local _, id, _ = fresh_turn({
    { turnId = "t1", item = { kind = "user_prompt", text = "go" } },
    { turnId = "t1", item = { kind = "agent_text", text = "ok" } },
  })
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")

  render.handle_current_mode_update({ instanceId = id, currentModeId = "plan" })

  local bufnr = buffer.find_by_name("hyprpilot://" .. id)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line(lines, "### adapter [1 change]"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "mode · plan"), true)

  helpers.cleanup_instance(id)
end

T["adapter: section sits ABOVE tasks / thoughts / tools (priority 0)"] = function()
  local _, id, _ = fresh_turn({
    { turnId = "t1", item = { kind = "user_prompt", text = "go" } },
    { turnId = "t1", item = { kind = "agent_thought", text = "thinking..." } },
    { turnId = "t1", item = { kind = "agent_text", text = "done" } },
  })
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")

  render.handle_current_mode_update({ instanceId = id, currentModeId = "plan" })

  local bufnr = buffer.find_by_name("hyprpilot://" .. id)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local adapter_idx, thoughts_idx
  for i, l in ipairs(lines) do
    if l:find("^### adapter") then
      adapter_idx = i
    elseif l:find("^### thoughts") then
      thoughts_idx = i
    end
  end

  MiniTest.expect.equality(adapter_idx ~= nil and thoughts_idx ~= nil, true)
  MiniTest.expect.equality(adapter_idx < thoughts_idx, true)

  helpers.cleanup_instance(id)
end

T["adapter: same value re-firing is a silent no-op (dedup per kind)"] = function()
  local _, id, _ = fresh_turn({
    { turnId = "t1", item = { kind = "user_prompt", text = "go" } },
    { turnId = "t1", item = { kind = "agent_text", text = "ok" } },
  })
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")

  render.handle_current_mode_update({ instanceId = id, currentModeId = "plan" })
  render.handle_current_mode_update({ instanceId = id, currentModeId = "plan" })
  render.handle_current_mode_update({ instanceId = id, currentModeId = "plan" })

  local bufnr = buffer.find_by_name("hyprpilot://" .. id)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local mode_rows = 0
  for _, l in ipairs(lines) do
    if l == "mode · plan" then
      mode_rows = mode_rows + 1
    end
  end
  MiniTest.expect.equality(mode_rows, 1)

  helpers.cleanup_instance(id)
end

T["adapter: different values for same kind stack as history"] = function()
  local _, id, _ = fresh_turn({
    { turnId = "t1", item = { kind = "user_prompt", text = "go" } },
    { turnId = "t1", item = { kind = "agent_text", text = "ok" } },
  })
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")

  render.handle_current_mode_update({ instanceId = id, currentModeId = "plan" })
  render.handle_current_mode_update({ instanceId = id, currentModeId = "default" })

  local bufnr = buffer.find_by_name("hyprpilot://" .. id)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line(lines, "mode · plan"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "mode · default"), true)

  helpers.cleanup_instance(id)
end

T["adapter: config_options_update emits one row per category"] = function()
  local _, id, _ = fresh_turn({
    { turnId = "t1", item = { kind = "user_prompt", text = "go" } },
    { turnId = "t1", item = { kind = "agent_text", text = "ok" } },
  })
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")

  render.handle_config_options_update({
    instanceId = id,
    categories = {
      {
        id = "effort",
        name = "Effort",
        currentValue = "high",
        options = {
          { value = "low", name = "Low" },
          { value = "high", name = "High" },
        },
      },
    },
  })

  local bufnr = buffer.find_by_name("hyprpilot://" .. id)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line(lines, "effort · High"), true)

  helpers.cleanup_instance(id)
end

T["adapter: system_prompt_injected drops a basename-joined row"] = function()
  local _, id, _ = fresh_turn({
    { turnId = "t1", item = { kind = "user_prompt", text = "go" } },
    { turnId = "t1", item = { kind = "agent_text", text = "ok" } },
  })
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")

  render.handle_system_prompt_injected({
    instanceId = id,
    files = { "/repo/CLAUDE.md", "/repo/.ai/notes.md" },
  })

  local bufnr = buffer.find_by_name("hyprpilot://" .. id)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line(lines, "system prompt · CLAUDE.md, notes.md"), true)

  helpers.cleanup_instance(id)
end

T["adapter: handler with no active turn is a silent no-op"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  render.state(id, bufnr)

  -- No turn hydrated → state.current_turn is nil. Handler should
  -- bail without throwing or writing to the buffer.
  render.handle_current_mode_update({ instanceId = id, currentModeId = "plan" })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line(lines, "mode · plan"), false)

  helpers.cleanup_instance(id)
end

return T
