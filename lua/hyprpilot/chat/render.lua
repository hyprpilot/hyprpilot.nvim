--- Chat-buffer renderer.
---
--- Per-instance state holds:
---   * the running text block (so streamed agent chunks append to the
---     same line)
---   * the monotonic `seq` cursor for snapshot pagination
---   * a registry of all rendered blocks keyed by block id, each with
---     head + tail extmarks so updates can locate the block and
---     replace its body without scanning the buffer
---   * tool-call → block-id and permission-request → block-id indexes
---     for routing live updates / resolutions
---
--- Block kinds: `turn_header`, `agent_text`, `agent_thought`,
--- `user_message`, `tool_call`, `plan`, `permission_request`,
--- `placeholder`. The folded kinds (tool_call / plan / agent_thought
--- / permission_request) carry a header line; the body lives between
--- the head + tail extmarks and gets exposed via `foldexpr`.

local chat_buffer = require("hyprpilot.chat.buffer")
local log = require("hyprpilot.log")

local M = {}

---@alias hyprpilot.render.BlockKind
---| "turn_header"
---| "agent_text"
---| "agent_thought"
---| "user_message"
---| "tool_call"
---| "plan"
---| "permission_request"
---| "placeholder"

---@class hyprpilot.render.Block
---@field id string
---@field kind hyprpilot.render.BlockKind
---@field turn_id? string
---@field head_mark integer  -- extmark id for the block's first line
---@field tail_mark integer  -- extmark id for the block's last line
---@field tool_call_id? string
---@field request_id? string
---@field button_row? integer  -- row offset inside the block where the button line lives
---@field option_count? integer
---@field focused_idx? integer

---@class hyprpilot.render.State
---@field bufnr integer
---@field instance_id string
---@field current_turn? string
---@field active_text_block? hyprpilot.render.Block
---@field last_seq? integer
---@field blocks table<string, hyprpilot.render.Block>
---@field tool_calls table<string, string>      -- daemon tool-call id → block id
---@field permissions table<string, string>     -- request id → block id

---@type table<string, hyprpilot.render.State>
M._states = {}

local NS = vim.api.nvim_create_namespace("hyprpilot.render")

---Get-or-create the per-instance render state.
---@param instance_id string
---@param bufnr integer
---@return hyprpilot.render.State
function M.state(instance_id, bufnr)
  local existing = M._states[instance_id]

  if existing ~= nil and existing.bufnr == bufnr then
    return existing
  end

  if existing ~= nil then
    log.debug("render.state: rebinding instance=%s from bufnr=%s to bufnr=%s", instance_id, existing.bufnr, bufnr)
  else
    log.debug("render.state: creating state for instance=%s bufnr=%s", instance_id, bufnr)
  end

  local state = {
    bufnr = bufnr,
    instance_id = instance_id,
    blocks = {},
    tool_calls = {},
    permissions = {},
  }

  M._states[instance_id] = state

  return state
end

---Drop the render state for an instance (used when the buffer is wiped).
---@param instance_id string
function M.forget(instance_id)
  if M._states[instance_id] == nil then
    return
  end

  log.debug("render.forget: instance=%s", instance_id)

  M._states[instance_id] = nil
end

---Append `lines` to the end of the buffer. Returns the line index of
---the first appended line.
---@param state hyprpilot.render.State
---@param lines string[]
---@return integer first_line
local function append_lines(state, lines)
  local bufnr = state.bufnr
  local total = vim.api.nvim_buf_line_count(bufnr)
  local first_line

  if total == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, lines)
    first_line = 0
  else
    vim.api.nvim_buf_set_lines(bufnr, total, total, false, lines)
    first_line = total
  end

  return first_line
end

---Track a fresh block by anchoring head/tail extmarks at `first_row`
---and `last_row`. `right_gravity` is set so subsequent inserts within
---the block grow the body, not push the markers around it.
---@param state hyprpilot.render.State
---@param block_id string
---@param kind hyprpilot.render.BlockKind
---@param first_row integer
---@param last_row integer
---@return hyprpilot.render.Block
local function track_block(state, block_id, kind, first_row, last_row)
  local head = vim.api.nvim_buf_set_extmark(state.bufnr, NS, first_row, 0, { right_gravity = true })
  local tail = vim.api.nvim_buf_set_extmark(state.bufnr, NS, last_row, 0, { right_gravity = true })

  local block = {
    id = block_id,
    kind = kind,
    turn_id = state.current_turn,
    head_mark = head,
    tail_mark = tail,
  }

  state.blocks[block_id] = block

  return block
end

---Resolve the `[head_row, tail_row]` line range for a block via its
---tracked extmarks.
---@param state hyprpilot.render.State
---@param block hyprpilot.render.Block
---@return integer head_row
---@return integer tail_row
local function block_range(state, block)
  local head = vim.api.nvim_buf_get_extmark_by_id(state.bufnr, NS, block.head_mark, {})
  local tail = vim.api.nvim_buf_get_extmark_by_id(state.bufnr, NS, block.tail_mark, {})

  return head[1], tail[1]
end

---Replace the body lines of a block (everything from `head_row + 1`
---through `tail_row`). Header line stays put. Re-anchors the tail
---extmark to the new last row.
---@param state hyprpilot.render.State
---@param block hyprpilot.render.Block
---@param body_lines string[]
local function replace_block_body(state, block, body_lines)
  chat_buffer.with_buffer(state.bufnr, function()
    local head_row, tail_row = block_range(state, block)
    vim.api.nvim_buf_set_lines(state.bufnr, head_row + 1, tail_row + 1, false, body_lines)

    local new_tail = head_row + #body_lines
    vim.api.nvim_buf_del_extmark(state.bufnr, NS, block.tail_mark)
    block.tail_mark = vim.api.nvim_buf_set_extmark(state.bufnr, NS, new_tail, 0, { right_gravity = true })
  end)
end

---Append a turn header (`## agent`, `## user`) and reset the active
---text block tracker.
---@param state hyprpilot.render.State
---@param role "agent" | "user"
---@param turn_id? string
local function append_turn_header(state, role, turn_id)
  chat_buffer.with_buffer(state.bufnr, function()
    local total = vim.api.nvim_buf_line_count(state.bufnr)
    local prepend_blank = not (total == 1 and vim.api.nvim_buf_get_lines(state.bufnr, 0, 1, false)[1] == "")

    local lines = prepend_blank and { "", "## " .. role, "" } or { "## " .. role, "" }
    append_lines(state, lines)
  end)

  state.active_text_block = nil

  if role == "agent" then
    state.current_turn = turn_id
  end
end

---Append `text` to the buffer's current `agent_text` block.
---@param state hyprpilot.render.State
---@param text string
local function append_agent_text(state, text)
  if text == "" then
    return
  end

  chat_buffer.with_buffer(state.bufnr, function()
    local bufnr = state.bufnr

    if state.active_text_block == nil then
      append_lines(state, vim.split(text, "\n", { plain = true }))

      state.active_text_block = { kind = "agent_text", turn_id = state.current_turn }

      return
    end

    local chunks = vim.split(text, "\n", { plain = true })
    local last_row = vim.api.nvim_buf_line_count(bufnr) - 1
    local last_line = vim.api.nvim_buf_get_lines(bufnr, last_row, last_row + 1, false)[1] or ""

    vim.api.nvim_buf_set_lines(bufnr, last_row, last_row + 1, false, { last_line .. chunks[1] })

    if #chunks > 1 then
      vim.api.nvim_buf_set_lines(bufnr, last_row + 1, last_row + 1, false, vim.list_slice(chunks, 2))
    end
  end)
end

---Append a labeled placeholder line for transcript variants we don't
---render structurally (agent attachments, unknown wire kinds).
---@param state hyprpilot.render.State
---@param label string
---@param detail? string
local function append_placeholder(state, label, detail)
  local body = detail ~= nil and ("[" .. label .. ": " .. detail .. "]") or ("[" .. label .. "]")

  chat_buffer.with_buffer(state.bufnr, function()
    append_lines(state, { body })
  end)

  state.active_text_block = nil
end

---Render the tool-call kind icon prefix.
---@param tool_kind? string
---@return string
local function tool_icon(tool_kind)
  if tool_kind == "execute" or tool_kind == "terminal" then
    return "$"
  elseif tool_kind == "edit" or tool_kind == "write" then
    return "~"
  elseif tool_kind == "read" or tool_kind == "fetch" then
    return "?"
  elseif tool_kind == "search" or tool_kind == "glob" then
    return "/"
  elseif tool_kind == "delete" then
    return "x"
  elseif tool_kind == "think" then
    return "*"
  end

  return "->"
end

---Status badge for tool-call state (`pending` / `running` /
---`completed` / `failed`).
---@param state_str? string
---@return string
local function tool_status_badge(state_str)
  if state_str == "completed" then
    return "[ok]"
  elseif state_str == "failed" then
    return "[fail]"
  elseif state_str == "pending" then
    return "[wait]"
  end

  return "[run]"
end

---Format a `Stat` entry from the `formatted.stats` array.
---@param stat table
---@return string?
local function format_stat(stat)
  if type(stat) ~= "table" or type(stat.kind) ~= "string" then
    return nil
  end

  if stat.kind == "text" then
    return tostring(stat.value or "")
  elseif stat.kind == "diff" then
    return string.format("+%d -%d", stat.added or 0, stat.removed or 0)
  elseif stat.kind == "duration" then
    local ms = tonumber(stat.ms) or 0
    if ms < 1000 then
      return string.format("%dms", ms)
    elseif ms < 60000 then
      return string.format("%.1fs", ms / 1000)
    end
    return string.format("%dm%ds", math.floor(ms / 60000), math.floor((ms % 60000) / 1000))
  end

  return nil
end

---Render the body lines for a tool-call block from its `formatted`
---spec. Always returns at least one line so the head/tail extmarks
---bracket distinct rows.
---@param formatted? table
---@return string[]
local function tool_body_lines(formatted)
  if type(formatted) ~= "table" then
    return { "  (no details)" }
  end

  local lines = {}

  if type(formatted.fields) == "table" then
    for _, field in ipairs(formatted.fields) do
      if type(field) == "table" and field.label and field.value then
        local value = tostring(field.value):gsub("\n", " ")
        table.insert(lines, string.format("  %s: %s", field.label, value))
      end
    end
  end

  if type(formatted.description) == "string" and formatted.description ~= "" then
    if #lines > 0 then
      table.insert(lines, "")
    end
    for _, l in ipairs(vim.split(formatted.description, "\n", { plain = true })) do
      table.insert(lines, "  " .. l)
    end
  end

  if type(formatted.output) == "string" and formatted.output ~= "" then
    if #lines > 0 then
      table.insert(lines, "")
    end
    for _, l in ipairs(vim.split(formatted.output, "\n", { plain = true })) do
      table.insert(lines, "  " .. l)
    end
  end

  if #lines == 0 then
    return { "  (no details)" }
  end

  return lines
end

---Compose the header line for a tool-call block.
---@param record table
---@return string
local function tool_header_line(record)
  local title = (record.formatted and record.formatted.title) or record.title or record.toolKind or "tool"
  local badge = tool_status_badge(record.state)
  local icon = tool_icon(record.toolKind)
  local stats_parts = {}

  if record.formatted and type(record.formatted.stats) == "table" then
    for _, stat in ipairs(record.formatted.stats) do
      local s = format_stat(stat)
      if s ~= nil then
        table.insert(stats_parts, s)
      end
    end
  end

  local stats = #stats_parts > 0 and (" · " .. table.concat(stats_parts, " ")) or ""

  return string.format("%s %s %s%s", icon, badge, title, stats)
end

---Render a tool-call block (initial). Body holds description + fields
---+ output, scoped under the head/tail extmarks for later updates.
---@param state hyprpilot.render.State
---@param record table
local function render_tool_call(state, record)
  if type(record.id) ~= "string" then
    log.warn("render.tool_call: missing id, dropping")
    return
  end

  local existing_block_id = state.tool_calls[record.id]
  if existing_block_id ~= nil and state.blocks[existing_block_id] ~= nil then
    log.debug("render.tool_call: re-rendering existing tool_call id=%s as update", record.id)
    return M.handle_tool_call_update(state.instance_id, record)
  end

  state.active_text_block = nil

  local header = tool_header_line(record)
  local body = tool_body_lines(record.formatted)
  local first_row

  chat_buffer.with_buffer(state.bufnr, function()
    first_row = append_lines(state, vim.list_extend({ header }, body))
  end)

  local block = track_block(state, record.id, "tool_call", first_row, first_row + #body)
  block.tool_call_id = record.id
  state.tool_calls[record.id] = block.id
end

---Apply a tool_call_update: re-render the header line and replace the
---body in place. The caller's payload merges with the prior record's
---fields where possible (the daemon already does that for `formatted`).
---@param instance_id string
---@param update table
function M.handle_tool_call_update(instance_id, update)
  local state = M._states[instance_id]
  if state == nil then
    log.debug("render.tool_call_update: no state for instance=%s", tostring(instance_id))
    return
  end

  if type(update.id) ~= "string" then
    log.warn("render.tool_call_update: missing id, dropping")
    return
  end

  local block_id = state.tool_calls[update.id]
  local block = block_id ~= nil and state.blocks[block_id] or nil

  if block == nil then
    log.debug("render.tool_call_update: no prior tool_call for id=%s — rendering as fresh", update.id)
    return render_tool_call(state, update)
  end

  chat_buffer.with_buffer(state.bufnr, function()
    local head_row = block_range(state, block)
    local existing = vim.api.nvim_buf_get_lines(state.bufnr, head_row, head_row + 1, false)[1] or ""
    vim.api.nvim_buf_set_text(state.bufnr, head_row, 0, head_row, #existing, { tool_header_line(update) })
  end)

  replace_block_body(state, block, tool_body_lines(update.formatted))
end

---Render an agent thought block — header + folded body so the chat
---transcript stays compact. Falls back to a placeholder for empty
---thoughts.
---@param state hyprpilot.render.State
---@param text string
local function render_thought(state, text)
  state.active_text_block = nil

  if text == "" then
    chat_buffer.with_buffer(state.bufnr, function()
      append_lines(state, { "* (empty thought)" })
    end)
    return
  end

  local body = {}
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(body, "  " .. l)
  end

  local first_row
  chat_buffer.with_buffer(state.bufnr, function()
    first_row = append_lines(state, vim.list_extend({ "* thought" }, body))
  end)

  local block_id = "thought:" .. tostring(first_row)
  track_block(state, block_id, "agent_thought", first_row, first_row + #body)
end

---Render a plan block — checklist of steps with priority annotations.
---@param state hyprpilot.render.State
---@param record table
local function render_plan(state, record)
  state.active_text_block = nil

  local steps = type(record.steps) == "table" and record.steps or {}
  local done = 0
  for _, step in ipairs(steps) do
    if type(step) == "table" and step.status == "completed" then
      done = done + 1
    end
  end

  local header = string.format("# plan · %d/%d done", done, #steps)
  local body = {}

  if #steps == 0 then
    table.insert(body, "  (no steps)")
  else
    for _, step in ipairs(steps) do
      local mark
      if step.status == "completed" then
        mark = "[x]"
      elseif step.status == "in_progress" then
        mark = "[~]"
      else
        mark = "[ ]"
      end
      local priority = step.priority and (" (" .. step.priority .. ")") or ""
      local content = type(step.content) == "string" and step.content or ""
      table.insert(body, string.format("  %s %s%s", mark, content:gsub("\n", " "), priority))
    end
  end

  local first_row
  chat_buffer.with_buffer(state.bufnr, function()
    first_row = append_lines(state, vim.list_extend({ header }, body))
  end)

  local block_id = "plan:" .. tostring(first_row)
  track_block(state, block_id, "plan", first_row, first_row + #body)
end

---Compose the button line shown at the bottom of a permission block.
---@param options table[]
---@param focused_idx integer
---@return string
local function permission_button_line(options, focused_idx)
  local parts = {}
  for i, opt in ipairs(options) do
    local label = tostring(opt.name or opt.optionId or "?")
    local cell
    if i == focused_idx then
      cell = "[> " .. label .. " <]"
    else
      cell = "[ " .. label .. " ]"
    end
    table.insert(parts, cell)
  end
  return "  " .. table.concat(parts, "  ")
end

---Render a permission_request block (header + tool details + button
---line). Registers the block in `state.permissions` so live
---`permission_resolved` events can dim the row.
---@param state hyprpilot.render.State
---@param record table
local function render_permission_request(state, record)
  if type(record.requestId) ~= "string" then
    log.warn("render.permission_request: missing requestId, dropping")
    return
  end

  local existing_id = state.permissions[record.requestId]
  if existing_id ~= nil and state.blocks[existing_id] ~= nil then
    log.debug("render.permission_request: requestId=%s already rendered", record.requestId)
    return
  end

  state.active_text_block = nil

  local header = string.format("? permission · %s", record.tool or record.toolKind or "tool")
  local body = tool_body_lines(record.formatted)
  local options = type(record.options) == "table" and record.options or {}
  local button_line = permission_button_line(options, 1)

  local lines = vim.list_extend({ header }, body)
  table.insert(lines, "")
  table.insert(lines, button_line)

  local first_row
  chat_buffer.with_buffer(state.bufnr, function()
    first_row = append_lines(state, lines)
  end)

  local block = track_block(state, "perm:" .. record.requestId, "permission_request", first_row, first_row + #lines - 1)
  block.request_id = record.requestId
  block.button_row = #lines - 1
  block.option_count = #options
  block.focused_idx = 1

  state.permissions[record.requestId] = block.id

  require("hyprpilot.ui.permissions").register(state.bufnr, block, options)
end

---Re-render the button line of a permission block (focus change or
---resolution). When `resolved_label` is non-nil the buttons are
---replaced with a dim "resolved: <label>" marker.
---@param state hyprpilot.render.State
---@param block hyprpilot.render.Block
---@param options? table[]
---@param focused_idx? integer
---@param resolved_label? string
function M.update_permission_buttons(state, block, options, focused_idx, resolved_label)
  local _, button_row = block_range(state, block)
  local new_line

  if resolved_label ~= nil then
    new_line = "  (resolved: " .. resolved_label .. ")"
  else
    new_line = permission_button_line(options or {}, focused_idx or block.focused_idx or 1)
    block.focused_idx = focused_idx or block.focused_idx
  end

  chat_buffer.with_buffer(state.bufnr, function()
    local existing = vim.api.nvim_buf_get_lines(state.bufnr, button_row, button_row + 1, false)[1] or ""
    vim.api.nvim_buf_set_text(state.bufnr, button_row, 0, button_row, #existing, { new_line })
  end)
end

---Drop a permission block from the registry once resolved. The
---block stays in the buffer (with the dimmed marker) for history.
---@param state hyprpilot.render.State
---@param request_id string
---@param resolved_label? string
function M.mark_permission_resolved(state, request_id, resolved_label)
  local block_id = state.permissions[request_id]
  local block = block_id ~= nil and state.blocks[block_id] or nil

  if block == nil then
    log.debug("render.mark_permission_resolved: no block for requestId=%s", request_id)
    return
  end

  M.update_permission_buttons(state, block, nil, nil, resolved_label or "ok")
  state.permissions[request_id] = nil

  require("hyprpilot.ui.permissions").unregister(state.bufnr, request_id)
end

---Render one transcript item (from snapshot or live transcript event).
---@param state hyprpilot.render.State
---@param turn_id? string
---@param item table
function M.render_item(state, turn_id, item)
  if type(item) ~= "table" or type(item.kind) ~= "string" then
    log.warn("render: dropping malformed item: %s", vim.inspect(item))
    return
  end

  if turn_id ~= nil and turn_id ~= state.current_turn then
    append_turn_header(state, "agent", turn_id)
  end

  local kind = item.kind

  if kind == "user_prompt" or kind == "user_text" then
    append_turn_header(state, "user")

    chat_buffer.with_buffer(state.bufnr, function()
      append_lines(state, vim.split(item.text or "", "\n", { plain = true }))
    end)
  elseif kind == "agent_text" then
    append_agent_text(state, item.text or "")
  elseif kind == "agent_thought" then
    render_thought(state, item.text or "")
  elseif kind == "tool_call" then
    render_tool_call(state, item)
  elseif kind == "tool_call_update" then
    M.handle_tool_call_update(state.instance_id, item)
  elseif kind == "plan" then
    render_plan(state, item)
  elseif kind == "permission_request" then
    render_permission_request(state, item)
  elseif kind == "agent_attachment" then
    append_placeholder(state, "attachment")
  elseif kind == "unknown" then
    log.warn("render.render_item: daemon emitted unknown wire kind=%s", tostring(item.wireKind))
    append_placeholder(state, "unknown", item.wireKind)
  else
    log.warn("render.render_item: unhandled transcript kind=%s for instance=%s", kind, state.instance_id)
    append_placeholder(state, "unhandled", kind)
  end
end

---Replay every item from a snapshot (`instance/snapshot/chat`).
---Wipes the buffer contents first so re-shows are clean.
---@param state hyprpilot.render.State
---@param snapshot { items: table[], oldestSeq?: integer, latestSeq?: integer, hasMore?: boolean }
function M.hydrate(state, snapshot)
  local items = snapshot.items or {}

  log.debug("render.hydrate: instance=%s items=%d latestSeq=%s hasMore=%s", state.instance_id, #items, tostring(snapshot.latestSeq), tostring(snapshot.hasMore))

  chat_buffer.with_buffer(state.bufnr, function()
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
    vim.api.nvim_buf_clear_namespace(state.bufnr, NS, 0, -1)
  end)

  state.current_turn = nil
  state.active_text_block = nil
  state.last_seq = snapshot.latestSeq
  state.blocks = {}
  state.tool_calls = {}
  state.permissions = {}

  require("hyprpilot.ui.permissions").reset(state.bufnr)

  for _, entry in ipairs(items) do
    M.render_item(state, entry.turnId, entry.item)
  end
end

---Live `transcript` event handler.
---@param event table
function M.handle_transcript(event)
  local state = M._states[event.instanceId]

  if state == nil then
    log.debug("render.handle_transcript: no state for instance=%s — dropping event", tostring(event.instanceId))
    return
  end

  M.render_item(state, event.turnId, event.item)
end

---Live `permission_request` event — renders inline + registers the
---button-group keymaps on the buffer.
---@param event table
function M.handle_permission_request(event)
  local state = M._states[event.instanceId]

  if state == nil then
    log.debug("render.handle_permission_request: no state for instance=%s", tostring(event.instanceId))
    return
  end

  local record = {
    requestId = event.requestId,
    tool = event.tool,
    toolKind = event.kind,
    args = event.args,
    options = event.options,
    formatted = event.formatted,
  }

  render_permission_request(state, record)
end

---Live `permission_resolved` event — dim the matching block.
---@param event table
function M.handle_permission_resolved(event)
  local state = M._states[event.instanceId]

  if state == nil then
    log.debug("render.handle_permission_resolved: no state for instance=%s", tostring(event.instanceId))
    return
  end

  if type(event.requestId) ~= "string" then
    log.warn("render.handle_permission_resolved: missing requestId")
    return
  end

  M.mark_permission_resolved(state, event.requestId, event.optionId)
end

---Live `turn_started` event handler.
---@param event table
function M.handle_turn_started(event)
  local state = M._states[event.instanceId]

  if state == nil then
    log.debug("render.handle_turn_started: no state for instance=%s", tostring(event.instanceId))
    return
  end

  log.debug("render.handle_turn_started: instance=%s turnId=%s", event.instanceId, event.turnId)

  append_turn_header(state, "agent", event.turnId)
end

---Live `turn_ended` event handler.
---@param event table
function M.handle_turn_ended(event)
  local state = M._states[event.instanceId]

  if state == nil then
    log.debug("render.handle_turn_ended: no state for instance=%s", tostring(event.instanceId))
    return
  end

  log.debug("render.handle_turn_ended: instance=%s turnId=%s stopReason=%s error=%s", event.instanceId, event.turnId, tostring(event.stopReason), tostring(event.error))

  state.active_text_block = nil

  if state.current_turn == event.turnId then
    state.current_turn = nil
  end

  local chip
  if event.error ~= nil then
    chip = "x " .. event.error
  elseif event.stopReason ~= nil then
    chip = "ok " .. event.stopReason
  end

  if chip == nil then
    return
  end

  local bufnr = state.bufnr
  local total = vim.api.nvim_buf_line_count(bufnr)
  local row = math.max(0, total - 1)

  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
    virt_text = { { " " .. chip, "Comment" } },
    virt_text_pos = "eol",
  })
end

---Compute fold level for `lnum` in the chat buffer the function is
---called from. Used as `foldexpr` on chat windows so block bodies
---collapse under their headers automatically.
---@param lnum integer
---@return string
function M.foldexpr(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  local state

  for _, candidate in pairs(M._states) do
    if candidate.bufnr == bufnr then
      state = candidate
      break
    end
  end

  if state == nil then
    return "0"
  end

  local row = lnum - 1

  for _, block in pairs(state.blocks) do
    if block.kind == "tool_call" or block.kind == "plan" or block.kind == "agent_thought" or block.kind == "permission_request" then
      local head_row, tail_row = block_range(state, block)

      if row == head_row then
        return ">1"
      elseif row > head_row and row <= tail_row then
        return "1"
      end
    end
  end

  return "0"
end

---Lookup the block registered for `bufnr` whose head row matches the
---cursor row (or whose body covers it). Used by the permissions UI to
---route keymaps.
---@param bufnr integer
---@param row integer  -- 0-indexed
---@return hyprpilot.render.Block?
function M.block_at_row(bufnr, row)
  for _, state in pairs(M._states) do
    if state.bufnr == bufnr then
      for _, block in pairs(state.blocks) do
        local head_row, tail_row = block_range(state, block)
        if row >= head_row and row <= tail_row then
          return block
        end
      end
    end
  end

  return nil
end

---State lookup by buffer (for permission UI keymaps).
---@param bufnr integer
---@return hyprpilot.render.State?
function M.state_for_bufnr(bufnr)
  for _, state in pairs(M._states) do
    if state.bufnr == bufnr then
      return state
    end
  end

  return nil
end

return M
