--- Behavioural tests for the `palettes/` modules. Each case stubs
--- `client.request` (so we don't hit a daemon) and `vim.ui.select`
--- (so we capture the items the palette built and drive a synthetic
--- pick), then verifies the expected commit RPC fired with the
--- right params.
---
--- We keep these in one file because the per-palette plumbing is
--- nearly identical (fetch meta → vim.ui.select → commit) — splitting
--- buys nothing but more harness boilerplate.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

local stub_ui_select = helpers.stub_ui_select
local stub_client_with = helpers.stub_client_with
local stub_active_instance = helpers.stub_active_instance

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

T["palettes.instances: picks a row → calls instances.attach with the chosen id"] = function()
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

  -- Stub `instances.attach` (the new default commit) — picker
  -- now routes through it so daemon-only ids (not in the local
  -- registry) get hydrated rather than crashing through
  -- `window.switch`.
  local hp_instances = require("hyprpilot.rpc.instances")
  local original_attach = hp_instances.attach
  local attached_to
  hp_instances.attach = function(id)
    attached_to = id
  end

  local restore_select, ui_calls = stub_ui_select(function(items)
    -- Pick the inactive instance.
    return items[2]
  end)

  require("hyprpilot.palettes.instances").open()

  MiniTest.expect.equality(ui_calls[1].opts.kind, "hyprpilot.instances")
  MiniTest.expect.equality(attached_to, "inst-b")
  -- The meta fetch never fired — instances palette only needs `list`.
  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].method, "instances/list")

  hp_instances.attach = original_attach
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

T["palettes.sessions: omitted cwd defaults the list filter to vim's cwd"] = function()
  local restore_client, calls = stub_client_with({
    ["sessions/list"] = { result = { sessions = {} } },
  })
  local restore_select = stub_ui_select(function() end)

  require("hyprpilot.palettes.sessions").open()

  local list_call
  for _, c in ipairs(calls) do
    if c.method == "sessions/list" then
      list_call = c
      break
    end
  end
  MiniTest.expect.equality(list_call ~= nil, true)
  MiniTest.expect.equality(list_call.params.cwd, vim.fn.getcwd())

  restore_select()
  restore_client()
end

T["palettes.sessions: `cwd = false` disables the filter (list every session)"] = function()
  local restore_client, calls = stub_client_with({
    ["sessions/list"] = { result = { sessions = {} } },
  })
  local restore_select = stub_ui_select(function() end)

  require("hyprpilot.palettes.sessions").open({ cwd = false })

  local list_call
  for _, c in ipairs(calls) do
    if c.method == "sessions/list" then
      list_call = c
      break
    end
  end
  MiniTest.expect.equality(list_call ~= nil, true)
  MiniTest.expect.equality(list_call.params.cwd, nil)

  restore_select()
  restore_client()
end

T["palettes.sessions.format_item composes `cwd · short-id`"] = function()
  local format = require("hyprpilot.palettes.sessions").format_item
  -- ACP-spec session entry without title/updatedAt: headline is cwd
  -- and a short id slug disambiguates two sessions in the same cwd.
  local out = format({
    session_id = "abcdef0123456789",
    cwd = "/tmp/proj",
  })
  MiniTest.expect.equality(out:find("/tmp/proj", 1, true) ~= nil, true)
  MiniTest.expect.equality(out:find("abcdef01", 1, true) ~= nil, true)
end

T["palettes.sessions.format_item: title becomes the headline, cwd + timestamp follow"] = function()
  local format = require("hyprpilot.palettes.sessions").format_item
  local out = format({
    session_id = "abcdef0123456789",
    cwd = "/tmp/proj",
    title = "wire up profiles palette",
    updated_at = "2026-05-15T10:30:45.123Z",
  })
  MiniTest.expect.equality(out:find("wire up profiles palette", 1, true) ~= nil, true)
  MiniTest.expect.equality(out:find("/tmp/proj", 1, true) ~= nil, true)
  MiniTest.expect.equality(out:find("2026-05-15 10:30", 1, true) ~= nil, true)
  MiniTest.expect.equality(out:find("abcdef01", 1, true) ~= nil, true)
end

T["palettes.sessions.format_item: malformed updatedAt is dropped, no junk in row"] = function()
  local format = require("hyprpilot.palettes.sessions").format_item
  local out = format({
    session_id = "abcdef0123456789",
    cwd = "/tmp/proj",
    updated_at = "not-a-real-timestamp",
  })
  MiniTest.expect.equality(out:find("not-a-real", 1, true), nil)
  MiniTest.expect.equality(out:find("/tmp/proj", 1, true) ~= nil, true)
end

T["palettes.sessions: from_wire pulls title / updatedAt / _meta off the wire"] = function()
  local from_wire = require("hyprpilot.palettes.sessions").from_wire
  local out = from_wire({
    sessionId = "sess-1",
    cwd = "/tmp/proj",
    title = "hello",
    updatedAt = "2026-05-15T10:30:00Z",
    _meta = { agentVersion = "1.2.3" },
  })
  MiniTest.expect.equality(out.session_id, "sess-1")
  MiniTest.expect.equality(out.title, "hello")
  MiniTest.expect.equality(out.updated_at, "2026-05-15T10:30:00Z")
  MiniTest.expect.equality(out.meta.agentVersion, "1.2.3")
end

T["palettes.sessions: list result is sorted by updatedAt descending; nil sinks last"] = function()
  local restore_client, calls = stub_client_with({
    ["sessions/list"] = {
      result = {
        sessions = {
          { sessionId = "old", cwd = "/tmp/a", updatedAt = "2026-01-01T00:00:00Z" },
          { sessionId = "no-ts", cwd = "/tmp/b" },
          { sessionId = "new", cwd = "/tmp/c", updatedAt = "2026-05-15T10:00:00Z" },
          { sessionId = "mid", cwd = "/tmp/d", updatedAt = "2026-03-01T00:00:00Z" },
        },
      },
    },
  })

  local seen_items
  local restore_select = stub_ui_select(function(items)
    seen_items = items
    return nil
  end)

  require("hyprpilot.palettes.sessions").open({ picker = "vim.ui.select" })

  MiniTest.expect.equality(#seen_items, 4)
  MiniTest.expect.equality(seen_items[1].session_id, "new")
  MiniTest.expect.equality(seen_items[2].session_id, "mid")
  MiniTest.expect.equality(seen_items[3].session_id, "old")
  MiniTest.expect.equality(seen_items[4].session_id, "no-ts")

  -- sanity: sessions/list was called once
  local list_count = 0
  for _, c in ipairs(calls) do
    if c.method == "sessions/list" then
      list_count = list_count + 1
    end
  end
  MiniTest.expect.equality(list_count, 1)

  restore_select()
  restore_client()
end

return T
