--- Behavioural tests for the `VimLeavePre` graceful-shutdown path.
--- Stubs every subsystem's teardown function so we can capture the
--- call order without touching the real window / client / events
--- state; drives the autocmd via `nvim_exec_autocmds` to verify
--- end-to-end wiring through `init.setup()`.

local T = MiniTest.new_set()

---Replace a function on a module with a recorder. Returns
---`(restore, calls)` — calls is an integer-indexed list of the
---invocation order, mixed across all stubs sharing the same shared
---`order` table.
---@param mod table
---@param key string
---@param order string[]                 -- shared list; appended to on each stub call
---@param label string                   -- name pushed onto `order` when the stub fires
---@param impl? fun(...): any            -- optional replacement body (defaults to no-op)
---@return fun()
local function stub_fn(mod, key, order, label, impl)
  local original = mod[key]
  mod[key] = function(...)
    table.insert(order, label)
    if impl ~= nil then
      return impl(...)
    end
  end
  return function()
    mod[key] = original
  end
end

T["shutdown.shutdown walks window.hide → events._reset → client.disconnect in order"] = function()
  local order = {}
  local r1 = stub_fn(require("hyprpilot.chat.window"), "hide", order, "window.hide")
  local r2 = stub_fn(require("hyprpilot.chat.events"), "_reset", order, "events._reset")
  local r3 = stub_fn(require("hyprpilot.client"), "disconnect", order, "client.disconnect")

  require("hyprpilot.shutdown").shutdown()

  MiniTest.expect.equality(order[1], "window.hide")
  MiniTest.expect.equality(order[2], "events._reset")
  MiniTest.expect.equality(order[3], "client.disconnect")
  MiniTest.expect.equality(#order, 3)

  r3()
  r2()
  r1()
end

T["shutdown.shutdown is pcall'd — one step throwing doesn't stop the rest"] = function()
  local order = {}
  -- First step throws; second + third must still run.
  local r1 = stub_fn(require("hyprpilot.chat.window"), "hide", order, "window.hide", function()
    error("boom — Neovim already tore this window down")
  end)
  local r2 = stub_fn(require("hyprpilot.chat.events"), "_reset", order, "events._reset")
  local r3 = stub_fn(require("hyprpilot.client"), "disconnect", order, "client.disconnect")

  -- The shutdown call itself must NOT raise even though `hide()`
  -- threw — that's the whole point of the pcall wrapping.
  local ok = pcall(require("hyprpilot.shutdown").shutdown)
  MiniTest.expect.equality(ok, true)

  -- All three labels landed; the failed one still got its turn at
  -- the start of the order list (the throw doesn't suppress the
  -- log/record path).
  MiniTest.expect.equality(order[1], "window.hide")
  MiniTest.expect.equality(order[2], "events._reset")
  MiniTest.expect.equality(order[3], "client.disconnect")

  r3()
  r2()
  r1()
end

T["shutdown.shutdown is idempotent — calling twice is safe"] = function()
  local order = {}
  local r1 = stub_fn(require("hyprpilot.chat.window"), "hide", order, "window.hide")
  local r2 = stub_fn(require("hyprpilot.chat.events"), "_reset", order, "events._reset")
  local r3 = stub_fn(require("hyprpilot.client"), "disconnect", order, "client.disconnect")

  local shutdown = require("hyprpilot.shutdown").shutdown
  shutdown()
  shutdown()

  -- Six entries — three per call, same order both times. No errors,
  -- no extra state to break.
  MiniTest.expect.equality(#order, 6)
  MiniTest.expect.equality(order[4], "window.hide")
  MiniTest.expect.equality(order[5], "events._reset")
  MiniTest.expect.equality(order[6], "client.disconnect")

  r3()
  r2()
  r1()
end

T["setup() registers VimLeavePre — firing the autocmd triggers the full teardown"] = function()
  local order = {}
  local r1 = stub_fn(require("hyprpilot.chat.window"), "hide", order, "window.hide")
  local r2 = stub_fn(require("hyprpilot.chat.events"), "_reset", order, "events._reset")
  local r3 = stub_fn(require("hyprpilot.client"), "disconnect", order, "client.disconnect")

  -- Drive `setup()` to register the autocmd. `clear = true` on the
  -- group means a re-setup wipes any prior listener, so this is
  -- safe to do mid-test even though the test runner already ran
  -- module load.
  require("hyprpilot").setup({})

  -- Trigger VimLeavePre exactly the way Neovim would on `:qa`.
  vim.api.nvim_exec_autocmds("VimLeavePre", { group = "HyprpilotShutdown" })

  MiniTest.expect.equality(order[1], "window.hide")
  MiniTest.expect.equality(order[2], "events._reset")
  MiniTest.expect.equality(order[3], "client.disconnect")

  r3()
  r2()
  r1()
end

T["require('hyprpilot').shutdown forwards to the shutdown module"] = function()
  local order = {}
  local r1 = stub_fn(require("hyprpilot.chat.window"), "hide", order, "window.hide")
  local r2 = stub_fn(require("hyprpilot.chat.events"), "_reset", order, "events._reset")
  local r3 = stub_fn(require("hyprpilot.client"), "disconnect", order, "client.disconnect")

  require("hyprpilot").shutdown()

  MiniTest.expect.equality(#order, 3)
  MiniTest.expect.equality(order[1], "window.hide")

  r3()
  r2()
  r1()
end

return T
