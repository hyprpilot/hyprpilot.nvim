--- Behavioural tests for the daemon-notifications mirror. The daemon
--- snapshot is global, but captain-facing reads are scoped to daemon
--- instances managed by this Neovim frontend.

local T = MiniTest.new_set()

local function fresh()
  local client = require("hyprpilot.client")
  local daemon = require("hyprpilot.notification.daemon")
  client._reset()
  daemon._reset()
  return client, daemon
end

local function entry(instance_id)
  return {
    instance_id = instance_id,
    reasons = { "turn_ended" },
    since = 1,
  }
end

T["list filters daemon notifications to managed instances"] = function()
  local client, daemon = fresh()
  client.instances.register({ instance_id = "managed", bufnr = 42 })

  daemon.apply({ entry("managed"), entry("foreign") })

  local items = daemon.list()
  MiniTest.expect.equality(#items, 1)
  MiniTest.expect.equality(items[1].instance_id, "managed")
  MiniTest.expect.equality(daemon.count(), 1)
  MiniTest.expect.equality(daemon.is_attention_needed(), true)
  MiniTest.expect.equality(daemon.is_attention_needed("managed"), true)
  MiniTest.expect.equality(daemon.is_attention_needed("foreign"), false)
end

T["newly registered instances appear from the existing daemon snapshot"] = function()
  local client, daemon = fresh()

  daemon.apply({ entry("inst-1") })
  MiniTest.expect.equality(#daemon.list(), 0)
  MiniTest.expect.equality(daemon.is_attention_needed(), false)

  client.instances.register({ instance_id = "inst-1", bufnr = 42 })

  MiniTest.expect.equality(#daemon.list(), 1)
  MiniTest.expect.equality(daemon.list()[1].instance_id, "inst-1")
end

T["forgotten instances disappear from the filtered daemon snapshot"] = function()
  local client, daemon = fresh()
  client.instances.register({ instance_id = "inst-1", bufnr = 42 })

  daemon.apply({ entry("inst-1") })
  MiniTest.expect.equality(#daemon.list(), 1)

  client.instances.forget("inst-1")

  MiniTest.expect.equality(#daemon.list(), 0)
  MiniTest.expect.equality(daemon.is_attention_needed(), false)
end

T["subscribers and autocmds receive filtered counts"] = function()
  local client, daemon = fresh()
  client.instances.register({ instance_id = "managed", bufnr = 42 })

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

  daemon.apply({ entry("managed"), entry("foreign") })

  MiniTest.expect.equality(subscriber_count, 1)
  MiniTest.expect.equality(autocmd_count, 1)
  vim.api.nvim_del_augroup_by_id(group)
end

T["dismiss_all clears only managed daemon notification entries"] = function()
  local client, daemon = fresh()
  client.instances.register({ instance_id = "managed", bufnr = 42 })
  daemon.apply({ entry("managed"), entry("foreign") })

  local rpc = require("hyprpilot.rpc.notifications")
  local original = rpc.clear
  local cleared = {}
  rpc.clear = function(instance_id)
    table.insert(cleared, instance_id)
  end

  daemon.dismiss_all()

  MiniTest.expect.equality(cleared, { "managed" })
  rpc.clear = original
end

return T
