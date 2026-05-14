--- Behavioural tests for `hyprpilot.rpc.with-config` — the helper
--- every spawn-bearing RPC routes through so per-call patches
--- stack on top of the captain's `config.options.with_config`
--- baseline.

local T = MiniTest.new_set()

local function reset_config()
  require("hyprpilot.config").setup({})
end

T["resolve: no global, no per-call → nil"] = function()
  reset_config()
  MiniTest.expect.equality(require("hyprpilot.rpc.with-config").resolve(nil), nil)
end

T["resolve: per-call only → returns per-call verbatim"] = function()
  reset_config()
  local out = require("hyprpilot.rpc.with-config").resolve({ { foo = "bar" }, { baz = "qux" } })
  MiniTest.expect.equality(#out, 2)
  MiniTest.expect.equality(out[1].foo, "bar")
  MiniTest.expect.equality(out[2].baz, "qux")
end

T["resolve: global only → returns global verbatim"] = function()
  require("hyprpilot.config").setup({ with_config = { { mode = "plan" } } })
  local out = require("hyprpilot.rpc.with-config").resolve(nil)
  MiniTest.expect.equality(#out, 1)
  MiniTest.expect.equality(out[1].mode, "plan")
  reset_config()
end

T["resolve: global + per-call → global first, per-call after (last-wins on conflict)"] = function()
  require("hyprpilot.config").setup({
    with_config = { { mode = "plan" }, { model = "claude-sonnet" } },
  })
  local out = require("hyprpilot.rpc.with-config").resolve({ { mode = "engineer" } })

  -- Global FIRST (positions 1-2), per-call AFTER (position 3). The
  -- daemon applies in declaration order with last-wins semantics, so
  -- per-call `mode = "engineer"` overrides global `mode = "plan"`.
  MiniTest.expect.equality(#out, 3)
  MiniTest.expect.equality(out[1].mode, "plan")
  MiniTest.expect.equality(out[2].model, "claude-sonnet")
  MiniTest.expect.equality(out[3].mode, "engineer")
  reset_config()
end

T["apply: stamps merged list onto params.withConfig in-place"] = function()
  require("hyprpilot.config").setup({ with_config = { { mode = "plan" } } })

  local params = { instanceId = "inst-1" }
  require("hyprpilot.rpc.with-config").apply(params, { { model = "claude-sonnet" } })

  MiniTest.expect.equality(params.instanceId, "inst-1")
  MiniTest.expect.equality(#params.withConfig, 2)
  MiniTest.expect.equality(params.withConfig[1].mode, "plan")
  MiniTest.expect.equality(params.withConfig[2].model, "claude-sonnet")
  reset_config()
end

T["apply: nothing to send → leaves params.withConfig unset"] = function()
  reset_config()

  local params = { instanceId = "inst-1" }
  require("hyprpilot.rpc.with-config").apply(params, nil)

  -- Don't stamp `withConfig = nil` — daemon's serde-default handles
  -- absent fields, no need to ship an explicit null.
  MiniTest.expect.equality(params.withConfig, nil)
  MiniTest.expect.equality(params.instanceId, "inst-1")
end

return T
