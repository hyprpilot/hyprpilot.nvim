--- Behavioural tests for `notification.bell`. The actual TTY write
--- is stubbed so we can assert on call counts without polluting the
--- test runner's stderr with bell characters.

local config = require("hyprpilot.config")

local T = MiniTest.new_set()

local function fresh()
  local bell = require("hyprpilot.notification.bell")
  local attention = require("hyprpilot.notification.attention")
  bell._reset()
  attention._reset()
  return bell, attention
end

---Stub `bell.ring` to count calls instead of writing BEL to stderr.
---@param bell table
---@return fun(), { count: integer }
local function stub_ring(bell)
  local original = bell.ring
  local counter = { count = 0 }
  bell.ring = function()
    counter.count = counter.count + 1
  end
  return function()
    bell.ring = original
  end, counter
end

T["bell.ensure_listeners is a no-op when disabled (default)"] = function()
  local bell, attention = fresh()
  config.options.notification = { bell = { enabled = false } }

  local restore, counter = stub_ring(bell)
  bell.ensure_listeners()
  attention._add_permission("inst-1", 1, "req-1")

  MiniTest.expect.equality(counter.count, 0)
  restore()
end

T["bell rings on attention-list growth when enabled"] = function()
  local bell, attention = fresh()
  config.options.notification = { bell = { enabled = true } }

  local restore, counter = stub_ring(bell)
  bell.ensure_listeners()

  attention._add_permission("inst-1", 1, "req-1")
  vim.wait(20) -- let the deferred vim.schedule ring fire
  MiniTest.expect.equality(counter.count, 1)

  attention._add_turn_ended("inst-2", 2)
  vim.wait(20)
  MiniTest.expect.equality(counter.count, 2)
  restore()
end

T["bell does NOT ring on remove (list shrinks)"] = function()
  local bell, attention = fresh()
  config.options.notification = { bell = { enabled = true } }

  local restore, counter = stub_ring(bell)
  bell.ensure_listeners()

  attention._add_permission("inst-1", 1, "req-1")
  vim.wait(20)
  MiniTest.expect.equality(counter.count, 1)

  attention._remove_permission("req-1")
  vim.wait(20)
  MiniTest.expect.equality(counter.count, 1) -- no extra ring on removal

  restore()
end

T["bell does NOT ring on duplicate-add (no list growth)"] = function()
  local bell, attention = fresh()
  config.options.notification = { bell = { enabled = true } }

  local restore, counter = stub_ring(bell)
  bell.ensure_listeners()

  attention._add_permission("inst-1", 1, "req-1")
  attention._add_permission("inst-1", 1, "req-1") -- dedup'd
  vim.wait(20)
  MiniTest.expect.equality(counter.count, 1)
  restore()
end

T["bell does NOT ring for auto-resolved permission (add + remove before schedule fires)"] = function()
  local bell, attention = fresh()
  config.options.notification = { bell = { enabled = true } }

  local restore, counter = stub_ring(bell)
  bell.ensure_listeners()

  -- Add then immediately remove (daemon auto-resolved the permission
  -- in the same socket burst). The schedule fires AFTER both events.
  attention._add_permission("inst-1", 1, "req-1")
  attention._remove_permission("req-1")
  vim.wait(20) -- let the deferred check run
  MiniTest.expect.equality(counter.count, 0)
  restore()
end

T["bell seeds count from existing entries so setup() mid-flight doesn't ring"] = function()
  local bell, attention = fresh()
  config.options.notification = { bell = { enabled = true } }

  -- Pre-existing entry before setup() runs.
  attention._add_permission("inst-1", 1, "req-1")

  local restore, counter = stub_ring(bell)
  bell.ensure_listeners()

  MiniTest.expect.equality(counter.count, 0)
  restore()
end

return T
