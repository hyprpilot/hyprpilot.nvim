--- Behavioural test for `chat.window.show()` auto-spawning a default
--- instance when none is registered. Captain hits their `hp.show`
--- keybind on a fresh nvim — they should land in a populated chat,
--- not a placeholder buffer that tells them to spawn first.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["window.show with no instances + no id calls instances.spawn({}) and reroutes"] = function()
  local window = require("hyprpilot.chat.window")
  local instances = require("hyprpilot.instances")

  -- Nuke whatever state lingered from the runner — the auto-spawn
  -- branch only fires when `_instances` is empty AND no id was
  -- passed. Clear directly (the public `window.close` only works
  -- on registered ids and depends on state being intact, which
  -- earlier tests may have left in odd shape).
  window._instances = {}
  window._last_active_id = nil

  -- Stub events.hydrate so the re-entry into show() doesn't
  -- attempt a real RPC.
  local events = require("hyprpilot.chat.events")
  local original_hydrate = events.hydrate
  events.hydrate = function() end

  local original_spawn = instances.spawn
  local spawn_calls = {}
  instances.spawn = function(opts, callback)
    table.insert(spawn_calls, { opts = opts })
    -- Production: spawn replies, instances.spawn handler registers
    -- the new state, callback fires. We mimic the registration
    -- inline so the re-entered show() finds the instance.
    window.register({
      bufnr = require("hyprpilot.chat.buffer").create("auto-spawned-id"),
      instance_id = "auto-spawned-id",
    })
    if callback ~= nil then
      callback(nil, { id = "auto-spawned-id", agent_id = "claude-code" })
    end
  end

  window.show()

  MiniTest.expect.equality(#spawn_calls, 1)
  MiniTest.expect.equality(spawn_calls[1].opts ~= nil, true)
  MiniTest.expect.equality(next(spawn_calls[1].opts), nil) -- empty opts

  -- Cleanup.
  instances.spawn = original_spawn
  events.hydrate = original_hydrate
  window.hide()
  window.close("auto-spawned-id")
  helpers.cleanup_instance("auto-spawned-id")
end

return T
