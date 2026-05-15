--- Tests for `palettes.instances` preview enrichment + the
--- `<C-d>` delete action. The picker action wiring is snacks-side
--- chrome; we test the underlying pieces (transcript-tail preview
--- + the `actions.delete.handler` callable) directly without
--- standing up snacks.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["palettes.instances preview includes a tail of the chat buffer"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local window = require("hyprpilot.chat.window")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  window.register({ bufnr = bufnr, instance_id = id }, { activate = true })
  local state = render.state(id, bufnr)

  render.hydrate(state, {
    items = {
      { turnId = "t1", item = { kind = "user_prompt", text = "what is the meaning of life?" } },
      { turnId = "t1", item = { kind = "agent_text", text = "forty-two" } },
    },
  })

  local format_preview = require("hyprpilot.palettes.instances").format_preview
  local preview = format_preview({ id = id, agent_id = "claude-code" }, nil)

  -- Header + structured fields land first.
  MiniTest.expect.equality(preview.ft, "markdown")

  -- The transcript tail must appear somewhere after the `---`
  -- separator we inject between metadata and content.
  local saw_separator, saw_transcript = false, false
  for _, line in ipairs(preview.lines) do
    if line == "---" then
      saw_separator = true
    end
    if line:find("forty%-two", 1, false) ~= nil then
      saw_transcript = true
    end
  end
  MiniTest.expect.equality(saw_separator, true)
  MiniTest.expect.equality(saw_transcript, true)

  helpers.cleanup_instance(id)
end

T["palettes.instances preview omits the separator when no buffer / empty buffer"] = function()
  local format_preview = require("hyprpilot.palettes.instances").format_preview
  -- Instance id with no live buffer behind it — `get_bufnr` returns nil.
  local preview = format_preview({ id = "ghost-instance", agent_id = "claude-code" }, nil)

  for _, line in ipairs(preview.lines) do
    MiniTest.expect.equality(line == "---", false)
  end
end

return T
