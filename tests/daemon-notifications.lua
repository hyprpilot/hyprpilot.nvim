--- Behavioural tests for the daemon-notifications mirror. The daemon
--- snapshot is global, but captain-facing reads are scoped to daemon
--- instances registered in this Neovim frontend.

local T = MiniTest.new_set()

local function fresh()
  local client = require("hyprpilot.client")
  local instances = require("hyprpilot.instances")
  local daemon = require("hyprpilot.notification.daemon")
  client._reset()
  instances._reset()
  daemon._reset()

  return instances, daemon
end

local function entry(instance_id)
  return {
    instance_id = instance_id,
    reasons = { "turn_ended" },
    since = 1,
  }
end

T["list filters daemon notifications to registered instances"] = function()
  local instances, daemon = fresh()
  instances.register({ instance_id = "local", bufnr = 42 })

  daemon.apply({ entry("local"), entry("foreign") })

  local items = daemon.list()
  MiniTest.expect.equality(#items, 1)
  MiniTest.expect.equality(items[1].instance_id, "local")
  MiniTest.expect.equality(daemon.count(), 1)
  MiniTest.expect.equality(daemon.is_attention_needed(), true)
  MiniTest.expect.equality(daemon.is_attention_needed("local"), true)
  MiniTest.expect.equality(daemon.is_attention_needed("foreign"), false)
end

T["newly registered instances appear from the existing daemon snapshot"] = function()
  local instances, daemon = fresh()

  daemon.apply({ entry("inst-1") })
  MiniTest.expect.equality(#daemon.list(), 0)
  MiniTest.expect.equality(daemon.is_attention_needed(), false)

  instances.register({ instance_id = "inst-1", bufnr = 42 })

  MiniTest.expect.equality(#daemon.list(), 1)
  MiniTest.expect.equality(daemon.list()[1].instance_id, "inst-1")
end

T["forgotten instances disappear from the filtered daemon snapshot"] = function()
  local instances, daemon = fresh()
  instances.register({ instance_id = "inst-1", bufnr = 42 })

  daemon.apply({ entry("inst-1") })
  MiniTest.expect.equality(#daemon.list(), 1)

  instances.forget("inst-1")

  MiniTest.expect.equality(#daemon.list(), 0)
  MiniTest.expect.equality(daemon.is_attention_needed(), false)
end

T["subscribers and autocmds receive filtered counts"] = function()
  local instances, daemon = fresh()
  instances.register({ instance_id = "local", bufnr = 42 })

  local subscriber_count = nil
  daemon.on_change(function(snapshot)
    subscriber_count = #snapshot
  end)

  local autocmd_count = nil
  local group = vim.api.nvim_create_augroup("HyprpilotDaemonNotificationsTest", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "HyprpilotNotificationsChanged",
    callback = function(args)
      autocmd_count = args.data.count
    end,
  })

  daemon.apply({ entry("local"), entry("foreign") })

  MiniTest.expect.equality(subscriber_count, 1)
  MiniTest.expect.equality(autocmd_count, 1)
  vim.api.nvim_del_augroup_by_id(group)
end

T["dismiss_all clears only registered daemon notification entries"] = function()
  local instances, daemon = fresh()
  instances.register({ instance_id = "local", bufnr = 42 })
  daemon.apply({ entry("local"), entry("foreign") })

  local rpc = require("hyprpilot.rpc.notifications")
  local original = rpc.clear
  local cleared = {}
  rpc.clear = function(instance_id)
    table.insert(cleared, instance_id)
  end

  daemon.dismiss_all()

  MiniTest.expect.equality(cleared, { "local" })
  rpc.clear = original
end

return T
