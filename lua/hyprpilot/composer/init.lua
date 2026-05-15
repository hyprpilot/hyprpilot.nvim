--- Composer — separate input buffer in a sub-split below the chat
--- window. One composer buffer per instance so drafts persist across
--- instance switching.
---
--- Public surface:
---   `open()` / `close()` / `toggle()` / `is_visible()`
---   `submit(text?, opts?)` — defaults `text` to the composer's contents
---   `cancel()` — sends `prompts/cancel` to the active instance
---   `attach(opts)` / `detach(slug, opts?)` / `attachments(instance_id?)`
---   `attach_buffer(bufnr?, opts?)` — attach the buffer's file path
---   `attach_clipboard_image(opts?)` — wraps img-clip (when available)
---   `clear_attachments(instance_id?)` — drop every staged attachment
---   `paste_buffer(bufnr?, opts?)` — append the buffer's contents as a
---     fenced block (header = cwd-relative path)
---   `paste_selection(opts?)` — append the last visual selection as a
---     fenced block (header = `path:start-end`)

local client = require("hyprpilot.client")
local config = require("hyprpilot.config")
local log = require("hyprpilot.log")
local window = require("hyprpilot.chat.window")

local M = {}

---@class hyprpilot.composer.Attachment
---@field slug string
---@field path string
---@field title? string
---@field mime? string
---@field body? string
---@field data? string  -- base64 for binary blobs

---@type table<string, integer>
local buffers = {}

---@type table<string, hyprpilot.composer.Attachment[]>
local attachments_by_instance = {}

---@type integer?
M._winid = nil

local INDICATOR_NS = vim.api.nvim_create_namespace("hyprpilot.composer.attachments")
--- Distinct namespace for the activity strip so attachment repaints
--- (which clear `INDICATOR_NS`) don't wipe the activity line and
--- vice-versa. One row of virt_text painted at the top of the
--- composer buffer when the bound instance is non-idle.
local ACTIVITY_NS = vim.api.nvim_create_namespace("hyprpilot.composer.activity")

---Forward-declared so `ensure_buffer`'s TextChanged autocmd can call
---it (the body anchors virt_lines to the current last line, so every
---edit needs a reposition to keep attachments at the bottom).
---@type fun(instance_id: string)
local paint_indicator

---Forward-declared activity painter — fires from the per-buffer
---HyprpilotActivityChanged listener and from `M.open` so a fresh
---open shows the current activity immediately rather than waiting
---for the next event tick.
---@type fun(instance_id: string)
local paint_activity

---Resolve a config height field (`min_height` or `max_height`). The
---field can be `integer` (constant), a `fun(lines: number)` (passed
---`vim.o.lines`), or nil. Returns the floor-1 line count. `fallback`
---kicks in for nil / invalid values.
---@param field "min_height" | "max_height"
---@param fallback integer
---@return integer
local function resolve_height_field(field, fallback)
  local raw = (config.options.composer or {})[field]

  if type(raw) == "function" then
    local ok, value = pcall(raw, vim.o.lines)
    if ok and type(value) == "number" then
      return math.max(1, math.floor(value))
    end
    log.warn("composer: %s function returned %s; falling back to %d", field, vim.inspect(value), fallback)
    return fallback
  end

  if type(raw) == "number" then
    return math.max(1, math.floor(raw))
  end

  return fallback
end

---@return integer
local function resolve_min_height()
  return resolve_height_field("min_height", 8)
end

---@return integer
local function resolve_max_height()
  return resolve_height_field("max_height", math.max(8, math.floor(vim.o.lines * 0.4)))
end

---Reverse-lookup the instance id that owns a composer bufnr.
---Called from `compute_target_height` so attachment virt_lines can
---factor into the auto-resize budget. `buffers` is small (one entry
---per live instance) so the linear scan stays cheap.
---@param bufnr integer
---@return string?
local function instance_id_for_buffer(bufnr)
  for id, b in pairs(buffers) do
    if b == bufnr then
      return id
    end
  end
  return nil
end

---Compute the ideal composer window height: clamp(content_lines +
---attachment_rows, min_height, max_height). Attachment rows render
---as virt_lines below the last buffer line (see `paint_indicator`),
---so the window has to grow to fit them — otherwise the captain
---never sees the list. When `content_lines + attachments` exceeds
---`max_height`, the window stays capped and the captain's writing
---area shrinks to make room for the attachment rows.
---@param bufnr integer
---@return integer
local function compute_target_height(bufnr)
  local min_h = resolve_min_height()
  local max_h = resolve_max_height()
  if max_h < min_h then
    max_h = min_h
  end

  local content_lines = vim.api.nvim_buf_line_count(bufnr)
  -- nvim_buf_line_count returns 1 for an empty buffer; treat that as 0.
  if content_lines == 1 and (vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or "") == "" then
    content_lines = 0
  end

  local instance_id = instance_id_for_buffer(bufnr)
  local attachment_rows = instance_id ~= nil and #(attachments_by_instance[instance_id] or {}) or 0
  local total = content_lines + attachment_rows

  if total < min_h then
    return min_h
  end
  if total > max_h then
    return max_h
  end
  return total
end

---Resize the composer window to fit its content, clamped to
---[min_height, max_height]. No-op when the window isn't visible.
function M.resize()
  if M._winid == nil or not vim.api.nvim_win_is_valid(M._winid) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(M._winid)
  local target = compute_target_height(bufnr)
  if vim.api.nvim_win_get_height(M._winid) ~= target then
    pcall(vim.api.nvim_win_set_height, M._winid, target)
  end
end

---Get-or-create the per-instance composer buffer.
---@param instance_id string
---@return integer bufnr
---Apply one action's keymaps onto `bufnr`. `spec` is either `false`
---(disabled), or `{ normal = ..., insert = ... }` where each value is
---a string, a list of strings, or `false` (disabled per-mode).
---@param bufnr integer
---@param spec hyprpilot.ConfigComposerKeymapAction | false | nil
---@param handler fun(): nil
---@param desc string
local function apply_action(bufnr, spec, handler, desc)
  if spec == false or spec == nil then
    log.debug("composer.apply_action: skipping %s (spec is %s)", desc, vim.inspect(spec))
    return
  end

  local mode_keys = { n = spec.normal, i = spec.insert }

  for mode, keys in pairs(mode_keys) do
    if keys ~= false then
      if type(keys) == "string" then
        keys = { keys }
      end

      for _, key in ipairs(keys) do
        vim.keymap.set(mode, key, handler, { buffer = bufnr, desc = "hyprpilot: " .. desc })
        log.debug("composer.apply_action: bound %s key=%s mode=%s bufnr=%s", desc, key, mode, bufnr)
      end
    end
  end
end

local function ensure_buffer(instance_id)
  local existing = buffers[instance_id]

  if existing ~= nil and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end

  -- Adopt an existing buffer with the same name when the in-module
  -- `buffers[instance_id]` reference got cleared but Neovim still
  -- holds the buffer alive (post-`shutdown()` hot-reload, etc.) —
  -- otherwise `nvim_buf_set_name` raises E95.
  local name = "hyprpilot://composer/" .. instance_id
  local adopted = require("hyprpilot.chat.buffer").find_by_name(name)
  if adopted ~= nil then
    buffers[instance_id] = adopted
    return adopted
  end

  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].filetype = "hyprpilot_input"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false
  require("hyprpilot.chat.buffer").suppress_external_ui(bufnr)

  local keymaps = (config.options.composer or {}).keymaps or {}

  -- Closure-capture `instance_id` at bind time — never re-resolve via
  -- `window.active_instance()` at fire time. The composer buffer for
  -- A could become focused while B is the active instance (manual
  -- `:b hyprpilot://composer/<id>`, layout-manager adoption, race
  -- between switch and a queued keystroke); without the bound id,
  -- submit / cancel would route to the wrong instance.
  apply_action(bufnr, keymaps.submit, function()
    M.submit(nil, { instance_id = instance_id })
  end, "submit composer prompt")

  apply_action(bufnr, keymaps.cancel, function()
    M.cancel(instance_id)
  end, "cancel in-flight turn")

  apply_action(bufnr, keymaps.close, function()
    M.close()
  end, "close composer split")

  -- Repaint the attachment indicator (whose virt_lines are anchored
  -- to the current last buffer line) and re-resize the window on
  -- every edit. `paint_indicator` calls `M.resize` itself, so this
  -- one callback covers both reposition + auto-grow paths.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    buffer = bufnr,
    callback = function()
      paint_indicator(instance_id)
    end,
  })

  -- Per-instance autocmd group for activity strip refresh. Filtering
  -- on `data.instance_id == instance_id` is the key multi-instance
  -- isolation guard: B's tool call must NOT repaint A's composer
  -- activity strip even though both listen on the same
  -- `User HyprpilotActivityChanged` pattern.
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("HyprpilotComposerActivity:" .. instance_id, { clear = true }),
    pattern = "HyprpilotActivityChanged",
    callback = function(args)
      local data = args.data or {}
      if data.instance_id ~= instance_id then
        return
      end
      paint_activity(instance_id)
    end,
  })

  buffers[instance_id] = bufnr

  return bufnr
end

---Derive a stable slug from a file path. Falls back to the basename
---when uniqueness in the staging list lets it stand on its own.
---@param path string
---@param existing hyprpilot.composer.Attachment[]
---@return string
local function slug_from_path(path, existing)
  local base = vim.fs.basename(path) or path
  local taken = {}
  for _, a in ipairs(existing) do
    taken[a.slug] = true
  end

  if not taken[base] then
    return base
  end

  local i = 2
  while taken[base .. "-" .. i] do
    i = i + 1
  end
  return base .. "-" .. i
end

---Best-effort MIME guess from a path's extension. Returns nil when
---we can't tell — the daemon will fall through to its own
---`mime_guess` based on extension anyway.
---@param path string
---@return string?
local function guess_mime(path)
  local ext = (path:match("%.([%w]+)$") or ""):lower()
  if ext == "" then
    return nil
  end

  local map = {
    png = "image/png",
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    gif = "image/gif",
    webp = "image/webp",
    svg = "image/svg+xml",
    pdf = "application/pdf",
    md = "text/markdown",
    txt = "text/plain",
    json = "application/json",
    yaml = "application/yaml",
    yml = "application/yaml",
    toml = "application/toml",
    lua = "text/x-lua",
    py = "text/x-python",
    rs = "text/x-rust",
    ts = "text/typescript",
    js = "text/javascript",
    go = "text/x-go",
    sh = "application/x-sh",
  }

  return map[ext]
end

---Repaint the per-instance attachment list as a stack of virt_lines
---below the composer's last real line. Each attachment takes one
---row so more attachments → more rows eating into the writing area.
---No-op when the composer buffer doesn't exist yet. Triggers
---`M.resize` afterwards so the window grows / shrinks to fit.
---@param instance_id string
---Resolve the activity glyph + label for a kind. Reads
---`config.icons.activity` (captain-overridable; ASCII fallbacks
---kick in when a key is empty / missing).
---@param kind string
---@param tool_name? string
---@return string?, string  -- text, hl_group
local function activity_text(kind, tool_name)
  if kind == nil or kind == "idle" then
    return nil, "HyprpilotComposerActivity"
  end
  local icons = (require("hyprpilot.config").options.icons or {}).activity or {}
  local glyph
  local hl
  local label
  if kind == "tool" then
    glyph = icons.tool
    hl = "HyprpilotComposerActivityTool"
    label = (type(tool_name) == "string" and tool_name ~= "") and tool_name or "tool"
  elseif kind == "thinking" then
    glyph = icons.thinking
    hl = "HyprpilotComposerActivityThinking"
    label = "thinking"
  elseif kind == "streaming" then
    glyph = icons.streaming
    hl = "HyprpilotComposerActivityStreaming"
    label = "streaming"
  elseif kind == "awaiting_permission" then
    glyph = icons.permission
    hl = "HyprpilotComposerActivityPermission"
    label = "awaiting permission"
  else
    return nil, "HyprpilotComposerActivity"
  end
  -- Glyph + label together ("⚙ tool · Bash"). Captains who clear an
  -- icon (set to "") get the bare label so the indicator stays
  -- legible in nerd-font-less terminals.
  if glyph ~= nil and glyph ~= "" then
    return glyph .. " " .. label, hl
  end
  return label, hl
end

paint_activity = function(instance_id)
  local bufnr = buffers[instance_id]
  if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ACTIVITY_NS, 0, -1)

  local activity = require("hyprpilot.status").activity(instance_id)
  if activity == nil or activity.kind == "idle" then
    return
  end

  local text, hl = activity_text(activity.kind, activity.tool_name)
  if text == nil then
    return
  end

  -- Anchor the activity strip at row 0, virt_lines_above = true so it
  -- sits ABOVE the captain's first writable row. One line of virt
  -- text — doesn't consume buffer rows, doesn't shift the cursor.
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ACTIVITY_NS, 0, 0, {
    virt_lines = { { { text, hl } } },
    virt_lines_above = true,
  })
end

paint_indicator = function(instance_id)
  local bufnr = buffers[instance_id]
  if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, INDICATOR_NS, 0, -1)

  local list = attachments_by_instance[instance_id] or {}
  if #list ~= 0 then
    local virt_lines = vim.tbl_map(function(a)
      local label = a.title ~= nil and a.title ~= "" and a.title or a.slug
      return { { "  - " .. label, "HyprpilotComposerAttachments" } }
    end, list)

    local last_line = math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, INDICATOR_NS, last_line, 0, {
      virt_lines = virt_lines,
    })
  end

  M.resize()
end

---Resolve which instance to operate on. Defaults to the active
---instance; logs + returns nil when none.
---@param instance_id? string
---@param caller string
---@return string?
local function resolve_instance(instance_id, caller)
  local id = instance_id or window.active_instance()

  if id == nil then
    log.warn("composer.%s: no active instance", caller)
    return nil
  end

  return id
end

---Stage an attachment on the active (or named) instance's composer.
---@param opts { path: string, instance_id?: string, slug?: string, title?: string, mime?: string, body?: string, data?: string }
---@return hyprpilot.composer.Attachment?
function M.attach(opts)
  if type(opts) ~= "table" then
    log.warn("composer.attach: opts must be a table")
    return nil
  end

  if type(opts.path) ~= "string" or opts.path == "" then
    log.warn("composer.attach: opts.path is required")
    return nil
  end

  local id = resolve_instance(opts.instance_id, "attach")
  if id == nil then
    return nil
  end

  local list = attachments_by_instance[id] or {}
  local slug = opts.slug or slug_from_path(opts.path, list)

  ---@type hyprpilot.composer.Attachment
  local entry = {
    slug = slug,
    path = opts.path,
    title = opts.title or vim.fs.basename(opts.path),
    mime = opts.mime or guess_mime(opts.path),
    body = opts.body,
    data = opts.data,
  }

  -- De-dupe by slug — a re-attach with the same slug refreshes the
  -- entry rather than appending a stale duplicate.
  for i, existing in ipairs(list) do
    if existing.slug == slug then
      list[i] = entry
      attachments_by_instance[id] = list
      paint_indicator(id)
      log.debug("composer.attach: refreshed slug=%s on instance=%s", slug, id)
      return entry
    end
  end

  table.insert(list, entry)
  attachments_by_instance[id] = list
  paint_indicator(id)

  log.debug("composer.attach: instance=%s slug=%s path=%s", id, slug, opts.path)

  return entry
end

---Drop the attachment with `slug` from the active (or named)
---instance's composer.
---@param slug string
---@param opts? { instance_id?: string }
function M.detach(slug, opts)
  if type(slug) ~= "string" or slug == "" then
    log.warn("composer.detach: slug must be a non-empty string")
    return
  end

  local id = resolve_instance((opts or {}).instance_id, "detach")
  if id == nil then
    return
  end

  local list = attachments_by_instance[id] or {}
  for i, entry in ipairs(list) do
    if entry.slug == slug then
      table.remove(list, i)
      paint_indicator(id)
      log.debug("composer.detach: instance=%s slug=%s", id, slug)
      return
    end
  end

  log.debug("composer.detach: instance=%s slug=%s not found", id, slug)
end

---Wipe every staged attachment for an instance. Defaults to active.
---@param instance_id? string
function M.clear_attachments(instance_id)
  local id = resolve_instance(instance_id, "clear_attachments")
  if id == nil then
    return
  end

  attachments_by_instance[id] = nil
  paint_indicator(id)
end

---Snapshot of the staged attachments for an instance.
---@param instance_id? string
---@return hyprpilot.composer.Attachment[]
function M.attachments(instance_id)
  local id = instance_id or window.active_instance()
  if id == nil then
    return {}
  end

  return vim.deepcopy(attachments_by_instance[id] or {})
end

---Convenience: attach the file backing `bufnr` (defaults to current).
---Skips with a warn when the buffer has no on-disk path.
---
---Two non-obvious bits:
---
---1. **Path is normalised to absolute** via `fnamemodify(:p)`. The
---    daemon's `Attachment` struct (`src-tauri/src/adapters/transcript.rs`)
---    uses `path` to build the `file://<...>` URI shipped to the
---    agent and to (eventually) read the file server-side. A relative
---    path under a different cwd would resolve to the wrong file.
---
---2. **Body is read from the BUFFER, not disk.** Captures the
---    captain's unsaved edits (the buffer they're actively typing
---    into) and sidesteps the "agent reads file → empty content"
---    bug where the daemon receives `path` only and the agent gets
---    `TextResourceContents { text = "", uri = "file://..." }`. We
---    populate `body` so the agent gets the actual content; the
---    daemon will accept it (`Attachment.body` is `#[serde(default)]
---    String`) and use it verbatim instead of trying to read the
---    file itself.
---@param bufnr? integer
---@param opts? { instance_id?: string, title?: string }
---@return hyprpilot.composer.Attachment?
function M.attach_buffer(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    log.warn("composer.attach_buffer: invalid bufnr=%s", bufnr)
    return nil
  end

  local raw_name = vim.api.nvim_buf_get_name(bufnr)
  if raw_name == "" then
    log.warn("composer.attach_buffer: bufnr=%s has no name (write it first)", bufnr)
    return nil
  end

  -- Normalise to an absolute path. `nvim_buf_get_name` may return a
  -- relative path when the buffer was opened with one, which would
  -- resolve to the wrong file daemon-side under any other cwd.
  local path = vim.fn.fnamemodify(raw_name, ":p")

  -- Read the buffer's CURRENT contents (captures unsaved edits) and
  -- ship as `body` so the agent receives the actual file text — the
  -- daemon doesn't read the file itself; without `body` the agent
  -- gets an empty `TextResourceContents`.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local body = table.concat(lines, "\n")

  return M.attach(vim.tbl_extend("force", { path = path, body = body }, opts or {}))
end

---Convenience: when `img-clip.nvim` is installed, drop the clipboard
---image to a temp file and stage it. Logs a warn when img-clip isn't
---available — captains can attach via `attach({ path = ... })`
---directly using their own clipboard helper.
---@param opts? { instance_id?: string, title?: string, dir?: string }
---@return hyprpilot.composer.Attachment?
function M.attach_clipboard_image(opts)
  opts = opts or {}

  local clipboard_ok, clipboard = pcall(require, "img-clip.clipboard")
  if not clipboard_ok then
    log.warn("composer.attach_clipboard_image: img-clip.nvim is not installed")
    return nil
  end

  if not clipboard.content_is_image() then
    log.warn("composer.attach_clipboard_image: clipboard does not contain an image")
    return nil
  end

  local dir = opts.dir or vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = string.format("%s/clipboard-%d.png", dir, vim.uv.hrtime())

  if not clipboard.save_image(path) then
    log.warn("composer.attach_clipboard_image: img-clip.save_image failed")
    return nil
  end

  -- Read the saved PNG back into base64 so the daemon can ship it
  -- as `ImageContent.data`. Without this, the agent receives the
  -- image as `{ data = "", uri = "file://<temp>", mimeType = ... }`
  -- — most agents need the inline base64; few resolve via URI.
  local fd = vim.uv.fs_open(path, "r", 438)
  local data
  if fd ~= nil then
    local stat = vim.uv.fs_fstat(fd)
    if stat ~= nil and stat.size > 0 then
      local raw = vim.uv.fs_read(fd, stat.size, 0)
      if type(raw) == "string" then
        data = vim.base64.encode(raw)
      end
    end
    vim.uv.fs_close(fd)
  end
  if data == nil then
    log.warn("composer.attach_clipboard_image: failed to read %s for base64 encoding", path)
  end

  return M.attach({
    path = path,
    instance_id = opts.instance_id,
    title = opts.title,
    mime = "image/png",
    data = data,
  })
end

---Build a fenced code block: optional header line above the fence,
---fence opens with the buffer's filetype (markdown is lenient about
---unknown tags), content verbatim, fence closes.
---@param header string?
---@param lang string?
---@param lines string[]
---@return string[]
local function build_fenced_block(header, lang, lines)
  local block = {}
  if header ~= nil and header ~= "" then
    table.insert(block, string.format("`%s`:", header))
  end
  table.insert(block, "```" .. (lang or ""))
  vim.list_extend(block, lines)
  table.insert(block, "```")
  return block
end

---Append `block` to the per-instance composer buffer, separating
---from existing content with a blank line. Mints the buffer when
---missing so a paste before the first `open()` still lands.
---@param instance_id string
---@param block string[]
local function append_to_composer(instance_id, block)
  local bufnr = ensure_buffer(instance_id)
  local existing = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local empty = (#existing == 0) or (#existing == 1 and existing[1] == "")

  if empty then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, block)
    return
  end

  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, vim.list_extend({ "" }, block))
end

---Append the buffer's contents into the composer as a fenced code
---block. Header is the path made relative to the cwd
---(`vim.fn.fnamemodify(path, ":.")`); fence language is the buffer's
---filetype. Unnamed buffers paste without a header.
---@param bufnr? integer                                -- default: current buffer
---@param opts? { instance_id?: string }
function M.paste_buffer(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    log.warn("composer.paste_buffer: invalid bufnr=%s", bufnr)
    return
  end

  local id = resolve_instance((opts or {}).instance_id, "paste_buffer")
  if id == nil then
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local header = path ~= "" and vim.fn.fnamemodify(path, ":.") or nil
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local lang = vim.bo[bufnr].filetype

  append_to_composer(id, build_fenced_block(header, lang, lines))
  M.resize()
end

---Append the last visual selection (line-wise) into the composer as
---a fenced code block. Reads marks `'<` / `'>` on the current buffer,
---so a captain wiring this for visual mode should `<Esc>` first (or
---bind in normal mode after the selection). Header is
---`<cwd-relative-path>:<start>-<end>`.
---@param opts? { instance_id?: string }
function M.paste_selection(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local start_line = vim.api.nvim_buf_get_mark(bufnr, "<")[1]
  local end_line = vim.api.nvim_buf_get_mark(bufnr, ">")[1]

  if start_line == 0 or end_line == 0 then
    log.warn("composer.paste_selection: no visual selection on bufnr=%s", bufnr)
    return
  end

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local id = resolve_instance((opts or {}).instance_id, "paste_selection")
  if id == nil then
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local relpath = path ~= "" and vim.fn.fnamemodify(path, ":.") or "(unnamed)"
  local header = string.format("%s:%d-%d", relpath, start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local lang = vim.bo[bufnr].filetype

  append_to_composer(id, build_fenced_block(header, lang, lines))
  M.resize()
end

---True when the composer split is currently open.
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

---Open the composer split below the chat window. Idempotent — when
---the composer is already visible, syncs its buffer to the active
---instance's composer buffer (so switch() flows pick the right
---draft) and re-enters insert mode. No-op when no instance is
---active or when the chat window isn't visible (open the chat first).
---@param opts? { focus?: boolean }  -- `focus = false` skips startinsert
function M.open(opts)
  opts = opts or {}
  local focus = opts.focus ~= false

  local instance_id = window.active_instance()

  if instance_id == nil then
    log.debug("composer.open: no active instance — skipping")
    return
  end

  if not window.is_visible() then
    log.debug("composer.open: chat window not visible — skipping")
    return
  end

  local bufnr = ensure_buffer(instance_id)

  if M.is_visible() then
    -- Already open — re-bind to the active instance's composer buffer
    -- (handles the switch() case where the chat flipped instances).
    if vim.api.nvim_win_get_buf(M._winid) ~= bufnr then
      vim.api.nvim_win_set_buf(M._winid, bufnr)
    end

    if focus then
      -- Same BufEnter risk as the open-fresh path below — pcall the
      -- focus so a third-party autocmd that throws on the composer
      -- buffer can't take out the open path.
      local ok, err = pcall(vim.api.nvim_set_current_win, M._winid)
      if ok then
        vim.cmd("startinsert")
      else
        log.warn("composer.open: nvim_set_current_win failed: %s", err)
      end
    end

    paint_indicator(instance_id)
    paint_activity(instance_id)
    M.resize()
    return
  end

  -- See `permission_row.open_window` — `window.focus()` absorbs third-
  -- party BufEnter throws so a missing markdown parser can't kill the
  -- composer-open path.
  if not window.focus() then
    return
  end
  local ok_split = pcall(vim.cmd, string.format("belowright %dsplit", resolve_min_height()))
  if not ok_split then
    log.warn("composer.open: belowright %dsplit failed", resolve_min_height())
    return
  end

  M._winid = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(M._winid, bufnr)
  require("hyprpilot.chat.buffer").clean_window_chrome(M._winid)
  vim.wo[M._winid].wrap = true
  vim.wo[M._winid].linebreak = true
  -- `winfixheight` keeps `<C-W>=` and other equalisation passes from
  -- redistributing space onto the composer, so our auto-resize stays
  -- the source of truth.
  vim.wo[M._winid].winfixheight = true
  vim.wo[M._winid].winfixwidth = true

  paint_indicator(instance_id)
  paint_activity(instance_id)
  M.resize()

  if focus then
    vim.cmd("startinsert")
  end
end

---Close the composer split. The buffer persists for next open.
function M.close()
  if not M.is_visible() then
    return
  end

  pcall(vim.api.nvim_win_close, M._winid, true)
  M._winid = nil
end

---Toggle the composer.
function M.toggle()
  if M.is_visible() then
    M.close()
  else
    M.open()
  end
end

---Submit the composer's contents (or `text` when provided) to the
---active instance. Clears the composer buffer on success.
---
---When the agent is non-idle (`status.activity.kind ~= "idle"`),
---the submit is routed to the per-instance composer queue
---(`composer_queue.enqueue`) instead of going straight to the
---daemon. The queue strip surfaces queued prompts above the
---composer; captain drains the head explicitly via the strip's
---`<C-CR>` (default) keymap. This mirrors the desktop overlay's
---`QueueStrip.vue` behaviour — captain stays in control of when
---the next prompt lands. Pass `opts.bypass_queue = true` to skip
---the queue check (the queue strip's send-now path uses this).
---`opts.with_config` mirrors `instances.spawn`'s field — only the
---daemon's auto-spawn fallback on `prompts/send` (no `instance_id`
---resolved live) actually uses it, but the composer carries it
---through for completeness so a captain calling
---`composer.submit(text, { with_config = ... })` against a not-yet-
---spawned instance gets the patches honoured.
---@param text string?
---@param opts { instance_id?: string, attachments?: table[], bypass_queue?: boolean, with_config?: hyprpilot.ConfigPatch[] }?
function M.submit(text, opts)
  opts = opts or {}
  local instance_id = opts.instance_id or window.active_instance()

  log.debug("composer.submit: invoked instance_id=%s text_passed=%s", tostring(instance_id), tostring(text ~= nil))

  if instance_id == nil then
    log.warn("composer.submit: no active instance")

    return
  end

  local bufnr = buffers[instance_id]

  if text == nil then
    if bufnr == nil then
      log.warn("composer.submit: no composer buffer for %s", instance_id)

      return
    end

    text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    log.debug("composer.submit: read %d bytes from composer bufnr=%s", #text, bufnr)
  end

  text = text:gsub("^%s+", ""):gsub("%s+$", "")

  if text == "" then
    log.debug("composer.submit: text empty after trim, no-op")
    return
  end

  -- Snapshot attachments at submit / enqueue time so a downstream
  -- composer edit doesn't change what a queued turn eventually
  -- sends (matches desktop overlay's pop-then-edit semantics).
  local attachments_snapshot = opts.attachments
  if attachments_snapshot == nil then
    local staged = attachments_by_instance[instance_id]
    if staged ~= nil and #staged > 0 then
      attachments_snapshot = vim.deepcopy(staged)
    end
  end

  -- Queue route: when THIS instance's agent is busy, park the prompt
  -- instead of firing it. Critically reads `status.activity(instance_id)`
  -- — the per-instance activity, NOT the global flag. Without this
  -- scoping, a long turn on instance A would cause every prompt
  -- typed in idle instance B's composer to land in B's queue (the
  -- old global flag was non-idle because A was running).
  if not opts.bypass_queue then
    local activity = require("hyprpilot.status").activity(instance_id)
    if activity ~= nil and activity.kind ~= nil and activity.kind ~= "idle" then
      require("hyprpilot.composer.queue").enqueue(instance_id, {
        text = text,
        attachments = attachments_snapshot,
      })
      -- Clear the composer buffer + staged attachments — the queue
      -- now owns the snapshot. Same UX as a successful send.
      if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
      end
      attachments_by_instance[instance_id] = nil
      paint_indicator(instance_id)
      log.debug("composer.submit: queued (activity=%s)", tostring(activity.kind))
      return
    end
  end

  local payload = { instanceId = instance_id, text = text }
  if attachments_snapshot ~= nil and #attachments_snapshot > 0 then
    payload.attachments = attachments_snapshot
  end
  -- Stack per-call patches on top of `config.options.with_config`
  -- (the captain's global baseline). Daemon validates the wire
  -- shape — bad patches come back as `-32602`.
  require("hyprpilot.rpc.with-config").apply(payload, opts.with_config)

  -- Fire BEFORE the daemon round-trip so captain autocmd handlers
  -- (UI detach, statusline "sending…" pill, etc.) can run while
  -- the request is still in flight. Captains who hook this won't
  -- double-fire when a submit is queue-parked — that path returns
  -- above.
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "HyprpilotComposerSubmitted",
    data = { instance_id = instance_id, bufnr = bufnr, text = text },
  })

  client.request("prompts/send", payload, nil, function(err, result)
    if err ~= nil then
      log.error("composer.submit: %s", err.message)
      return
    end

    -- Daemon-side disposition (added in hyprpilot's post-`with_config`
    -- branch): the daemon takes a `was_busy` snapshot at submit time
    -- and returns one of `sent` (immediate dispatch) / `queued`
    -- (parked behind the in-flight turn, auto-dispatches when it
    -- drains) / `drafted` (draft path — composer doesn't use this).
    --
    -- Races: the plugin's pre-flight `status.activity.kind ~= "idle"`
    -- check parks on the local queue strip when busy, but a turn
    -- can start between that check and the daemon receiving the
    -- request. In that case the daemon queues the prompt and we
    -- learn about it here. The composer still clears (the captain
    -- handed off the draft), but a `HyprpilotPromptQueued` event
    -- fires so notification handlers (bell, toast) can surface that
    -- the prompt isn't running yet.
    local disposition = (type(result) == "table" and type(result.disposition) == "string") and result.disposition or "sent"
    local accepted = type(result) ~= "table" or result.accepted ~= false

    if not accepted then
      log.warn("composer.submit: daemon rejected the prompt (disposition=%s) — leaving composer intact", disposition)
      return
    end

    if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end
    attachments_by_instance[instance_id] = nil
    paint_indicator(instance_id)

    if disposition == "queued" then
      log.info("composer.submit: daemon queued the prompt behind an in-flight turn")
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "HyprpilotPromptQueued",
        data = { instance_id = instance_id, bufnr = bufnr },
      })
    end

    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "HyprpilotPromptDispatched",
      data = { instance_id = instance_id, bufnr = bufnr, disposition = disposition },
    })
  end)
end

---Cancel the in-flight turn on the active instance.
---@param instance_id string?
function M.cancel(instance_id)
  local id = instance_id or window.active_instance()

  if id == nil then
    log.warn("composer.cancel: no active instance")

    return
  end

  -- `prompts/cancel` is request-shaped on the daemon
  -- (`HandlerOutcome::Reply` in `rpc/handlers/prompts.rs`) — sending
  -- it as a notification gets back `id: null` + `-32600
  -- "missing or invalid id"` and the captain's <C-c> silently no-ops.
  client.request("prompts/cancel", { instanceId = id }, nil, function(err)
    if err ~= nil then
      log.warn("composer.cancel: prompts/cancel failed: %s", err.message)
    end
  end)
end

---Wipe the composer buffer for a given instance. Used when the
---instance is closed daemon-side.
---@param instance_id string
function M.wipe(instance_id)
  local bufnr = buffers[instance_id]

  if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end

  -- Drop the per-instance activity-listener augroup so a future
  -- `ensure_buffer(instance_id)` for the same id re-creates it
  -- against the fresh buffer (and we don't leak listeners that
  -- fire callbacks on a deleted bufnr).
  pcall(vim.api.nvim_del_augroup_by_name, "HyprpilotComposerActivity:" .. instance_id)

  buffers[instance_id] = nil
  attachments_by_instance[instance_id] = nil
end

---Replace the composer buffer's content for `instance_id` with
---`text`. Used by the queue strip's `edit_head` so a captain who
---wants to tweak a queued prompt before resubmit gets the prompt
---loaded into the composer (matching the desktop overlay's
---`onQueueEdit` behaviour) instead of an immediate dispatch.
---Opens the composer + drops the cursor at end-of-buffer in
---insert mode so the captain can keep typing immediately.
---@param instance_id string
---@param text string
function M.set_text(instance_id, text)
  if type(text) ~= "string" then
    log.warn("composer.set_text: text must be a string")
    return
  end

  local bufnr = ensure_buffer(instance_id)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
  paint_indicator(instance_id)

  -- Surface the composer for editing. `focus = true` is the default,
  -- which also enters insert mode below.
  M.open({ focus = true })

  -- Land the cursor at the end of the loaded text so typing extends
  -- rather than overwrites. Guard against the composer window not
  -- being visible in headless / test contexts where `M.open` is a
  -- no-op without a chat split.
  if M._winid ~= nil and vim.api.nvim_win_is_valid(M._winid) then
    local last_row = vim.api.nvim_buf_line_count(bufnr)
    local last_line = vim.api.nvim_buf_get_lines(bufnr, last_row - 1, last_row, false)[1] or ""
    pcall(vim.api.nvim_win_set_cursor, M._winid, { last_row, #last_line })
  end
end

---Test-only seam: register a bufnr under the composer's internal
---per-instance map so `wipe(id)` can find it. Mirrors what
---`ensure_buffer` does at the end of its mint path; lets unit tests
---drive `composer.wipe(id)` without standing up the real split
---layout that `open()` needs.
---@param instance_id string
---@param bufnr integer
function M._register_buffer_for_tests(instance_id, bufnr)
  buffers[instance_id] = bufnr
end

return M
