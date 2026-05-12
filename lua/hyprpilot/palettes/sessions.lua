--- Sessions palette — picker over resumable sessions the daemon
--- advertises via `sessions/list`. Pick a row, the daemon spawns a
--- fresh instance and adopts the chosen `sessionId` via
--- `sessions/load`.
---
--- Wire shape mirrors the ACP `ListSessionsResponse`:
---   { sessions: [{ sessionId, cwd, additionalDirectories? }], nextCursor? }

local client = require("hyprpilot.client")
local instances = require("hyprpilot.instances")
local log = require("hyprpilot.log")
local pickers = require("hyprpilot.palettes.pickers")

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
---@field picker? "auto" | "snacks" | "vim.ui.select"

---@param wire table
---@return hyprpilot.palettes.sessions.Session
local function from_wire(wire)
  return {
    session_id = wire.sessionId,
    cwd = wire.cwd,
    additional_directories = wire.additionalDirectories,
  }
end

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

---@param item hyprpilot.palettes.sessions.Session
---@return { lines: string[], ft: string }
local function format_preview(item)
  local lines = { "# " .. (item.cwd or "(no cwd)"), "" }
  if item.session_id ~= nil then
    table.insert(lines, string.format("- **session id:** `%s`", item.session_id))
  end
  if item.cwd ~= nil then
    table.insert(lines, string.format("- **cwd:** `%s`", item.cwd))
  end
  if type(item.additional_directories) == "table" and #item.additional_directories > 0 then
    table.insert(lines, "- **additional directories:**")
    for _, d in ipairs(item.additional_directories) do
      table.insert(lines, "  - `" .. d .. "`")
    end
  end
  return { lines = lines, ft = "markdown" }
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

    pickers.open({
      items = items,
      title = "sessions",
      kind = "hyprpilot.sessions",
      picker = opts.picker,
      format_item = format_item,
      preview = format_preview,
      on_pick = function(choice)
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
      end,
    })
  end)
end

M.format_item = format_item
M.format_preview = format_preview
M.from_wire = from_wire

return M
