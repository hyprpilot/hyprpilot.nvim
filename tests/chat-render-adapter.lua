--- Behavioural tests for the chat's `### adapter` section.
--- Durable `change_advertisement` transcript items render mode / model
--- / config chapter-break rows; `system_prompt_injected` remains the
--- side-event-only adapter note.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

---Mint a state with an optional hydrated transcript.
---@param items? table[]
---@return integer bufnr, string instance_id, table state
local function fresh_turn(items)
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)
  render.hydrate(state, { items = items or {} })
  return bufnr, id, state
end

local function lines_for(id)
  local buffer = require("hyprpilot.chat.buffer")
  local bufnr = buffer.find_by_name("hyprpilot://" .. id)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function count_line(lines, needle)
  local count = 0
  for _, line in ipairs(lines) do
    if line == needle then
      count = count + 1
    end
  end
  return count
end

T["adapter: live change_advertisement appends a mode row"] = function()
  local _, id, _ = fresh_turn()
  local render = require("hyprpilot.chat.render")

  render.handle_transcript({
    instanceId = id,
    turnId = "t1",
    item = {
      kind = "change_advertisement",
      type = "mode",
      value = "build",
      name = "Build",
      prevValue = "plan",
      prevName = "Plan",
    },
  })

  local lines = lines_for(id)
  MiniTest.expect.equality(helpers.has_line(lines, "### adapter [1 change]"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "mode · Plan → Build"), true)

  helpers.cleanup_instance(id)
end

T["adapter: hydrate replays mode model and config advertisements"] = function()
  local _, id, _ = fresh_turn({
    { turnId = "t1", item = { kind = "user_prompt", text = "go" } },
    {
      turnId = "t1",
      item = {
        kind = "change_advertisement",
        type = "mode",
        value = "build",
        name = "Build",
        prevValue = "plan",
        prevName = "Plan",
      },
    },
    {
      turnId = "t1",
      item = {
        kind = "change_advertisement",
        type = "model",
        value = "gpt-5.5",
        name = "GPT-5.5",
        prevValue = "gpt-5",
        prevName = "GPT-5",
      },
    },
    {
      turnId = "t1",
      item = {
        kind = "change_advertisement",
        type = "config_option",
        categoryId = "effort",
        value = "high",
        name = "High",
        prevValue = "medium",
        prevName = "Medium",
      },
    },
  })

  local lines = lines_for(id)
  MiniTest.expect.equality(helpers.has_line(lines, "### adapter [3 changes]"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "mode · Plan → Build"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "model · GPT-5 → GPT-5.5"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "effort · Medium → High"), true)

  helpers.cleanup_instance(id)
end

T["adapter: section sits ABOVE tasks / thoughts / tools (priority 0)"] = function()
  local _, id, _ = fresh_turn({
    { turnId = "t1", item = { kind = "user_prompt", text = "go" } },
    {
      turnId = "t1",
      item = {
        kind = "change_advertisement",
        type = "mode",
        value = "plan",
      },
    },
    { turnId = "t1", item = { kind = "agent_thought", text = "thinking..." } },
    { turnId = "t1", item = { kind = "agent_text", text = "done" } },
  })

  local lines = lines_for(id)

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

T["adapter: same advertisement re-firing is a silent no-op"] = function()
  local _, id, _ = fresh_turn()
  local render = require("hyprpilot.chat.render")

  for _ = 1, 3 do
    render.handle_transcript({
      instanceId = id,
      turnId = "t1",
      item = {
        kind = "change_advertisement",
        type = "mode",
        value = "plan",
      },
    })
  end

  MiniTest.expect.equality(count_line(lines_for(id), "mode · plan"), 1)

  helpers.cleanup_instance(id)
end

T["adapter: different values for same kind stack as history"] = function()
  local _, id, _ = fresh_turn()
  local render = require("hyprpilot.chat.render")

  render.handle_transcript({
    instanceId = id,
    turnId = "t1",
    item = { kind = "change_advertisement", type = "mode", value = "plan" },
  })
  render.handle_transcript({
    instanceId = id,
    turnId = "t1",
    item = { kind = "change_advertisement", type = "mode", value = "build" },
  })

  local lines = lines_for(id)
  MiniTest.expect.equality(helpers.has_line(lines, "mode · plan"), true)
  MiniTest.expect.equality(helpers.has_line(lines, "mode · build"), true)

  helpers.cleanup_instance(id)
end

T["adapter: nil-turn advertisement does not attach to stale current turn"] = function()
  local _, id, _ = fresh_turn({
    { turnId = "t1", item = { kind = "user_prompt", text = "go" } },
    { turnId = "t1", item = { kind = "agent_text", text = "ok" } },
    { item = { kind = "change_advertisement", type = "mode", value = "build" } },
  })

  MiniTest.expect.equality(helpers.has_line(lines_for(id), "mode · build"), false)

  helpers.cleanup_instance(id)
end

T["adapter: system_prompt_injected drops a basename-joined row"] = function()
  local _, id, _ = fresh_turn({
    { turnId = "t1", item = { kind = "user_prompt", text = "go" } },
    { turnId = "t1", item = { kind = "agent_text", text = "ok" } },
  })
  local render = require("hyprpilot.chat.render")

  render.handle_system_prompt_injected({
    instanceId = id,
    files = { "/repo/CLAUDE.md", "/repo/.ai/notes.md" },
  })

  MiniTest.expect.equality(helpers.has_line(lines_for(id), "system prompt · CLAUDE.md, notes.md"), true)

  helpers.cleanup_instance(id)
end

T["adapter: system prompt handler with no active turn is a silent no-op"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  render.state(id, bufnr)

  render.handle_system_prompt_injected({ instanceId = id, files = { "/repo/CLAUDE.md" } })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line(lines, "system prompt · CLAUDE.md"), false)

  helpers.cleanup_instance(id)
end

return T
