--- Behavioural tests for chat code-block folds.
---
--- The captain wants every fenced code block in chat content to be
--- foldable via native vim motions, but NEVER auto-folded. Each
--- case hydrates a chat with prose containing a fenced block, opens
--- a real window on the buffer (folds only attach to live windows),
--- then asserts the fold exists but stays open.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["hydrate creates open folds over fenced code blocks in agent prose"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  -- A real window is required for the `:N,Mfold` / `:foldopen`
  -- commands to land — manual folds attach per-window.
  local winid = helpers.open_chat_window(bufnr)

  render.hydrate(state, {
    items = {
      { turnId = "t1", item = { kind = "user_prompt", text = "show me a snippet" } },
      {
        turnId = "t1",
        item = {
          kind = "agent_text",
          text = "Here's the snippet:\n```lua\nlocal x = 1\nreturn x\n```\nThat's it.",
        },
      },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Find the fence open + close rows so we can read the fold state
  -- at the exact location. There's exactly one block here.
  local fence_open_row, fence_close_row
  for i, line in ipairs(lines) do
    if line == "```lua" then
      fence_open_row = i
    elseif line == "```" and fence_open_row ~= nil and fence_close_row == nil then
      fence_close_row = i
    end
  end

  MiniTest.expect.equality(fence_open_row ~= nil, true)
  MiniTest.expect.equality(fence_close_row ~= nil, true)

  vim.api.nvim_win_call(winid, function()
    -- Every row in the fence range must belong to a fold (foldlevel
    -- > 0) — that's the contract for "a fold exists here". And the
    -- fold must NOT be closed (`foldclosed` returns -1 when open).
    for row = fence_open_row, fence_close_row do
      local lvl = vim.fn.foldlevel(row)
      local closed = vim.fn.foldclosed(row)
      MiniTest.expect.equality(lvl > 0, true)
      MiniTest.expect.equality(closed, -1)
    end
  end)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

T["captain can close the code-block fold with `zc` (fold IS foldable)"] = function()
  local render = require("hyprpilot.chat.render")
  local buffer = require("hyprpilot.chat.buffer")
  local id = helpers.unique_id()
  local bufnr = buffer.create(id)
  local state = render.state(id, bufnr)

  local winid = helpers.open_chat_window(bufnr)

  render.hydrate(state, {
    items = {
      { turnId = "t1", item = { kind = "user_prompt", text = "go" } },
      {
        turnId = "t1",
        item = { kind = "agent_text", text = "```python\nprint(1)\nprint(2)\n```" },
      },
    },
  })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local fence_open_row
  for i, line in ipairs(lines) do
    if line == "```python" then
      fence_open_row = i
      break
    end
  end
  MiniTest.expect.equality(fence_open_row ~= nil, true)

  vim.api.nvim_win_call(winid, function()
    -- Position at the fence-open row and close the fold the way
    -- the captain would (`zc`).
    vim.api.nvim_win_set_cursor(winid, { fence_open_row, 0 })
    vim.cmd("normal! zc")

    MiniTest.expect.equality(vim.fn.foldclosed(fence_open_row) >= 0, true)
  end)

  helpers.close_window(winid)
  helpers.cleanup_instance(id)
end

return T
