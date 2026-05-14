--- Behavioural tests for `hyprpilot.palettes.profiles`. Stubs the
--- wire and `vim.ui.select` so the test drives a synthetic pick and
--- asserts the spawn RPC fires with the right params.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["palettes.profiles: picks a row → fires instances/spawn with chosen profile_id"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["tauri/profiles_list"] = {
      result = {
        profiles = {
          { id = "engineer", agent = "claude-code", isDefault = true },
          { id = "plan", agent = "claude-code", isDefault = false },
        },
      },
    },
    ["instances/spawn"] = { result = { instanceId = "inst-new" } },
  })

  local restore_select, ui_calls = helpers.stub_ui_select(function(items)
    return items[2]
  end)

  require("hyprpilot.palettes.profiles").open({ picker = "vim.ui.select", show = false })

  MiniTest.expect.equality(#ui_calls, 1)
  MiniTest.expect.equality(#ui_calls[1].items, 2)
  MiniTest.expect.equality(ui_calls[1].opts.kind, "hyprpilot.profiles")

  MiniTest.expect.equality(calls[1].method, "tauri/profiles_list")
  MiniTest.expect.equality(calls[2].method, "instances/spawn")
  MiniTest.expect.equality(calls[2].params.profileId, "plan")

  restore_select()
  restore_client()
end

T["palettes.profiles: opts.on_pick override receives full profile and short-circuits spawn"] = function()
  local restore_client, calls = helpers.stub_client_with({
    ["tauri/profiles_list"] = {
      result = { profiles = { { id = "engineer", agent = "claude-code", isDefault = true } } },
    },
  })
  local restore_select = helpers.stub_ui_select(function(items)
    return items[1]
  end)

  local picked
  require("hyprpilot.palettes.profiles").open({
    picker = "vim.ui.select",
    on_pick = function(profile)
      picked = profile
    end,
  })

  MiniTest.expect.equality(picked.id, "engineer")
  MiniTest.expect.equality(picked.agent_id, "claude-code")
  MiniTest.expect.equality(picked.is_default, true)
  MiniTest.expect.equality(#calls, 1)

  restore_select()
  restore_client()
end

T["palettes.profiles: no profiles → warns + no picker opened"] = function()
  local restore_client = helpers.stub_client_with({
    ["tauri/profiles_list"] = { result = { profiles = {} } },
  })
  local restore_select, ui_calls = helpers.stub_ui_select(function() end)

  require("hyprpilot.palettes.profiles").open({ picker = "vim.ui.select" })

  MiniTest.expect.equality(#ui_calls, 0)
  restore_select()
  restore_client()
end

return T
