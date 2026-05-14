--- Behavioural tests for `permission_row.refresh_if_queued`. When
--- the chat re-appears (after a `:q`-driven WinClosed cascade or
--- `hp.hide` + `hp.show`), the local queue is still populated but
--- the row window was closed. `refresh_if_queued` re-opens the row
--- so the captain doesn't lose pending prompts on a layout reset.

local T = MiniTest.new_set()

T["refresh_if_queued: empty queue → no-op (no window opened)"] = function()
  local pr = require("hyprpilot.chat.permission_row")
  pr.reset()

  pr.refresh_if_queued()

  MiniTest.expect.equality(pr.is_visible(), false)
end

T["refresh_if_queued: queue non-empty + chat hidden → no-op (open_window guards on chat visibility)"] = function()
  local pr = require("hyprpilot.chat.permission_row")
  local window = require("hyprpilot.chat.window")

  -- Force the chat to look hidden so `open_window`'s guard short-
  -- circuits — the row should NOT mint a window without a chat to
  -- attach to.
  window._winid = nil

  pr.reset()
  table.insert(pr._queue, {
    instance_id = "inst-1",
    request_id = "req-1",
    tool = "Bash",
    options = { { optionId = "allow", name = "Allow", kind = "allow_once" } },
    focused_idx = 1,
  })

  pr.refresh_if_queued()

  -- The row stays closed because the chat itself isn't on screen.
  -- The queue is preserved so a later `chat.window.show()` can
  -- still pick it up.
  MiniTest.expect.equality(pr.is_visible(), false)
  MiniTest.expect.equality(#pr._queue, 1)

  pr.reset()
end

return T
