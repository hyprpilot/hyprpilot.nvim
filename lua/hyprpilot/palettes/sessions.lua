--- Sessions palette — `vim.ui.select` over resumable sessions the
--- daemon advertises via `sessions/list`. Pick a row, the daemon
--- spawns a fresh instance and adopts the chosen `sessionId` via
--- `sessions/load`.
---
--- Wire shape mirrors the ACP `ListSessionsResponse`:
---   { sessions: [{ sessionId, cwd, additionalDirectories? }], nextCursor? }
--- The agent (claude-agent-acp, opencode, etc.) is the source of
--- truth for the per-session fields; ACP keeps the list lean
--- (sessionId + cwd) instead of carrying title / lastSeenAt /
--- agentId — those don't exist on the protocol surface.

local client = require("hyprpilot.client")
local instances = require("hyprpilot.instances")
local log = require("hyprpilot.log")

local M = {}

---@class hyprpilot.palettes.sessions.Session
---@field session_id string
---@field cwd? string
---@field additional_directories? string[]

---@class hyprpilot.palettes.sessions.Opts
---@field instance_id? string  -- reuse a live instance's actor for the list call
---@field agent_id? string     -- direct ACP agent id (skip profile resolution)
---@field profile_id? string   -- profile to resolve against when no instance / agent specified
---@field cwd? string          -- filter to sessions whose cwd matches; default: every session

---Translate the daemon's camelCase wire entry to our snake_case
---table. ACP's `SessionInfo` minimum is `sessionId + cwd`; the
---`additionalDirectories` field is unstable and may be absent.
---@param wire table
---@return hyprpilot.palettes.sessions.Session
local function from_wire(wire)
  return {
    session_id = wire.sessionId,
    cwd = wire.cwd,
    additional_directories = wire.additionalDirectories,
  }
end

---Format a session row for the picker. Headline = cwd (it's the
---human-recognisable handle for "which project was this for");
---short session id rides as the trailing identifier so two sessions
---in the same cwd still disambiguate.
---@param item hyprpilot.palettes.sessions.Session
---@return string
local function format_item(item)
  local headline = item.cwd or "(no cwd)"
  local short_id = (item.session_id or ""):sub(1, 8)
  if short_id == "" then
    return headline
  end
  return headline .. " · " .. short_id
end

---@param opts? hyprpilot.palettes.sessions.Opts
function M.open(opts)
  opts = opts or {}

  local params = {}
  if opts.instance_id ~= nil then
    params.instanceId = opts.instance_id
  end
  if opts.agent_id ~= nil then
    params.agentId = opts.agent_id
  end
  if opts.profile_id ~= nil then
    params.profileId = opts.profile_id
  end
  if opts.cwd ~= nil then
    params.cwd = opts.cwd
  end

  client.request("sessions/list", params, nil, function(err, result)
    if err ~= nil then
      log.p.warn("palettes.sessions: sessions/list failed: " .. tostring(err.message))
      return
    end

    local raw = (result and result.sessions) or {}
    if #raw == 0 then
      log.warn("palettes.sessions: no resumable sessions")
      return
    end

    local items = {}
    for _, w in ipairs(raw) do
      table.insert(items, from_wire(w))
    end

    vim.ui.select(items, {
      prompt = "sessions",
      format_item = format_item,
      kind = "hyprpilot.sessions",
    }, function(choice)
      if choice == nil then
        return
      end

      client.request(
        "sessions/load",
        {
          sessionId = choice.session_id,
          instanceId = opts.instance_id,
          agentId = opts.agent_id,
          profileId = opts.profile_id,
          cwd = choice.cwd or opts.cwd,
        },
        nil,
        function(load_err, load_result)
          if load_err ~= nil then
            log.p.warn("palettes.sessions: sessions/load failed: " .. tostring(load_err.message))
            return
          end

          local instance_id = load_result and load_result.instanceId
          if instance_id == nil then
            log.warn("palettes.sessions: sessions/load returned no instanceId")
            return
          end

          -- Register the freshly-spawned instance with the chat buffer
          -- + window so the captain lands inside the loaded session on
          -- the next show.
          instances.info(instance_id, function(info_err, info)
            if info_err ~= nil then
              log.p.warn("palettes.sessions: instances/info post-load failed: " .. tostring(info_err.message))
              return
            end
            local bufnr = require("hyprpilot.chat.buffer").create(info.id)
            require("hyprpilot.chat.window").register({ bufnr = bufnr, instance_id = info.id, name = info.name })
            require("hyprpilot.chat.window").show(info.id)
          end)
        end
      )
    end)
  end)
end

M.format_item = format_item
M.from_wire = from_wire

return M
