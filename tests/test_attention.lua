--- Behavioural tests for `notification.attention`. Drive the private
--- mutators (`_add_permission` / `_add_turn_ended` / `_remove_*` /
--- `_clear_*`) and the autocmd-wired pathway, then assert the list
--- snapshot, dedup behavior, and `on_change` subscriber fan-out.

local T = MiniTest.new_set()

local function fresh()
  local attention = require("hyprpilot.notification.attention")
  attention._reset()
  return attention
end

T["list starts empty; is_attention_needed agrees"] = function()
  local a = fresh()
  MiniTest.expect.equality(#a.list(), 0)
  MiniTest.expect.equality(a.is_attention_needed(), false)
  MiniTest.expect.equality(a.is_attention_needed("inst-x"), false)
end

T["_add_permission appends an entry + fires subscribers"] = function()
  local a = fresh()
  local seen = {}
  a.on_change(function(snapshot)
    table.insert(seen, #snapshot)
  end)

  a._add_permission("inst-1", 42, "req-1")
  MiniTest.expect.equality(#a.list(), 1)
  MiniTest.expect.equality(a.list()[1].kind, "permission")
  MiniTest.expect.equality(a.list()[1].instance_id, "inst-1")
  MiniTest.expect.equality(a.list()[1].bufnr, 42)
  MiniTest.expect.equality(a.list()[1].request_id, "req-1")
  MiniTest.expect.equality(a.is_attention_needed(), true)
  MiniTest.expect.equality(a.is_attention_needed("inst-1"), true)
  MiniTest.expect.equality(a.is_attention_needed("inst-other"), false)
  MiniTest.expect.equality(#seen, 1)
end

T["_add_permission dedups by request_id (silent no-op on duplicate)"] = function()
  local a = fresh()
  a._add_permission("inst-1", 42, "req-1")
  a._add_permission("inst-1", 42, "req-1")
  MiniTest.expect.equality(#a.list(), 1)
end

T["_add_turn_ended dedups by instance_id (one row per instance)"] = function()
  local a = fresh()
  a._add_turn_ended("inst-1", 42)
  a._add_turn_ended("inst-1", 42)
  a._add_turn_ended("inst-2", 43)

  MiniTest.expect.equality(#a.list(), 2)
  MiniTest.expect.equality(a.list()[1].kind, "turn_ended")
  MiniTest.expect.equality(a.list()[1].instance_id, "inst-1")
  MiniTest.expect.equality(a.list()[2].instance_id, "inst-2")
end

T["_remove_permission drops the matching row + fires subscribers"] = function()
  local a = fresh()
  a._add_permission("inst-1", 42, "req-1")
  a._add_permission("inst-1", 42, "req-2")

  local fire_count = 0
  a.on_change(function()
    fire_count = fire_count + 1
  end)

  a._remove_permission("req-1")
  MiniTest.expect.equality(#a.list(), 1)
  MiniTest.expect.equality(a.list()[1].request_id, "req-2")
  MiniTest.expect.equality(fire_count, 1)

  -- Unknown request id → no fire, no change.
  a._remove_permission("req-nope")
  MiniTest.expect.equality(#a.list(), 1)
  MiniTest.expect.equality(fire_count, 1)
end

T["_clear_turn_ended drops only turn_ended rows for the instance"] = function()
  local a = fresh()
  a._add_permission("inst-1", 42, "req-1")
  a._add_turn_ended("inst-1", 42)
  a._add_turn_ended("inst-2", 43)

  a._clear_turn_ended("inst-1")
  -- Permission stays; turn_ended for inst-1 drops; inst-2 untouched.
  MiniTest.expect.equality(#a.list(), 2)
  local kinds_per_instance = {}
  for _, entry in ipairs(a.list()) do
    kinds_per_instance[entry.instance_id] = entry.kind
  end
  MiniTest.expect.equality(kinds_per_instance["inst-1"], "permission")
  MiniTest.expect.equality(kinds_per_instance["inst-2"], "turn_ended")
end

T["_clear_instance drops every entry for the instance"] = function()
  local a = fresh()
  a._add_permission("inst-1", 42, "req-1")
  a._add_turn_ended("inst-1", 42)
  a._add_turn_ended("inst-2", 43)

  a._clear_instance("inst-1")
  MiniTest.expect.equality(#a.list(), 1)
  MiniTest.expect.equality(a.list()[1].instance_id, "inst-2")
end

T["on_change returns an unsubscribe closure"] = function()
  local a = fresh()
  local fire_count = 0
  local unsub = a.on_change(function()
    fire_count = fire_count + 1
  end)

  a._add_permission("inst-1", 42, "req-1")
  MiniTest.expect.equality(fire_count, 1)

  unsub()
  a._add_permission("inst-1", 42, "req-2")
  MiniTest.expect.equality(fire_count, 1)
end

T["ensure_listeners: HyprpilotPermissionRequested User autocmd → add"] = function()
  local a = fresh()
  a.ensure_listeners()

  vim.api.nvim_exec_autocmds("User", {
    pattern = "HyprpilotPermissionRequested",
    data = { instance_id = "inst-1", bufnr = 99, request_id = "req-99" },
  })

  MiniTest.expect.equality(#a.list(), 1)
  MiniTest.expect.equality(a.list()[1].request_id, "req-99")
  MiniTest.expect.equality(a.list()[1].bufnr, 99)
end

T["ensure_listeners: HyprpilotPermissionResolved User autocmd → remove"] = function()
  local a = fresh()
  a.ensure_listeners()
  a._add_permission("inst-1", 99, "req-99")

  vim.api.nvim_exec_autocmds("User", {
    pattern = "HyprpilotPermissionResolved",
    data = { instance_id = "inst-1", request_id = "req-99" },
  })

  MiniTest.expect.equality(#a.list(), 0)
end

T["ensure_listeners: HyprpilotTurnEnded User autocmd → add"] = function()
  local a = fresh()
  a.ensure_listeners()

  vim.api.nvim_exec_autocmds("User", {
    pattern = "HyprpilotTurnEnded",
    data = { instance_id = "inst-1", bufnr = 99 },
  })

  MiniTest.expect.equality(#a.list(), 1)
  MiniTest.expect.equality(a.list()[1].kind, "turn_ended")
end

return T
