--- Sessions palette — picker over resumable sessions the daemon
--- advertises via `sessions/list`. Pick a row, the daemon spawns a
--- fresh instance and adopts the chosen `sessionId` via
--- `sessions/load`.
---
--- Wire shape mirrors the ACP `ListSessionsResponse` (schema 0.12+):
---   { sessions: [{ sessionId, cwd, title?, updatedAt?,
---                  additionalDirectories?, _meta? }], nextCursor? }
--- Rows are sorted by `updatedAt` descending so the most-recent
--- session lands at the top.

local client = require("hyprpilot.client")
local instances = require("hyprpilot.rpc.instances")
local log = require("hyprpilot.log")
local pickers = require("hyprpilot.palettes.pickers")

local M = {}

---@class hyprpilot.palettes.sessions.Session
---@field session_id string
---@field cwd? string
---@field additional_directories? string[]
---@field title? string                -- agent-supplied human-readable label
---@field updated_at? string           -- ISO 8601; sortable as a string
---@field meta? table                  -- ACP `_meta` extensibility blob

---@class hyprpilot.palettes.sessions.Opts
---@field instance_id? string         -- reuse a live instance's actor for the list call
---@field agent_id? string            -- direct ACP agent id (skip profile resolution)
---@field profile_id? string          -- profile to resolve against when no instance / agent specified
---@field cwd? string | false         -- filter & load cwd; default `vim.fn.getcwd()`; `false` disables the filter (every session)
---@field picker? "auto" | "snacks" | "vim.ui.select"
---@field with_config? hyprpilot.ConfigPatch[]
--- Same shape as `instances.spawn`'s `with_config`. Stacks on top of
--- `config.options.with_config`; daemon folds the merged list onto
--- the resolved profile before spawning the resumed instance and
--- stores it on the instance for restart replay.

---@param wire table
---@return hyprpilot.palettes.sessions.Session
local function from_wire(wire)
  return {
    session_id = wire.sessionId,
    cwd = wire.cwd,
    additional_directories = wire.additionalDirectories,
    title = wire.title,
    updated_at = wire.updatedAt,
    meta = wire._meta,
  }
end

---Trim an ISO 8601 timestamp down to `YYYY-MM-DD HH:MM` for the
---picker row. Returns nil when the input doesn't match the shape so
---the caller can drop the field instead of rendering a junk string.
---@param iso string?
---@return string?
local function short_timestamp(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local date, time = iso:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
  if date == nil then
    return nil
  end
  return date .. " " .. time
end

---@param item hyprpilot.palettes.sessions.Session
---@return string
local function format_item(item)
  local headline
  if type(item.title) == "string" and item.title ~= "" then
    headline = item.title
  else
    headline = item.cwd or "(no cwd)"
  end

  local meta_parts = {}
  -- When title carries the headline, surface the cwd alongside so
  -- captains who orient by directory still see it without opening
  -- the preview pane.
  if headline ~= item.cwd and type(item.cwd) == "string" and item.cwd ~= "" then
    table.insert(meta_parts, item.cwd)
  end
  local short_ts = short_timestamp(item.updated_at)
  if short_ts ~= nil then
    table.insert(meta_parts, short_ts)
  end
  local short_id = (item.session_id or ""):sub(1, 8)
  if short_id ~= "" then
    table.insert(meta_parts, short_id)
  end

  if #meta_parts == 0 then
    return headline
  end
  return headline .. " · " .. table.concat(meta_parts, " · ")
end

---@param item hyprpilot.palettes.sessions.Session
---@return { lines: string[], ft: string }
local function format_preview(item)
  local headline = (type(item.title) == "string" and item.title ~= "" and item.title) or item.cwd or "(no cwd)"
  local lines = { "# " .. headline, "" }
  local function field(label, value)
    if value ~= nil and value ~= "" then
      table.insert(lines, string.format("- **%s:** `%s`", label, value))
    end
  end
  field("title", item.title)
  field("session id", item.session_id)
  field("cwd", item.cwd)
  field("updated at", item.updated_at)
  if type(item.additional_directories) == "table" and #item.additional_directories > 0 then
    table.insert(lines, "- **additional directories:**")
    for _, d in ipairs(item.additional_directories) do
      table.insert(lines, "  - `" .. d .. "`")
    end
  end
  if type(item.meta) == "table" and not vim.tbl_isempty(item.meta) then
    table.insert(lines, "- **meta:**")
    table.insert(lines, "")
    table.insert(lines, "```json")
    vim.list_extend(lines, vim.split(vim.json.encode(item.meta), "\n", { plain = true }))
    table.insert(lines, "```")
  end
  return { lines = lines, ft = "markdown" }
end

---ISO 8601 timestamps are lexicographically sortable when normalised
---to the same precision; we only need a relative ordering here so a
---raw string compare on `updated_at` is enough. Sessions without
---`updated_at` sink to the bottom — the picker still shows them but
---doesn't pretend they're recent.
---@param a hyprpilot.palettes.sessions.Session
---@param b hyprpilot.palettes.sessions.Session
---@return boolean
local function by_updated_desc(a, b)
  local au, bu = a.updated_at, b.updated_at
  if au == nil and bu == nil then
    return false
  end
  if au == nil then
    return false
  end
  if bu == nil then
    return true
  end
  return au > bu
end

---@param opts? hyprpilot.palettes.sessions.Opts
function M.open(opts)
  opts = opts or {}

  -- `opts.cwd = false` is the explicit "no filter" opt-out; nil/absent
  -- defaults to vim's cwd. Resolved load-side cwd always falls back to
  -- vim.fn.getcwd() because `sessions/load` needs a non-nil cwd to
  -- spawn the loaded session.
  local cwd_filter, cwd_for_load
  if opts.cwd == false then
    cwd_filter = nil
    cwd_for_load = vim.fn.getcwd()
  elseif opts.cwd == nil then
    cwd_filter = vim.fn.getcwd()
    cwd_for_load = cwd_filter
  else
    cwd_filter = opts.cwd
    cwd_for_load = opts.cwd
  end

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
  if cwd_filter ~= nil then
    params.cwd = cwd_filter
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

    local items = vim.tbl_map(from_wire, raw)
    table.sort(items, by_updated_desc)

    pickers.open({
      items = items,
      title = "sessions",
      kind = "hyprpilot.sessions",
      picker = opts.picker,
      format_item = format_item,
      preview = format_preview,
      on_pick = function(choice)
        local load_params = {
          sessionId = choice.session_id,
          instanceId = opts.instance_id,
          agentId = opts.agent_id,
          profileId = opts.profile_id,
          cwd = choice.cwd or cwd_for_load,
        }
        require("hyprpilot.rpc.with-config").apply(load_params, opts.with_config)

        client.request("sessions/load", load_params, nil, function(load_err, load_result)
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
        end)
      end,
    })
  end)
end

M.format_item = format_item
M.format_preview = format_preview
M.from_wire = from_wire
M.by_updated_desc = by_updated_desc
M.short_timestamp = short_timestamp

return M
