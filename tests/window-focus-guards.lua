--- Behavioural tests for the BufEnter-crash guards in `chat.window`:
---
--- 1. `window.focus()` returns `false` when `_winid` is invalid or
---    `nvim_set_current_win` throws, instead of letting the throw
---    bubble through our event dispatch (the symptom was a
---    third-party `BufEnter` `vim.treesitter.start()` failure
---    cascading from `permission_row.enqueue` and killing the
---    client RPC loop).
---
--- 2. The `WinClosed` autocmd resets `_winid` and drains the child
---    surfaces (composer / header / queue_strip / permission_row)
---    when the chat window is closed through stock Vim controls
---    (`:q`, `<C-w>q`) so subsequent enqueues don't reach for a
---    stale winid.

local T = MiniTest.new_set()

T["window.focus: returns false (no throw) when _winid is invalid"] = function()
  local window = require("hyprpilot.chat.window")

  window._winid = 99999

  MiniTest.expect.equality(window.focus(), false)
  MiniTest.expect.equality(window._winid, nil)
end

T["window.focus: returns true when _winid points at a real window"] = function()
  local window = require("hyprpilot.chat.window")

  vim.cmd("new")
  local winid = vim.api.nvim_get_current_win()
  window._winid = winid

  MiniTest.expect.equality(window.focus(), true)
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), winid)

  pcall(vim.api.nvim_win_close, winid, true)
  window._winid = nil
end

T["WinClosed on the chat winid drains children and resets _winid"] = function()
  local window = require("hyprpilot.chat.window")
  local composer = require("hyprpilot.composer")
  local header = require("hyprpilot.chat.header")
  local queue_strip = require("hyprpilot.chat.queue-strip")
  local permission_row = require("hyprpilot.chat.permission-row")

  -- Capture each child's close call. Stub-and-restore keeps other
  -- tests in this file independent of side effects.
  local calls = {}
  local function stub(mod, name)
    local original = mod[name]
    mod[name] = function(...)
      table.insert(calls, name)
      return original(...)
    end
    return function()
      mod[name] = original
    end
  end

  local restores = {
    stub(composer, "close"),
    stub(header, "close"),
    stub(queue_strip, "close"),
    stub(permission_row, "close"),
  }

  vim.cmd("new")
  local fake_chat = vim.api.nvim_get_current_win()
  window._winid = fake_chat

  -- Closing the window fires WinClosed synchronously; the cascade
  -- itself is `vim.schedule`d so we flush pending callbacks below.
  vim.api.nvim_win_close(fake_chat, true)
  vim.wait(20, function()
    return #calls >= 4
  end)

  MiniTest.expect.equality(window._winid, nil)
  -- Order isn't guaranteed (vim.schedule callback runs all four in
  -- one tick), just that each child saw its close call.
  local saw = {}
  for _, name in ipairs(calls) do
    saw[name] = true
  end
  MiniTest.expect.equality(saw["close"] and #calls >= 4, true)

  for _, restore in ipairs(restores) do
    restore()
  end
end

T["WinClosed for an unrelated winid does not reset _winid"] = function()
  local window = require("hyprpilot.chat.window")

  vim.cmd("new")
  local our_winid = vim.api.nvim_get_current_win()
  window._winid = our_winid

  vim.cmd("new")
  local other_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_close(other_winid, true)
  vim.wait(10)

  MiniTest.expect.equality(window._winid, our_winid)

  pcall(vim.api.nvim_win_close, our_winid, true)
  vim.wait(20)
  window._winid = nil
end

local function set_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

T["open_aux_split: sticky chat stays at tail after scheduled restore"] = function()
  local window = require("hyprpilot.chat.window")
  local buffer = require("hyprpilot.chat.buffer")
  local previous_chat = window._winid
  local home = vim.api.nvim_get_current_win()

  vim.cmd("vsplit")
  local chat_win = vim.api.nvim_get_current_win()
  local chat_buf = vim.api.nvim_get_current_buf()
  vim.bo[chat_buf].filetype = "hyprpilot"
  set_lines(chat_buf, { "one", "two", "three", "four", "five" })
  vim.api.nvim_win_set_cursor(chat_win, { 5, 0 })
  window._winid = chat_win
  vim.api.nvim_set_current_win(home)

  local aux_buf = vim.api.nvim_create_buf(false, true)
  local aux_win = buffer.open_aux_split({
    direction = "belowright 1split",
    bufnr = aux_buf,
  })

  MiniTest.expect.equality(vim.api.nvim_get_current_win(), home)

  set_lines(chat_buf, { "one", "two", "three", "four", "five", "six" })
  vim.api.nvim_win_set_cursor(chat_win, { 6, 0 })
  vim.wait(20)

  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(chat_win)[1], 6)

  if aux_win ~= nil and vim.api.nvim_win_is_valid(aux_win) then
    pcall(vim.api.nvim_win_close, aux_win, true)
  end
  if vim.api.nvim_win_is_valid(chat_win) then
    pcall(vim.api.nvim_win_close, chat_win, true)
  end
  window._winid = previous_chat
end

T["open_aux_split: scrolled chat keeps saved view"] = function()
  local window = require("hyprpilot.chat.window")
  local buffer = require("hyprpilot.chat.buffer")
  local previous_chat = window._winid
  local home = vim.api.nvim_get_current_win()

  vim.cmd("vsplit")
  local chat_win = vim.api.nvim_get_current_win()
  local chat_buf = vim.api.nvim_get_current_buf()
  vim.bo[chat_buf].filetype = "hyprpilot"
  set_lines(chat_buf, { "one", "two", "three", "four", "five" })
  vim.api.nvim_win_set_cursor(chat_win, { 2, 0 })
  window._winid = chat_win
  vim.api.nvim_set_current_win(home)

  local aux_buf = vim.api.nvim_create_buf(false, true)
  local aux_win = buffer.open_aux_split({
    direction = "belowright 1split",
    bufnr = aux_buf,
  })

  set_lines(chat_buf, { "one", "two", "three", "four", "five", "six" })
  vim.wait(20)

  MiniTest.expect.equality(vim.api.nvim_get_current_win(), home)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(chat_win)[1], 2)

  if aux_win ~= nil and vim.api.nvim_win_is_valid(aux_win) then
    pcall(vim.api.nvim_win_close, aux_win, true)
  end
  if vim.api.nvim_win_is_valid(chat_win) then
    pcall(vim.api.nvim_win_close, chat_win, true)
  end
  window._winid = previous_chat
end

return T
