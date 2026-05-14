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
local stats = require("hyprpilot.chat.stats")

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

---@class hyprpilot.render.Section
---@field head_mark integer                     -- extmark on the `### tasks` / `### thoughts` / `### tools` header row
---@field tail_mark integer                     -- extmark on the section's trailing blank row (visual separator)
---@field block_ids string[]                    -- ids of blocks that belong to this section (ordered)
---@field item_count integer                    -- number of inner blocks rendered so far (drives `[N]` chip on header)

---@class hyprpilot.render.TurnLayout
---@field turn_id string
---@field pilot_header_mark integer             -- extmark on the `## pilot` header row so we can re-render stats
---@field response_header_emitted? boolean      -- set true after the lazy `### response` subhead lands on first agent_text
---@field section_anchor_mark integer           -- new sections insert at this row; stays put when prose grows
---@field prose_anchor_mark integer             -- agent_text appends at this extmark; moves down as prose grows
---@field sections table<string, hyprpilot.render.Section>  -- "tasks" | "thoughts" | "tools" → section
---@field started_at_ms? integer                -- turn_started timestamp (daemon-side, ms since epoch)
---@field ended_at_ms? integer                  -- turn_ended timestamp (set on handle_turn_ended)
---@field usage? { used?: integer, size?: integer, cost?: table }  -- latest usage_update reading
---@field stop_reason? string                   -- turn_ended.stopReason, rendered as a status chip on the pilot header
---@field stop_error? string                    -- turn_ended.error (mutually exclusive with stop_reason)

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
---@field turn_layouts table<string, hyprpilot.render.TurnLayout>  -- per-turn section anchors + prose anchor (only pilot turns)
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
local fold_range

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
    turn_layouts = {},
    pending_fold_rows = {},
    has_more = false,
    snapshot_limit = 100,
    -- Conversational-exchange tracking. Replay session snapshots
    -- ship a single synthetic turn_id for every historical item
    -- (the daemon doesn't re-emit TurnStarted boundaries during
    -- session/load). To stop the whole replay from collapsing under
    -- one ## pilot / ## captain header pair we partition by
    -- exchange: each user_prompt that follows an agent item (or is
    -- the first item) bumps `exchange_index`; the renderer
    -- namespaces the daemon turn_id under that counter so headers
    -- and turn layouts get a fresh bucket per exchange.
    exchange_index = 0,
    last_render_role = nil, ---@type "user" | "agent" | nil
    -- Map daemon turn_id → effective (namespaced) turn_id so live
    -- lifecycle events (turn_ended / handle_usage_update arriving
    -- after replay finishes) can find the layout we created under
    -- the namespaced key.
    turn_id_map = {},
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

---Per-turn section ordering. Sections appear in this order (top to
---bottom) between the `## pilot` header and the prose. The values
---double as priority ranks for new-section insertion.
local SECTION_ORDER = { tasks = 1, thoughts = 2, tools = 3, attachments = 4 }

local SECTION_HEADER = {
  tasks = "### tasks",
  thoughts = "### thoughts",
  tools = "### tools",
  attachments = "### attachments",
}

---Resolve the turn layout for `turn_id`, or nil when this isn't a
---pilot turn (captain prompts don't get sections — they're just text).
---@param state hyprpilot.render.State
---@param turn_id? string
---@return hyprpilot.render.TurnLayout?
local function get_layout(state, turn_id)
  if turn_id == nil then
    return nil
  end
  return state.turn_layouts[turn_id]
end

---Resolve the row OF the section's trailing blank (where new body
---inserts go, pushing the blank down). Each section ends at a blank
---line that doubles as the visual separator before the next section
---/ prose region.
---@param state hyprpilot.render.State
---@param section hyprpilot.render.Section
---@return integer
local function section_end_row(state, section)
  return vim.api.nvim_buf_get_extmark_by_id(state.bufnr, NS, section.tail_mark, {})[1]
end

---Find the row at which a NEW section of `kind` should insert. Three
---cases:
---  * higher-priority sections exist (order > kind's order) → insert
---    AT the lowest of their head_rows so we land just above them
---  * only lower-priority sections exist → insert at the row JUST
---    AFTER the highest of their tail_rows (their trailing blank
---    serves as our leading separator)
---  * no other sections → insert at section_anchor row (with
---    prose_anchor as legacy fallback)
---@param state hyprpilot.render.State
---@param layout hyprpilot.render.TurnLayout
---@param kind string
---@return integer
local function find_section_insert_row(state, layout, kind)
  local order = SECTION_ORDER[kind]

  local higher_min = nil
  for other_kind, other in pairs(layout.sections) do
    if SECTION_ORDER[other_kind] > order then
      local head_row = vim.api.nvim_buf_get_extmark_by_id(state.bufnr, NS, other.head_mark, {})[1]
      if higher_min == nil or head_row < higher_min then
        higher_min = head_row
      end
    end
  end

  if higher_min ~= nil then
    return higher_min
  end

  local lower_max_end = nil
  for other_kind, other in pairs(layout.sections) do
    if SECTION_ORDER[other_kind] < order then
      local tail_row = section_end_row(state, other)
      if lower_max_end == nil or tail_row > lower_max_end then
        lower_max_end = tail_row
      end
    end
  end

  if lower_max_end ~= nil then
    return lower_max_end + 1
  end

  local anchor_mark = layout.section_anchor_mark or layout.prose_anchor_mark
  return vim.api.nvim_buf_get_extmark_by_id(state.bufnr, NS, anchor_mark, {})[1]
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

  -- Role label stays as `pilot` / `captain` — those are the
  -- semantic anchors. We DO add a `### request` subhead under
  -- the captain header (and `### response` lands lazily on the
  -- first agent_text chunk via `append_agent_text`) so the prose
  -- itself sits inside a sibling subsection of `### tasks` /
  -- `### thoughts` / `### tools`. This gives markdown treesitter
  -- a clean ordinary heading hierarchy to anchor on without
  -- swallowing the role identifier.
  local label = role == "agent" and "pilot" or "captain"
  local header_row
  local prose_anchor_row

  chat_buffer.with_buffer(state.bufnr, function()
    local total = vim.api.nvim_buf_line_count(state.bufnr)
    local prepend_blank = not (total == 1 and vim.api.nvim_buf_get_lines(state.bufnr, 0, 1, false)[1] == "")

    -- For pilot turns: the trailing blank row IS the prose anchor —
    -- agent_text inserts there, sections (including the lazy
    -- `### response` subhead) insert above it. For captain turns
    -- we inline the `### request` subhead right under the header
    -- so the user prompt that appends afterwards sits inside it.
    local lines
    if role == "user" then
      lines = prepend_blank and { "", "## " .. label, "", "### request", "" } or { "## " .. label, "", "### request", "" }
    else
      lines = prepend_blank and { "", "## " .. label, "" } or { "## " .. label, "" }
    end
    local first_row = append_lines(state, lines)
    -- For both shapes the `## <label>` line is at the position
    -- right after the optional leading blank, and the trailing
    -- blank (the prose anchor) is the last line we inserted.
    local label_offset = prepend_blank and 1 or 0
    header_row = first_row + label_offset
    prose_anchor_row = first_row + #lines - 1
  end)

  state.active_text_block = nil

  if role == "agent" then
    state.current_turn = turn_id
    if turn_id ~= nil and state.turn_layouts[turn_id] == nil and prose_anchor_row ~= nil then
      -- section_anchor uses gravity=false so it STAYS at the topmost
      -- section row even when prose inserts at the same row (gravity-
      -- false attaches the mark to the LEFT of the insertion boundary).
      -- prose_anchor uses gravity=true so it follows the prose tail
      -- down as more chunks stream in.
      local pilot_mark = vim.api.nvim_buf_set_extmark(state.bufnr, NS, header_row, 0, { right_gravity = true })
      local section_mark = vim.api.nvim_buf_set_extmark(state.bufnr, NS, prose_anchor_row, 0, { right_gravity = false })
      local prose_mark = vim.api.nvim_buf_set_extmark(state.bufnr, NS, prose_anchor_row, 0, { right_gravity = true })
      local pending = state._pending_turn_started and state._pending_turn_started[turn_id] or nil
      state.turn_layouts[turn_id] = {
        turn_id = turn_id,
        pilot_header_mark = pilot_mark,
        section_anchor_mark = section_mark,
        prose_anchor_mark = prose_mark,
        sections = {},
        started_at_ms = pending,
      }
      if state._pending_turn_started ~= nil then
        state._pending_turn_started[turn_id] = nil
      end
    end
  end
end

---Compose the `## pilot` header line including stat pills. Pills are
---driven by the turn's accumulated metadata (started_at / usage /
---ended_at). Idempotent — re-rendering with the same inputs produces
---the same string.
---@param layout hyprpilot.render.TurnLayout
---@return string
local function pilot_header_line(layout)
  -- Wall-clock `now` for live elapsed (matches the daemon's
  -- started_at_ms which is also wall-clock). `os.time()` returns
  -- seconds; we multiply for ms parity.
  local pills = stats.turn_pills({
    started_at_ms = layout.started_at_ms,
    ended_at_ms = layout.ended_at_ms,
    now_ms = os.time() * 1000,
    usage = layout.usage,
    stop_reason = layout.stop_reason,
    stop_error = layout.stop_error,
  })
  return "## pilot" .. stats.format_pills(pills)
end

---Re-paint the `## pilot` header for `layout` with current stat pills
---in place. Cheap; called whenever usage_update or turn_ended changes
---the metadata.
---@param state hyprpilot.render.State
---@param layout hyprpilot.render.TurnLayout
local function repaint_pilot_header(state, layout)
  if layout.pilot_header_mark == nil then
    return
  end
  local row = vim.api.nvim_buf_get_extmark_by_id(state.bufnr, NS, layout.pilot_header_mark, {})[1]
  if row == nil then
    return
  end

  local existing = vim.api.nvim_buf_get_lines(state.bufnr, row, row + 1, false)[1] or ""
  local new_line = pilot_header_line(layout)
  if new_line == existing then
    return
  end

  chat_buffer.with_buffer(state.bufnr, function()
    vim.api.nvim_buf_set_text(state.bufnr, row, 0, row, #existing, { new_line })
  end)
end

---Compose a section header line with the item-count pill.
---@param kind string
---@param item_count integer
---@return string
local function section_header_line(kind, item_count)
  local base = SECTION_HEADER[kind] or ("### " .. kind)
  if item_count == nil or item_count <= 0 then
    return base
  end

  local unit
  if kind == "tasks" then
    unit = item_count == 1 and "plan" or "plans"
  elseif kind == "thoughts" then
    unit = item_count == 1 and "thought" or "thoughts"
  elseif kind == "tools" then
    unit = item_count == 1 and "call" or "calls"
  elseif kind == "attachments" then
    unit = item_count == 1 and "file" or "files"
  else
    unit = "items"
  end

  return base .. stats.format_pills({ string.format("%d %s", item_count, unit) })
end

---Re-paint a section header line in place after its item_count
---changes (called whenever a new block is appended to the section).
---@param state hyprpilot.render.State
---@param kind string
---@param section hyprpilot.render.Section
local function repaint_section_header(state, kind, section)
  local row = vim.api.nvim_buf_get_extmark_by_id(state.bufnr, NS, section.head_mark, {})[1]
  if row == nil then
    return
  end

  local existing = vim.api.nvim_buf_get_lines(state.bufnr, row, row + 1, false)[1] or ""
  local new_line = section_header_line(kind, section.item_count or 0)
  if new_line == existing then
    return
  end

  chat_buffer.with_buffer(state.bufnr, function()
    vim.api.nvim_buf_set_text(state.bufnr, row, 0, row, #existing, { new_line })
  end)
end

---Ensure the `### tasks` / `### thoughts` / `### tools` section exists
---in `turn_id`'s layout, inserting the header line at the correct
---priority-ordered position. Returns the section table (head_mark +
---block_ids), or `nil` when no layout is registered for the turn
---(captain turn / spontaneous item).
---@param state hyprpilot.render.State
---@param turn_id? string
---@param kind string
---@return hyprpilot.render.Section?
local function ensure_section(state, turn_id, kind)
  local layout = get_layout(state, turn_id)
  if layout == nil then
    return nil
  end

  if layout.sections[kind] ~= nil then
    return layout.sections[kind]
  end

  local insert_row = find_section_insert_row(state, layout, kind)
  local header = section_header_line(kind, 0)

  -- Add a leading blank only when the row immediately above isn't
  -- already blank (e.g. first section under `## pilot`). When the
  -- row above IS blank (preceding section's trailing blank, or pilot
  -- header's own trailing blank), reuse it as the separator.
  --
  -- Below the header we always add TWO blanks: the first is a fixed
  -- spacer between `### kind` and the section's body (captain wants
  -- one blank after every header, like markdown convention), the
  -- second is the trailing separator that doubles as the gap before
  -- the next section / prose. Body inserts go AT the trailing blank
  -- (tail_mark with gravity=true follows the blank down) so the
  -- spacer between header and body never moves.
  local needs_leading_blank = true
  if insert_row > 0 then
    local line_above = vim.api.nvim_buf_get_lines(state.bufnr, insert_row - 1, insert_row, false)[1]
    if line_above == "" then
      needs_leading_blank = false
    end
  end

  local lines = {}
  if needs_leading_blank then
    table.insert(lines, "")
  end
  table.insert(lines, header)
  table.insert(lines, "")
  table.insert(lines, "")

  chat_buffer.with_buffer(state.bufnr, function()
    vim.api.nvim_buf_set_lines(state.bufnr, insert_row, insert_row, false, lines)
  end)

  local header_offset = needs_leading_blank and 1 or 0
  local header_row = insert_row + header_offset
  local tail_row = header_row + 2

  local head_mark = vim.api.nvim_buf_set_extmark(state.bufnr, NS, header_row, 0, { right_gravity = true })
  local tail_mark = vim.api.nvim_buf_set_extmark(state.bufnr, NS, tail_row, 0, { right_gravity = true })
  apply_line_hl(state, header_row, "HyprpilotSectionHeader")

  layout.sections[kind] = { head_mark = head_mark, tail_mark = tail_mark, block_ids = {}, item_count = 0 }
  return layout.sections[kind]
end

---Insert `lines` into `kind`'s section as a single block tracked by
---`block_id`. Returns the block (with head_mark / tail_mark wired) and
---the row where the block's header now lives. Returns `nil, nil` when
---the turn has no layout (caller falls back to legacy append).
---@param state hyprpilot.render.State
---@param turn_id? string
---@param kind string                     -- section kind ("tasks" / "thoughts" / "tools")
---@param block_id string
---@param block_kind hyprpilot.render.BlockKind
---@param lines string[]
---@return hyprpilot.render.Block?
---@return integer?
local function insert_block_into_section(state, turn_id, kind, block_id, block_kind, lines)
  local section = ensure_section(state, turn_id, kind)
  if section == nil then
    return nil, nil
  end

  -- Insert AT the section's trailing blank row — the blank gets
  -- pushed down (gravity=true on the tail_mark follows), and the new
  -- block lands above it. Result: [header][...prior blocks...]
  -- [new block][trailing blank].
  --
  -- Prepend a blank when this isn't the section's first block: the
  -- previous block's closing `---` and the new block's header would
  -- otherwise sit on adjacent rows. The first block uses the
  -- section's own spacer row (head+1) as its leading separator.
  local lines_to_insert = lines
  local block_row_offset = 0
  if #section.block_ids > 0 then
    lines_to_insert = vim.list_extend({ "" }, lines)
    block_row_offset = 1
  end

  local insert_row = section_end_row(state, section)

  chat_buffer.with_buffer(state.bufnr, function()
    vim.api.nvim_buf_set_lines(state.bufnr, insert_row, insert_row, false, lines_to_insert)
  end)

  -- The block's head_row sits at insert_row + block_row_offset (skip
  -- the leading blank when present); tail follows from there.
  local block_head = insert_row + block_row_offset
  local block_tail = insert_row + #lines_to_insert - 1
  local block = {
    id = block_id,
    kind = block_kind,
    turn_id = state.current_turn,
    head_mark = vim.api.nvim_buf_set_extmark(state.bufnr, NS, block_head, 0, { right_gravity = true }),
    tail_mark = vim.api.nvim_buf_set_extmark(state.bufnr, NS, block_tail, 0, { right_gravity = true }),
  }
  state.blocks[block_id] = block
  table.insert(section.block_ids, block_id)
  section.item_count = (section.item_count or 0) + 1

  -- Find which kind this section is so we can repaint its `[N items]`
  -- chip. The section table doesn't store its own kind; lookup by
  -- comparing references in the layout's sections map.
  local layout = get_layout(state, turn_id)
  if layout ~= nil then
    for kind_lookup, candidate in pairs(layout.sections) do
      if candidate == section then
        repaint_section_header(state, kind_lookup, section)
        break
      end
    end
  end

  return block, block_head
end

---Insert `lines` directly under the prose anchor of `turn_id`, growing
---the prose region. Returns the first row of the inserted content.
---When no layout is registered, falls back to appending at the end.
---@param state hyprpilot.render.State
---@param turn_id? string
---@param lines string[]
---@return integer
local function insert_at_prose_anchor(state, turn_id, lines)
  local layout = get_layout(state, turn_id)
  if layout == nil then
    return append_lines(state, lines)
  end

  local anchor_row = vim.api.nvim_buf_get_extmark_by_id(state.bufnr, NS, layout.prose_anchor_mark, {})[1]
  vim.api.nvim_buf_set_lines(state.bufnr, anchor_row, anchor_row, false, lines)
  return anchor_row
end

---Append `text` to the buffer's current `agent_text` block. Prose
---lands at the turn's prose-anchor (just below the section block),
---so streaming text never gets pushed below new tools / thoughts /
---plans that arrive afterwards.
---@param state hyprpilot.render.State
---@param text string
local function append_agent_text(state, text)
  if text == "" then
    return
  end

  local turn_id = state.current_turn
  local layout = get_layout(state, turn_id)

  chat_buffer.with_buffer(state.bufnr, function()
    local bufnr = state.bufnr
    local chunks = vim.split(text, "\n", { plain = true })

    if state.active_text_block == nil then
      -- First chunk of prose for this turn. Before laying the text
      -- down, drop a `### response` subhead so the prose sits inside
      -- a sibling subsection of `### tasks` / `### thoughts` /
      -- `### tools`. Subsequent chunks stream below the subhead via
      -- the continuation branch — no need to track per-chunk state.
      -- `response_header_emitted` is per-layout so a re-streamed
      -- turn (continuation after cancel, etc.) doesn't double up.
      if layout ~= nil and not layout.response_header_emitted then
        insert_at_prose_anchor(state, turn_id, { "### response", "" })
        layout.response_header_emitted = true
      end
      insert_at_prose_anchor(state, turn_id, chunks)
      state.active_text_block = { kind = "agent_text", turn_id = turn_id }
      return
    end

    -- Continuation: append `chunks[1]` to the previous last-prose row,
    -- then insert any remaining chunks at the prose anchor.
    local last_prose_row
    if layout ~= nil then
      local anchor_row = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, layout.prose_anchor_mark, {})[1]
      last_prose_row = anchor_row - 1
    else
      last_prose_row = vim.api.nvim_buf_line_count(bufnr) - 1
    end

    if last_prose_row < 0 then
      insert_at_prose_anchor(state, turn_id, chunks)
      return
    end

    local last_line = vim.api.nvim_buf_get_lines(bufnr, last_prose_row, last_prose_row + 1, false)[1] or ""
    vim.api.nvim_buf_set_lines(bufnr, last_prose_row, last_prose_row + 1, false, { last_line .. chunks[1] })

    if #chunks > 1 then
      insert_at_prose_anchor(state, turn_id, vim.list_slice(chunks, 2))
    end
  end)
end

---Render an `agent_attachment` transcript item as a single line:
---`@ <title or slug> · <mime> · <path>` with the body lines available
---only by clicking through to the file. We don't inline image / audio
---content; the agent attached it for reference, not display.
---Routes through the per-turn `### attachments` section so multiple
---attachments cluster together below the tools section and fold as
---one unit on turn end.
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
  local lines = { line }

  local layout = get_layout(state, state.current_turn)
  if layout ~= nil then
    layout._attachment_seq = (layout._attachment_seq or 0) + 1
  end
  local block_id = "attachment:" .. (layout and layout._attachment_seq or "anon") .. ":" .. tostring(vim.uv and vim.uv.hrtime() or os.time())

  local _, first_row = insert_block_into_section(state, state.current_turn, "attachments", block_id, "agent_text", lines)

  if first_row == nil then
    -- Fallback for spontaneous attachments (no turn layout): append
    -- inline at end-of-buffer like the legacy behaviour.
    chat_buffer.with_buffer(state.bufnr, function()
      first_row = append_lines(state, lines)
    end)
    track_block(state, block_id, "agent_text", first_row, first_row)
  end

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

---Wrap a list of paragraphs (each paragraph is an array of lines) in
---`---` horizontal rules with proper markdown spacing: blank lines
---above and below each rule, blank lines between paragraphs, and a
---trailing blank that doubles as the inter-block separator inside a
---section. The result reads like a well-formed markdown document and
---renders cleanly in markdown viewers (markview / render-markdown)
---instead of running rules into adjacent content (which CommonMark
---requires a preceding blank for to recognise as a horizontal rule
---at all — without it many parsers treat `---` as a setext heading
---underline for the line above).
---@param paragraphs string[][]
---@return string[]
local function wrap_in_rules(paragraphs)
  if #paragraphs == 0 then
    paragraphs = { { "(no details)" } }
  end

  local lines = { "", "---", "" }
  for i, paragraph in ipairs(paragraphs) do
    if i > 1 then
      table.insert(lines, "")
    end
    for _, l in ipairs(paragraph) do
      table.insert(lines, l)
    end
  end
  table.insert(lines, "")
  table.insert(lines, "---")
  return lines
end

---Render the body lines for a tool-call block from its `formatted`
---spec. Wraps content in `---` separators + uses 4-backtick fenced
---code blocks so the chat buffer's markdown highlighter (registered
---for `filetype = "hyprpilot"` in `plugin/hyprpilot.lua`) takes
---over — no `line_hl_group` dimming. We use 4 backticks instead of
---the more common 3 because pilot prose / tool output frequently
---contains 3-backtick fences of its own; nesting 3-fence content
---inside a 3-fence wrapper terminates the outer fence prematurely
---and breaks rendering. 4 backticks bracket cleanly past 3-fence
---inner content.
---
---Fields render as `<label>: <value>` lines; description renders
---plain; output renders as a fenced code block (language inferred
---from `tool_kind`). Always returns at least one line so the
---head/tail extmarks bracket distinct rows.
---@param formatted? table
---@param tool_kind? string
---@return string[]
local function tool_body_lines(formatted, tool_kind)
  if type(formatted) ~= "table" then
    return wrap_in_rules({})
  end

  local paragraphs = {}
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
      table.insert(paragraphs, { "````" .. input_lang, tostring(single_field.value), "````" })
    elseif field_count > 0 then
      local field_lines = {}
      for _, field in ipairs(formatted.fields) do
        if type(field) == "table" and field.label and field.value then
          local value = tostring(field.value):gsub("\n", " ")
          table.insert(field_lines, string.format("%s: %s", field.label, value))
        end
      end
      table.insert(paragraphs, field_lines)
    end
  end

  -- Prefer the daemon's plain unified `diff` over `description` for
  -- tools that ship both (Edit / Write / MultiEdit). `description`
  -- carries Shiki `[!code ++]` / `[!code --]` markers meant for the
  -- desktop overlay's `transformerNotationDiff` pipeline — markdown
  -- consumers like us see those markers as raw text. The `diff`
  -- field is the same change projected as a unified-patch we can
  -- fence with the `diff` language so treesitter colours adds /
  -- removes naturally.
  if type(formatted.diff) == "string" and formatted.diff ~= "" then
    local diff_para = { "````diff" }
    for _, l in ipairs(vim.split(formatted.diff, "\n", { plain = true })) do
      table.insert(diff_para, l)
    end
    table.insert(diff_para, "````")
    table.insert(paragraphs, diff_para)
  elseif type(formatted.description) == "string" and formatted.description ~= "" then
    table.insert(paragraphs, vim.split(formatted.description, "\n", { plain = true }))
  end

  if type(formatted.output) == "string" and formatted.output ~= "" then
    local output_lang = tool_output_lang(tool_kind)
    local output_para = { "````" .. output_lang }
    for _, l in ipairs(vim.split(formatted.output, "\n", { plain = true })) do
      table.insert(output_para, l)
    end
    table.insert(output_para, "````")
    table.insert(paragraphs, output_para)
  end

  return wrap_in_rules(paragraphs)
end

---Compose the header line for a tool-call block.
---@param record table
---@return string
local function tool_header_line(record)
  local title = (record.formatted and record.formatted.title) or record.title or record.toolKind or "tool"
  local badge = tool_status_badge(record.state)
  local icon = tool_icon(record.toolKind)
  local pill_labels = {}

  if record.formatted and type(record.formatted.stats) == "table" then
    pill_labels = stats.from_wire_stats(record.formatted.stats)
  end

  return string.format("%s %s %s", icon, badge, title) .. stats.format_pills(pill_labels)
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
  local lines = vim.list_extend({ header }, body)
  local block, first_row = insert_block_into_section(state, state.current_turn, "tools", record.id, "tool_call", lines)

  if block == nil then
    -- No turn layout (orphan tool call): legacy append at end.
    chat_buffer.with_buffer(state.bufnr, function()
      first_row = append_lines(state, lines)
    end)
    block = track_block(state, record.id, "tool_call", first_row, first_row + #body)
  end

  block.tool_call_id = record.id
  state.tool_calls[record.id] = block.id

  -- Header gets a status colour; body intentionally has no
  -- `line_hl_group` so the chat buffer's markdown highlighter takes
  -- over (fenced code blocks ` ```` ` get treesitter highlight).
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
---transcript stays compact. Empty thoughts are dropped entirely (no
---placeholder, no section header) so a turn that streams an empty
---thought event doesn't get a vestigial `### thoughts` section
---hanging around with nothing inside it.
---@param state hyprpilot.render.State
---@param text string
local function render_thought(state, text)
  if text == "" then
    log.debug("render_thought: dropping empty thought (no placeholder)")
    return
  end

  state.active_text_block = nil

  local body = wrap_in_rules({ vim.split(text, "\n", { plain = true }) })
  local lines = vim.list_extend({ "* thought" }, body)

  -- Route through the per-turn `### thoughts` section. Block IDs are
  -- per-turn-counter to stay unique across re-renders that drop and
  -- re-insert thoughts at the same row.
  local layout = get_layout(state, state.current_turn)
  if layout ~= nil then
    layout._thought_seq = (layout._thought_seq or 0) + 1
  end
  local block_id = "thought:" .. (layout and layout._thought_seq or "anon") .. ":" .. tostring(vim.uv and vim.uv.hrtime() or os.time())

  local _, first_row = insert_block_into_section(state, state.current_turn, "thoughts", block_id, "agent_thought", lines)

  if first_row == nil then
    -- Fallback for spontaneous thoughts (no turn layout).
    chat_buffer.with_buffer(state.bufnr, function()
      first_row = append_lines(state, lines)
    end)
    track_block(state, block_id, "agent_thought", first_row, first_row + #lines - 1)
  end

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

  local lines = vim.list_extend({ header }, body)

  local layout = get_layout(state, state.current_turn)
  if layout ~= nil then
    layout._plan_seq = (layout._plan_seq or 0) + 1
  end
  local block_id = "plan:" .. (layout and layout._plan_seq or "anon") .. ":" .. tostring(vim.uv and vim.uv.hrtime() or os.time())

  local _, first_row = insert_block_into_section(state, state.current_turn, "tasks", block_id, "plan", lines)

  if first_row == nil then
    chat_buffer.with_buffer(state.bufnr, function()
      first_row = append_lines(state, lines)
    end)
    track_block(state, block_id, "plan", first_row, first_row + #lines - 1)
  end

  apply_line_hl(state, first_row, "HyprpilotPlanHeader")
  for i, step in ipairs(steps) do
    apply_line_hl(state, first_row + i, plan_step_hl(step.status))
  end
end

---Forward a permission request to the pinned permission row. Chat
---buffer stays untouched on purpose — the captain doesn't want
---permission prompts cluttering the conversation history; the row
---is the single interaction surface (auto-grows up to 40% vh,
---default-focuses the Allow-shaped option, exposes Tab/CR/g/d
---keymaps).
---@param state hyprpilot.render.State
---@param record table
local function render_permission_request(state, record)
  if type(record.requestId) ~= "string" then
    log.warn("render.permission_request: missing requestId, dropping")
    return
  end

  if state.permissions[record.requestId] ~= nil then
    log.debug("render.permission_request: requestId=%s already enqueued", record.requestId)
    return
  end

  -- Track the request id with a sentinel value so resolution events
  -- can find it. We don't create a chat-buffer block.
  state.permissions[record.requestId] = "row:" .. record.requestId

  require("hyprpilot.chat.permission_row").enqueue(state.instance_id, {
    request_id = record.requestId,
    tool = record.tool or record.toolKind or "tool",
    tool_kind = record.toolKind,
    options = type(record.options) == "table" and record.options or {},
    formatted = record.formatted,
  })
end

---Drop a permission block from the registry once resolved. The
---block stays in the buffer (with the dimmed marker) for history.
---@param state hyprpilot.render.State
---@param request_id string
---@param resolved_label? string
function M.mark_permission_resolved(state, request_id, resolved_label)
  if state.permissions[request_id] == nil then
    log.debug("render.mark_permission_resolved: no pending request for id=%s", request_id)
    return
  end

  state.permissions[request_id] = nil
  require("hyprpilot.chat.permission_row").resolve(request_id, resolved_label)
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
  local role = is_user_kind and "user" or "agent"

  -- Conversational-exchange boundary detection. A user_prompt that
  -- follows an agent item (or is the first item) starts a fresh
  -- exchange. Bumping the counter here ensures the per-exchange
  -- namespace below changes, which makes `headers_emitted` /
  -- `turn_layouts` allocate fresh buckets — even when the daemon
  -- ships the same synthetic turn_id for every replayed item.
  if is_user_kind and state.last_render_role ~= "user" then
    state.exchange_index = (state.exchange_index or 0) + 1
  end
  state.last_render_role = role

  -- Namespace the daemon turn_id under the current exchange so each
  -- exchange gets its own header + layout. `vim.NIL` (JSON null)
  -- collapses to nil so the downstream `nil` guards behave.
  local daemon_turn_id = turn_id
  if daemon_turn_id == vim.NIL then
    daemon_turn_id = nil
  end
  local effective_turn_id = nil
  if daemon_turn_id ~= nil then
    effective_turn_id = string.format("%d|%s", state.exchange_index or 0, tostring(daemon_turn_id))
    -- Remember the translation so live lifecycle events
    -- (turn_ended, handle_usage_update post-replay) can resolve the
    -- daemon's turn_id back to the namespaced key we used for the
    -- layout. The most recent exchange wins when the daemon reuses
    -- a turn_id (it shouldn't outside replay, but the map is
    -- best-effort either way).
    state.turn_id_map = state.turn_id_map or {}
    state.turn_id_map[tostring(daemon_turn_id)] = effective_turn_id
    -- `turn_started` arrives before the first transcript item, so
    -- `_pending_turn_started` was stashed by daemon turn_id.
    -- Migrate it under the effective key so `append_turn_header`'s
    -- pending-drain (it reads by `state._pending_turn_started[turn_id]`)
    -- finds the value at the namespaced key.
    if state._pending_turn_started ~= nil then
      local pending = state._pending_turn_started[daemon_turn_id]
      if pending ~= nil and state._pending_turn_started[effective_turn_id] == nil then
        state._pending_turn_started[effective_turn_id] = pending
        state._pending_turn_started[daemon_turn_id] = nil
      end
    end
  end

  -- Lazy headers — `append_turn_header` is idempotent per
  -- (effective_turn_id, role), so the daemon's broadcast order
  -- between user_prompt and turn_started doesn't matter. Whichever
  -- side arrives first lands its header; the other side's header
  -- lands on its first item.
  if effective_turn_id ~= nil and not is_user_kind then
    append_turn_header(state, "agent", effective_turn_id)
  end

  if is_user_kind then
    append_turn_header(state, "user", effective_turn_id)

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
  state.turn_layouts = {}
  state.pending_fold_rows = {}
  state.exchange_index = 0
  state.last_render_role = nil
  state.turn_id_map = {}

  require("hyprpilot.chat.permission_row").reset()

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

  -- Per-tick render notification. Captains hook this for markview
  -- reattach / treesitter refresh / statusline animations that need
  -- to follow the stream. Fires on every transcript item — keep
  -- handlers cheap.
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "HyprpilotChatRendered",
    data = { instance_id = event.instanceId, bufnr = state.bufnr },
  })
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

  log.debug("render.handle_turn_started: instance=%s turnId=%s started_at=%s", event.instanceId, event.turnId, tostring(event.startedAt))

  -- Record the turn's start time on the layout so the pilot header
  -- can render its `[<elapsed>]` chip. The layout itself is created
  -- lazily by `append_turn_header` on the first agent-side item; if
  -- it doesn't exist yet, we stash on a pending table keyed by turn
  -- id and apply when the layout shows up. `render_item` migrates
  -- the pending entry from `daemon_turn_id` to the namespaced
  -- effective key on its first transcript pass, so the stash lands
  -- correctly even though we don't know the exchange index yet.
  local started_at = event.startedAt or event.started_at
  if type(started_at) == "number" and event.turnId ~= nil then
    state._pending_turn_started = state._pending_turn_started or {}
    state._pending_turn_started[event.turnId] = started_at

    -- If render_item has already created the effective key, look up
    -- via the daemon→effective map; otherwise the lookup falls
    -- through to nil and the pending stash carries the value.
    local effective = (state.turn_id_map or {})[tostring(event.turnId)]
    local layout = effective ~= nil and state.turn_layouts[effective] or state.turn_layouts[event.turnId]
    if layout ~= nil then
      layout.started_at_ms = started_at
      repaint_pilot_header(state, layout)
    end
  end
end

---Live `usage_update` event. Attaches the latest reading to the
---active turn's layout and repaints the pilot header chips.
---@param event table
function M.handle_usage_update(event)
  local state = M._states[event.instanceId]
  if state == nil then
    log.debug("render.handle_usage_update: no state for instance=%s", tostring(event.instanceId))
    return
  end

  local turn_id = state.current_turn
  if turn_id == nil then
    log.debug("render.handle_usage_update: no active turn for instance=%s", tostring(event.instanceId))
    return
  end

  local layout = state.turn_layouts[turn_id]
  if layout == nil then
    return
  end

  layout.usage = { used = event.used, size = event.size, cost = event.cost }
  repaint_pilot_header(state, layout)
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

  -- Translate the daemon turn_id to the plugin's effective
  -- (exchange-namespaced) key. During replay this is what
  -- `state.current_turn` actually holds; live flow's `turn_id_map`
  -- also routes here for the same reason.
  local effective_turn_id = (state.turn_id_map or {})[tostring(event.turnId)] or event.turnId

  if state.current_turn == effective_turn_id then
    state.current_turn = nil
  end

  -- Stamp the turn's end timestamp + stop reason on the layout, then
  -- repaint the pilot header so the elapsed chip freezes at its
  -- final value AND the `[ok end_turn]` / `[cancelled <reason>]` /
  -- `[error: <msg>]` chip lands on the header alongside the other
  -- stat pills (same pill format, same place — captain reads turn
  -- outcome at a glance from the header instead of scrolling to the
  -- end of the prose).
  local layout = state.turn_layouts[effective_turn_id]
  if layout ~= nil then
    local ended_at = event.endedAt or event.ended_at or (os.time() * 1000)
    layout.ended_at_ms = ended_at
    if event.error ~= nil then
      layout.stop_error = tostring(event.error)
    elseif event.stopReason ~= nil then
      layout.stop_reason = tostring(event.stopReason)
    end
    repaint_pilot_header(state, layout)
  end

  -- Fold each section (tasks / thoughts / tools) belonging to this
  -- turn so the chat tightens up after the pilot finishes. Individual
  -- tool / terminal / permission blocks have already auto-folded
  -- themselves at their terminal state; the outer section fold sits
  -- on top of those (nested manual folds work fine in Neovim).
  if layout ~= nil then
    for _, section in pairs(layout.sections) do
      local head_row = vim.api.nvim_buf_get_extmark_by_id(state.bufnr, NS, section.head_mark, {})[1]
      local tail_row = section_end_row(state, section)
      -- Fold up to tail_row - 1 so the trailing blank stays visible
      -- as the separator between this folded section and whatever
      -- follows (the next section / prose region).
      if tail_row - 1 > head_row then
        fold_range(state, head_row, tail_row - 1)
      end
    end
  end

  -- Legacy fallback for turns that never got a layout (captain-only or
  -- spontaneous items): fold any orphan plan / thought blocks the way
  -- we used to. Match against the effective key (block.turn_id is
  -- written from state.current_turn which already holds it).
  for _, block in pairs(state.blocks) do
    if block.turn_id == effective_turn_id and (block.kind == "plan" or block.kind == "agent_thought") then
      local _, tail = block_range(state, block)
      local head, _ = block_range(state, block)
      if layout == nil or layout.sections[block.kind == "plan" and "tasks" or "thoughts"] == nil then
        fold_range(state, head, tail)
      end
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
    local lines = vim.list_extend({ header }, wrap_in_rules({ { "(no output yet)" } }))

    local block, first_row = insert_block_into_section(state, state.current_turn, "tools", block_id, "tool_call", lines)

    if block == nil then
      chat_buffer.with_buffer(state.bufnr, function()
        first_row = append_lines(state, lines)
      end)
      block = track_block(state, block_id, "tool_call", first_row, first_row + #lines - 1)
    end

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

  local body
  if term.output == "" then
    body = wrap_in_rules({ { "(no output yet)" } })
  else
    local out_para = { "````console" }
    for _, l in ipairs(vim.split(term.output, "\n", { plain = true })) do
      table.insert(out_para, l)
    end
    table.insert(out_para, "````")
    body = wrap_in_rules({ out_para })
  end

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
function fold_range(state, start_row, end_row)
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
