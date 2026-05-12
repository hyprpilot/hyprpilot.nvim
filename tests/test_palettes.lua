--- Behavioural tests for the `palettes/` modules. Each case stubs
--- `client.request` (so we don't hit a daemon) and `vim.ui.select`
--- (so we capture the items the palette built and drive a synthetic
--- pick), then verifies the expected commit RPC fired with the
--- right params.
---
--- We keep these in one file because the per-palette plumbing is
--- nearly identical (fetch meta → vim.ui.select → commit) — splitting
--- buys nothing but more harness boilerplate.

local T = MiniTest.new_set()

---Stub `vim.ui.select` so the test drives the picker programmatically.
---Captures `(items, opts)` of every invocation; the synthetic pick is
---controlled by `pick_fn(items, opts) → choice|nil`.
---@param pick_fn fun(items: any[], opts: table): any
---@return fun(), table[]
local function stub_ui_select(pick_fn)
  local original = vim.ui.select
  local invocations = {}

  vim.ui.select = function(items, opts, callback)
    table.insert(invocations, { items = items, opts = opts })
    local choice = pick_fn(items, opts)
    callback(choice)
  end

  return function()
    vim.ui.select = original
  end, invocations
end

---Stub `client.request` with a method → reply table. Reply is
---`{ err = nil, result = ... }`; absent methods return a transport
---error so a stray RPC can't pass silently. Captures every call as
---`{ method, params }` for assertions.
---@param replies table<string, { err?: table, result?: any }>
---@return fun(), table[]
local function stub_client_with(replies)
  local client = require("hyprpilot.client")
  local original = client.request
  local calls = {}

  client.request = function(method, params, _opts, callback)
    table.insert(calls, { method = method, params = params })
    local r = replies[method]
    if r == nil then
      callback({ kind = "transport", message = "unstubbed RPC: " .. method }, nil)
      return
    end
    callback(r.err, r.result)
  end

  return function()
    client.request = original
  end, calls
end

---Force a known active instance for tests that depend on
---`window.active_instance()`. Returns a teardown to restore.
---@param instance_id string?
---@return fun()
local function stub_active_instance(instance_id)
  local window = require("hyprpilot.chat.window")
  local original = window.active_instance
  window.active_instance = function()
    return instance_id
  end
  return function()
    window.active_instance = original
  end
end

---------------------------------------------------------------------
-- modes
---------------------------------------------------------------------

T["palettes.modes: picks a row → fires instances/setMode with the chosen mode id"] = function()
  local restore_active = stub_active_instance("inst-1")
  local restore_client, calls = stub_client_with({
    ["instance/snapshot/meta"] = {
      result = {
        currentModeId = "edit",
        availableModes = {
          { id = "edit", name = "Edit" },
          { id = "plan", name = "Plan" },
        },
      },
    },
    ["instances/setMode"] = { result = { ok = true } },
  })

  local restore_select, ui_calls = stub_ui_select(function(items)
    -- Pick the second row ("plan").
    return items[2]
  end)

  require("hyprpilot.palettes.modes").open()

  -- The picker saw both modes; meta + setMode RPCs both fired.
  MiniTest.expect.equality(#ui_calls, 1)
  MiniTest.expect.equality(#ui_calls[1].items, 2)
  MiniTest.expect.equality(ui_calls[1].opts.kind, "hyprpilot.modes")

  MiniTest.expect.equality(calls[1].method, "instance/snapshot/meta")
  MiniTest.expect.equality(calls[2].method, "instances/setMode")
  MiniTest.expect.equality(calls[2].params.instanceId, "inst-1")
  MiniTest.expect.equality(calls[2].params.modeId, "plan")

  restore_select()
  restore_client()
  restore_active()
end

T["palettes.modes: picking the current mode is a no-op (no setMode RPC)"] = function()
  local restore_active = stub_active_instance("inst-1")
  local restore_client, calls = stub_client_with({
    ["instance/snapshot/meta"] = {
      result = {
        currentModeId = "edit",
        availableModes = { { id = "edit", name = "Edit" } },
      },
    },
  })
  local restore_select = stub_ui_select(function(items)
    return items[1]
  end)

  require("hyprpilot.palettes.modes").open()

  -- Only the meta fetch fired — the no-op skipped the setMode RPC.
  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].method, "instance/snapshot/meta")

  restore_select()
  restore_client()
  restore_active()
end

T["palettes.modes: no active instance → warns + no RPC"] = function()
  local restore_active = stub_active_instance(nil)
  local restore_client, calls = stub_client_with({})
  local restore_select = stub_ui_select(function() end)

  require("hyprpilot.palettes.modes").open()

  MiniTest.expect.equality(#calls, 0)

  restore_select()
  restore_client()
  restore_active()
end

---------------------------------------------------------------------
-- models
---------------------------------------------------------------------

T["palettes.models: picks a row → fires instances/setModel"] = function()
  local restore_active = stub_active_instance("inst-1")
  local restore_client, calls = stub_client_with({
    ["instance/snapshot/meta"] = {
      result = {
        currentModelId = "claude-sonnet",
        availableModels = {
          { id = "claude-sonnet", name = "Sonnet" },
          { id = "claude-opus", name = "Opus" },
        },
      },
    },
    ["instances/setModel"] = { result = { ok = true } },
  })
  local restore_select, ui_calls = stub_ui_select(function(items)
    return items[2]
  end)

  require("hyprpilot.palettes.models").open()

  MiniTest.expect.equality(ui_calls[1].opts.kind, "hyprpilot.models")
  MiniTest.expect.equality(calls[2].method, "instances/setModel")
  MiniTest.expect.equality(calls[2].params.modelId, "claude-opus")

  restore_select()
  restore_client()
  restore_active()
end

---------------------------------------------------------------------
-- effort
---------------------------------------------------------------------

T["palettes.effort: picks an option → fires instances/setOption with config_id=effort"] = function()
  local restore_active = stub_active_instance("inst-1")
  local restore_client, calls = stub_client_with({
    ["instance/snapshot/meta"] = {
      result = {
        configOptions = {
          {
            id = "effort",
            name = "Effort",
            currentValue = "medium",
            options = {
              { value = "low", name = "Low" },
              { value = "medium", name = "Medium" },
              { value = "high", name = "High" },
            },
          },
        },
      },
    },
    ["instances/setOption"] = { result = { ok = true } },
  })
  local restore_select, ui_calls = stub_ui_select(function(items)
    -- Pick "high" (third row).
    return items[3]
  end)

  require("hyprpilot.palettes.effort").open()

  MiniTest.expect.equality(ui_calls[1].opts.kind, "hyprpilot.effort")
  MiniTest.expect.equality(calls[2].method, "instances/setOption")
  MiniTest.expect.equality(calls[2].params.configId, "effort")
  MiniTest.expect.equality(calls[2].params.value, "high")

  restore_select()
  restore_client()
  restore_active()
end

T["palettes.effort: no effort category in configOptions → warn + no picker"] = function()
  local restore_active = stub_active_instance("inst-1")
  local restore_client = stub_client_with({
    ["instance/snapshot/meta"] = {
      result = {
        configOptions = { { id = "thinking", options = {} } },
      },
    },
  })
  local restore_select, ui_calls = stub_ui_select(function() end)

  require("hyprpilot.palettes.effort").open()

  MiniTest.expect.equality(#ui_calls, 0)

  restore_select()
  restore_client()
  restore_active()
end

---------------------------------------------------------------------
-- instances
---------------------------------------------------------------------

T["palettes.instances: picks a row → calls window.switch with the chosen id"] = function()
  local restore_client, calls = stub_client_with({
    ["instances/list"] = {
      result = {
        instances = {
          { instanceId = "inst-a", agentId = "claude-code", profileId = "personal/claude/opus" },
          { instanceId = "inst-b", agentId = "opencode" },
        },
      },
    },
  })

  local restore_active = stub_active_instance("inst-a")

  -- Stub window.switch to capture the call without touching real splits.
  local window = require("hyprpilot.chat.window")
  local original_switch = window.switch
  local switched_to
  window.switch = function(id)
    switched_to = id
  end

  local restore_select, ui_calls = stub_ui_select(function(items)
    -- Pick the inactive instance.
    return items[2]
  end)

  require("hyprpilot.palettes.instances").open()

  MiniTest.expect.equality(ui_calls[1].opts.kind, "hyprpilot.instances")
  MiniTest.expect.equality(switched_to, "inst-b")
  -- The meta fetch never fired — instances palette only needs `list`.
  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].method, "instances/list")

  window.switch = original_switch
  restore_select()
  restore_client()
  restore_active()
end

T["palettes.instances.format_item marks the active instance with a `*` prefix"] = function()
  local format = require("hyprpilot.palettes.instances").format_item
  local active = format({ id = "x", agent_id = "claude-code" }, "x")
  local idle = format({ id = "y", agent_id = "claude-code" }, "x")
  MiniTest.expect.equality(active:sub(1, 2), "* ")
  MiniTest.expect.equality(idle:sub(1, 2), "  ")
end

---------------------------------------------------------------------
-- sessions
---------------------------------------------------------------------

T["palettes.sessions: daemon error from sessions/list is graceful (no picker, no crash)"] = function()
  local restore_client = stub_client_with({
    ["sessions/list"] = { err = { code = -32602, message = "no agents configured" } },
  })
  local restore_select, ui_calls = stub_ui_select(function() end)

  require("hyprpilot.palettes.sessions").open()

  -- The palette must NOT call vim.ui.select after the failure.
  MiniTest.expect.equality(#ui_calls, 0)

  restore_select()
  restore_client()
end

T["palettes.sessions: pick → fires sessions/load with the chosen sessionId + cwd"] = function()
  local restore_client, calls = stub_client_with({
    ["sessions/list"] = {
      -- ACP `ListSessionsResponse` wire shape: every entry is
      -- `{ sessionId, cwd }` (additionalDirectories is unstable; we
      -- don't depend on it). No title / agentId / profileId on the
      -- protocol surface.
      result = {
        sessions = {
          { sessionId = "sess-1", cwd = "/tmp/proj" },
          { sessionId = "sess-2", cwd = "/tmp/other" },
        },
      },
    },
    ["sessions/load"] = { result = { instanceId = "fresh-inst" } },
    -- instances/info follows after sessions/load to register the
    -- buffer; the test only asserts the load fires correctly so we
    -- short-circuit info with a transport error to avoid touching
    -- real buffer/window plumbing.
    ["instances/info"] = { err = { kind = "transport", message = "skipped in test" } },
  })

  local restore_select = stub_ui_select(function(items)
    return items[1]
  end)

  require("hyprpilot.palettes.sessions").open({ profile_id = "personal/claude/opus" })

  local load_call
  for _, c in ipairs(calls) do
    if c.method == "sessions/load" then
      load_call = c
      break
    end
  end

  MiniTest.expect.equality(load_call ~= nil, true)
  MiniTest.expect.equality(load_call.params.sessionId, "sess-1")
  MiniTest.expect.equality(load_call.params.cwd, "/tmp/proj")
  -- profile_id from opts propagates to the load call so the daemon
  -- can resolve the right agent for the resume.
  MiniTest.expect.equality(load_call.params.profileId, "personal/claude/opus")

  restore_select()
  restore_client()
end

T["palettes.sessions.format_item composes `cwd · short-id`"] = function()
  local format = require("hyprpilot.palettes.sessions").format_item
  -- ACP-spec session entry: just sessionId + cwd. The format string
  -- becomes the headline + a short id slug so two sessions in the
  -- same cwd still disambiguate.
  local out = format({
    session_id = "abcdef0123456789",
    cwd = "/tmp/proj",
  })
  MiniTest.expect.equality(out:find("/tmp/proj", 1, true) ~= nil, true)
  MiniTest.expect.equality(out:find("abcdef01", 1, true) ~= nil, true)
end

return T
