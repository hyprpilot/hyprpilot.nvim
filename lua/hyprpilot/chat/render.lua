--- Chat-buffer renderer.
---
--- Per-instance state holds the current turn id, the running text
--- block (so streamed agent chunks append to the same line), and the
--- monotonic `seq` cursor for snapshot pagination. Block IDs come
--- from the daemon's seq + an internal counter for synthesized blocks
--- (turn header, error, etc.).
---
--- Block kinds in v1: `turn_header`, `agent_text`, `agent_thought`,
--- `user_message`, `placeholder`. Tool calls / plans / permissions
--- land as `placeholder` here; a follow-up PR ships proper rendering.

local chat_buffer = require("hyprpilot.chat.buffer")
local log = require("hyprpilot.log")

local M = {}

---@alias hyprpilot.render.BlockKind
---| "turn_header"
---| "agent_text"
---| "agent_thought"
---| "user_message"
---| "placeholder"

---@class hyprpilot.render.Block
---@field kind hyprpilot.render.BlockKind
---@field turn_id? string

---@class hyprpilot.render.State
---@field bufnr integer
---@field instance_id string
---@field current_turn? string
---@field active_text_block? hyprpilot.render.Block  -- the open `agent_text` block accepting chunks
---@field last_seq? integer

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

  local state = {
    bufnr = bufnr,
    instance_id = instance_id,
  }

  M._states[instance_id] = state

  return state
end

---Drop the render state for an instance (used when the buffer is wiped).
---@param instance_id string
function M.forget(instance_id)
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

  -- An empty buffer line-counts as 1 (a single blank line). Treat
  -- that as "buffer is empty" so the first written content lands at
  -- the top instead of after a phantom blank.
  if total == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, lines)
    first_line = 0
  else
    vim.api.nvim_buf_set_lines(bufnr, total, total, false, lines)
    first_line = total
  end

  return first_line
end

---Append a turn header (`## agent`, `## user`) and reset the active
---text block tracker.
---@param state hyprpilot.render.State
---@param role "agent" | "user"
---@param turn_id? string
local function append_turn_header(state, role, turn_id)
  chat_buffer.with_buffer(state.bufnr, function()
    -- A blank line before the header keeps adjacent turns visually
    -- separated except for the very first one.
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

---Append `text` to the buffer's current `agent_text` block. Opens a
---new block at the end of the buffer when one isn't already active.
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

    -- Append at end-of-buffer: split the text on \n, glue the first
    -- chunk onto the buffer's last line, push the rest as fresh lines.
    local chunks = vim.split(text, "\n", { plain = true })
    local last_row = vim.api.nvim_buf_line_count(bufnr) - 1
    local last_line = vim.api.nvim_buf_get_lines(bufnr, last_row, last_row + 1, false)[1] or ""

    vim.api.nvim_buf_set_lines(bufnr, last_row, last_row + 1, false, { last_line .. chunks[1] })

    if #chunks > 1 then
      vim.api.nvim_buf_set_lines(bufnr, last_row + 1, last_row + 1, false, vim.list_slice(chunks, 2))
    end
  end)
end

---Append a labeled placeholder line. Used for transcript variants
---we don't render properly yet (tool calls, plans, permissions);
---they show up as `(tool_call: bash)` until the follow-up PR fills
---the kinds in.
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
    append_placeholder(state, "thought", (item.text or ""):sub(1, 60))
  elseif kind == "tool_call" then
    local rec = item or {}
    append_placeholder(state, "tool", (rec.title and tostring(rec.title)) or rec.toolKind or "?")
  elseif kind == "tool_call_update" then
    -- updates land in v1 as no-op text; PR B threads them into a fold
    log.debug("render: tool_call_update (deferred to next PR)")
  elseif kind == "plan" then
    append_placeholder(state, "plan")
  elseif kind == "permission_request" then
    append_placeholder(state, "permission", item.tool)
  elseif kind == "agent_attachment" then
    append_placeholder(state, "attachment")
  elseif kind == "unknown" then
    append_placeholder(state, "unknown", item.wireKind)
  else
    append_placeholder(state, "unhandled", kind)
  end
end

---Replay every item from a snapshot (`instance/snapshot/chat`).
---Wipes the buffer contents first so re-shows are clean.
---@param state hyprpilot.render.State
---@param snapshot { items: table[], oldestSeq?: integer, latestSeq?: integer, hasMore?: boolean }
function M.hydrate(state, snapshot)
  chat_buffer.with_buffer(state.bufnr, function()
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
  end)

  state.current_turn = nil
  state.active_text_block = nil
  state.last_seq = snapshot.latestSeq

  for _, entry in ipairs(snapshot.items or {}) do
    M.render_item(state, entry.turnId, entry.item)
  end
end

---Live `transcript` event handler. Renders the item if it belongs to
---an instance we're tracking.
---@param event table
function M.handle_transcript(event)
  local state = M._states[event.instanceId]

  if state == nil then
    return
  end

  M.render_item(state, event.turnId, event.item)
end

---Live `turn_started` event handler. Opens an agent header so
---incoming `agent_text` chunks land under the right boundary.
---@param event table
function M.handle_turn_started(event)
  local state = M._states[event.instanceId]

  if state == nil then
    return
  end

  append_turn_header(state, "agent", event.turnId)
end

---Live `turn_ended` event handler. Adds an inline elapsed/error chip
---via virt_text on the turn header line.
---@param event table
function M.handle_turn_ended(event)
  local state = M._states[event.instanceId]

  if state == nil then
    return
  end

  state.active_text_block = nil

  if state.current_turn == event.turnId then
    state.current_turn = nil
  end

  local chip
  if event.error ~= nil then
    chip = "✗ " .. event.error
  elseif event.stopReason ~= nil then
    chip = "✓ " .. event.stopReason
  end

  if chip == nil then
    return
  end

  -- Anchor the chip on the buffer's last non-empty line.
  local bufnr = state.bufnr
  local total = vim.api.nvim_buf_line_count(bufnr)
  local row = math.max(0, total - 1)

  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
    virt_text = { { " " .. chip, "Comment" } },
    virt_text_pos = "eol",
  })
end

return M
