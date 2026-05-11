--- Sessions palette — `vim.ui.select` over resumable sessions the
--- daemon advertises via `sessions/list`. Pick a row, the daemon
--- spawns a fresh instance and adopts the chosen `sessionId` via
--- `sessions/load`.
---
--- The wire RPCs (`sessions/list`, `sessions/load`) aren't on the
--- public socket surface yet — they currently live as Tauri-only
--- commands. See `docs/plans/2026-05-12-sessions-rpc-handoff.md`
--- for the daemon-side handoff. Until that lands, the palette
--- gracefully surfaces a `-32601 method_not_found` error via
--- log.warn instead of crashing — captains who wire the keymap
--- ahead of the daemon shipping the RPC see a single warn line and
--- the picker no-ops.

local client = require("hyprpilot.client")
local instances = require("hyprpilot.instances")
local log = require("hyprpilot.log")

local M = {}

---@class hyprpilot.palettes.sessions.Session
---@field session_id string
---@field agent_id? string
---@field profile_id? string
---@field cwd? string
---@field title? string
---@field last_seen_at? string  -- ISO-8601

---@class hyprpilot.palettes.sessions.Opts
---@field cwd? string  -- filter to sessions whose cwd matches; default: every session

---Translate the daemon's wire shape (camelCase) to our snake_case
---table. Keeps the palette agnostic to wire renames the daemon team
---might make on either side of the handoff.
---@param wire table
---@return hyprpilot.palettes.sessions.Session
local function from_wire(wire)
  return {
    session_id = wire.sessionId,
    agent_id = wire.agentId,
    profile_id = wire.profileId,
    cwd = wire.cwd,
    title = wire.title,
    last_seen_at = wire.lastSeenAt,
  }
end

---Format a session row for the picker. Headline column = title (when
---present) or session_id; the agent / profile / cwd / last-seen
---fields fan out into a `· `-joined trailing block.
---@param item hyprpilot.palettes.sessions.Session
---@return string
local function format_item(item)
  local headline = item.title or item.session_id
  local meta = {}
  if item.agent_id ~= nil then
    table.insert(meta, item.agent_id)
  end
  if item.profile_id ~= nil then
    table.insert(meta, item.profile_id)
  end
  if item.cwd ~= nil then
    table.insert(meta, item.cwd)
  end
  if item.last_seen_at ~= nil then
    table.insert(meta, item.last_seen_at)
  end

  if #meta == 0 then
    return headline
  end
  return headline .. " · " .. table.concat(meta, " · ")
end

---@param opts? hyprpilot.palettes.sessions.Opts
function M.open(opts)
  opts = opts or {}

  local params = {}
  if opts.cwd ~= nil then
    params.cwd = opts.cwd
  end

  client.request("sessions/list", params, nil, function(err, result)
    if err ~= nil then
      log.warn("palettes.sessions: sessions/list failed: %s", err)
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

      -- `sessions/load` adopts the session into a fresh instance.
      -- We pass through to `instances.focus` with `restore = true`
      -- + the `session_id` once the daemon-side handoff lands; for
      -- now route the load directly so the palette is wire-ready.
      client.request(
        "sessions/load",
        {
          sessionId = choice.session_id,
          cwd = choice.cwd,
          agentId = choice.agent_id,
          profileId = choice.profile_id,
        },
        nil,
        function(load_err, load_result)
          if load_err ~= nil then
            log.warn("palettes.sessions: sessions/load failed: %s", load_err.message)
            return
          end

          local instance_id = load_result and load_result.instanceId
          if instance_id == nil then
            log.warn("palettes.sessions: sessions/load returned no instanceId")
            return
          end

          -- Refresh the instance into the local registry so the chat
          -- buffer + window pick it up on the next show.
          instances.info(instance_id, function(info_err, info)
            if info_err ~= nil then
              log.warn("palettes.sessions: instances/info post-load failed: %s", info_err.message)
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
