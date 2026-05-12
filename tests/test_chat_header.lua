--- Behavioural tests for the pinned chat header. We exercise the
--- segment composition + per-segment highlight ranges directly
--- against the header buffer (no real chat window needed).

local T = MiniTest.new_set()

local NS = vim.api.nvim_create_namespace("hyprpilot.chat.header")

---Force the chat window's active-instance lookup to a known id.
---@param instance_id string?
---@return fun()
local function stub_active_instance(instance_id)
  local window = require("hyprpilot.chat.window")
  local original = window.active_instance
  window.active_instance = function()
    return instance_id
  end
  return function()
    window.active_instance = original
  end
end

---Stub `instances.info` so the header's lazy name-fetch path doesn't
---fire a real `client.request` (which would leave state on the
---global client and poison subsequent tests).
---@return fun()
local function stub_instances_info()
  local instances = require("hyprpilot.instances")
  local original = instances.info
  instances.info = function(_id, callback)
    if callback ~= nil then
      callback({ kind = "transport", message = "stubbed in test" }, nil)
    end
  end
  return function()
    instances.info = original
  end
end

---Mint a header buffer with the same shape `header.ensure_buffer`
---would, so we can call `refresh()` without opening the chat window.
---@return integer
local function mint_header_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "hyprpilot://header")
  vim.bo[bufnr].filetype = "hyprpilot_header"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].modifiable = false
  return bufnr
end

---Drop cached header state so each test starts clean.
local function reset_header()
  local header = require("hyprpilot.chat.header")
  if header._winid and vim.api.nvim_win_is_valid(header._winid) then
    pcall(vim.api.nvim_win_close, header._winid, true)
  end
  header._winid = nil
  if header._bufnr and vim.api.nvim_buf_is_valid(header._bufnr) then
    pcall(vim.api.nvim_buf_delete, header._bufnr, { force = true })
  end
  header._bufnr = nil
end

T["header.refresh renders the hyprpilot brand + per-segment highlights"] = function()
  reset_header()
  local restore_active = stub_active_instance("inst-1")
  local restore_info = stub_instances_info()

  local winbar = require("hyprpilot.chat.winbar")
  winbar._meta["inst-1"] = {
    name = "main",
    profile_id = "personal/claude/opus",
    agent_id = "claude-code",
    current_mode_id = "edit",
    current_model_id = "opus",
    available_modes = { { id = "edit", name = "Edit" } },
    available_models = { { id = "opus", name = "Opus" } },
    usage = { used = 12345, size = 200000 },
    mcps_count = 3,
  }

  local header = require("hyprpilot.chat.header")
  header._bufnr = mint_header_buffer()
  header.refresh()

  local line = vim.api.nvim_buf_get_lines(header._bufnr, 0, 1, false)[1] or ""

  MiniTest.expect.equality(line:find("hyprpilot", 1, true) ~= nil, true)
  MiniTest.expect.equality(line:find("main", 1, true) ~= nil, true)
  MiniTest.expect.equality(line:find("personal/claude/opus", 1, true) ~= nil, true)
  MiniTest.expect.equality(line:find("claude-code", 1, true) ~= nil, true)
  MiniTest.expect.equality(line:find("Opus", 1, true) ~= nil, true)
  MiniTest.expect.equality(line:find("Edit", 1, true) ~= nil, true)
  -- Shared `chat.stats.format_tokens` (Math.round-like): 12345 → `12k`,
  -- 200000 → `200k`.
  MiniTest.expect.equality(line:find("12k/200k tok", 1, true) ~= nil, true)
  MiniTest.expect.equality(line:find("+3 mcps", 1, true) ~= nil, true)

  -- Per-segment highlight groups landed via extmarks.
  local marks = vim.api.nvim_buf_get_extmarks(header._bufnr, NS, 0, -1, { details = true })
  local seen = {}
  for _, m in ipairs(marks) do
    local details = m[4] or {}
    if details.hl_group then
      seen[details.hl_group] = true
    end
  end
  MiniTest.expect.equality(seen.HyprpilotHeaderBrand, true)
  MiniTest.expect.equality(seen.HyprpilotHeaderName, true)
  MiniTest.expect.equality(seen.HyprpilotHeaderProfile, true)
  MiniTest.expect.equality(seen.HyprpilotHeaderProvider, true)
  MiniTest.expect.equality(seen.HyprpilotHeaderModel, true)
  MiniTest.expect.equality(seen.HyprpilotHeaderMode, true)
  MiniTest.expect.equality(seen.HyprpilotHeaderUsage, true)
  MiniTest.expect.equality(seen.HyprpilotHeaderCount, true)
  MiniTest.expect.equality(seen.HyprpilotHeaderSeparator, true)

  winbar._meta["inst-1"] = nil
  restore_info()
  restore_active()
  reset_header()
end

T["header.refresh with no active instance shows `(no instance)` pill"] = function()
  reset_header()
  local restore_active = stub_active_instance(nil)
  local restore_info = stub_instances_info()

  local header = require("hyprpilot.chat.header")
  header._bufnr = mint_header_buffer()
  header.refresh()

  local line = vim.api.nvim_buf_get_lines(header._bufnr, 0, 1, false)[1] or ""
  MiniTest.expect.equality(line:find("hyprpilot", 1, true) ~= nil, true)
  MiniTest.expect.equality(line:find("(no instance)", 1, true) ~= nil, true)

  restore_info()
  restore_active()
  reset_header()
end

T["header.refresh tolerates vim.NIL in meta (JSON-null wire fields)"] = function()
  -- Regression for snapshot replays where the daemon ships explicit
  -- nulls for unset Optional<String> fields — `vim.json.decode` maps
  -- those to `vim.NIL` (userdata), not Lua nil. Without strict
  -- type-string guards, `#seg.text` blew up with
  -- "attempt to get length of a userdata value" inside `render_line`.
  reset_header()
  local restore_active = stub_active_instance("inst-nil")
  local restore_info = stub_instances_info()

  local winbar = require("hyprpilot.chat.winbar")
  winbar._meta["inst-nil"] = {
    -- vim.NIL is what vim.json.decode produces for JSON `null`.
    name = vim.NIL,
    profile_id = vim.NIL,
    agent_id = "claude-code",
    current_mode_id = vim.NIL,
    current_model_id = vim.NIL,
    available_modes = {},
    available_models = {},
    usage = vim.NIL,
    mcps_count = 0,
    instance_state = vim.NIL,
  }

  local header = require("hyprpilot.chat.header")
  header._bufnr = mint_header_buffer()

  -- The bug: this used to crash with `attempt to get length of field
  -- 'text' (a userdata value)`. After the fix, it must complete and
  -- render only the segments that have valid string data.
  local ok = pcall(header.refresh)
  MiniTest.expect.equality(ok, true)

  local line = vim.api.nvim_buf_get_lines(header._bufnr, 0, 1, false)[1] or ""
  MiniTest.expect.equality(line:find("hyprpilot", 1, true) ~= nil, true)
  MiniTest.expect.equality(line:find("claude-code", 1, true) ~= nil, true)
  -- vim.NIL fields didn't sneak in as `userdata` strings.
  MiniTest.expect.equality(line:find("vim.NIL", 1, true), nil)
  MiniTest.expect.equality(line:find("userdata", 1, true), nil)

  winbar._meta["inst-nil"] = nil
  restore_info()
  restore_active()
  reset_header()
end

T["header.refresh paints activity pill with its specific highlight group"] = function()
  reset_header()
  local restore_active = stub_active_instance("inst-2")
  local restore_info = stub_instances_info()

  local winbar = require("hyprpilot.chat.winbar")
  winbar._meta["inst-2"] = { name = "alt", agent_id = "claude-code" }

  require("hyprpilot.status").set_activity({ kind = "streaming" })

  local header = require("hyprpilot.chat.header")
  header._bufnr = mint_header_buffer()
  header.refresh()

  local marks = vim.api.nvim_buf_get_extmarks(header._bufnr, NS, 0, -1, { details = true })
  local has_streaming_pill = false
  for _, m in ipairs(marks) do
    if m[4] and m[4].hl_group == "HyprpilotHeaderActivityStreaming" then
      has_streaming_pill = true
    end
  end
  MiniTest.expect.equality(has_streaming_pill, true)

  require("hyprpilot.status").set_activity({ kind = "idle" })
  winbar._meta["inst-2"] = nil
  restore_info()
  restore_active()
  reset_header()
end

return T
