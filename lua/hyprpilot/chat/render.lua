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
local config = require("hyprpilot.config")
local log = require("hyprpilot.log")
local stats = require("hyprpilot.chat.stats")

local M = {}

---Forward-declared so `M.hydrate` / `M.handle_turn_ended` /
---`M.apply_pending_folds` can call it before its body lands further
---down the file (Lua locals aren't visible above their declaration).
---@type fun(state: hyprpilot.render.State)
local rescan_code_block_folds

---@alias hyprpilot.render.BlockKind
---| "turn_header"
---| "agent_text"
---| "agent_thought"
---| "user_message"
---| "tool_call"
---| "plan"
---| "permission_request"
---| "placeholder"
---| "adapter"

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
---@field started_at_ms? integer                -- monotonic `vim.uv.now()` stamp at section creation (drives `### thoughts` elapsed pill)
---@field ended_at_ms? integer                  -- monotonic stamp set on `handle_turn_ended` so the elapsed pill freezes
---@field aggregated_stats? hyprpilot.render.SectionAggregatedStats  -- summed wire stats across `block_ids` (drives `### tools` pills)

---@class hyprpilot.render.SectionAggregatedStats
---@field added integer                         -- sum of `formatted.stats[*].added` across every tool_call block
---@field removed integer                       -- sum of `formatted.stats[*].removed`
---@field duration_ms integer                   -- sum of `formatted.stats[*].ms` for every duration stat

---@class hyprpilot.render.TurnLayout
---@field turn_id string
---@field pilot_header_mark integer             -- extmark on the `## pilot` header row so we can re-render stats
---@field response_wrap_emitted? boolean        -- set true after the opening `---` prose wrapper lands on first agent_text (handle_turn_ended closes it)
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
-- Re-export the tracking namespace so consumers (chat/keymaps for
-- turn / section jump anchors) can read extmarks without duplicating
-- the namespace string.
M.NS = NS
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
  local state = M._states[instance_id]
  if state == nil then
    return
  end

  log.debug("render.forget: instance=%s", instance_id)

  -- Cancel any pending per-block coalesce timers so callbacks
  -- scheduled before the forget don't fire against a nil state. The
  -- timer callbacks ALSO nil-check at fire time, but cancelling
  -- here is the cheaper + cleaner path.
  for _, block in pairs(state.blocks or {}) do
    if block._coalesce_timer ~= nil then
      pcall(block._coalesce_timer.stop, block._coalesce_timer)
      pcall(block._coalesce_timer.close, block._coalesce_timer)
      block._coalesce_timer = nil
      block._pending_update = nil
    end
  end

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
---Strip embedded newlines from a single string. Used at every
---`nvim_buf_set_text` call site (which requires single-line
---replacement and rejects multi-line entries with "'replacement
---string' item contains newlines"). Daemon-supplied tool titles
---/ pilot header pills occasionally carry a `\n`; one byte-for-
---byte strip keeps the write safe.
---@param s any
---@return string
local function flatten_text(s)
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("[\r\n]", " "))
end

---Flatten a list of strings so no element contains an embedded
---newline. `nvim_buf_set_lines` rejects multi-line items with
---"'replacement string' item contains newlines"; defensively
---splitting here lets every caller pass the daemon's wire-supplied
---strings through without each one having to remember to split.
---Empty input returns empty; nil-safe via the `lines or {}` guard
---at every call site.
---@param lines string[]
---@return string[]
local function flatten_lines(lines)
  local out = {}
  for _, line in ipairs(lines) do
    if type(line) ~= "string" then
      table.insert(out, "")
    elseif line:find("\n", 1, true) == nil then
      table.insert(out, line)
    else
      vim.list_extend(out, vim.split(line, "\n", { plain = true }))
    end
  end
  return out
end

---the first appended line.
---@param state hyprpilot.render.State
---@param lines string[]
---@return integer first_line
local function append_lines(state, lines)
  lines = flatten_lines(lines)
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
---
---`adapter` sits at the top because it surfaces session-context
---changes (mode / model / effort flips, system prompt injection)
---that frame everything else in the turn — captain sees "what is
---this turn running with" before reading what the agent did.
local SECTION_ORDER = { adapter = 0, tasks = 1, thoughts = 2, tools = 3, attachments = 4 }

local SECTION_HEADER = {
  adapter = "### adapter",
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
  body_lines = flatten_lines(body_lines)
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
    --
    -- Captain headers wrap the user-prompt body in `---` horizontal
    -- rules instead of the older `### request` subhead — the rules
    -- visually bracket the captain's text without claiming a
    -- markdown heading slot. Pilot turns rely on the lazy `---`
    -- prose wrapper laid down by `append_agent_text` on the first
    -- agent_text chunk (sections render in between).
    local lines
    if role == "user" then
      lines = prepend_blank and { "", "## " .. label, "", "---", "" } or { "## " .. label, "", "---", "" }
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
  -- Reset the per-turn streaming accumulators — a new role header
  -- (user OR agent) means the previous turn's blocks are closed.
  -- Next `agent_thought` / `plan` events mint fresh accumulators
  -- against the new turn's layout instead of overwriting last
  -- turn's content.
  state.active_thought_block = nil
  state.active_plan_block = nil

  -- BOTH roles update `current_turn` so subsequent items
  -- (agent_attachment, agent_thought) that route via
  -- `state.current_turn` find the correct turn. The previous code
  -- only set this for `agent` headers, which meant a user_prompt
  -- mid-replay left `current_turn` pointing at the PREVIOUS turn's
  -- agent layout — and the next agent_attachment landed in the
  -- old turn's `### attachments` section. (This is the hydration
  -- bug captain reported: attachments work live, drop on replay.)
  state.current_turn = turn_id

  if role == "agent" then
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
    vim.api.nvim_buf_set_text(state.bufnr, row, 0, row, #existing, { flatten_text(new_line) })
  end)
end

---Compose a section header line with the item-count pill (and an
---elapsed-time pill for thoughts where item_count would always be 1).
---
---Thoughts are a special case: every chunk in a turn streams into
---ONE accumulated block (see `render_thought` — it appends to the
---layout-bound block instead of minting a new one), so a count
---would always read "1 thought". Show the elapsed time the agent
---spent thinking instead — that's the metric the captain cares
---about ("how long was it thinking?").
---@param kind string
---@param section hyprpilot.render.Section?
---@return string
local function section_header_line(kind, section)
  local base = SECTION_HEADER[kind] or ("### " .. kind)
  local item_count = section and section.item_count or 0

  if kind == "thoughts" then
    -- Pill shows only after `handle_turn_ended` stamps
    -- `ended_at_ms`. During streaming the captain sees the live
    -- thinking activity on the composer's virt indicator; once the
    -- turn ends, this pill freezes the total time the agent spent
    -- in the thoughts section so the captain can see "the agent
    -- thought for 3.4s here" at a glance.
    if section == nil or section.started_at_ms == nil or section.ended_at_ms == nil then
      return base
    end
    local elapsed = stats.format_duration(section.ended_at_ms - section.started_at_ms)
    if elapsed == nil then
      return base
    end
    return base .. stats.format_pills({ elapsed })
  end

  if item_count <= 0 then
    return base
  end

  local unit
  if kind == "tasks" then
    unit = item_count == 1 and "plan" or "plans"
  elseif kind == "tools" then
    unit = item_count == 1 and "call" or "calls"
  elseif kind == "attachments" then
    unit = item_count == 1 and "file" or "files"
  elseif kind == "adapter" then
    unit = item_count == 1 and "change" or "changes"
  else
    unit = "items"
  end

  local pills = { string.format("%d %s", item_count, unit) }

  -- Tools section: append summed `+N -M` and total `Xs` pills so the
  -- captain reads "this turn touched +120 -30 lines across 4 tool
  -- calls in 3.4s" at a glance from the section header — same shape
  -- as the per-tool-call header pills, just rolled up.
  if kind == "tools" and section ~= nil and section.aggregated_stats ~= nil then
    local agg = section.aggregated_stats
    if (agg.added or 0) > 0 then
      table.insert(pills, string.format("+%d", agg.added))
    end
    if (agg.removed or 0) > 0 then
      table.insert(pills, string.format("-%d", agg.removed))
    end
    if (agg.duration_ms or 0) > 0 then
      local d = stats.format_duration(agg.duration_ms)
      if d ~= nil then
        table.insert(pills, d)
      end
    end
  end

  return base .. stats.format_pills(pills)
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
  local new_line = section_header_line(kind, section)
  if new_line == existing then
    return
  end

  chat_buffer.with_buffer(state.bufnr, function()
    vim.api.nvim_buf_set_text(state.bufnr, row, 0, row, #existing, { flatten_text(new_line) })
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
  -- Mint with no section yet — header shows the bare label;
  -- `repaint_section_header` overwrites it once the section table
  -- exists (immediately below) and we've taken at least one event.
  local header = section_header_line(kind, nil)

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

  -- Stamp `started_at_ms` (monotonic via `vim.uv.now`) so the
  -- thoughts section header can show elapsed time on `turn_ended`.
  -- Same clock for end stamp; `format_duration` just sees a delta.
  layout.sections[kind] = { head_mark = head_mark, tail_mark = tail_mark, block_ids = {}, item_count = 0, started_at_ms = vim.uv.now() }
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
  -- Defensive flatten: any caller (tool_body_lines, render_attachment,
  -- adapter notes) that passes a daemon-supplied string with an
  -- embedded `\n` would crash `nvim_buf_set_lines` with the
  -- "'replacement string' item contains newlines" error. Splitting
  -- here is one place to fix every caller.
  local lines_to_insert = flatten_lines(lines)
  local block_row_offset = 0
  if #section.block_ids > 0 then
    lines_to_insert = vim.list_extend({ "" }, lines_to_insert)
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
  lines = flatten_lines(lines)
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
      -- First chunk of prose for this turn. Drop an OPENING `---`
      -- horizontal rule (replacing the older `### response`
      -- subhead) so the prose sits inside an explicit visual
      -- wrapper between the sections (`### tasks` / `### thoughts`
      -- / `### tools`) and the turn-end marker that
      -- `handle_turn_ended` writes below.
      --
      -- Spacing: leading blank pre-pads when the row immediately
      -- above is non-empty (e.g. `## pilot` header). The opening
      -- `---` is followed by a trailing blank so markdown sees a
      -- paragraph break between the rule and the first chunk.
      -- The CLOSING `---` lands when `handle_turn_ended` fires;
      -- it inserts at the prose anchor (which by then sits after
      -- the last prose line), then drops the turn-result marker
      -- below.
      if layout ~= nil and not layout.response_wrap_emitted then
        local anchor_row = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, layout.prose_anchor_mark, {})[1]
        local line_above = ""
        if anchor_row > 0 then
          line_above = vim.api.nvim_buf_get_lines(bufnr, anchor_row - 1, anchor_row, false)[1] or ""
        end
        local opener_lines = line_above == "" and { "---", "" } or { "", "---", "" }
        insert_at_prose_anchor(state, turn_id, opener_lines)
        layout.response_wrap_emitted = true
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
    -- Token-streaming concat: chunk boundaries from the daemon are
    -- arbitrary (mid-word, mid-sentence). Daemon-shipped `\n\n` for
    -- paragraph breaks already lands as `["", "next para"]` after
    -- the split above; the `chunks[2:]` insert below preserves the
    -- blank. So we only concat the FIRST chunk-line onto the
    -- previous tail (token streaming); subsequent split lines stay
    -- as-inserted (paragraph-aware).
    vim.api.nvim_buf_set_lines(bufnr, last_prose_row, last_prose_row + 1, false, { flatten_text(last_line .. chunks[1]) })

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

---Resolve the first non-empty string from a list. Treats both
---`nil` and `""` as "unset" — Lua's truthy-by-default `or` chain
---would happily return `""` and produce double-space artifacts in
---the header line. Mirrors the CLAUDE.md convention codified
---alongside `format_stop_chip`'s `with_glyph` helper.
---@param ... string?
---@return string
local function first_nonempty(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "string" and v ~= "" then
      return v
    end
  end
  return ""
end

---Render the tool-call kind icon prefix. Reads from
---`config.options.icons.tool_kind` so the captain can swap the
---defaults (nerd-font glyphs) for ASCII or alternate glyph sets.
---Returns `""` when nothing resolves; `tool_header_line` strips
---empty components so we never emit a doubled space.
---@param tool_kind? string
---@return string
local function tool_icon(tool_kind)
  local map = (config.options.icons or {}).tool_kind or {}
  return first_nonempty(tool_kind ~= nil and map[tool_kind] or nil, map.default, "->")
end

---Status badge for tool-call state (`pending` / `running` /
---`completed` / `failed`). Reads from
---`config.options.icons.tool_status`. Returns `""` when nothing
---resolves so the caller's join can drop the slot.
---@param state_str? string
---@return string
local function tool_status_badge(state_str)
  local map = (config.options.icons or {}).tool_status or {}
  return first_nonempty(state_str ~= nil and map[state_str] or nil, map.running, "[run]")
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
---renders cleanly in any markdown viewer instead of running rules
---into adjacent content (which CommonMark
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
    vim.list_extend(lines, paragraph)
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
--- Cap a daemon-shipped free-form text field (output / diff /
--- description) at 256 KB. Truncates from the FRONT (captain cares
--- about the tail — errors / completion / final hunks) with an
--- `[N earlier bytes elided]` marker. Pure function; safe to call
--- per render — `tool_body_lines` is invoked per update and the
--- cap is the line of defence against the daemon shipping a 10 MB
--- `formatted.output` from a single tool result.
---@param raw string?
---@return string?
local function cap_tool_text(raw)
  if type(raw) ~= "string" or raw == "" then
    return raw
  end
  local MAX = 256 * 1024
  if #raw <= MAX then
    return raw
  end
  local elided = #raw - MAX
  return string.format("[%d earlier bytes elided]\n", elided) .. raw:sub(-MAX)
end

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
  -- `diff` ships uncapped — a truncated patch is a broken patch
  -- (hunk headers + context lines are load-bearing). `output` and
  -- `description` are free-form text where the tail carries the
  -- meaningful content (errors, completion lines, last-state).
  local diff_text = formatted.diff
  local description_text = cap_tool_text(formatted.description)
  local output_text = cap_tool_text(formatted.output)

  if type(diff_text) == "string" and diff_text ~= "" then
    local diff_para = { "````diff" }
    vim.list_extend(diff_para, vim.split(diff_text, "\n", { plain = true }))
    table.insert(diff_para, "````")
    table.insert(paragraphs, diff_para)
  elseif type(description_text) == "string" and description_text ~= "" then
    table.insert(paragraphs, vim.split(description_text, "\n", { plain = true }))
  end

  if type(output_text) == "string" and output_text ~= "" then
    local output_lang = tool_output_lang(tool_kind)
    local output_para = { "````" .. output_lang }
    vim.list_extend(output_para, vim.split(output_text, "\n", { plain = true }))
    table.insert(output_para, "````")
    table.insert(paragraphs, output_para)
  end

  return wrap_in_rules(paragraphs)
end

---Walk every tool_call block in `section` and sum its per-block
---wire stats (`block.stats[*]`) into a single aggregate the section
---header pills off. Diff entries sum added / removed; duration
---entries sum ms. Text-kind stats are skipped (no meaningful sum
---for free-form strings). Idempotent — recomputed from scratch on
---every call so streaming updates that overwrite a tool's stats
---don't double-count.
---@param state hyprpilot.render.State
---@param section hyprpilot.render.Section
local function recompute_section_aggregate(state, section)
  local added, removed, duration_ms = 0, 0, 0
  for _, block_id in ipairs(section.block_ids) do
    local block = state.blocks[block_id]
    if block ~= nil and type(block.stats) == "table" then
      for _, stat in ipairs(block.stats) do
        if type(stat) == "table" then
          if stat.kind == "diff" then
            added = added + (stat.added or 0)
            removed = removed + (stat.removed or 0)
          elseif stat.kind == "duration" then
            duration_ms = duration_ms + (stat.ms or 0)
          end
        end
      end
    end
  end
  section.aggregated_stats = { added = added, removed = removed, duration_ms = duration_ms }
end

---Compose the header line for a tool-call block. Shape:
---`<status> <tool_kind> · <title> · [stat] [stat]` — status pill
---leads (captain's "is this running / done / failed" check),
---tool-kind glyph follows, then `·` separators bracket the title
---so glyphs / title / stats read as three visually distinct
---units. Drops empty glyph slots so a captain who clears
---`icons.tool_kind.default` (or any specific status) doesn't end
---up with a doubled space or a leading `·`; drops the trailing
---`·` when the tool has no stats so the line doesn't trail off.
---@param record table
---@return string
local function tool_header_line(record)
  local title = (record.formatted and record.formatted.title) or record.title or record.toolKind or "tool"
  local pill_labels = {}

  if record.formatted and type(record.formatted.stats) == "table" then
    pill_labels = stats.from_wire_stats(record.formatted.stats)
  end

  local glyph_parts = {}
  for _, piece in ipairs({ tool_status_badge(record.state), tool_icon(record.toolKind) }) do
    if type(piece) == "string" and piece ~= "" then
      table.insert(glyph_parts, piece)
    end
  end
  local glyphs = table.concat(glyph_parts, " ")
  local header = glyphs ~= "" and (glyphs .. " · " .. title) or title
  local pills = stats.format_pills(pill_labels)
  -- format_pills returns " [pill] [pill]" (leading space) or "".
  -- Promote the leading space to ` ·` so the stats cluster reads as
  -- a sibling of the title rather than running into it; no-op when
  -- there are no stats (empty `pills`).
  if pills ~= "" then
    pills = " ·" .. pills
  end
  return header .. pills
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
  -- Stash the original toolKind on the block. `tool_call_update`
  -- events from the daemon ship only the CHANGED fields (state,
  -- formatted, output) — `toolKind` is omitted on updates. Without
  -- this stash the update path would rebuild the header line via
  -- `tool_icon(update.toolKind)` → nil → fallback to
  -- `icons.tool_kind.default` (the cog), so every tool reverted to
  -- the cog glyph the moment it finished executing.
  block.tool_kind = record.toolKind
  -- Stash the raw wire stats so `recompute_section_aggregate` can
  -- sum diffs / durations across every tool_call in this section.
  -- Wholesale replacement on update mirrors how the daemon ships
  -- running totals (each event carries the current state, not a
  -- delta) — summing block-level stats on top would double-count.
  block.stats = (record.formatted and record.formatted.stats) or nil
  state.tool_calls[record.id] = block.id

  -- Header gets a status colour; body intentionally has no
  -- `line_hl_group` so the chat buffer's markdown highlighter takes
  -- over (fenced code blocks ` ```` ` get treesitter highlight).
  apply_line_hl(state, first_row, tool_status_hl(record.state))

  -- Refresh the section's aggregate + repaint the `### tools`
  -- header pills (skip when the block landed without a layout —
  -- orphan path has no section to roll up into).
  local layout = get_layout(state, state.current_turn)
  local tools_section = layout and layout.sections and layout.sections.tools or nil
  if tools_section ~= nil then
    recompute_section_aggregate(state, tools_section)
    repaint_section_header(state, "tools", tools_section)
  end

  -- Tool calls fold from the moment they appear and stay folded for
  -- their entire lifecycle. Captain `zo`s explicitly when they want
  -- to read the body. Folding only on terminal state used to flop
  -- the layout under the cursor every time a tool finished — chat
  -- visibly jumped as N rows of body collapsed.
  fold_block(state, block)
end

--- Coalesce window for tool_call_update bursts. The daemon ships
--- per-token updates with cumulative `formatted.output`; rendering
--- every chunk does O(N²) buffer work (full body re-write per
--- chunk over growing output). Folding bursts into one render every
--- 50ms drops the work to ~20 renders/sec under any chunk-rate,
--- invisible to humans, with a fast-path that flushes terminal
--- states (`completed` / `failed` / `cancelled`) synchronously so
--- the captain sees the final state crisp.
local TOOL_CALL_COALESCE_MS = 50

---@type table<string, boolean>
local TOOL_CALL_TERMINAL_STATES = { completed = true, failed = true, cancelled = true }

---Cancel + close the per-block coalesce timer. Idempotent.
---@param block hyprpilot.render.Block
local function cancel_tool_call_timer(block)
  local timer = block._coalesce_timer
  if timer == nil then
    return
  end
  block._coalesce_timer = nil
  pcall(timer.stop, timer)
  pcall(timer.close, timer)
end

---Do the actual tool_call_update render. Called either from the
---coalesce timer (deferred path) or synchronously for terminal
---states. Skip-if-unchanged guards short-circuit each subexpression:
--- - body re-render (the expensive one) skipped when output / diff /
---   description / kind / state / stats all match the prior render
--- - header `set_text` skipped when the new header string equals
---   what's already on the row
--- - line_hl clear+reapply skipped when state hasn't transitioned
---@param state hyprpilot.render.State
---@param block hyprpilot.render.Block
---@param update table
local function render_tool_call_update_now(state, block, update)
  if state.blocks[block.id] ~= block then
    -- Block was dropped (instance close, hydrate, late timer fire);
    -- rendered state is definitively stale. Bail.
    return
  end
  if not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  local merged = vim.tbl_extend("keep", update, { toolKind = block.tool_kind })

  -- Refresh per-block stats from the merged payload so the section
  -- aggregate stays accurate as durations / diffs grow during the
  -- tool's lifecycle. Wholesale replacement (no merge) — daemon
  -- ships running totals.
  block.stats = (merged.formatted and merged.formatted.stats) or block.stats

  local output_text = (merged.formatted and merged.formatted.output) or ""
  local diff_text = (merged.formatted and merged.formatted.diff) or ""
  local description_text = (merged.formatted and merged.formatted.description) or ""
  local kind = merged.toolKind or ""
  local state_str = merged.state or ""

  -- Skip body re-render when nothing the body depends on has
  -- changed — the dominant CPU win under daemon re-shipping. Stats
  -- get a reference compare (daemon usually ships a fresh table per
  -- update, so this only short-circuits the truly-idle case).
  local body_needs_render = block._last_output ~= output_text
    or block._last_diff ~= diff_text
    or block._last_description ~= description_text
    or block._last_kind ~= kind
    or block._last_state ~= state_str
    or block._last_stats ~= block.stats

  local state_transitioned = block._last_state ~= state_str

  with_autoscroll(state, function()
    local new_header = flatten_text(tool_header_line(merged))
    chat_buffer.with_buffer(state.bufnr, function()
      local head_row = block_range(state, block)
      local existing = vim.api.nvim_buf_get_lines(state.bufnr, head_row, head_row + 1, false)[1] or ""
      if existing ~= new_header then
        vim.api.nvim_buf_set_text(state.bufnr, head_row, 0, head_row, #existing, { new_header })
      end
    end)

    if body_needs_render then
      replace_block_body(state, block, tool_body_lines(merged.formatted, merged.toolKind))
    end

    -- Bubble the refreshed stats up to the section header.
    -- `repaint_section_header` already skips when the line is
    -- unchanged, so this is cheap on no-op repaints.
    local layout = get_layout(state, block.turn_id)
    local tools_section = layout and layout.sections and layout.sections.tools or nil
    if tools_section ~= nil then
      recompute_section_aggregate(state, tools_section)
      repaint_section_header(state, "tools", tools_section)
    end

    -- Only clear+reapply line highlights when the state badge colour
    -- actually flipped. Under streaming this is per-tool-lifecycle,
    -- not per-chunk — saves an extmark churn per update.
    if state_transitioned then
      local head_row, tail_row = block_range(state, block)
      clear_range_hl(state, head_row, tail_row)
      apply_line_hl(state, head_row, tool_status_hl(state_str))
      local _ = tail_row
    end

    -- DO NOT re-fold here. `:N,Mfold` stacks manual folds — every
    -- streaming chunk would push another layer onto the same range,
    -- and the captain would need N+1 `zo`s to open a tool call. The
    -- create-time fold from `render_tool_call` survives body
    -- modifications (manual folds adjust their range as lines shift)
    -- and stays closed across the whole lifecycle.
  end)

  -- Stash what we just rendered for the next skip-if-unchanged
  -- comparison. Strings are immutable in Lua so the reference is
  -- the cheapest "what did we render" cache.
  block._last_output = output_text
  block._last_diff = diff_text
  block._last_description = description_text
  block._last_kind = kind
  block._last_state = state_str
  block._last_stats = block.stats
end

---Flush a pending coalesce timer for `block` synchronously. Safe
---to call when no timer / no pending update. Used by both the
---terminal-state fast path and by `handle_turn_ended` so folded
---turns don't lock in a stale (pre-flush) body snapshot.
---@param state hyprpilot.render.State
---@param block hyprpilot.render.Block
local function flush_tool_call_timer(state, block)
  cancel_tool_call_timer(block)
  local pending = block._pending_update
  if pending == nil then
    return
  end
  block._pending_update = nil
  render_tool_call_update_now(state, block, pending)
end

---Apply a tool_call_update: schedule a coalesced re-render. The
---daemon ships streaming updates with cumulative `formatted.output`;
---without coalescing we'd do a full `replace_block_body` per chunk
---(O(N²) in stream size). The timer folds bursts into at most one
---render per 50ms window. Terminal states (`completed` / `failed` /
---`cancelled`) bypass the coalesce and render immediately.
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

  -- Always stash the LATEST update — the timer reads from here at
  -- fire time. This avoids the "stale closure capture" trap: a
  -- timer scheduled at t=0 with update A must NOT render A when a
  -- newer update B arrived at t=25ms; the timer at t=50ms should
  -- render B.
  block._pending_update = update

  if TOOL_CALL_TERMINAL_STATES[update.state] == true then
    -- Terminal — flush immediately so the captain sees the final
    -- state without a coalesce-window delay. Cancels any pending
    -- timer so it can't fire a duplicate render after this one.
    cancel_tool_call_timer(block)
    block._pending_update = nil
    render_tool_call_update_now(state, block, update)
    return
  end

  if block._coalesce_timer ~= nil then
    -- Timer already armed; the latest update is now in
    -- `_pending_update`. Let the existing timer fire.
    return
  end

  local timer = vim.uv.new_timer()
  if timer == nil then
    -- uv resource exhaustion (rare). Fall back to a synchronous
    -- render so the update isn't silently dropped until the next
    -- terminal-state event flushes `_pending_update`.
    log.warn("render.tool_call_update: vim.uv.new_timer() returned nil — falling back to sync render")
    block._pending_update = nil
    render_tool_call_update_now(state, block, update)
    return
  end
  block._coalesce_timer = timer
  timer:start(
    TOOL_CALL_COALESCE_MS,
    0,
    vim.schedule_wrap(function()
      -- Re-resolve at fire time: the instance + block may have been
      -- torn down during the coalesce window. State may also have
      -- been dropped via `M.forget`.
      local live_state = M._states[instance_id]
      if live_state == nil or live_state.blocks[block.id] ~= block then
        cancel_tool_call_timer(block)
        return
      end
      -- Mark the timer as not-pending BEFORE rendering — the render
      -- path could fire fresh events that need to schedule a new
      -- timer; we don't want them to short-circuit on a stale handle.
      block._coalesce_timer = nil
      pcall(timer.stop, timer)
      pcall(timer.close, timer)

      local pending = block._pending_update
      if pending == nil then
        return
      end
      block._pending_update = nil
      render_tool_call_update_now(live_state, block, pending)
    end)
  )
end

M._flush_tool_call_timer = flush_tool_call_timer

---Render an agent thought block — every `agent_thought` chunk in
---the same turn streams into ONE accumulating block (like
---`append_agent_text` does for `agent_text`). The first chunk
---mints the block (single body, no per-chunk header); each
---subsequent chunk appends its lines below the existing body and
---pushes the tail mark down. Result: one continuous thought
---section per turn, body grows as the model thinks.
---
---Empty thoughts still mint the `### thoughts` section header so the
---captain has an anchor for the elapsed-time pill (set on
---`turn_ended`) — they want to know how long the agent spent
---thinking even when no thought text actually streamed.
---@param state hyprpilot.render.State
---@param text string
local function render_thought(state, text)
  state.active_text_block = nil

  -- Always touch the section first — covers the empty-text path
  -- (header + timer stamp, no body) AND every subsequent non-empty
  -- chunk (header already there, falls through idempotently).
  ensure_section(state, state.current_turn, "thoughts")

  if text == "" then
    log.debug("render_thought: empty text — kept section header, no body")
    return
  end

  local chunk_lines = vim.split(text, "\n", { plain = true })

  -- Append-to-existing path: there's already an accumulating thought
  -- block in the current turn. Splice the new lines onto the end of
  -- the block's body and re-anchor `tail_mark` to the new last row.
  -- Mirrors `replace_block_body`'s tail-mark dance.
  --
  -- Guard: if the active block belongs to a previous turn (a non-
  -- thought item or a turn boundary slipped through without resetting
  -- the tracker), drop it and mint a fresh accumulator below.
  local active_id = state.active_thought_block
  local active_block = active_id ~= nil and state.blocks[active_id] or nil
  if active_block ~= nil and active_block.turn_id ~= state.current_turn then
    state.active_thought_block = nil
    active_block = nil
  end
  if active_block ~= nil then
    chat_buffer.with_buffer(state.bufnr, function()
      local head_row, tail_row = block_range(state, active_block)
      if head_row == nil or tail_row == nil then
        -- Lost the marks (rare — buffer wipe race). The closure
        -- captures `active_block` as an upvalue; reassigning it to
        -- nil here propagates to the outer scope's check below
        -- (Lua upvalues are by-reference for the lexical local).
        state.active_thought_block = nil
        active_block = nil
        return
      end
      -- Each `agent_thought` event is its own markdown paragraph.
      -- Splice a blank separator between the existing body's tail
      -- and the new chunk when both ends carry content — without
      -- this, markdown renders consecutive chunks as a single mashed
      -- paragraph (the captain's screenshot showed this regression).
      -- Same rule when the new chunk's first line is non-empty:
      -- treat it as a fresh paragraph relative to the previous tail.
      local existing_tail = vim.api.nvim_buf_get_lines(state.bufnr, tail_row, tail_row + 1, false)[1] or ""
      local lines_to_insert
      if existing_tail ~= "" and (chunk_lines[1] or "") ~= "" then
        lines_to_insert = vim.list_extend({ "" }, chunk_lines)
      else
        lines_to_insert = chunk_lines
      end
      lines_to_insert = flatten_lines(lines_to_insert)
      vim.api.nvim_buf_set_lines(state.bufnr, tail_row + 1, tail_row + 1, false, lines_to_insert)
      local new_tail = tail_row + #lines_to_insert
      vim.api.nvim_buf_del_extmark(state.bufnr, NS, active_block.tail_mark)
      active_block.tail_mark = vim.api.nvim_buf_set_extmark(state.bufnr, NS, new_tail, 0, { right_gravity = true })
    end)
    if active_block ~= nil then
      return
    end
  end

  -- First thought in this turn — mint the accumulating block. No
  -- `* thought` per-chunk subheader; the `### thoughts` section
  -- header carries the role identifier on its own.
  local layout = get_layout(state, state.current_turn)
  local block_id = "thought:" .. tostring(layout and layout.turn_id or "anon") .. ":" .. tostring(vim.uv and vim.uv.hrtime() or os.time())

  local _, first_row = insert_block_into_section(state, state.current_turn, "thoughts", block_id, "agent_thought", chunk_lines)

  if first_row == nil then
    -- Fallback for spontaneous thoughts (no turn layout).
    chat_buffer.with_buffer(state.bufnr, function()
      first_row = append_lines(state, chunk_lines)
    end)
    track_block(state, block_id, "agent_thought", first_row, first_row + #chunk_lines - 1)
  end

  -- Track the new block as the active accumulator so subsequent
  -- chunks append into it rather than minting fresh blocks.
  state.active_thought_block = block_id

  -- Body lines stay plain so the markdown highlighter handles them.
  apply_line_hl(state, first_row, "HyprpilotThoughtBody")
end

---Render a plan block. Multiple plan updates in the same turn
---OVERWRITE the existing block in place (the daemon ships the
---full step list every time — appending would stack N stale
---copies of the same plan as the captain watches it grow).
---First plan in a turn mints the block; subsequent ones replace
---the body of the same block via `replace_block_body` and
---re-apply the per-step highlights.
---@param state hyprpilot.render.State
---@param record table
local function render_plan(state, record)
  state.active_text_block = nil

  local steps = type(record.steps) == "table" and record.steps or {}

  -- Prefer the daemon's `record.stats = { done, total }` checklist
  -- summary (shipped on every plan emit as of daemon PR #83). Falls
  -- back to walking `steps` when the daemon omits stats (older
  -- daemons / non-plan checklist-shaped records that don't carry the
  -- wire field yet).
  local done, total
  if type(record.stats) == "table" and type(record.stats.done) == "number" and type(record.stats.total) == "number" then
    done = record.stats.done
    total = record.stats.total
  else
    done = 0
    for _, step in ipairs(steps) do
      if type(step) == "table" and step.status == "completed" then
        done = done + 1
      end
    end
    total = #steps
  end

  -- Pill-style header matching the per-tool + tools-section header
  -- convention (`[+N] [-M] [Xs]`) — captain wanted the checklist
  -- stat surfaced via the same pill chrome.
  local header = "# plan" .. stats.format_pills({ string.format("%d/%d done", done, total) })
  local body = {}

  if #steps == 0 then
    table.insert(body, "  (no steps)")
  else
    local task_glyphs = (config.options.icons or {}).task_status or {}
    -- Fall back to the legacy ASCII so a captain who pre-emptively
    -- nukes `icons.task_status` still gets a readable mark.
    local fallback = { pending = "[ ]", in_progress = "[~]", completed = "[x]" }
    for _, step in ipairs(steps) do
      local key = step.status or "pending"
      local mark = task_glyphs[key] or fallback[key] or fallback.pending
      local priority = step.priority and (" (" .. step.priority .. ")") or ""
      local content = type(step.content) == "string" and step.content or ""
      table.insert(body, string.format("  %s %s%s", mark, content:gsub("\n", " "), priority))
    end
  end

  local lines = vim.list_extend({ header }, body)

  -- Replace-in-place path: the current turn already has an active
  -- plan block — overwrite its full content (header + body) so the
  -- captain sees one evolving plan, not a stack of revisions.
  local active_id = state.active_plan_block
  local active_block = active_id ~= nil and state.blocks[active_id] or nil
  if active_block ~= nil and active_block.turn_id == state.current_turn then
    chat_buffer.with_buffer(state.bufnr, function()
      local head_row = block_range(state, active_block)
      if head_row == nil then
        -- Lost the marks (rare); fall through to mint-new path.
        state.active_plan_block = nil
        active_block = nil
        return
      end
      -- Rewrite header line + body in one set_lines call. New body
      -- lengths are captured via `replace_block_body` which also
      -- re-anchors the tail mark.
      vim.api.nvim_buf_set_lines(state.bufnr, head_row, head_row + 1, false, { flatten_text(header) })
      replace_block_body(state, active_block, body)
    end)
    if active_block ~= nil then
      local head_row = block_range(state, active_block)
      if head_row ~= nil then
        apply_line_hl(state, head_row, "HyprpilotPlanHeader")
        for i, step in ipairs(steps) do
          apply_line_hl(state, head_row + i, plan_step_hl(step.status))
        end
      end
      return
    end
  end

  local layout = get_layout(state, state.current_turn)
  local block_id = "plan:" .. tostring(layout and layout.turn_id or "anon") .. ":" .. tostring(vim.uv and vim.uv.hrtime() or os.time())

  local _, first_row = insert_block_into_section(state, state.current_turn, "tasks", block_id, "plan", lines)

  if first_row == nil then
    chat_buffer.with_buffer(state.bufnr, function()
      first_row = append_lines(state, lines)
    end)
    track_block(state, block_id, "plan", first_row, first_row + #lines - 1)
  end

  -- Track the new block as the active accumulator so subsequent
  -- plan events overwrite it instead of stacking.
  state.active_plan_block = block_id

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

  require("hyprpilot.chat.permission-row").enqueue(state.instance_id, {
    request_id = record.requestId,
    tool = record.tool or record.toolKind or "tool",
    tool_kind = record.toolKind,
    options = type(record.options) == "table" and record.options or {},
    formatted = record.formatted,
    -- Daemon-computed pre-select. Honoured by `permission-row`'s
    -- `default_focused_idx` when it points at a real option id; the
    -- local kind-based heuristic still runs as the fallback so older
    -- daemons (or events the daemon couldn't classify) still get a
    -- sane Allow focus.
    default_option_id = record.defaultOptionId,
    -- The diff-preview module reads `raw_input.path` /
    -- `.file_path` / `.old_string` / `.new_string` / `.content` /
    -- `.edits[]` off the entry — keep the wire shape verbatim so
    -- a per-agent normalisation lives in one place (diff_preview).
    raw_input = record.rawInput,
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
  require("hyprpilot.chat.permission-row").resolve(request_id, resolved_label)
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
      -- Close the captain-prompt `---` wrapper opened by
      -- `append_turn_header(user)`. Leading blank gives the
      -- closing rule one space above the prompt body; trailing
      -- blank gives any attachments (rendered below) one
      -- paragraph break before they land. Captain spec: every
      -- chat-bubble `---` separator carries one space top + one
      -- space bottom — matches the desktop UI's bubble chrome.
      --   ## captain
      --
      --   ---
      --   <prompt>
      --
      --   ---
      --
      --   <attachments>
      append_lines(state, { "", "---", "" })
    end)

    -- Render any captain-side attachments shipped on the user prompt
    -- (`UserPrompt { text, attachments }` from the daemon). Without
    -- this, captain images / file attachments were silently dropped
    -- both live and on hydrate. Each attachment is a Lua table with
    -- the same shape `render_attachment` consumes.
    local attachments = item.attachments
    if type(attachments) == "table" then
      for _, a in ipairs(attachments) do
        if type(a) == "table" then
          render_attachment(state, a)
        end
      end
    end
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
  state.active_thought_block = nil
  state.active_plan_block = nil
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

  require("hyprpilot.chat.permission-row").reset()

  for _, entry in ipairs(items) do
    M.render_item(state, entry.turnId, entry.item)
  end

  -- Snapshot is bulk-loaded; sweep the entire buffer once so every
  -- fenced code block in the historical transcript becomes
  -- foldable. Live appends pick up their folds via
  -- `handle_turn_ended` instead.
  rescan_code_block_folds(state)
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

  -- Per-tick render notification. Captains hook this for any
  -- treesitter / decoration / statusline animation that needs to
  -- follow the stream. Fires on every transcript item — keep
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
      -- The agent's structured input (path / old_string /
      -- new_string / content / edits[] for the edit family). Carried
      -- through so the diff-preview module can extract it from the
      -- row entry without a second daemon round-trip.
      rawInput = event.rawInput,
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

---Resolve the display name for a wire id via a `{ id, name }` list
---(`available_modes` / `available_models` / `options`). Falls back
---to the id when the list doesn't carry a name for it — better the
---wire id than nothing.
---@param wire_id string
---@param list table[]?
---@return string
local function resolve_display_name(wire_id, list)
  if type(list) == "table" then
    for _, item in ipairs(list) do
      if item.id == wire_id or item.value == wire_id then
        if type(item.name) == "string" and item.name ~= "" then
          return item.name
        end
      end
    end
  end
  return wire_id
end

---Mint a stable block id for an adapter note. One id per (turn,
---kind) pair so re-firing the same notification kind dedups against
---the existing block instead of stacking duplicates.
---@param turn_id string
---@param kind string
---@return string
local function adapter_block_id(turn_id, kind)
  return "adapter:" .. turn_id .. ":" .. kind
end

---Append (or dedup-update) an adapter note row in the current
---turn's `### adapter` section. `kind` is the wire-level category
---("mode" / "effort" / "model" / "system_prompt"). `label` is the
---fully-formatted display string. Dedups against the last value
---recorded for `kind` on this turn — repeating the same value is a
---silent no-op to avoid spam from a chatty daemon.
---@param state hyprpilot.render.State
---@param kind string
---@param label string
local function add_adapter_note(state, kind, label)
  local turn_id = state.current_turn
  if turn_id == nil then
    return
  end

  local layout = state.turn_layouts[turn_id]
  if layout == nil then
    return
  end

  layout.adapter_last = layout.adapter_last or {}
  if layout.adapter_last[kind] == label then
    return
  end
  layout.adapter_last[kind] = label

  insert_block_into_section(state, turn_id, "adapter", adapter_block_id(turn_id, kind) .. ":" .. tostring(vim.uv.hrtime()), "adapter", { label })
end

---Live `current_mode_update` event. Drops a `mode · <name>` row in
---the adapter section. Resolves the display name from the cached
---`available_modes` list when available; falls back to the wire id
---otherwise.
---@param event table
function M.handle_current_mode_update(event)
  local state = M._states[event.instanceId]
  if state == nil then
    return
  end

  local available = (require("hyprpilot.chat.winbar")._meta[event.instanceId] or {}).available_modes
  local label = "mode · " .. resolve_display_name(event.currentModeId, available)
  add_adapter_note(state, "mode", label)
end

---Live `config_options_update` event — one row per category whose
---`currentValue` actually changed (dedup is per-kind so reruns with
---the same selection collapse). `effort` / future vendor toggles
---flow through here.
---@param event table
function M.handle_config_options_update(event)
  local state = M._states[event.instanceId]
  if state == nil then
    return
  end

  local categories = event.categories
  if type(categories) ~= "table" then
    return
  end

  for _, category in ipairs(categories) do
    if type(category) == "table" and type(category.id) == "string" and type(category.currentValue) == "string" then
      local value_label = resolve_display_name(category.currentValue, category.options)
      local category_label = (type(category.name) == "string" and category.name ~= "") and category.name or category.id
      local label = string.format("%s · %s", category_label:lower(), value_label)
      add_adapter_note(state, "config:" .. category.id, label)
    end
  end
end

---Live `system_prompt_injected` event. Drops a `system prompt ·
---<files>` row in the adapter section. Files are joined by commas;
---basenames only so the row stays readable.
---@param event table
function M.handle_system_prompt_injected(event)
  local state = M._states[event.instanceId]
  if state == nil then
    return
  end

  local files = event.files
  if type(files) ~= "table" or #files == 0 then
    return
  end

  local basenames = {}
  for _, path in ipairs(files) do
    if type(path) == "string" then
      table.insert(basenames, vim.fs.basename(path) or path)
    end
  end

  if #basenames == 0 then
    return
  end

  local label = "system prompt · " .. table.concat(basenames, ", ")
  add_adapter_note(state, "system_prompt", label)
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

  -- Flush every per-block coalesce timer in this turn before the
  -- fold / section-repaint / stats-aggregate pass below. Without
  -- this the folded section captures a stale body snapshot (the
  -- pending update from the last 50ms-window chunk hasn't landed
  -- yet) and the section-aggregate misses the final stats values.
  for _, block in pairs(state.blocks) do
    if block.turn_id == effective_turn_id and (block._coalesce_timer ~= nil or block._pending_update ~= nil) then
      flush_tool_call_timer(state, block)
    end
  end

  -- Stamp the turn's end timestamp + stop reason on the layout, then
  -- repaint the pilot header so the elapsed pill freezes at its
  -- final value. The stop reason itself is NOT emitted as a header
  -- pill anymore — it lives as a one-line marker at the prose tail
  -- (see the `_emit_turn_end_marker` step below) where the captain's
  -- eyes already are after reading the response.
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

    -- Close the response `---` wrapper opened by `append_agent_text`
    -- (only when opened — empty pilot turns without prose skip
    -- this). Lands at the prose anchor, which by now sits AFTER the
    -- last prose line. Leading blank keeps the closing rule one
    -- space below the prose tail — captain's bubble-chrome spec
    -- (every `---` carries one space top + one space bottom).
    -- Idempotent via the same `end_marker_emitted` flag so a
    -- replayed event doesn't stack duplicates.
    if not layout.end_marker_emitted and layout.response_wrap_emitted then
      chat_buffer.with_buffer(state.bufnr, function()
        insert_at_prose_anchor(state, effective_turn_id, { "", "---", "" })
      end)
    end

    -- Drop a one-line outcome marker at the prose tail. Verbatim
    -- daemon text — no `"ok " .. reason` humanisation — because
    -- the daemon is the source of truth for the wording and
    -- forcing a translation here means we drift from whatever the
    -- desktop UI shows. Highlight by category (ok / cancelled /
    -- error) via the existing `HyprpilotTurnEnd*` groups.
    -- Idempotent per turn via `layout.end_marker_emitted` so a
    -- replayed event doesn't stack duplicate markers.
    if not layout.end_marker_emitted then
      layout.end_marker_emitted = true

      local hl, body
      if event.error ~= nil then
        hl = "HyprpilotTurnEndError"
        body = tostring(event.error)
      elseif event.stopReason ~= nil then
        local reason = tostring(event.stopReason)
        body = reason
        if reason:lower():find("cancel", 1, true) ~= nil then
          hl = "HyprpilotTurnEndCancelled"
        else
          hl = "HyprpilotTurnEndOk"
        end
      end

      if body ~= nil then
        -- Markdown blockquote prefix for the visual band; same shape
        -- as the legacy error block so existing styling carries
        -- over. Multi-line bodies (e.g. errors with stack traces)
        -- get one quote prefix per line.
        local marker_lines = { "" }
        for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
          table.insert(marker_lines, "> " .. line)
        end
        table.insert(marker_lines, "")
        local first_row
        chat_buffer.with_buffer(state.bufnr, function()
          first_row = insert_at_prose_anchor(state, effective_turn_id, marker_lines)
        end)
        -- Highlight the body rows (skip the leading + trailing blanks).
        for i = 1, #marker_lines - 2 do
          apply_line_hl(state, first_row + i, hl)
        end
      end
    end
  end

  -- Freeze section timing on the same turn boundary as the pilot
  -- header. Repaint each section header so any timing pill (today
  -- only `### thoughts`, others may follow) shows the final value
  -- instead of a stale running one.
  if layout ~= nil then
    for kind, section in pairs(layout.sections) do
      section.ended_at_ms = vim.uv.now()
      repaint_section_header(state, kind, section)
    end
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

  -- Orphan-block fallback. The section loop above folds every
  -- block that lives inside a `layout.sections[*]` (tasks /
  -- thoughts / tools / attachments / adapter). Orphan blocks
  -- (turns that never minted a layout, or items rendered before
  -- the layout existed) need individual folds so the captain
  -- still ends up with a clean turn-tail.
  --
  -- Block kinds we DO fold here:
  --   plan, agent_thought, tool_call, terminal, permission,
  --   adapter, agent_attachment
  -- Block kinds we DON'T fold (these are the request/response
  -- pair the captain explicitly wants to stay readable):
  --   turn_header (`## you` / `## pilot`), agent_text (the prose
  --   response under `### response`), placeholder.
  local FOLDABLE_ORPHAN_KIND = {
    plan = "tasks",
    agent_thought = "thoughts",
    tool_call = "tools",
    terminal = "tools",
    permission = "tools",
    adapter = "adapter",
    agent_attachment = "attachments",
  }
  for _, block in pairs(state.blocks) do
    if block.turn_id == effective_turn_id then
      local section_kind = FOLDABLE_ORPHAN_KIND[block.kind]
      if section_kind ~= nil then
        local already_folded_by_section = layout ~= nil and layout.sections[section_kind] ~= nil
        if not already_folded_by_section then
          local head, tail = block_range(state, block)
          if head ~= nil and tail ~= nil and tail > head then
            fold_range(state, head, tail)
          end
        end
      end
    end
  end

  -- Post-render cleanup. Once the turn is folded + the section
  -- pills are frozen at their final values, the per-block wire
  -- payloads (`block.stats`) and per-section aggregates
  -- (`section.aggregated_stats`) are render-input we'll never need
  -- again — `tool_call_update` doesn't fire on closed turns, the
  -- section header text was already painted by the freeze loop
  -- above. Tool_kind is the only post-end consumer (header rebuild
  -- on update) so it goes too. Drop them so a long session with
  -- hundreds of tool calls doesn't keep their cumulative wire-
  -- payload garbage alive on the state table.
  --
  -- KEEP per block: id, kind, turn_id, head_mark, tail_mark — the
  -- jump keymaps + the orphan-fold fallback above already ran for
  -- this turn, but extmarks anchor buffer positions vim needs for
  -- the manual folds we just created (deleting them is safe; vim
  -- folds persist by range, not by extmark, but keeping them is
  -- cheap and protects any future "scroll to block" surface).
  --
  -- KEEP per section: head_mark, tail_mark, started_at_ms,
  -- ended_at_ms — the jump keymaps walk `### tasks` / `thoughts` /
  -- `tools` head marks for `[s` / `]s`.
  if layout ~= nil then
    for _, section in pairs(layout.sections) do
      for _, block_id in ipairs(section.block_ids) do
        local block = state.blocks[block_id]
        if block ~= nil then
          block.stats = nil
          block.tool_kind = nil
        end
      end
      section.aggregated_stats = nil
      -- We've already iterated `block_ids` for the orphan-fold
      -- pass above; no more callers for this turn's sections.
      section.block_ids = {}
    end
  end

  -- `tool_calls[id] = block_id` is the routing table for
  -- `handle_tool_call_update`. The daemon won't fire updates after
  -- `turn_ended`, so the entries for this turn's tool calls are
  -- dead. Walk the table once + drop the matching keys. (We can't
  -- just iterate the section's block_ids and reverse-lookup —
  -- already cleared above.)
  for tool_call_id, block_id in pairs(state.tool_calls) do
    local block = state.blocks[block_id]
    if block ~= nil and block.turn_id == effective_turn_id then
      state.tool_calls[tool_call_id] = nil
    end
  end

  -- Mark every fenced code block in the buffer as foldable (open by
  -- default). Streaming chunks may have completed multiple code
  -- blocks across the turn; sweep once on turn-end to catch them
  -- all. Captain folds via native `zc` / `zM`; no auto-collapse.
  rescan_code_block_folds(state)
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

  -- Cap the cumulative output at 256 KB. Without this, a long-
  -- running tool (cargo build, npm install, etc.) grows `term.output`
  -- unbounded — every chunk concatenated AND every chunk triggers
  -- a full body re-render via `replace_block_body` (O(N²) buffer
  -- churn). Capping keeps the tail (most recent — errors / completion
  -- are what the captain wants to see) and marks the truncated bytes.
  local TERMINAL_OUTPUT_MAX_BYTES = 256 * 1024
  local body_changed = false

  if chunk.kind == "output" then
    if type(chunk.data) == "string" and chunk.data ~= "" then
      term.output = term.output .. chunk.data
      if #term.output > TERMINAL_OUTPUT_MAX_BYTES then
        local elided = #term.output - TERMINAL_OUTPUT_MAX_BYTES
        term.output = string.format("[%d earlier bytes elided]\n", elided) .. term.output:sub(-TERMINAL_OUTPUT_MAX_BYTES)
      end
      body_changed = true
    end
  elseif chunk.kind == "exit" then
    term.exit_code = chunk.exitCode
    term.signal = chunk.signal
    -- Body content doesn't change on exit; just the header. Skip the
    -- expensive body re-render below.
  end

  if body_changed then
    local body
    if term.output == "" then
      body = wrap_in_rules({ { "(no output yet)" } })
    else
      local out_para = { "````console" }
      vim.list_extend(out_para, vim.split(term.output, "\n", { plain = true }))
      table.insert(out_para, "````")
      body = wrap_in_rules({ out_para })
    end
    replace_block_body(state, term._block, body)
  end

  local head_row, tail_row = block_range(state, term._block)

  -- Header rewrite + line-hl reapply only fire when the header
  -- content actually changed (status: running ↔ ok/fail). For
  -- output-only chunks BEFORE exit, the header still reads
  -- "running" and any subsequent output chunk doesn't change it —
  -- skip the buf_set_text + clear/apply_line_hl churn. For output
  -- chunks AFTER exit (late events, race), the header already
  -- locked in its final state — skip too (idempotent).
  local header_needs_repaint = chunk.kind == "exit" or term._header_painted ~= true
  if header_needs_repaint then
    term._header_painted = true
    clear_range_hl(state, head_row, tail_row)
    -- Gate on chunk.kind, NOT on `term.exit_code ~= nil`: a process
    -- killed by signal ships `{kind="exit", exitCode=nil,
    -- signal="SIGTERM"}` — exit_code is nil but the run DID fail.
    -- The `nil == 0` short-circuit picks the Fail branch correctly.
    local header_hl = chunk.kind == "exit" and (term.exit_code == 0 and "HyprpilotToolStatusOk" or "HyprpilotToolStatusFail") or "HyprpilotToolStatusRunning"
    apply_line_hl(state, head_row, header_hl)

    chat_buffer.with_buffer(state.bufnr, function()
      local new_header = terminal_header_line(terminal_id, term.exit_code, term.signal)
      local existing = vim.api.nvim_buf_get_lines(state.bufnr, head_row, head_row + 1, false)[1] or ""
      if existing ~= new_header then
        vim.api.nvim_buf_set_text(state.bufnr, head_row, 0, head_row, #existing, { new_header })
      end
    end)
  end
  local _ = tail_row

  if chunk.kind == "exit" then
    fold_block(state, term._block)
    -- Terminal is done. The visible body lives in the buffer; the
    -- in-memory `term.output` string was only there to feed re-
    -- renders on subsequent output chunks. Drop it so a long-running
    -- session (many terminals over time) doesn't keep megabytes of
    -- already-rendered output strings alive on the state table.
    term.output = ""
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

---Create a manual fold over `[start_row, end_row]` and immediately
---open it — captain ends up with a foldable range they can `zc` on
---demand, but content stays visible by default. Used for fenced
---code blocks in prose where we DON'T want auto-collapse, just the
---ability to fold.
---@param bufnr integer
---@param start_row integer
---@param end_row integer
local function mark_foldable_range(bufnr, start_row, end_row)
  if end_row <= start_row then
    return
  end

  local fold_cmd = string.format("silent! %d,%dfold", start_row + 1, end_row + 1)
  local open_cmd = string.format("silent! %d,%dfoldopen", start_row + 1, end_row + 1)

  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      vim.api.nvim_win_call(winid, function()
        pcall(vim.cmd, fold_cmd)
        pcall(vim.cmd, open_cmd)
      end)
    end
  end
end

---Scan `bufnr`'s lines between `start_row` (inclusive) and `end_row`
---(exclusive — or `-1` for end-of-buffer) for fenced markdown code
---blocks and create open-by-default folds for each pair. Captain
---uses native `zc` / `zM` etc. to collapse. Dedup is naive: we run
---`:fold` blindly, vim discards no-op folds when the range is
---already covered.
---@param bufnr integer
---@param start_row integer
---@param end_row? integer
local function scan_code_block_folds(bufnr, start_row, end_row)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  end_row = end_row or vim.api.nvim_buf_line_count(bufnr)
  if end_row <= start_row then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
  local opening = nil
  for i, line in ipairs(lines) do
    -- A line is a fence open / close when it's exactly three (or more)
    -- backticks optionally followed by a language tag. We don't try
    -- to be fancy about indented fences — chat content uses
    -- column-zero fences from the renderer's `paste_buffer` and the
    -- agent's own prose.
    if line:match("^```") ~= nil then
      if opening == nil then
        opening = i
      else
        local fence_start = start_row + opening - 1
        local fence_end = start_row + i - 1
        mark_foldable_range(bufnr, fence_start, fence_end)
        opening = nil
      end
    end
  end
end

---Walk every prose region we own (turn layouts' anchor rows + their
---ended ranges) and re-mark fenced code blocks as foldable. Called
---from `apply_pending_folds` and `handle_turn_ended` so folds appear
---when the window first shows the buffer + on every turn-end tick.
---Assigned to the forward-declared local at the top of the file.
rescan_code_block_folds = function(state)
  if state == nil then
    return
  end
  scan_code_block_folds(state.bufnr, 0, nil)
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
  if state == nil then
    return
  end

  -- Code-block folds get re-scanned on every window-show so a
  -- newly-opened window picks up folds that landed before the
  -- window existed (`mark_foldable_range` is a no-op when no
  -- window shows the buffer, same constraint as `fold_range`).
  rescan_code_block_folds(state)

  if #state.pending_fold_rows == 0 then
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

---Custom foldtext: returns the head row VERBATIM. Section headers
---(`### thoughts` / `### tools` / etc.) and pilot turn headers
---(`## pilot [123 in/45 out tok · $0.001]`) already carry their stat
---pills written in-line via `repaint_section_header` /
---`repaint_pilot_header` — appending a second `[N items]` chip in
---the foldtext was the regression that hid stats behind a
---duplicated count and pushed pilot pills off-screen on narrow
---chat sidebars. Now the foldtext is the head row, untouched.
---
---The line-count chrome Neovim adds by default is unhelpful for our
---use case (the body of a tool-block fold is the same content the
---captain would expand to read; line count is meaningless context),
---so we deliberately don't append it.
function M.foldtext()
  local fs = vim.v.foldstart or 1
  return vim.fn.getline(fs) or ""
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
