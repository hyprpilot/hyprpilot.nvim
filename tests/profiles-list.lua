--- Behavioural tests for `hyprpilot.profiles`. Stubs `client.request`
--- so we exercise the wire→snake_case translation without a live
--- daemon.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["profiles.list: translates camelCase wire → snake_case Lua shape"] = function()
  local restore_client = helpers.stub_client_with({
    ["tauri/profiles_list"] = {
      result = {
        profiles = {
          { id = "engineer", agent = "claude-code", model = "claude-sonnet-4-5", isDefault = true },
          { id = "plan", agent = "claude-code", isDefault = false },
        },
      },
    },
  })

  local captured_err, captured_items
  require("hyprpilot.profiles").list(function(err, items)
    captured_err = err
    captured_items = items
  end)

  MiniTest.expect.equality(captured_err, nil)
  MiniTest.expect.equality(#captured_items, 2)
  MiniTest.expect.equality(captured_items[1].id, "engineer")
  MiniTest.expect.equality(captured_items[1].agent_id, "claude-code")
  MiniTest.expect.equality(captured_items[1].model, "claude-sonnet-4-5")
  MiniTest.expect.equality(captured_items[1].is_default, true)
  MiniTest.expect.equality(captured_items[2].is_default, false)
  MiniTest.expect.equality(captured_items[2].model, nil)

  restore_client()
end

T["profiles.list: empty profiles array → empty list, no error"] = function()
  local restore_client = helpers.stub_client_with({
    ["tauri/profiles_list"] = { result = { profiles = {} } },
  })

  local items
  require("hyprpilot.profiles").list(function(_, result)
    items = result
  end)

  MiniTest.expect.equality(#items, 0)
  restore_client()
end

T["profiles.list: rpc error → callback(err, nil)"] = function()
  local restore_client = helpers.stub_client_with({
    ["tauri/profiles_list"] = { err = { kind = "rpc", message = "boom" } },
  })

  local captured_err, captured_items
  require("hyprpilot.profiles").list(function(err, items)
    captured_err = err
    captured_items = items
  end)

  MiniTest.expect.equality(captured_err.message, "boom")
  MiniTest.expect.equality(captured_items, nil)
  restore_client()
end

return T
