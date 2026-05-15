--- Pinned single-line header buffer above the chat split.
---
--- Replaces the per-window `winbar` (which only painted while the
--- chat window held focus — the moment the captain dropped into the
--- composer below, the bar disappeared). The header lives in its own
--- 1-row split sized via `winfixheight` and shows the same meta the
--- winbar used to: instance state · mode · model · usage · mcps ·
--- activity.
---
--- Public surface:
---   `open()`       — open the header above the chat window
---   `close()`      — tear down the header window (buffer persists)
---   `is_visible()` — split is open + valid
---   `refresh()`    — re-render the header line for the active instance

local buffer = require("hyprpilot.chat.buffer")
local log = require("hyprpilot.log")
local winbar = require("hyprpilot.chat.winbar")
local window = require("hyprpilot.chat.window")

local M = {}

local BUFFER_NAME = "hyprpilot://header"
local NS = vim.api.nvim_create_namespace("hyprpilot.chat.header")

---@type integer?
M._winid = nil

---@type integer?
M._bufnr = nil

---Get-or-create the shared header buffer (one buffer reused across
---instance switches; content is just a single-line string). Adopts
---an existing buffer with the same name when `M._bufnr` got cleared
---but Neovim still holds the buffer alive (post-`shutdown()`
---hot-reload, lazy plugin re-source, etc.) — otherwise
---`nvim_buf_set_name` blows up with `E95: Buffer with this name
---already exists`.
---@return integer
local function ensure_buffer()
  if M._bufnr ~= nil and vim.api.nvim_buf_is_valid(M._bufnr) then
    return M._bufnr
  end

  local existing = require("hyprpilot.chat.buffer").find_by_name(BUFFER_NAME)
  if existing ~= nil then
    M._bufnr = existing
    return existing
  end

  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_name(bufnr, BUFFER_NAME)
  vim.bo[bufnr].filetype = "hyprpilot_header"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].modifiable = false
  require("hyprpilot.chat.buffer").suppress_external_ui(bufnr)

  M._bufnr = bufnr
  return bufnr
end

---True when the header window exists + is valid.
---@return boolean
function M.is_visible()
  if M._winid == nil then
    return false
  end
  if not vim.api.nvim_win_is_valid(M._winid) then
    M._winid = nil
    return false
  end
  return true
end

---Resolve a mode / model id against the `available_*` list. Falls
---back to the id when no entry matches. Returns nil for non-string
---inputs (notably `vim.NIL` from JSON-null fields) so callers don't
---accidentally embed userdata in the rendered line.
---@param id? string
---@param available? table[]
---@return string?
local function display_name(id, available)
  if type(id) ~= "string" or id == "" then
    return nil
  end
  if type(available) == "table" then
    for _, entry in ipairs(available) do
      if type(entry) == "table" and entry.id == id then
        local name = entry.name
        if type(name) == "string" and name ~= "" then
          return name
        end
        return id
      end
    end
  end
  return id
end

--- Reuse the shared token formatter (`chat/stats.format_tokens`) so
--- usage pills here line up with the in-buffer `[Nk/Mk]` chips on the
--- pilot turn header. Returns "0" instead of nil for missing values
--- so the formatter call site stays terse.
---@param n? number
---@return string
local function compact(n)
  return require("hyprpilot.chat.stats").format_tokens(n or 0) or "0"
end

---Resolve the instance-state pill — one glyph + a short label per
---lifecycle state. The pill is the LEFTMOST column so the captain
---reads "is this instance live / booting / ended / errored" before
---parsing anything else. Glyph alone when set; falls back to the
---bare label when the captain cleared the icon (no double-emit).
---Highlight reflects the state's diagnostic palette.
---@param meta? table
---@return string?, string  -- text, hl_group
local function status_pill(meta)
  local state
  if meta ~= nil and type(meta.instance_state) == "string" and meta.instance_state ~= "" then
    state = meta.instance_state
  else
    -- Default to "starting" while we wait for the daemon's first
    -- `state` event — closer to truth than a pre-emptive "running"
    -- and clearly visible (the spinner glyph + DiagnosticInfo color
    -- read as "boot in progress" rather than "live and ready").
    state = "starting"
  end

  local icons = (require("hyprpilot.config").options.icons or {}).instance_state or {}
  local glyph = icons[state]
  local hl_map = {
    starting = "HyprpilotHeaderStatusStarting",
    running = "HyprpilotHeaderStatusRunning",
    ended = "HyprpilotHeaderStatusEnded",
    error = "HyprpilotHeaderStatusError",
  }
  local hl = hl_map[state] or "HyprpilotHeaderState"

  if glyph ~= nil and glyph ~= "" then
    return glyph, hl
  end
  -- No glyph configured — fall back to the bare state label so the
  -- pill is still visible. We never duplicate (glyph + label) because
  -- the icon stands on its own.
  return state, hl
end

---Trailing activity segment — `[<glyph> <label>]` shape, with a
---per-kind highlight (HyprpilotHeaderActivity*). Captain wanted
---this in brackets so it visually reads as "transient state on
---top of the static identity columns" rather than another pill.
---Returns nil text when idle so the segment is skipped entirely.
---@param activity? hyprpilot.Activity
---@return string?, string  -- text, hl_group
local function activity_pill(activity)
  if activity == nil or activity.kind == nil or activity.kind == "idle" then
    return nil, "HyprpilotHeaderActivity"
  end
  local icons = (require("hyprpilot.config").options.icons or {}).activity or {}
  local glyph
  local hl
  local label
  if activity.kind == "tool" then
    glyph = icons.tool
    hl = "HyprpilotHeaderActivityTool"
    label = (type(activity.tool_name) == "string" and activity.tool_name ~= "") and activity.tool_name or "tool"
  elseif activity.kind == "thinking" then
    glyph = icons.thinking
    hl = "HyprpilotHeaderActivityThinking"
    label = "thinking"
  elseif activity.kind == "streaming" then
    glyph = icons.streaming
    hl = "HyprpilotHeaderActivityStreaming"
    label = "streaming"
  elseif activity.kind == "awaiting_permission" then
    glyph = icons.permission
    hl = "HyprpilotHeaderActivityPermission"
    label = "awaiting permission"
  else
    return nil, "HyprpilotHeaderActivity"
  end
  -- Bracketed: `[⚡ streaming]` / `[⚙ Bash]`. Glyph optional —
  -- captains who clear an icon still get the bare `[label]` shape.
  local body
  if glyph ~= nil and glyph ~= "" then
    body = glyph .. " " .. label
  else
    body = label
  end
  return "[" .. body .. "]", hl
end

---Track which instances we've already kicked an `instances/info`
---round-trip for. One-shot per instance so `compose()` doesn't fire
---an RPC on every refresh — the cached name lands on `_meta` and
---subsequent renders pick it up there.
local _name_fetched = {}

---Lazy-hydrate `meta.name` for `instance_id` when the daemon hasn't
---published it on any meta event yet. Fire-and-forget — the `info`
---callback updates `winbar._meta` which triggers a re-render via the
---nudge path.
---@param instance_id string
local function ensure_name(instance_id)
  if _name_fetched[instance_id] then
    return
  end
  _name_fetched[instance_id] = true
  require("hyprpilot.rpc.instances").info(instance_id, function(err, info)
    if err ~= nil or info == nil then
      log.debug("header.ensure_name: instance=%s info failed: %s", instance_id, err and err.message or "no info")
      return
    end
    if info.name ~= nil and info.name ~= "" then
      winbar.update_meta(instance_id, { name = info.name })
      M.refresh()
    end
  end)
end

---@class hyprpilot.chat.header.Segment
---@field text string                 -- segment label (without surrounding · separators)
---@field hl string                   -- highlight group applied to the segment span

---Compose the header line as a list of segments. Each segment has its
---own highlight group so the rendered line picks up per-pill colours
---from `HyprpilotHeader*` (registered in `ui/highlights.lua`).
---Mirrors the UI's `Frame.vue` row-1 layout, minus the cwd / git /
---title (captain explicitly dropped cwd; title isn't plumbed; git
---would need a separate composable). The `hyprpilot` brand stays
---leftmost as the constant anchor.
---Truthy when `v` is a non-empty string. Critically guards against
---`vim.NIL` (userdata sentinel from `vim.json.decode` for JSON null),
---which is `~= nil` in Lua but not a string — feeding it into
---`#seg.text` later crashes with "attempt to get length of a
---userdata value".
---@param v any
---@return boolean
local function is_str(v)
  return type(v) == "string" and v ~= ""
end

---@return hyprpilot.chat.header.Segment[]
local function compose_segments()
  local instance_id = window.active_instance()
  if instance_id == nil then
    return {
      { text = "hyprpilot", hl = "HyprpilotHeaderBrand" },
      { text = "(no instance)", hl = "HyprpilotHeaderEmpty" },
    }
  end

  local meta = winbar._meta[instance_id]

  -- Order (left → right): status · brand · name · profile ·
  -- agent · model · mode · used/size · +N mcps. The status pill
  -- leads because it's the captain's "is this thing alive" check;
  -- brand / name / etc. follow as identifying detail. Activity
  -- moved out of the header entirely — it lives on the composer
  -- now (where the captain is typing) for max visibility. Cwd was
  -- pulled too: redundant with the captain's known working dir +
  -- always shown in the instances palette preview when needed.
  local segments = {}
  local status_text, status_hl = status_pill(meta)
  if is_str(status_text) then
    table.insert(segments, { text = status_text, hl = status_hl })
  end

  table.insert(segments, { text = "hyprpilot", hl = "HyprpilotHeaderBrand" })

  if meta ~= nil then
    if is_str(meta.name) then
      table.insert(segments, { text = meta.name, hl = "HyprpilotHeaderName" })
    else
      ensure_name(instance_id)
    end
    if is_str(meta.profile_id) then
      table.insert(segments, { text = meta.profile_id, hl = "HyprpilotHeaderProfile" })
    end
    if is_str(meta.agent_id) then
      table.insert(segments, { text = meta.agent_id, hl = "HyprpilotHeaderProvider" })
    end

    local model = display_name(meta.current_model_id, meta.available_models)
    if is_str(model) then
      table.insert(segments, { text = model, hl = "HyprpilotHeaderModel" })
    end

    local mode = display_name(meta.current_mode_id, meta.available_modes)
    if is_str(mode) then
      table.insert(segments, { text = mode, hl = "HyprpilotHeaderMode" })
    end

    if meta.usage ~= nil and type(meta.usage) == "table" and (tonumber(meta.usage.size) or 0) > 0 then
      table.insert(segments, {
        text = string.format("%s/%s tok", compact(tonumber(meta.usage.used)), compact(tonumber(meta.usage.size))),
        hl = "HyprpilotHeaderUsage",
      })
    end

    if (tonumber(meta.mcps_count) or 0) > 0 then
      table.insert(segments, { text = string.format("+%d mcps", meta.mcps_count), hl = "HyprpilotHeaderCount" })
    end
  end

  -- Activity comes LAST so the static identity columns (name /
  -- profile / agent / model / mode / usage) stay positionally
  -- stable as the agent's state changes — nothing left of the
  -- bracket shifts when streaming / thinking / tool flips. Reads
  -- the per-instance activity (not the global) so background
  -- instances don't leak their state onto the foreground header.
  local activity = require("hyprpilot.status").activity(instance_id)
  local activity_text, activity_hl = activity_pill(activity)
  if is_str(activity_text) then
    table.insert(segments, { text = activity_text, hl = activity_hl })
  end

  return segments
end

---Stitch `segments` into the rendered line + a parallel list of
---`{ start_col, end_col, hl }` ranges so the caller can paint each
---segment with its own highlight group. Separator `·` glyphs get
---their own range with `HyprpilotHeaderSeparator` so the captain can
---dim them or theme them apart from the segments themselves.
---@param segments hyprpilot.chat.header.Segment[]
---@return string, { start_col: integer, end_col: integer, hl: string }[]
local function render_line(segments)
  local SEP = " · "
  -- Single leading space (no `# ` markdown prefix). We style every
  -- segment via per-range extmarks ourselves; piggybacking on
  -- treesitter's heading highlight would just fight our per-pill
  -- colors. The space gives the leftmost segment a one-column gutter
  -- against the window edge so it doesn't kiss the border.
  local PREFIX = " "
  local pieces = { PREFIX }
  local ranges = {}
  local col = #PREFIX

  -- Filter non-string segment text first so the main loop stays
  -- linear (no goto / continue). `compose_segments` already does
  -- this via `is_str`, but defence in depth — a future caller that
  -- appends a raw `vim.NIL` userdata shouldn't crash `#seg.text`.
  -- Newline-stripping happens at the actual `set_lines` write site
  -- (one chokepoint, no per-layer redundancy).
  local valid = vim.tbl_filter(function(seg)
    return type(seg.text) == "string"
  end, segments)

  for i, seg in ipairs(valid) do
    if i > 1 then
      table.insert(pieces, SEP)
      -- The `·` glyph is U+00B7 → 2 bytes (0xC2 0xB7) in UTF-8.
      -- The previous range covered only 1 byte (mid-character); the
      -- extmark either rejected it or painted half a glyph, so the
      -- separator highlight never showed. Cover both bytes via
      -- `start_col = col + 1`, `end_col = col + 1 + #SEP_GLYPH`.
      local SEP_GLYPH = "·"
      table.insert(ranges, { start_col = col + 1, end_col = col + 1 + #SEP_GLYPH, hl = "HyprpilotHeaderSeparator" })
      col = col + #SEP
    end
    table.insert(pieces, seg.text)
    table.insert(ranges, { start_col = col, end_col = col + #seg.text, hl = seg.hl })
    col = col + #seg.text
  end

  return table.concat(pieces), ranges
end

---Re-render the header line. Cheap; called whenever meta / activity /
---active instance changes. Paints per-segment highlights so each pill
---(brand / name / profile / provider / model / mode / usage / count /
---activity) gets its own colour via the `HyprpilotHeader*` groups.
---No-op when the header isn't visible.
function M.refresh()
  if M._bufnr == nil or not vim.api.nvim_buf_is_valid(M._bufnr) then
    return
  end

  local segments = compose_segments()
  local line, ranges = render_line(segments)

  buffer.with_buffer(M._bufnr, function()
    -- Header is one buffer row by design — strip `\r\n` so a
    -- daemon-supplied segment with embedded newlines (rare but
    -- happens with multi-line tool / model names) doesn't crash
    -- `nvim_buf_set_lines` with "'replacement string' item
    -- contains newlines". Single chokepoint: every render path
    -- ends up here, no per-layer sanitisation needed upstream.
    -- Stripping (vs splitting) preserves the row count + keeps
    -- the per-segment extmark column ranges valid (newline → space
    -- is byte-for-byte).
    local safe_line = line:gsub("[\r\n]", " ")
    vim.api.nvim_buf_set_lines(M._bufnr, 0, -1, false, { safe_line })
    vim.api.nvim_buf_clear_namespace(M._bufnr, NS, 0, -1)
    -- Background fill for the whole row + per-segment highlights on
    -- top. `line_hl_group` sets the trailing background so the bar
    -- reads as a cohesive band instead of segment-shaped islands.
    vim.api.nvim_buf_set_extmark(M._bufnr, NS, 0, 0, { line_hl_group = "HyprpilotHeader" })
    -- Priority bump: the line starts with `# ` so the markdown
    -- treesitter parser highlights it as H1 (`@markup.heading.1` →
    -- `Title`) at the standard treesitter priority of 100. Default
    -- extmark `priority` is 4096 in current Neovim, but explicit
    -- 200 makes the override behavior intentional and survives any
    -- future Neovim default change. Without this, every segment
    -- inherits the heading colour and per-pill highlights vanish.
    for _, range in ipairs(ranges) do
      vim.api.nvim_buf_set_extmark(M._bufnr, NS, 0, range.start_col, {
        end_col = range.end_col,
        hl_group = range.hl,
        priority = 200,
      })
    end
  end)
end

---Open the header window above the chat split. Idempotent: if already
---visible, just refreshes the line.
function M.open()
  if not window.is_visible() then
    log.debug("header.open: chat window not visible, skipping")
    return
  end

  local bufnr = ensure_buffer()

  if M.is_visible() then
    if vim.api.nvim_win_get_buf(M._winid) ~= bufnr then
      vim.api.nvim_win_set_buf(M._winid, bufnr)
    end
    M.refresh()
    return
  end

  local winid, err = require("hyprpilot.chat.buffer").open_aux_split({
    direction = "aboveleft 1split",
    bufnr = bufnr,
    after = function(w)
      vim.wo[w].wrap = false
      vim.wo[w].winhighlight = "Normal:HyprpilotHeader"
      if buffer.layout_manager_active() then
        -- Cooperate with edgy: set its dynamic-sizing hook to 1 row
        -- so adopted layouts honour our intent. The captain's slot
        -- config (`size = { height = 1 }`, `wo = { winbar = false }`)
        -- also feeds in; this hook wins on the per-window read.
        pcall(function()
          vim.w[w].edgy_height = 1
        end)
        -- `layout()` triggers resize + apply_size; `update()` doesn't.
        pcall(function()
          require("edgy.layout").layout()
        end)
      else
        -- Lock to one row. `winfixheight` protects against
        -- `equalalways` redistributing height when sibling splits
        -- open; `nvim_win_set_height` still works through the pin.
        vim.wo[w].winfixheight = true
        vim.wo[w].winfixwidth = true
        vim.api.nvim_win_set_height(w, 1)
      end
    end,
  })
  if winid == nil then
    log.warn("header.open: %s", err)
    return
  end

  M._winid = winid
  M.refresh()
end

---Close the header window. Buffer persists for next open.
function M.close()
  if not M.is_visible() then
    return
  end

  pcall(vim.api.nvim_win_close, M._winid, true)
  M._winid = nil
end

local listeners_wired = false

---Wire the autocmds that drive `refresh()` (idempotent).
---
---Critical filter: Meta and Activity events for *non-active*
---instances no longer trigger a header repaint. Without this, every
---meta tick or tool-call on a background instance would re-render
---the captain's foreground header even though the rendered line
---only ever reads the active instance's state — visible flicker on
---slow terminals, wasted CPU at scale.
function M.ensure_listeners()
  if listeners_wired then
    return
  end
  listeners_wired = true

  local group = vim.api.nvim_create_augroup("HyprpilotHeader", { clear = true })

  -- InstanceChanged always refreshes (the active instance flipped,
  -- everything is stale by definition).
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "HyprpilotInstanceChanged",
    callback = function()
      M.refresh()
    end,
  })

  -- Meta + activity events filter on instance_id == active so we
  -- only repaint when the change is actually visible.
  for _, pattern in ipairs({ "HyprpilotInstanceMetaChanged", "HyprpilotActivityChanged" }) do
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = pattern,
      callback = function(args)
        local data = args.data or {}
        if data.instance_id ~= nil and data.instance_id ~= window.active_instance() then
          return
        end
        M.refresh()
      end,
    })
  end
end

---Drop the cached `_name_fetched` flag for `instance_id` so a future
---instance that reuses the id (daemon-side resume, manual recreate)
---re-runs the `instances/info` round-trip rather than reading the
---stale "we already fetched this" sentinel. Called from
---`window.close`.
---@param instance_id string
function M.forget(instance_id)
  _name_fetched[instance_id] = nil
end

return M
