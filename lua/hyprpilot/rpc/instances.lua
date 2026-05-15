--- Multi-instance Lua API.
---
--- Thin wrapper over the daemon's `instances/*` RPCs (`list`, `spawn`,
--- `focus`, `restart`, `shutdown`, `rename`, `info`). Every call
--- translates Lua-idiomatic snake_case option keys to the daemon's
--- camelCase wire shape and back.
---
--- `spawn` and `focus` (in ensure-mode) take care of the buffer
--- lifecycle: create the per-instance chat buffer, register it with
--- `chat.window`, and optionally `show` the chat split.

local buffer = require("hyprpilot.chat.buffer")
local client = require("hyprpilot.client")
local log = require("hyprpilot.log")
local window = require("hyprpilot.chat.window")

local M = {}

-- Spawn-bearing daemon calls (spawn / focus + ensure / restart) wait
-- on a cold agent handshake (claude-code, opencode, etc. spinning up
-- their ACP runtime). The default 5s client timeout is too short for
-- that path; bump to 30s for the calls that actually hit spawn paths.
-- Read-only calls (list / info / meta / setMode / setModel / setOption
-- / rename / shutdown) stay on the default timeout.
local SPAWN_TIMEOUT_MS = 30000

---@class hyprpilot.Instance
---@field id string
---@field name? string
---@field agent_id? string
---@field profile_id? string
---@field session_id? string
---@field mode? string
---@field cwd? string

---One Kustomize-style overlay patch — a JSON-shaped table merged
---onto the daemon's resolved `Config` before a spawn-bearing RPC
---proceeds. Each patch supports object merge, keyed-array merge by
---`id`, primitive-array append, plus `$patch: replace`,
---`$patch: delete`, and `$deleteFromPrimitiveList/<field>`
---directives (see daemon's `merge::strategic_merge`). Bad shapes
---are rejected daemon-side with `-32602`.
---@alias hyprpilot.ConfigPatch table<string, any>

---@class hyprpilot.SpawnOpts
---@field profile_id? string
---@field agent_id? string
---@field cwd? string         -- default: `vim.fn.getcwd()`
---@field mode? string
---@field model? string
---@field restore? boolean    -- default false; true → resume the latest matching session if any
---@field name? string        -- captain-assigned slug (uses `focus` with ensure=true under the hood)
---@field show? boolean       -- default true; switch the chat split to the spawned instance
---@field with_config? hyprpilot.ConfigPatch[]
--- Overlay patches applied in declaration order. Sticks to the
--- spawned instance for restart replay. Omitted from the wire when
--- nil / empty / malformed (a `log.warn` fires on bad shapes so
--- captain misuse doesn't drop silently).

---@class hyprpilot.FocusOpts
---@field ensure? boolean     -- default false; true → spawn-and-rename if the slug doesn't resolve
---@field profile_id? string
---@field agent_id? string
---@field cwd? string
---@field mode? string
---@field model? string
---@field restore? boolean
---@field show? boolean       -- default true
---@field with_config? hyprpilot.ConfigPatch[]
--- Same shape as `SpawnOpts.with_config`; only honoured on the
--- ensure-spawn path (a focus that resolves to a live instance
--- ignores it).

---@class hyprpilot.InstanceMeta
---@field profile_id? string
---@field session_id? string
---@field cwd? string
---@field current_mode_id? string
---@field current_model_id? string
---@field available_modes? table[]
---@field available_models? table[]
---@field config_options? table[]
---@field mcps_count? integer
---@field usage? table
---@field latest_seq? integer
---@field pending_permissions? table[]

---@alias hyprpilot.InstanceCallback fun(err: hyprpilot.client.RpcError?, instance: hyprpilot.Instance?): nil
---@alias hyprpilot.InstancesCallback fun(err: hyprpilot.client.RpcError?, instances: hyprpilot.Instance[]?): nil
---@alias hyprpilot.InstanceMetaCallback fun(err: hyprpilot.client.RpcError?, meta: hyprpilot.InstanceMeta?): nil

---Translate the daemon's camelCase Instance wire shape into our
---snake_case `hyprpilot.Instance` shape. Used for `instances/list`
---and `instances/info` replies. Defensively coerces the input to a
---table so a malformed daemon reply (nil / vim.NIL / wrong type)
---degrades to an empty Instance rather than crashing the callback
---chain — every caller can read the returned `id` and decide
---whether to proceed.
---@param wire any
---@return hyprpilot.Instance
local function from_wire(wire)
  if type(wire) ~= "table" then
    return { id = "" }
  end
  return {
    id = wire.instanceId or "",
    name = wire.name,
    agent_id = wire.agentId,
    profile_id = wire.profileId,
    session_id = wire.sessionId,
    mode = wire.mode,
    cwd = wire.cwd,
  }
end

---Translate the daemon's camelCase MetaSnapshot shape into our
---snake_case `hyprpilot.InstanceMeta`. Distinct from `from_wire`
---because MetaSnapshot is a fundamentally different payload —
---no `instanceId` / `name` / `agentId`, but it carries mode /
---model / usage / mcps_count / available_* fields the pickers and
---winbar consume.
---@param wire any
---@return hyprpilot.InstanceMeta
local function from_meta_wire(wire)
  if type(wire) ~= "table" then
    return {}
  end
  return {
    profile_id = wire.profileId,
    session_id = wire.sessionId,
    cwd = wire.cwd,
    current_mode_id = wire.currentModeId,
    current_model_id = wire.currentModelId,
    available_modes = wire.availableModes,
    available_models = wire.availableModels,
    config_options = wire.configOptions,
    mcps_count = wire.mcpsCount,
    usage = wire.usage,
    latest_seq = wire.latestSeq,
    pending_permissions = wire.pendingPermissions,
  }
end

local with_config = require("hyprpilot.rpc.with-config")

---Bring a freshly-spawned instance into the local registry + window.
---`activate = show_after`: a background spawn (`show = false`) leaves
---the existing active instance in place rather than silently flipping
---`_last_active_id` and rerouting the next composer submit. Shown
---spawns flip active as part of the explicit `window.show` below.
---@param instance hyprpilot.Instance
---@param show_after boolean
local function attach(instance, show_after)
  local bufnr = buffer.create(instance.id)

  window.register({ bufnr = bufnr, instance_id = instance.id, name = instance.name }, { activate = show_after })

  if show_after then
    window.show(instance.id)
  end
end

---Attach to an instance the daemon knows about — mint a local
---buffer, register it with the window, hydrate the chat snapshot,
---and (by default) show it. When the instance is ALREADY in the
---local registry this is a thin wrapper around `window.show(id)`
---so callers don't need to distinguish "known locally" from
---"only known daemon-side" — same call works for both.
---
---Use case: the captain opens the instances palette after a
---restart / re-source. The plugin's local registry is empty, but
---the daemon still has the instance running. Picking it from
---`instances/list` should bring it back into the captain's UI
---without forcing a respawn — that's exactly what this does.
---@param instance_id string
---@param opts? { show?: boolean, callback?: hyprpilot.InstanceCallback }
function M.attach(instance_id, opts)
  opts = opts or {}
  local show_after = opts.show ~= false
  local callback = opts.callback

  if type(instance_id) ~= "string" or instance_id == "" then
    log.warn("instances.attach: instance_id must be a non-empty string")
    if callback ~= nil then
      callback({ message = "instance_id required" }, nil)
    end
    return
  end

  -- Already known locally — just show. `window.show` handles the
  -- already-visible / not-visible cases idempotently.
  if window._instances[instance_id] ~= nil then
    if show_after then
      window.show(instance_id)
    end
    if callback ~= nil then
      callback(nil, { id = instance_id })
    end
    return
  end

  -- Daemon-only — fetch the instance shape so we can register with
  -- the right name, then mint + hydrate. `attach()` (the local
  -- helper above) handles the mint / register / show / hydrate
  -- choreography so spawn / focus / load_session / attach all
  -- converge on the same path.
  M.info(instance_id, function(err, info)
    if err ~= nil then
      log.warn("instances.attach: info failed for %s: %s", instance_id, err.message)
      if callback ~= nil then
        callback(err, nil)
      end
      return
    end
    if type(info) ~= "table" or info.id == nil or info.id == "" then
      log.warn("instances.attach: daemon returned no instance for %s", instance_id)
      if callback ~= nil then
        callback({ message = "daemon returned no instance" }, nil)
      end
      return
    end
    attach(info, show_after)
    if callback ~= nil then
      callback(nil, info)
    end
  end)
end

---List every live instance the daemon knows about.
---@param callback hyprpilot.InstancesCallback
function M.list(callback)
  client.request("instances/list", nil, nil, function(err, result)
    if err ~= nil then
      callback(err, nil)

      return
    end

    local list = (type(result) == "table" and type(result.instances) == "table") and result.instances or {}
    callback(nil, vim.tbl_map(from_wire, list))
  end)
end

---Fetch one instance's identity (`Instance` shape — id / name /
---agent_id / profile_id / session_id / mode / cwd). Defaults to the
---focused instance when `instance_id` is nil. Calls the daemon's
---`instances/info` RPC; use `M.meta` when you need mode / model /
---usage / availability details.
---@param instance_id string?
---@param callback hyprpilot.InstanceCallback
function M.info(instance_id, callback)
  local params = nil

  if instance_id ~= nil then
    params = { instanceId = instance_id }
  end

  client.request("instances/info", params, nil, function(err, result)
    if err ~= nil then
      callback(err, nil)

      return
    end

    callback(nil, from_wire(result))
  end)
end

---Fetch the live `MetaSnapshot` (mode / model / usage / mcps_count /
---availability lists / pending permissions) for an instance. This is
---the payload the chat winbar hydrates from and what the README's
---mode / model pickers read off. Defaults to the focused instance
---when `instance_id` is nil.
---@param instance_id string?
---@param callback hyprpilot.InstanceMetaCallback
function M.meta(instance_id, callback)
  client.request("instance/snapshot/meta", { instanceId = instance_id }, nil, function(err, result)
    if err ~= nil then
      callback(err, nil)

      return
    end

    callback(nil, from_meta_wire(result))
  end)
end

---Spawn a new instance. Defaults `cwd = vim.fn.getcwd()` and
---`show = true`. When `name` is provided, routes through `focus`
---with `ensure = true` so the daemon spawns + renames atomically.
---@param opts hyprpilot.SpawnOpts?
---@param callback hyprpilot.InstanceCallback?
function M.spawn(opts, callback)
  opts = opts or {}

  if opts.name ~= nil and opts.name ~= "" then
    M.focus(opts.name, vim.tbl_extend("force", opts, { ensure = true }), callback)

    return
  end

  local cwd = opts.cwd or vim.fn.getcwd()
  local show_after = opts.show ~= false

  local params = {
    profileId = opts.profile_id,
    agentId = opts.agent_id,
    cwd = cwd,
    mode = opts.mode,
    model = opts.model,
    restore = opts.restore == true,
  }
  with_config.apply(params, opts.with_config)

  client.request("instances/spawn", params, { timeout_ms = SPAWN_TIMEOUT_MS }, function(err, result)
    if err ~= nil then
      log.warn("instances.spawn: %s", err.message)

      if callback ~= nil then
        callback(err, nil)
      end

      return
    end

    local instance = { id = result.instanceId, cwd = cwd }
    attach(instance, show_after)

    if callback ~= nil then
      callback(nil, instance)
    end
  end)
end

---Focus an instance by id-or-slug. With `ensure = true`, spawns
---+ renames when the slug doesn't resolve (matches the daemon's
---ensure-mode overload).
---@param instance_id string
---@param opts hyprpilot.FocusOpts?
---@param callback hyprpilot.InstanceCallback?
function M.focus(instance_id, opts, callback)
  opts = opts or {}

  local cwd = opts.cwd or vim.fn.getcwd()
  local show_after = opts.show ~= false

  local params = {
    instanceId = instance_id,
    ensure = opts.ensure == true,
    profileId = opts.profile_id,
    agentId = opts.agent_id,
    cwd = cwd,
    mode = opts.mode,
    model = opts.model,
    restore = opts.restore == true,
  }
  with_config.apply(params, opts.with_config)

  client.request("instances/focus", params, { timeout_ms = SPAWN_TIMEOUT_MS }, function(err, result)
    if err ~= nil then
      log.warn("instances.focus: %s", err.message)

      if callback ~= nil then
        callback(err, nil)
      end

      return
    end

    local instance = { id = result.instanceId, name = result.name, cwd = cwd }
    attach(instance, show_after)

    if callback ~= nil then
      callback(nil, instance)
    end
  end)
end

---Restart an instance daemon-side. Buffer stays put — the daemon's
---next snapshot will fill it. Defaults to the active instance.
---@param instance_id string?
---@param callback hyprpilot.InstanceCallback?
function M.restart(instance_id, callback)
  local id = instance_id or window.active_instance()

  if id == nil then
    log.warn("instances.restart: no active instance and none specified")

    if callback ~= nil then
      callback({ kind = "transport", message = "no active instance" }, nil)
    end

    return
  end

  client.request("instances/restart", { instanceId = id }, { timeout_ms = SPAWN_TIMEOUT_MS }, function(err, result)
    if err ~= nil then
      if callback ~= nil then
        callback(err, nil)
      end

      return
    end

    if callback ~= nil then
      callback(nil, { id = result.instanceId })
    end
  end)
end

---Shut down a daemon-side instance. The local buffer stays put — call
---`require("hyprpilot").close(id)` to also wipe the buffer.
---Defaults to the active instance.
---@param instance_id string?
---@param callback hyprpilot.InstanceCallback?
function M.shutdown(instance_id, callback)
  local id = instance_id or window.active_instance()

  if id == nil then
    log.warn("instances.shutdown: no active instance and none specified")

    if callback ~= nil then
      callback({ kind = "transport", message = "no active instance" }, nil)
    end

    return
  end

  client.request("instances/shutdown", { instanceId = id }, nil, function(err, result)
    if err ~= nil then
      if callback ~= nil then
        callback(err, nil)
      end

      return
    end

    if callback ~= nil then
      callback(nil, { id = result.instanceId })
    end
  end)
end

---Rename an instance daemon-side.
---@param instance_id string
---@param name string
---@param callback hyprpilot.InstanceCallback?
function M.rename(instance_id, name, callback)
  client.request("instances/rename", { instanceId = instance_id, name = name }, nil, function(err, result)
    if err ~= nil then
      if callback ~= nil then
        callback(err, nil)
      end

      return
    end

    if callback ~= nil then
      callback(nil, { id = result.instanceId, name = result.name })
    end
  end)
end

---@alias hyprpilot.SetterCallback fun(err: hyprpilot.client.RpcError?, result: any?): nil

---Switch the instance to `mode_id`. Mode ids come from the
---`available_modes[].id` advertised on `acp:instance-meta` /
---`instance/snapshot/meta` (also rendered in the chat winbar).
---@param instance_id string
---@param mode_id string
---@param callback? hyprpilot.SetterCallback
function M.set_mode(instance_id, mode_id, callback)
  if type(instance_id) ~= "string" or instance_id == "" then
    log.warn("instances.set_mode: instance_id must be a non-empty string")
    return
  end

  if type(mode_id) ~= "string" or mode_id == "" then
    log.warn("instances.set_mode: mode_id must be a non-empty string")
    return
  end

  client.request("instances/setMode", { instanceId = instance_id, modeId = mode_id }, nil, function(err, result)
    if callback ~= nil then
      callback(err, result)
    end
  end)
end

---Switch the instance to `model_id`. Model ids come from
---`available_models[].id` on the instance meta.
---@param instance_id string
---@param model_id string
---@param callback? hyprpilot.SetterCallback
function M.set_model(instance_id, model_id, callback)
  if type(instance_id) ~= "string" or instance_id == "" then
    log.warn("instances.set_model: instance_id must be a non-empty string")
    return
  end

  if type(model_id) ~= "string" or model_id == "" then
    log.warn("instances.set_model: model_id must be a non-empty string")
    return
  end

  client.request("instances/setModel", { instanceId = instance_id, modelId = model_id }, nil, function(err, result)
    if callback ~= nil then
      callback(err, result)
    end
  end)
end

---Set a session config option (e.g. `effort = high` for claude-agent-acp
---0.21+). `config_id` and `value` come from the agent's advertised
---`configOptions[]` shape.
---@param instance_id string
---@param config_id string
---@param value string
---@param callback? hyprpilot.SetterCallback
function M.set_option(instance_id, config_id, value, callback)
  if type(instance_id) ~= "string" or instance_id == "" then
    log.warn("instances.set_option: instance_id must be a non-empty string")
    return
  end

  if type(config_id) ~= "string" or config_id == "" then
    log.warn("instances.set_option: config_id must be a non-empty string")
    return
  end

  if type(value) ~= "string" then
    log.warn("instances.set_option: value must be a string")
    return
  end

  client.request("instances/setOption", { instanceId = instance_id, configId = config_id, value = value }, nil, function(err, result)
    if callback ~= nil then
      callback(err, result)
    end
  end)
end

return M
