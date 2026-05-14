--- Behavioural tests for the `[h`/`]h` (turn) and `[s`/`]s` (section)
--- jump keymaps wired in `chat/keymaps.lua`. Both pull anchor rows
--- off the live `render._states` extmarks, so a hydrated chat with
--- multiple turns must surface every header to the jumper.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

local function fixture()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  -- Two pilot turns with a tools section in the second so we get
  -- both turn anchors AND a section anchor to jump between.
  render.hydrate(state, {
    items = {
      { turnId = "t1", item = { kind = "user_prompt", text = "first" } },
      { turnId = "t1", item = { kind = "agent_text", text = "first answer" } },
      { turnId = "t2", item = { kind = "user_prompt", text = "second" } },
      {
        turnId = "t2",
        item = {
          kind = "tool_call",
          id = "tc-jump",
          toolKind = "execute",
          title = "ls",
          state = "completed",
          formatted = { title = "ls", stats = {}, fields = { { label = "command", value = "ls" } } },
        },
      },
    },
  })

  return id, bufnr
end

T["]h jumps to the next pilot/captain turn header"] = function()
  local id, bufnr = fixture()

  -- Drive `attach` so the autocmd + keymap install happens (mirror
  -- of what chat/buffer.lua does on mint).
  require("hyprpilot.chat.keymaps").attach(bufnr)

  -- Open the buffer in a real window so cursor positioning works.
  vim.cmd("new")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  vim.cmd("normal ]h")
  local first_jump = vim.api.nvim_win_get_cursor(winid)[1]
  vim.cmd("normal ]h")
  local second_jump = vim.api.nvim_win_get_cursor(winid)[1]

  -- Two distinct turn headers — second jump must move us further
  -- down the buffer.
  MiniTest.expect.equality(second_jump > first_jump, true)

  pcall(vim.api.nvim_win_close, winid, true)
  helpers.cleanup_instance(id)
end

T["]s jumps to the next section header (### tools / ### thoughts)"] = function()
  local id, bufnr = fixture()
  require("hyprpilot.chat.keymaps").attach(bufnr)

  vim.cmd("new")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  vim.cmd("normal ]s")
  local row = vim.api.nvim_win_get_cursor(winid)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""

  -- Should land on a `###` section header.
  MiniTest.expect.equality(line:sub(1, 4), "### ")

  pcall(vim.api.nvim_win_close, winid, true)
  helpers.cleanup_instance(id)
end

return T
