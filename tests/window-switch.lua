--- Behavioural tests for `chat.window.switch` — specifically the
--- F1 fix that drains the permission row queue on instance change.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["window.switch drains the permission_row queue (no cross-instance leak)"] = function()
  local permission_row = require("hyprpilot.chat.permission-row")
  local window = require("hyprpilot.chat.window")
  permission_row.reset()

  local id_a = helpers.unique_id()
  local id_b = helpers.unique_id()

  -- Mint buffers + register both instances so `window.switch`
  -- accepts the target id.
  local buffer = require("hyprpilot.chat.buffer")
  local buf_a = buffer.create(id_a)
  local buf_b = buffer.create(id_b)
  window.register({ bufnr = buf_a, instance_id = id_a, name = "a" })
  window.register({ bufnr = buf_b, instance_id = id_b, name = "b" })

  -- Force is_visible() to true without standing up the real chat
  -- split (the rest of window.show in headless test env hits
  -- foldtext + fillchars wiring that doesn't apply here).
  local original_is_visible = window.is_visible
  local original_winid = window._winid
  local scratch_win
  local original_open = nil
  do
    -- Use a real scratch window so nvim_win_set_buf inside switch
    -- has a valid winid to write to; the test cares about the
    -- queue drain side effect, not the actual buffer swap.
    vim.cmd("vsplit")
    scratch_win = vim.api.nvim_get_current_win()
    window._winid = scratch_win
    window.is_visible = function()
      return true
    end
    -- Composer + header refresh fire from switch; stub them out
    -- since they need their own splits the test isn't providing.
    local composer = require("hyprpilot.composer")
    original_open = composer.open
    composer.open = function() end
    local header = require("hyprpilot.chat.header")
    local original_refresh = header.refresh
    header.refresh = function() end
    -- Save the original_refresh so cleanup can restore.
    T._original_refresh = original_refresh
  end

  permission_row.enqueue(id_a, {
    request_id = "req-a",
    tool = "Bash",
    options = { { optionId = "allow", name = "Allow", kind = "allow_once" } },
    formatted = { title = "ls", stats = {}, fields = {} },
  })
  MiniTest.expect.equality(#permission_row._queue, 1)

  -- Trigger the switch. The F1 fix calls
  -- `permission_row.reset()` after `nvim_win_set_buf`; the queue
  -- must drain.
  window.switch(id_b)

  MiniTest.expect.equality(#permission_row._queue, 0)

  -- Restore everything we stubbed.
  window.is_visible = original_is_visible
  window._winid = original_winid
  require("hyprpilot.composer").open = original_open
  require("hyprpilot.chat.header").refresh = T._original_refresh
  T._original_refresh = nil
  if scratch_win ~= nil and vim.api.nvim_win_is_valid(scratch_win) then
    pcall(vim.api.nvim_win_close, scratch_win, true)
  end

  permission_row.reset()
  helpers.cleanup_instance(id_a)
  helpers.cleanup_instance(id_b)
end

return T
