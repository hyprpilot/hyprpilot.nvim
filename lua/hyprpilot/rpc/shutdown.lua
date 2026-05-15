--- Graceful Neovim-exit teardown.
---
--- Registered on `VimLeavePre` from `init.lua::setup()`. Single
--- entry point `M.shutdown()` walks each subsystem's teardown in
--- dependency order. Every step is `pcall`-wrapped because we're
--- on the way out — errors during teardown are noise, not signal.
---
--- What this DOES NOT do (intentional):
---   - `nvim_clear_autocmds` on our groups — Neovim wipes autocmds
---     as part of process exit.
---   - `prompts/cancel` per in-flight turn — daemon-side turn
---     finishes in background; captain reattaches on next launch.
---     (Session cleanup isn't in scope; the daemon owns instance
---     persistence.)

local log = require("hyprpilot.log")

local M = {}

---Wrap a teardown step in `pcall` + a debug log so the captain can
---trace the shutdown order via `log_level = TRACE`. Errors are
---swallowed — we're exiting, the storm of API-during-teardown
---errors is noise.
---@param label string
---@param fn fun(): any
local function step(label, fn)
  local ok, err = pcall(fn)
  if ok then
    log.debug("shutdown: %s ok", label)
  else
    log.debug("shutdown: %s pcall error: %s", label, tostring(err))
  end
end

---Tear down the plugin's runtime state. Idempotent + re-entrant
---safe — every called teardown checks its own state guards
---(`is_visible()`, `unsubscribe ~= nil`, etc.) before acting.
---
---Called automatically on `VimLeavePre` (wired in `setup()`); also
---callable manually as `require("hyprpilot").shutdown()` when the
---captain wants to stop the plugin without quitting Neovim
---(hot-reload, manual disconnect from a keymap).
function M.shutdown()
  log.debug("shutdown: tearing down on captain request / VimLeavePre")

  -- Inner → outer:
  -- 1. Close every plugin-managed window. `chat.window.hide()`
  --    cascades through composer / header / permission_row / chat
  --    so a single call collapses the whole split layout.
  --    Buffers stay — Neovim wipes them on process exit.
  step("window.hide", function()
    require("hyprpilot.chat.window").hide()
  end)

  -- Queue-strip cache teardown — drops every per-instance daemon-
  -- mirror entry so a hot-reload doesn't render against a stale
  -- snapshot from the previous session.
  step("queue_strip._reset", function()
    require("hyprpilot.chat.queue-strip")._reset()
  end)

  -- Attention list + bell teardown. Drops every entry and the
  -- bell's `on_change` subscription so a hot-reload doesn't re-bell
  -- on entries from the prior session or fan out to stale handlers.
  step("attention._reset", function()
    require("hyprpilot.notification.attention")._reset()
  end)
  step("bell._reset", function()
    require("hyprpilot.notification.bell")._reset()
  end)
  -- Status — drop the per-instance activity table + reset the
  -- one-shot `wired` flag. Without this, a hot-reload inherits
  -- stale activity badges from the prior session.
  step("status._reset", function()
    require("hyprpilot.status")._reset()
  end)

  -- 2. Drop the daemon event subscription before the channel goes
  --    away. Otherwise the `events/changed` callback can fire
  --    against a half-torn-down state.
  step("events._reset", function()
    require("hyprpilot.chat.events")._reset()
  end)

  -- 3. Disconnect the client. Closes the socket via `chanclose`,
  --    stops local in-flight timers (each timer:stop + close in
  --    `client.teardown`), fails pending callbacks with a clean
  --    "client disconnected" error so anything still awaiting
  --    sees a sane terminal state.
  step("client.disconnect", function()
    require("hyprpilot.client").disconnect()
  end)

  -- 4. Force-close every window still showing a plugin buffer.
  --    `chat.window.hide()` cascades through composer / header /
  --    queue strip / permission row, but a layout manager (edgy)
  --    can still hold "ghost" slots — and `nvim_buf_delete` below
  --    only swaps the buffer in any surviving window for an empty
  --    unnamed one, leaving a literal blank window pinned in the
  --    captain's exit screen. Walking the window list here closes
  --    those orphans before they get re-buffered.
  --
  --    Skip the last remaining window: Neovim can't have zero
  --    windows, so if every visible surface is plugin-owned we let
  --    one survive and `wipe_buffers` swaps its buffer to an
  --    alternate. The process is exiting on the next tick anyway.
  step("close_plugin_windows", function()
    local PREFIX = "hyprpilot://"
    local wins = vim.api.nvim_list_wins()
    for _, winid in ipairs(wins) do
      if vim.api.nvim_win_is_valid(winid) and #vim.api.nvim_list_wins() > 1 then
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name:sub(1, #PREFIX) == PREFIX then
          pcall(vim.api.nvim_win_close, winid, true)
        end
      end
    end
  end)

  -- 5. Wipe every plugin-managed buffer. All of them are named with
  --    a `hyprpilot://` prefix (header / permission_row / composer
  --    /<id> / <instance-id> / placeholder), so a single walk-by-
  --    prefix catches them in one go without each module needing a
  --    custom teardown call. Neovim wipes buffers on process exit
  --    regardless, but doing it explicitly clears `:ls!` BEFORE we
  --    let go and prevents stale-bufnr references from surviving
  --    across a hot-reload `shutdown()` → `setup()` cycle.
  step("wipe_buffers", function()
    local PREFIX = "hyprpilot://"
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name:sub(1, #PREFIX) == PREFIX then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
      end
    end
  end)
end

return M
