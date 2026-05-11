--- Behavioural tests for the per-instance winbar driver.
--- Each case opens a real window so `winbar.render()` resolves the
--- right instance via the buffer name; we then assert on the
--- composed string (mode / model / usage / mcps chips) without
--- coupling to specific glyph choices beyond the segment text.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

local function open_chat_window_for(id)
  local buffer = require("hyprpilot.chat.buffer")
  local bufnr = buffer.create(id)
  local winid = helpers.open_chat_window(bufnr)
  return bufnr, winid
end

local function render_in_window(winid)
  local out
  vim.api.nvim_win_call(winid, function()
    out = require("hyprpilot.chat.winbar").render()
  end)
  return out
end

T["render returns empty when buffer is non-chat"] = function()
  local winbar = require("hyprpilot.chat.winbar")
  local out = winbar.render()
  -- The clean nvim used in tests likely has [No Name]; render should
  -- skip and return "".
  MiniTest.expect.equality(out, "")
end

T["instance_meta event surfaces mode + model + usage chips"] = function()
  local id = helpers.unique_id()
  local _, winid = open_chat_window_for(id)
  local winbar = require("hyprpilot.chat.winbar")

  winbar.update_meta(id, {
    current_mode_id = "plan",
    available_modes = { { id = "plan", name = "Plan" }, { id = "ask", name = "Ask" } },
    current_model_id = "sonnet",
    available_models = { { id = "sonnet", name = "Sonnet" }, { id = "opus", name = "Opus" } },
    usage = { used = 1234, size = 200000 },
  })

  local out = render_in_window(winid)
  MiniTest.expect.equality(out:find("Plan", 1, true) ~= nil, true)
  MiniTest.expect.equality(out:find("Sonnet", 1, true) ~= nil, true)
  MiniTest.expect.equality(out:find("1.2k", 1, true) ~= nil, true)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
  winbar.forget(id)
end

T["current_mode_update flips the mode chip"] = function()
  local id = helpers.unique_id()
  local _, winid = open_chat_window_for(id)
  local winbar = require("hyprpilot.chat.winbar")

  winbar.update_meta(id, {
    current_mode_id = "plan",
    available_modes = { { id = "plan", name = "Plan" }, { id = "ask", name = "Ask" } },
  })

  winbar.update_mode(id, "ask")

  local out = render_in_window(winid)
  MiniTest.expect.equality(out:find("Ask", 1, true) ~= nil, true)
  MiniTest.expect.equality(out:find("Plan", 1, true), nil)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
  winbar.forget(id)
end

T["usage_update overwrites the usage chip"] = function()
  local id = helpers.unique_id()
  local _, winid = open_chat_window_for(id)
  local winbar = require("hyprpilot.chat.winbar")

  winbar.update_usage(id, 100, 1000)
  local first = render_in_window(winid)
  MiniTest.expect.equality(first:find("100/", 1, true) ~= nil, true)

  winbar.update_usage(id, 5000, 200000)
  local second = render_in_window(winid)
  MiniTest.expect.equality(second:find("5.0k", 1, true) ~= nil, true)
  MiniTest.expect.equality(second:find("100/", 1, true), nil)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
  winbar.forget(id)
end

T["mcps_count surfaces only when > 0"] = function()
  local id = helpers.unique_id()
  local _, winid = open_chat_window_for(id)
  local winbar = require("hyprpilot.chat.winbar")

  winbar.update_meta(id, { mcps_count = 0 })
  MiniTest.expect.equality(render_in_window(winid):find("mcps", 1, true), nil)

  winbar.update_meta(id, { mcps_count = 3 })
  MiniTest.expect.equality(render_in_window(winid):find("+3 mcps", 1, true) ~= nil, true)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
  winbar.forget(id)
end

T["hydrate maps camelCase snapshot fields onto state"] = function()
  local id = helpers.unique_id()
  local _, winid = open_chat_window_for(id)
  local winbar = require("hyprpilot.chat.winbar")

  winbar.hydrate(id, {
    profileId = "default",
    sessionId = "sess-1",
    cwd = "/tmp",
    currentModeId = "plan",
    currentModelId = "sonnet",
    availableModes = { { id = "plan", name = "Plan" } },
    availableModels = { { id = "sonnet", name = "Sonnet" } },
    mcpsCount = 2,
    usage = { used = 42, size = 100 },
  })

  local out = render_in_window(winid)
  MiniTest.expect.equality(out:find("Plan", 1, true) ~= nil, true)
  MiniTest.expect.equality(out:find("Sonnet", 1, true) ~= nil, true)
  MiniTest.expect.equality(out:find("42/100", 1, true) ~= nil, true)
  MiniTest.expect.equality(out:find("+2 mcps", 1, true) ~= nil, true)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
  winbar.forget(id)
end

T["forget drops the meta state"] = function()
  local id = helpers.unique_id()
  local _, winid = open_chat_window_for(id)
  local winbar = require("hyprpilot.chat.winbar")

  winbar.update_meta(id, { current_mode_id = "plan", available_modes = { { id = "plan", name = "Plan" } } })
  MiniTest.expect.equality(render_in_window(winid):find("Plan", 1, true) ~= nil, true)

  winbar.forget(id)
  -- After forget the bar still renders the bare label but no chips.
  local out = render_in_window(winid)
  MiniTest.expect.equality(out:find("Plan", 1, true), nil)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

T["agent_attachment renders as a single labelled line"] = function()
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
          kind = "agent_attachment",
          slug = "diagram",
          path = "/tmp/diagram.svg",
          title = "Architecture",
          mime = "image/svg+xml",
        },
      },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "Architecture"), true)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "image/svg+xml"), true)
  MiniTest.expect.equality(helpers.has_line_containing(lines, "/tmp/diagram.svg"), true)

  helpers.cleanup_instance(id)
end

return T
