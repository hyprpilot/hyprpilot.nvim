--- Behavioural tests for `hyprpilot.instances`, the local daemon-instance
--- registry owned by the Neovim frontend.

local T = MiniTest.new_set()

local function fresh()
  local client = require("hyprpilot.client")
  local instances = require("hyprpilot.instances")
  client._reset()

  return instances
end

T["instances registry starts empty"] = function()
  local instances = fresh()

  MiniTest.expect.equality(instances.is_managed("inst-1"), false)
  MiniTest.expect.equality(instances.get("inst-1"), nil)
  MiniTest.expect.equality(vim.tbl_count(instances.list()), 0)
end

T["instances.register tracks a managed daemon instance"] = function()
  local instances = fresh()
  local state = { instance_id = "inst-1", bufnr = 42, spawned_with_shutdown = true }

  instances.register(state)

  MiniTest.expect.equality(instances.is_managed("inst-1"), true)
  MiniTest.expect.equality(instances.get("inst-1"), state)
  MiniTest.expect.equality(instances.list()["inst-1"].bufnr, 42)
end

T["instances.forget drops a managed daemon instance"] = function()
  local instances = fresh()

  instances.register({ instance_id = "inst-1", bufnr = 42 })
  instances.forget("inst-1")

  MiniTest.expect.equality(instances.is_managed("inst-1"), false)
  MiniTest.expect.equality(instances.get("inst-1"), nil)
end

T["instances.register ignores invalid state"] = function()
  local instances = fresh()

  instances.register(nil)
  instances.register({})
  instances.register({ instance_id = "", bufnr = 42 })

  MiniTest.expect.equality(vim.tbl_count(instances.list()), 0)
end

T["chat.window register and close update the client registry"] = function()
  local instances = fresh()
  local window = require("hyprpilot.chat.window")
  local bufnr = vim.api.nvim_create_buf(false, true)

  window.register({ instance_id = "inst-1", bufnr = bufnr }, { activate = false })
  MiniTest.expect.equality(instances.is_managed("inst-1"), true)

  window.close("inst-1")
  MiniTest.expect.equality(instances.is_managed("inst-1"), false)
end

return T
