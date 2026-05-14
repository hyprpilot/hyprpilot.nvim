--- Behavioural tests for `ui.window.focus`. Drives real windows
--- minted with `vsplit`, plants their winids into `chat_window` /
--- `composer` module state via the test seams, then asserts the
--- cursor moves correctly between them and the captain's "previous"
--- window.

local T = MiniTest.new_set()

---Set up two extra windows next to the test's home window. Returns
---all three winids so the case can stash refs + tear down cleanly.
---@return integer home, integer chat_winid, integer composer_winid
local function mint_window_triple()
  local home = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local chat_winid = vim.api.nvim_get_current_win()
  vim.cmd("split")
  local composer_winid = vim.api.nvim_get_current_win()
  -- Return cursor to home so each test starts "outside" the chrome.
  vim.api.nvim_set_current_win(home)
  return home, chat_winid, composer_winid
end

local function teardown_windows(winids)
  for _, w in ipairs(winids) do
    if vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

local function setup_chrome(chat_winid, composer_winid)
  local chat_window = require("hyprpilot.chat.window")
  local composer = require("hyprpilot.composer")
  chat_window._winid = chat_winid
  composer._winid = composer_winid
end

local function restore_chrome(prev_chat, prev_composer)
  require("hyprpilot.chat.window")._winid = prev_chat
  require("hyprpilot.composer")._winid = prev_composer
end

T["focus: from outside chrome → jumps to composer + stashes previous winid"] = function()
  local home, chat, composer = mint_window_triple()
  local prev_chat = require("hyprpilot.chat.window")._winid
  local prev_composer = require("hyprpilot.composer")._winid
  setup_chrome(chat, composer)
  require("hyprpilot.ui.window")._prev_winid = nil

  require("hyprpilot.ui.window").focus()

  MiniTest.expect.equality(vim.api.nvim_get_current_win(), composer)
  MiniTest.expect.equality(require("hyprpilot.ui.window")._prev_winid, home)

  restore_chrome(prev_chat, prev_composer)
  teardown_windows({ chat, composer })
end

T["focus: target=chat steers to the chat window instead of composer"] = function()
  local home, chat, composer = mint_window_triple()
  local prev_chat = require("hyprpilot.chat.window")._winid
  local prev_composer = require("hyprpilot.composer")._winid
  setup_chrome(chat, composer)
  require("hyprpilot.ui.window")._prev_winid = nil

  require("hyprpilot.ui.window").focus({ target = "chat" })

  MiniTest.expect.equality(vim.api.nvim_get_current_win(), chat)
  MiniTest.expect.equality(require("hyprpilot.ui.window")._prev_winid, home)

  local _ = home
  restore_chrome(prev_chat, prev_composer)
  teardown_windows({ chat, composer })
end

T["focus: second call from inside chrome → jumps back to stashed previous"] = function()
  local home, chat, composer = mint_window_triple()
  local prev_chat = require("hyprpilot.chat.window")._winid
  local prev_composer = require("hyprpilot.composer")._winid
  setup_chrome(chat, composer)
  require("hyprpilot.ui.window")._prev_winid = nil

  -- First call: jump into composer.
  require("hyprpilot.ui.window").focus()
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), composer)
  MiniTest.expect.equality(require("hyprpilot.ui.window")._prev_winid, home)

  -- Exit insert mode (focus -> composer calls `startinsert`); not
  -- strictly required for `nvim_set_current_win` to work but keeps
  -- the test in a clean mode-less state.
  vim.cmd("stopinsert")

  -- Second call: cursor is inside chrome, should jump back to home.
  require("hyprpilot.ui.window").focus()
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), home)
  MiniTest.expect.equality(require("hyprpilot.ui.window")._prev_winid, nil)

  restore_chrome(prev_chat, prev_composer)
  teardown_windows({ chat, composer })
end

T["focus: composer winid invalid → falls back to chat as target"] = function()
  local home, chat, composer = mint_window_triple()
  local prev_chat = require("hyprpilot.chat.window")._winid
  local prev_composer = require("hyprpilot.composer")._winid
  setup_chrome(chat, nil) -- composer not yet open
  require("hyprpilot.ui.window")._prev_winid = nil

  require("hyprpilot.ui.window").focus()

  MiniTest.expect.equality(vim.api.nvim_get_current_win(), chat)
  MiniTest.expect.equality(require("hyprpilot.ui.window")._prev_winid, home)

  local _ = composer
  restore_chrome(prev_chat, prev_composer)
  teardown_windows({ chat, composer })
end

T["focus: chat hidden → show() runs then cursor lands on composer (insert mode pending)"] = function()
  local home, chat, composer = mint_window_triple()
  local chat_window = require("hyprpilot.chat.window")
  local prev_chat = chat_window._winid
  local prev_composer = require("hyprpilot.composer")._winid

  -- Start "hidden" — chat_window has no winid, so is_visible() is false.
  chat_window._winid = nil
  require("hyprpilot.composer")._winid = nil

  -- Stub `chat_window.show` to populate the chrome winids the way
  -- the real show() would. No daemon hydration, no buffer churn.
  local original_show = chat_window.show
  local show_calls = 0
  chat_window.show = function()
    show_calls = show_calls + 1
    chat_window._winid = chat
    require("hyprpilot.composer")._winid = composer
    vim.api.nvim_set_current_win(composer)
  end

  require("hyprpilot.ui.window")._prev_winid = nil
  require("hyprpilot.ui.window").focus()

  MiniTest.expect.equality(show_calls, 1)
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), composer)
  MiniTest.expect.equality(require("hyprpilot.ui.window")._prev_winid, home)

  chat_window.show = original_show
  restore_chrome(prev_chat, prev_composer)
  teardown_windows({ chat, composer })
end

T["focus: chat hidden + target=chat → show() then steers to chat (not composer)"] = function()
  local home, chat, composer = mint_window_triple()
  local chat_window = require("hyprpilot.chat.window")
  local prev_chat = chat_window._winid
  local prev_composer = require("hyprpilot.composer")._winid

  chat_window._winid = nil
  require("hyprpilot.composer")._winid = nil

  local original_show = chat_window.show
  chat_window.show = function()
    chat_window._winid = chat
    require("hyprpilot.composer")._winid = composer
    -- Real show() drops cursor on composer; the focus helper should
    -- override that for target = "chat".
    vim.api.nvim_set_current_win(composer)
  end

  require("hyprpilot.ui.window")._prev_winid = nil
  require("hyprpilot.ui.window").focus({ target = "chat" })

  MiniTest.expect.equality(vim.api.nvim_get_current_win(), chat)
  MiniTest.expect.equality(require("hyprpilot.ui.window")._prev_winid, home)

  chat_window.show = original_show
  restore_chrome(prev_chat, prev_composer)
  teardown_windows({ chat, composer })
end

T["focus: previous window closed before jump-back → log + stay in chrome"] = function()
  local home, chat, composer = mint_window_triple()
  local prev_chat = require("hyprpilot.chat.window")._winid
  local prev_composer = require("hyprpilot.composer")._winid
  setup_chrome(chat, composer)
  require("hyprpilot.ui.window")._prev_winid = nil

  -- Jump in.
  require("hyprpilot.ui.window").focus()
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), composer)

  -- Close the captain's "home" window before they call focus again.
  vim.api.nvim_set_current_win(home)
  vim.cmd("quit!") -- closes home; cursor lands on whichever window vim picks
  -- Force-set cursor back to the chrome so we test the jump-back path.
  if vim.api.nvim_win_is_valid(composer) then
    vim.api.nvim_set_current_win(composer)
  end

  require("hyprpilot.ui.window").focus()
  -- Stale prev winid → no jump; cursor remains on composer.
  MiniTest.expect.equality(vim.api.nvim_get_current_win(), composer)

  restore_chrome(prev_chat, prev_composer)
  teardown_windows({ chat, composer })
end

return T
