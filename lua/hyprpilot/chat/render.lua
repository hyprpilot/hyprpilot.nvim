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
---@field terminals table<string, hyprpilot.render.TerminalState>  -- terminal id → state
---@field headers_emitted table<string, table<string, boolean>>  -- turn_id → { user?, agent? } so each (turn, role) header drops at most once
---@field pending_fold_rows integer[]           -- 0-indexed rows whose fold should close on next window-show
---@field oldest_seq? integer                   -- snapshot's oldestSeq cursor; nil when transcript is empty
---@field has_more boolean                      -- true when the daemon reported more items beyond what we fetched
---@field snapshot_limit integer                -- current snapshot page size (grows on load_older)

---@class hyprpilot.render.TerminalState
---@field block_id string
---@field output string  -- accumulated stdout/stderr
---@field exit_code? integer
---@field signal? string

---@type table<string, hyprpilot.render.State>
M._states = {}

local NS = vim.api.nvim_create_namespace("hyprpilot.render")
-- Highlights live in a sibling namespace so a `clear_namespace` for a
-- block's range can wipe `line_hl_group` extmarks without disturbing
-- the block's head/tail tracking marks (which live in `NS`).
local HL_NS = vim.api.nvim_create_namespace("hyprpilot.render.hl")

-- Forward-declared helpers (definitions live further down so the
-- handler block above can stay close to the high-level logic).
-- Without these declarations Lua resolves the names as nil-valued
-- locals at parse time, since each `local` only enters scope after
-- the line it's declared on.
local close_fold_at
local fold_block

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
    terminals = {},
    headers_emitted = {},
    pending_fold_rows = {},
    has_more = false,
    snapshot_limit = 100,
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

---Run `fn` (a buffer mutation) while preserving autoscroll semantics:
---every window showing `state.bufnr` whose cursor was parked on the
---last line before `fn` ran gets re-parked on the new last line
---after, so the captain stays glued to the stream when she's already
---at the bottom. Windows scrolled away keep their cursor where it is.
---@param state hyprpilot.render.State
---@param fn fun(): nil
local function with_autoscroll(state, fn)
  local bufnr = state.bufnr
  local pre_total = vim.api.nvim_buf_line_count(bufnr)
  local sticky = {}

  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      local cursor = vim.api.nvim_win_get_cursor(winid)
      if cursor[1] >= pre_total then
        table.insert(sticky, winid)
      end
    end
  end

  fn()

  if #sticky == 0 then
    return
  end

  local post_total = vim.api.nvim_buf_line_count(bufnr)
  for _, winid in ipairs(sticky) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      pcall(vim.api.nvim_win_set_cursor, winid, { post_total, 0 })
    end
  end
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

---Tag `row` with `hl_group` via a `line_hl_group` extmark in HL_NS.
---No-op when `hl_group` is nil.
---@param state hyprpilot.render.State
---@param row integer
---@param hl_group? string
local function apply_line_hl(state, row, hl_group)
  if hl_group == nil then
    return
  end
  vim.api.nvim_buf_set_extmark(state.bufnr, HL_NS, row, 0, { line_hl_group = hl_group })
end

---Clear every HL_NS extmark from `start_row` through `end_row`
---(inclusive). Used before re-applying highlights after content
---changes (tool_call_update, permission button repaint).
---@param state hyprpilot.render.State
---@param start_row integer
---@param end_row integer
local function clear_range_hl(state, start_row, end_row)
  vim.api.nvim_buf_clear_namespace(state.bufnr, HL_NS, start_row, end_row + 1)
end

---Resolve the highlight group for a tool-call header row by state.
---@param tool_state? string
---@return string
local function tool_status_hl(tool_state)
  if tool_state == "completed" then
    return "HyprpilotToolStatusOk"
  elseif tool_state == "failed" then
    return "HyprpilotToolStatusFail"
  elseif tool_state == "pending" then
    return "HyprpilotToolStatusPending"
  end
  return "HyprpilotToolStatusRunning"
end

---Resolve the highlight group for a plan-step row by status.
---@param step_status? string
---@return string
local function plan_step_hl(step_status)
  if step_status == "completed" then
    return "HyprpilotPlanStepDone"
  elseif step_status == "in_progress" then
    return "HyprpilotPlanStepInProgress"
  end
  return "HyprpilotPlanStepPending"
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

---Append a turn header (`## pilot`, `## captain`) and reset the
---active text block tracker. Idempotent per (turn_id, role): the
---daemon's broadcast order for transcript / turn_started events is
---not guaranteed (user_prompt and turn_started can arrive in either
---order), so each role-per-turn must drop one header at most no
---matter how many times the renderer asks for it. `role` is the
---internal discriminator (`"agent"` / `"user"`); the rendered label
---is `pilot` / `captain` to match the daemon-side voice.
---@param state hyprpilot.render.State
---@param role "agent" | "user"
---@param turn_id? string
local function append_turn_header(state, role, turn_id)
  -- Idempotency key: turn_id (or "" for spontaneous items without a
  -- turn). One slot per role per turn.
  local key = turn_id or ""
  local emitted = state.headers_emitted[key]
  if emitted == nil then
    emitted = {}
    state.headers_emitted[key] = emitted
  end

  if emitted[role] then
    return
  end
  emitted[role] = true

  local label = role == "agent" and "pilot" or "captain"

  chat_buffer.with_buffer(state.bufnr, function()
    local total = vim.api.nvim_buf_line_count(state.bufnr)
    local prepend_blank = not (total == 1 and vim.api.nvim_buf_get_lines(state.bufnr, 0, 1, false)[1] == "")

    local lines = prepend_blank and { "", "## " .. label, "" } or { "## " .. label, "" }
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

---Render an `agent_attachment` transcript item as a single line:
---`@ <title or slug> · <mime> · <path>` with the body lines available
---only by clicking through to the file. We don't inline image / audio
---content; the agent attached it for reference, not display.
---@param state hyprpilot.render.State
---@param attachment table
local function render_attachment(state, attachment)
  state.active_text_block = nil

  local label = tostring(attachment.title or attachment.slug or "attachment")
  local mime = attachment.mime
  local path = attachment.path
  local parts = { "@ " .. label }
  if mime ~= nil and mime ~= "" then
    table.insert(parts, tostring(mime))
  end
  if path ~= nil and path ~= "" then
    table.insert(parts, tostring(path))
  end

  local line = table.concat(parts, " · ")
  local first_row

  chat_buffer.with_buffer(state.bufnr, function()
    first_row = append_lines(state, { line })
  end)

  apply_line_hl(state, first_row, "HyprpilotToolBody")
end

---Append a labeled placeholder line for transcript variants we don't
---render structurally (unknown wire kinds, unhandled future shapes).
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

---Heuristic: pick a fenced-code language hint for a tool's output
---based on its kind. Terminals dump shell output (`console`); read /
---fetch / write / edit fall back to plain text (no language).
---@param tool_kind? string
---@return string
local function tool_output_lang(tool_kind)
  if tool_kind == "execute" or tool_kind == "terminal" then
    return "console"
  end
  return ""
end

---Heuristic: pick a fenced-code language for a tool's *input* fields
---(e.g. the command line). Mirrors `tool_output_lang` but for shell.
---@param tool_kind? string
---@return string
local function tool_input_lang(tool_kind)
  if tool_kind == "execute" or tool_kind == "terminal" then
    return "bash"
  end
  return ""
end

---Render the body lines for a tool-call block from its `formatted`
---spec. Wraps content in `---` separators + uses fenced code blocks
---so the chat buffer's markdown highlighter (registered for
---`filetype = "hyprpilot"` in `plugin/hyprpilot.lua`) takes over —
---no `line_hl_group` dimming. Fields render as `<label>: <value>`
---lines; description renders plain; output renders as a fenced
---code block (language inferred from `tool_kind`). Always returns
---at least one line so the head/tail extmarks bracket distinct rows.
---@param formatted? table
---@param tool_kind? string
---@return string[]
local function tool_body_lines(formatted, tool_kind)
  if type(formatted) ~= "table" then
    return { "---", "(no details)", "---" }
  end

  local lines = { "---" }
  local input_lang = tool_input_lang(tool_kind)

  if type(formatted.fields) == "table" then
    -- Single-field, single-line, command-shaped — render as a fenced
    -- input block so the captain sees the actual command, not
    -- `command: ls -la`. Multi-field renders as a plain key: value list.
    local field_count = 0
    local single_field
    for _, field in ipairs(formatted.fields) do
      if type(field) == "table" and field.label and field.value then
        field_count = field_count + 1
        single_field = field
      end
    end

    if field_count == 1 and input_lang ~= "" and not tostring(single_field.value):find("\n", 1, true) then
      table.insert(lines, "```" .. input_lang)
      table.insert(lines, tostring(single_field.value))
      table.insert(lines, "```")
    else
      for _, field in ipairs(formatted.fields) do
        if type(field) == "table" and field.label and field.value then
          local value = tostring(field.value):gsub("\n", " ")
          table.insert(lines, string.format("%s: %s", field.label, value))
        end
      end
    end
  end

  if type(formatted.description) == "string" and formatted.description ~= "" then
    if #lines > 1 then
      table.insert(lines, "")
    end
    for _, l in ipairs(vim.split(formatted.description, "\n", { plain = true })) do
      table.insert(lines, l)
    end
  end

  if type(formatted.output) == "string" and formatted.output ~= "" then
    if #lines > 1 then
      table.insert(lines, "")
    end
    local output_lang = tool_output_lang(tool_kind)
    table.insert(lines, "```" .. output_lang)
    for _, l in ipairs(vim.split(formatted.output, "\n", { plain = true })) do
      table.insert(lines, l)
    end
    table.insert(lines, "```")
  end

  if #lines == 1 then
    table.insert(lines, "(no details)")
  end

  table.insert(lines, "---")

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
  local body = tool_body_lines(record.formatted, record.toolKind)
  local first_row

  chat_buffer.with_buffer(state.bufnr, function()
    first_row = append_lines(state, vim.list_extend({ header }, body))
  end)

  local block = track_block(state, record.id, "tool_call", first_row, first_row + #body)
  block.tool_call_id = record.id
  state.tool_calls[record.id] = block.id

  -- Header gets a status colour; body intentionally has no
  -- `line_hl_group` so the chat buffer's markdown highlighter takes
  -- over (fenced code blocks ` ``` ` get treesitter highlight).
  apply_line_hl(state, first_row, tool_status_hl(record.state))

  if record.state == "completed" or record.state == "failed" then
    fold_block(state, block)
  end
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
    return with_autoscroll(state, function()
      render_tool_call(state, update)
    end)
  end

  with_autoscroll(state, function()
    chat_buffer.with_buffer(state.bufnr, function()
      local head_row = block_range(state, block)
      local existing = vim.api.nvim_buf_get_lines(state.bufnr, head_row, head_row + 1, false)[1] or ""
      vim.api.nvim_buf_set_text(state.bufnr, head_row, 0, head_row, #existing, { tool_header_line(update) })
    end)

    replace_block_body(state, block, tool_body_lines(update.formatted, update.toolKind))

    -- Re-apply highlights: header colour can flip with the new state;
    -- body has no line_hl_group (markdown highlighter handles it).
    local head_row, tail_row = block_range(state, block)
    clear_range_hl(state, head_row, tail_row)
    apply_line_hl(state, head_row, tool_status_hl(update.state))
    local _ = tail_row

    if update.state == "completed" or update.state == "failed" then
      fold_block(state, block)
    end
  end)
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

  local body = { "---" }
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(body, l)
  end
  table.insert(body, "---")

  local first_row
  chat_buffer.with_buffer(state.bufnr, function()
    first_row = append_lines(state, vim.list_extend({ "* thought" }, body))
  end)

  local block_id = "thought:" .. tostring(first_row)
  track_block(state, block_id, "agent_thought", first_row, first_row + #body)

  -- Header gets the conceal-style highlight; body lines stay plain so
  -- the markdown highlighter handles them (matches tool / terminal).
  apply_line_hl(state, first_row, "HyprpilotThoughtHeader")
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

  apply_line_hl(state, first_row, "HyprpilotPlanHeader")
  for i, step in ipairs(steps) do
    apply_line_hl(state, first_row + i, plan_step_hl(step.status))
  end
end

---Pick the "default" option index for a fresh permission prompt.
---Captain wants Allow / Accept / Proceed pre-focused so a bare `<CR>`
---is the safe-path; falls back to the first option when the prompt
---doesn't include an allow-shaped option.
---@param options table[]
---@return integer
local function default_focused_idx(options)
  for i, opt in ipairs(options) do
    local id = string.lower(tostring(opt.optionId or ""))
    local name = string.lower(tostring(opt.name or ""))
    if id:match("^allow") or id:match("^accept") or id:match("^proceed") or name:match("^allow") or name:match("^accept") or name:match("^proceed") then
      return i
    end
  end
  return 1
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
  local body = tool_body_lines(record.formatted, record.toolKind)
  local options = type(record.options) == "table" and record.options or {}
  local default_idx = default_focused_idx(options)
  local button_line = permission_button_line(options, default_idx)

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
  block.focused_idx = default_idx

  state.permissions[record.requestId] = block.id

  apply_line_hl(state, first_row, "HyprpilotPermissionHeader")
  apply_line_hl(state, first_row + #lines - 1, "HyprpilotPermissionButton")

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

  clear_range_hl(state, button_row, button_row)
  apply_line_hl(state, button_row, resolved_label ~= nil and "HyprpilotPermissionResolved" or "HyprpilotPermissionButton")
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

  fold_block(state, block)
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

  local kind = item.kind
  local is_user_kind = kind == "user_prompt" or kind == "user_text"

  -- Lazy headers — `append_turn_header` is idempotent per (turn_id,
  -- role), so the daemon's broadcast order between user_prompt and
  -- turn_started doesn't matter. Whichever side arrives first lands
  -- its header; the other side's header lands on its first item.
  if turn_id ~= nil and not is_user_kind then
    append_turn_header(state, "agent", turn_id)
  end

  if is_user_kind then
    append_turn_header(state, "user", turn_id)

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
    render_attachment(state, item)
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
    vim.api.nvim_buf_clear_namespace(state.bufnr, HL_NS, 0, -1)
  end)

  state.current_turn = nil
  state.active_text_block = nil
  state.last_seq = snapshot.latestSeq
  state.oldest_seq = snapshot.oldestSeq
  state.has_more = snapshot.hasMore == true
  state.blocks = {}
  state.tool_calls = {}
  state.permissions = {}
  state.terminals = {}
  state.headers_emitted = {}
  state.pending_fold_rows = {}

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

  with_autoscroll(state, function()
    M.render_item(state, event.turnId, event.item)
  end)
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

  with_autoscroll(state, function()
    render_permission_request(state, {
      requestId = event.requestId,
      tool = event.tool,
      toolKind = event.kind,
      args = event.args,
      options = event.options,
      formatted = event.formatted,
    })
  end)
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

---Live `turn_started` event handler. Status / activity bookkeeping
---is the events module's job; rendering-side, the `## agent` header
---is added lazily by `render_item` on the first agent-side item, so
---this handler doesn't need to write anything to the buffer.
---@param event table
function M.handle_turn_started(event)
  local state = M._states[event.instanceId]

  if state == nil then
    log.debug("render.handle_turn_started: no state for instance=%s", tostring(event.instanceId))
    return
  end

  log.debug("render.handle_turn_started: instance=%s turnId=%s", event.instanceId, event.turnId)
end

---Live `turn_ended` event handler. Stamps a stop-reason chip on the
---last line of the turn and folds the *inner* blocks (plans /
---thoughts) belonging to that turn so the chat tightens up after the
---agent finishes. The turn itself is NOT folded — the captain still
---wants the conversation flow visible top-to-bottom; only the
---expandable inner blocks collapse.
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
  local chip_hl
  if event.error ~= nil then
    chip = "x " .. event.error
    chip_hl = "HyprpilotTurnEndError"
  elseif event.stopReason ~= nil then
    local reason = tostring(event.stopReason)
    if reason:lower():find("cancel", 1, true) ~= nil then
      chip = "[cancelled] " .. reason
      chip_hl = "HyprpilotTurnEndCancelled"
    else
      chip = "ok " .. reason
      chip_hl = "HyprpilotTurnEndOk"
    end
  end

  if chip ~= nil then
    local bufnr = state.bufnr
    local total = vim.api.nvim_buf_line_count(bufnr)
    local row = math.max(0, total - 1)

    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
      virt_text = { { " " .. chip, chip_hl } },
      virt_text_pos = "eol",
    })
  end

  -- Fold plans / thoughts belonging to this turn. Tool calls and
  -- terminal blocks fold themselves on completion / exit; permission
  -- blocks fold on resolution. Plans + thoughts have no per-block
  -- terminal signal, so the turn boundary is the natural collapse
  -- point.
  for _, block in pairs(state.blocks) do
    if block.turn_id == event.turnId and (block.kind == "plan" or block.kind == "agent_thought") then
      fold_block(state, block)
    end
  end
end

---Format the header for a terminal block.
---@param terminal_id string
---@param exit_code? integer
---@param signal? string
---@return string
local function terminal_header_line(terminal_id, exit_code, signal)
  local short = terminal_id
  if #short > 8 then
    short = short:sub(1, 8) .. "…"
  end

  local status_str
  if signal ~= nil then
    status_str = "signal=" .. tostring(signal)
  elseif exit_code ~= nil then
    status_str = "exit=" .. tostring(exit_code)
  else
    status_str = "running"
  end

  return string.format("$ terminal · %s · %s", short, status_str)
end

---Live `terminal` event. Each `terminal_id` gets one tracked block;
---chunks accumulate into `state.terminals[id].output` and the body is
---re-rendered from the running buffer. `Exit` chunks freeze the
---header with the exit/signal status and fold the block.
---@param event table
function M.handle_terminal(event)
  local state = M._states[event.instanceId]
  if state == nil then
    log.debug("render.handle_terminal: no state for instance=%s", tostring(event.instanceId))
    return
  end

  local terminal_id = event.terminalId
  if type(terminal_id) ~= "string" then
    log.warn("render.handle_terminal: missing terminalId, dropping")
    return
  end

  local chunk = event.chunk
  if type(chunk) ~= "table" or type(chunk.kind) ~= "string" then
    log.warn("render.handle_terminal: malformed chunk, dropping")
    return
  end

  with_autoscroll(state, function()
    M._render_terminal_chunk(state, terminal_id, chunk)
  end)
end

---Internal: actually mutate the buffer for a terminal chunk. Split out
---of `handle_terminal` so the `with_autoscroll` wrap can capture the
---pre-mutation cursor state once around the whole block.
---@param state hyprpilot.render.State
---@param terminal_id string
---@param chunk table
function M._render_terminal_chunk(state, terminal_id, chunk)
  local term = state.terminals[terminal_id]

  -- Bootstrap the block on first observation.
  if term == nil then
    state.active_text_block = nil

    local block_id = "term:" .. terminal_id
    local header = terminal_header_line(terminal_id, nil, nil)
    local first_row

    chat_buffer.with_buffer(state.bufnr, function()
      first_row = append_lines(state, { header, "---", "(no output yet)", "---" })
    end)

    local block = track_block(state, block_id, "tool_call", first_row, first_row + 3)
    apply_line_hl(state, first_row, "HyprpilotToolStatusRunning")

    term = { block_id = block_id, output = "" }
    state.terminals[terminal_id] = term
    -- Stash a back-pointer so the merge path below can find the block.
    term._block = block
  end

  if chunk.kind == "output" then
    if type(chunk.data) == "string" and chunk.data ~= "" then
      term.output = term.output .. chunk.data
    end
  elseif chunk.kind == "exit" then
    term.exit_code = chunk.exitCode
    term.signal = chunk.signal
  end

  local body = { "---" }
  if term.output == "" then
    table.insert(body, "(no output yet)")
  else
    table.insert(body, "```console")
    for _, l in ipairs(vim.split(term.output, "\n", { plain = true })) do
      table.insert(body, l)
    end
    table.insert(body, "```")
  end
  table.insert(body, "---")

  replace_block_body(state, term._block, body)
  local head_row, tail_row = block_range(state, term._block)

  -- Re-apply highlights: only the header gets a status colour; body
  -- relies on markdown treesitter for its fenced code block highlight.
  clear_range_hl(state, head_row, tail_row)
  local header_hl = chunk.kind == "exit" and (term.exit_code == 0 and "HyprpilotToolStatusOk" or "HyprpilotToolStatusFail") or "HyprpilotToolStatusRunning"
  apply_line_hl(state, head_row, header_hl)
  local _ = tail_row

  -- Refresh the header with the latest exit/signal status.
  chat_buffer.with_buffer(state.bufnr, function()
    local new_header = terminal_header_line(terminal_id, term.exit_code, term.signal)
    local existing = vim.api.nvim_buf_get_lines(state.bufnr, head_row, head_row + 1, false)[1] or ""
    vim.api.nvim_buf_set_text(state.bufnr, head_row, 0, head_row, #existing, { new_header })
  end)

  if chunk.kind == "exit" then
    fold_block(state, term._block)
  end
end

---Resolve the row range a turn covers — from its anchor row down to
---Run `:N,Mfold` in every window currently showing `bufnr`. Manual
---folds are created closed by default — exactly what we want for the
---auto-collapse-on-finalize behaviour. Queues the operation when no
---window is showing the buffer; `apply_pending_folds` replays it on
---the next show.
---@param state hyprpilot.render.State
---@param start_row integer
---@param end_row integer
local function fold_range(state, start_row, end_row)
  if end_row < start_row then
    return
  end

  local cmd = string.format("silent! %d,%dfold", start_row + 1, end_row + 1)
  local applied = false

  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == state.bufnr then
      vim.api.nvim_win_call(winid, function()
        pcall(vim.cmd, cmd)
      end)
      applied = true
    end
  end

  if not applied then
    table.insert(state.pending_fold_rows, start_row)
    table.insert(state.pending_fold_rows, end_row)
  end
end

function close_fold_at(state, target_row)
  fold_range(state, target_row, target_row)
end

---Fold a tool / plan / thought / permission block by its registered
---head + tail extmarks (block-level inner fold).
---@param state hyprpilot.render.State
---@param block hyprpilot.render.Block
function fold_block(state, block)
  local head_row, tail_row = block_range(state, block)
  fold_range(state, head_row, tail_row)
end

---Apply queued fold-close requests to the window that just opened
---`bufnr` (called from `chat.window` on show / switch).
---@param bufnr integer
function M.apply_pending_folds(bufnr)
  local state = M.state_for_bufnr(bufnr)
  if state == nil or #state.pending_fold_rows == 0 then
    return
  end

  local rows = state.pending_fold_rows
  state.pending_fold_rows = {}

  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      vim.api.nvim_win_call(winid, function()
        for i = 1, #rows, 2 do
          local start_row = rows[i]
          local end_row = rows[i + 1] or start_row
          pcall(vim.cmd, string.format("silent! %d,%dfold", start_row + 1, end_row + 1))
        end
      end)
      return
    end
  end
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

---State lookup by instance id. Public accessor — sibling modules in
---`chat/` route through this instead of reaching into `_states`.
---@param instance_id string
---@return hyprpilot.render.State?
function M.state_for(instance_id)
  return M._states[instance_id]
end

---Custom `foldtext` for chat windows — renders the fold's head line
---verbatim plus a trailing `▸ N` marker, instead of Neovim's default
---`+-- N lines: <line>` chrome which clobbers the head row's own
---icon / status / title we want visible at a glance.
---@return string
function M.foldtext()
  local fs = vim.v.foldstart or 1
  local fe = vim.v.foldend or fs
  local line = vim.fn.getline(fs) or ""
  local count = fe - fs + 1

  -- Strip any leading tab that vim's default would have replaced with
  -- "+" to make room for the chrome — we own the line, render it as-is.
  return string.format("%s  ▸ %d", line, count)
end

---Iterate every tracked state. `fn` receives `(instance_id, state)`
---per entry; return value ignored. Public accessor so consumers
---(events.lua's lagged-recovery loop) don't depend on the private
---`_states` table.
---@param fn fun(instance_id: string, state: hyprpilot.render.State): nil
function M.iter_states(fn)
  for instance_id, state in pairs(M._states) do
    fn(instance_id, state)
  end
end

return M
