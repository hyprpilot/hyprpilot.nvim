--- Composer — separate input buffer in a sub-split below the chat
--- window. One composer buffer per instance so drafts persist across
--- instance switching.
---
--- Public surface:
---   `open()` / `close()` / `toggle()` / `is_visible()`
---   `submit(text?, opts?)` — defaults `text` to the composer's contents
---   `cancel()` — sends `prompts/cancel` to the active instance
---   `attach(opts)` / `detach(slug, opts?)` / `attachments(instance_id?)`
---   `attach_buffer(bufnr?, opts?)` — attach an unsaved / open buffer
---     (captures live edits)
---   `attach_file(path, opts?)` — generic disk-file attach with mime
---     + text/binary auto-detect; respects `composer.attach.max_bytes`
---   `attach_clipboard(opts?)` — image (internal shell-out probe) OR
---     text (via getreg('+')) autodetect; round-trips through
---     `attach_file`
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

--- Per-instance "you're editing this queue slot" pointer. Set by
--- `M.set_text` when the queue strip's `edit` keymap loads a
--- queued item into the composer. The next `M.submit` on this
--- instance routes through `queue/edit` (preserving the slot's
--- `id` / `enqueued_seq` / `enqueued_at` daemon-side) instead of
--- firing `prompts/send`. Cleared on submit success / wipe.
---@type table<string, { item_id: string, attachments?: table[] }>
local editing_queue_slot_by_instance = {}

---@type integer?
M._winid = nil

local INDICATOR_NS = vim.api.nvim_create_namespace("hyprpilot.composer.attachments")

---Forward-declared so `ensure_buffer`'s TextChanged autocmd can call
---it (the body anchors virt_lines to the current last line, so every
---edit needs a reposition to keep attachments at the bottom).
---@type fun(instance_id: string)
local paint_indicator

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

  local buffer_mod = require("hyprpilot.chat.buffer")
  if buffer_mod.layout_manager_active() then
    -- Cooperate with edgy's apply_size pass instead of fighting it:
    -- `vim.w[winid].edgy_height` is edgy's documented dynamic-sizing
    -- hook (`win:dim("height")` reads this first, falls back to
    -- view.size.height). Set the captain's expected height; edgy
    -- redistributes leftover into the absorber view (the chat).
    pcall(function()
      vim.w[M._winid].edgy_height = target
    end)
    -- Nudge edgy to recompute, debounced so a keystroke burst
    -- doesn't fire N full-layout passes per second (the captain
    -- saw UI thrash + occasional hangs from the un-debounced path).
    buffer_mod.nudge_edgy_layout()
    return
  end

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
  -- Dotted-filetype alias: composer is `hyprpilot_composer.markdown`
  -- so vim's ftplugin/markdown.* runs (markdown ftplugin features),
  -- AND blink/cmp / snippet sources keyed to "markdown" apply
  -- (codeblock snippets, table snippets, etc.). Our own predicate
  -- (`buffer.has_filetype`) iterates the dotted components so
  -- callers comparing against "hyprpilot_composer" still match.
  vim.bo[bufnr].filetype = "hyprpilot_composer.markdown"
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

  apply_action(bufnr, keymaps.detach, function()
    require("hyprpilot.palettes.attachments").detach({ instance_id = instance_id })
  end, "detach attachment")

  -- Repaint the attachment indicator (whose virt_lines are anchored
  -- to the current last buffer line) and re-resize the window on
  -- every edit. `paint_indicator` calls `M.resize` itself, so this
  -- one callback covers both reposition + auto-grow paths.
  --
  -- Per-buffer augroup with `clear = true` so adopting a same-named
  -- buffer (post-shutdown hot-reload, see `find_by_name` branch
  -- above) doesn't double up the autocmd — every keystroke would
  -- otherwise fire `paint_indicator` N times after N adoptions.
  local augroup = vim.api.nvim_create_augroup("HyprpilotComposerEdits_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      paint_indicator(instance_id)
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
paint_indicator = function(instance_id)
  local bufnr = buffers[instance_id]
  if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, INDICATOR_NS, 0, -1)

  local list = attachments_by_instance[instance_id] or {}
  if #list ~= 0 then
    -- Match the chat-side `render_attachment` format
    -- (`@ <title|slug> · <mime> · <path>`) so the captain reads
    -- staged composer attachments with the same shape they'll
    -- appear under the submitted prompt in the chat buffer.
    -- Mime / path are conditional — composer attachments minted
    -- from `attach_buffer` (unsaved scratch) won't carry a path,
    -- so the segment list collapses gracefully.
    local virt_lines = vim.tbl_map(function(a)
      local label = (a.title ~= nil and a.title ~= "") and a.title or a.slug
      local parts = { "@ " .. tostring(label) }
      if a.mime ~= nil and a.mime ~= "" then
        table.insert(parts, tostring(a.mime))
      end
      if a.path ~= nil and a.path ~= "" then
        table.insert(parts, tostring(a.path))
      end
      return { { "  " .. table.concat(parts, " · "), "HyprpilotComposerAttachments" } }
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

--- Mime types we treat as text-like — body lands as a UTF-8 string
--- in the attachment's `body` field. Everything else (images, PDFs,
--- archives, unknown binary) round-trips through `data` as base64.
--- The set is deliberately tight; when the mime is nil we fall
--- through to a null-byte sniff on the first 1 KiB.
local TEXT_MIME_PREFIXES = { "text/" }
local TEXT_MIME_LITERALS = {
  ["application/json"] = true,
  ["application/yaml"] = true,
  ["application/toml"] = true,
  ["application/xml"] = true,
  ["application/x-sh"] = true,
  ["application/javascript"] = true,
  ["application/typescript"] = true,
}

---@param mime string?
---@return boolean
local function mime_is_text(mime)
  if mime == nil or mime == "" then
    return false
  end
  if TEXT_MIME_LITERALS[mime] then
    return true
  end
  for _, prefix in ipairs(TEXT_MIME_PREFIXES) do
    if mime:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

---Sniff the first chunk of `path` for null bytes — the canonical
---heuristic for "is this a text file" when the mime map doesn't know
---the extension. A single 0x00 byte in the first 1 KiB and we treat
---it as binary; otherwise text. Cheap, sufficient for our use case
---(agent attachments), avoids pulling a libmagic dep.
---@param path string
---@return boolean
local function sniff_is_text(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if fd == nil then
    return false
  end
  local chunk = vim.uv.fs_read(fd, 1024, 0)
  vim.uv.fs_close(fd)
  if type(chunk) ~= "string" or chunk == "" then
    return true
  end
  return chunk:find("\0", 1, true) == nil
end

---Read `path` fully into a base64-encoded string. Used for binary
---attachments (images, PDFs, ...) so the daemon ships them as
---inline `ImageContent.data` / `BlobResourceContents.blob` — most
---agents read the inline payload; few resolve `file://` URIs.
---@param path string
---@return string?
local function read_as_base64(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if fd == nil then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  if stat == nil or stat.size == 0 then
    vim.uv.fs_close(fd)
    return nil
  end
  local raw = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if type(raw) ~= "string" then
    return nil
  end
  return vim.base64.encode(raw)
end

---Generic file attach: read `path` from disk, classify text vs
---binary by mime (or null-byte sniff for unknown extensions), and
---hand off to `M.attach` with `body` (text) or `data` (base64).
---Captain wire:
---
---   require("hyprpilot.composer").attach_file("/path/to/file")
---
---   -- captains driving from a one-shot clipboard probe:
---   require("hyprpilot.composer").attach_clipboard({ title = "screenshot" })
---
---Rejects paths over `composer.attach.max_bytes` (default 8 MiB) so
---a stray `attach_file("/var/log/syslog")` doesn't ship a 200 MB
---base64 blob over the socket.
---@param path string
---@param opts? { instance_id?: string, title?: string, slug?: string, mime?: string }
---@return hyprpilot.composer.Attachment?
function M.attach_file(path, opts)
  if type(path) ~= "string" or path == "" then
    log.warn("composer.attach_file: path must be a non-empty string")
    return nil
  end
  opts = opts or {}

  local resolved = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(resolved) ~= 1 then
    log.warn("composer.attach_file: file not readable: %s", resolved)
    return nil
  end

  local stat = vim.uv.fs_stat(resolved)
  if stat == nil then
    log.warn("composer.attach_file: stat failed for %s", resolved)
    return nil
  end

  local max_bytes = ((config.options.composer or {}).attach or {}).max_bytes or (8 * 1024 * 1024)
  if stat.size > max_bytes then
    log.warn("composer.attach_file: %s is %d bytes, exceeds composer.attach.max_bytes=%d", resolved, stat.size, max_bytes)
    return nil
  end

  local mime = opts.mime or guess_mime(resolved)
  local is_text
  if mime ~= nil and mime ~= "" then
    is_text = mime_is_text(mime)
  else
    is_text = sniff_is_text(resolved)
  end

  local payload = {
    path = resolved,
    instance_id = opts.instance_id,
    title = opts.title,
    slug = opts.slug,
    mime = mime,
  }

  if is_text then
    local lines = vim.fn.readfile(resolved)
    payload.body = table.concat(lines, "\n")
  else
    local data = read_as_base64(resolved)
    if data == nil then
      log.warn("composer.attach_file: failed to base64-encode %s", resolved)
      return nil
    end
    payload.data = data
    -- Daemon needs SOMETHING in mime for binary contents to route
    -- via `BlobResourceContents`. Falling back to octet-stream when
    -- the extension map didn't know — safe default.
    if payload.mime == nil or payload.mime == "" then
      payload.mime = "application/octet-stream"
    end
  end

  return M.attach(payload)
end

---Attach whatever's on the system clipboard. Probes the
---clipboard's advertised mime types, picks the highest-fidelity
---one (image > pdf > rich text > html > markdown > plain text >
---uri-list — see `clipboard.pick_best_mime`), writes the bytes
---to a temp file with the right extension, and routes through
---`attach_file` so `attach`'s mime-aware text/binary auto-detect
---picks the right wire path (text → `body`, binary → `data`).
---
---The captain's intent is "attach whatever I copied" — they
---shouldn't have to know whether the clipboard holds a PNG, a
---PDF, RTF, HTML, or plain text. The probe surfaces every mime
---the backend exposes (xclip's `-t TARGETS -o`, wl-paste's
---`--list-types`, macOS's `clipboard info`, Windows's
---`Contains*` checks), and the mime-pick + extension map cover
---everything we know how to write.
---
---Falls through to the `+` register text fallback only when the
---backend resolves to nothing usable (no xclip / wl-paste /
---pbpaste / powershell on PATH). When the backend is present
---but the clipboard is empty / unsupported → warn + return nil.
---@param opts? { instance_id?: string, title?: string, slug?: string, dir?: string, mime?: string }
---@return hyprpilot.composer.Attachment?
function M.attach_clipboard(opts)
  opts = opts or {}
  local clipboard = require("hyprpilot.composer.clipboard")

  if clipboard.resolve_cmd() == nil then
    -- No native clipboard backend — fall through to vim's `+`
    -- register so captains running over plain SSH (no DISPLAY /
    -- WAYLAND_DISPLAY) still get text-paste support.
    return M._attach_clipboard_text_fallback(opts)
  end

  -- Caller can pin a specific mime when they know what's on the
  -- clipboard (test / scripting). Default: take the FIRST mime
  -- the backend advertised — clipboard sources publish their
  -- preferred format first (image/png before image/tiff before
  -- text/plain filename for a screenshot, etc.), and
  -- `list_mime_types` filters X11 protocol noise so the first
  -- entry is always an actual mime.
  local mime = opts.mime
  if mime == nil then
    local available = clipboard.list_mime_types()
    if #available == 0 then
      -- Backend resolved but the clipboard is empty / opaque.
      -- Last-ditch: try the `+` register before warning out.
      return M._attach_clipboard_text_fallback(opts)
    end
    mime = available[1]
  end

  -- Fresh temp directory per paste (mirrors the captain's
  -- `vim.fn.tempname()` pattern in their nvim config). Avoids
  -- the same `clipboard-<ts>` basename colliding across pastes.
  local dir = opts.dir or vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  -- Extension lookup goes through the system mime DB
  -- (`/etc/mime.types`). When the system doesn't know the mime
  -- (Windows hosts, or an exotic mime not in `media-types`), we
  -- save as `.bin` and force-pass the explicit mime to
  -- `attach_file` so the wire payload still carries the right
  -- mime hint to the daemon (extension-based inference would
  -- otherwise return nil for `.bin`).
  local ext = clipboard.extension_for(mime)
  local path = string.format("%s/clipboard-%d.%s", dir, vim.uv.hrtime(), ext or "bin")

  if not clipboard.save_as(mime, path) then
    log.warn("composer.attach_clipboard: clipboard.save_as(%s) failed for %s", mime, path)
    return nil
  end

  -- Plumb the explicit mime through when the extension is
  -- generic (`.bin`); `attach_file` honours `opts.mime` over
  -- extension-based inference, so the daemon still receives the
  -- correct mime even when the basename doesn't help.
  local file_opts = opts
  if ext == nil then
    file_opts = vim.tbl_extend("force", {}, opts, { mime = mime })
  end
  return M.attach_file(path, file_opts)
end

---Text-only fallback for `attach_clipboard`. Used when no native
---clipboard backend is on PATH (plain SSH, no display) OR when
---the backend is present but reports an empty clipboard. Reads
---the `+` register, writes to a temp `.txt`, attaches.
---@param opts table
---@return hyprpilot.composer.Attachment?
function M._attach_clipboard_text_fallback(opts)
  local text = vim.fn.getreg("+")
  if type(text) ~= "string" or text == "" then
    log.warn("composer.attach_clipboard: clipboard is empty (no native backend payload, no `+` register text)")
    return nil
  end

  local path = vim.fn.tempname() .. ".txt"
  local fd = vim.uv.fs_open(path, "w", 420)
  if fd == nil then
    log.warn("composer.attach_clipboard: failed to open temp file for clipboard text")
    return nil
  end
  vim.uv.fs_write(fd, text, 0)
  vim.uv.fs_close(fd)
  return M.attach_file(path, opts)
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
---a fenced code block. Reads the live `v`/`.` anchors when called
---from inside visual mode (the `'<`/`'>` marks aren't refreshed
---until vim exits visual mode, so a keymap bound with mode `"v"`
---that fires mid-selection would see the PREVIOUS selection's marks
---— captain hit a "needs second try" reliability bug); falls back to
---the marks when called from normal mode. Header is
---`<cwd-relative-path>:<start>-<end>`.
---@param opts? { instance_id?: string }
function M.paste_selection(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local start_line, end_line
  if mode == "v" or mode == "V" or mode == "\22" then
    start_line = vim.fn.getpos("v")[2]
    end_line = vim.fn.getpos(".")[2]
  else
    start_line = vim.api.nvim_buf_get_mark(bufnr, "<")[1]
    end_line = vim.api.nvim_buf_get_mark(bufnr, ">")[1]
  end

  if start_line == 0 or end_line == 0 then
    log.warn("composer.paste_selection: no visual selection on bufnr=%s", bufnr)
    return
  end

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  -- Snapshot lines + buffer metadata BEFORE leaving visual mode —
  -- captain configs that wire BufLeave / WinLeave autocmds can
  -- swap the buffer out from under us when <Esc> fires.
  local path = vim.api.nvim_buf_get_name(bufnr)
  local relpath = path ~= "" and vim.fn.fnamemodify(path, ":.") or "(unnamed)"
  local header = string.format("%s:%d-%d", relpath, start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local lang = vim.bo[bufnr].filetype

  if mode == "v" or mode == "V" or mode == "\22" then
    -- Drop back to normal mode so subsequent reads of `'<`/`'>`
    -- reflect this selection (vim only refreshes the visual marks
    -- on visual-mode EXIT) and the captain's cursor lands cleanly.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end

  local id = resolve_instance((opts or {}).instance_id, "paste_selection")
  if id == nil then
    return
  end

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

  local buffer_mod = require("hyprpilot.chat.buffer")

  if M.is_visible() then
    -- Already open — re-bind to the active instance's composer buffer
    -- (handles the switch() case where the chat flipped instances).
    if vim.api.nvim_win_get_buf(M._winid) ~= bufnr then
      if not buffer_mod.safe_win_set_buf(M._winid, bufnr) then
        -- Composer window invalidated between is_visible and now;
        -- bail rather than chain focus + paint on a dead handle.
        return
      end
    end

    if focus then
      if buffer_mod.safe_set_current_win(M._winid) then
        pcall(vim.cmd, "startinsert")
      end
    end

    paint_indicator(instance_id)
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

  if not buffer_mod.safe_win_set_buf(M._winid, bufnr) then
    log.warn("composer.open: safe_win_set_buf failed; bailing out of open path")
    return
  end
  buffer_mod.clean_window_chrome(M._winid)
  vim.wo[M._winid].wrap = true
  vim.wo[M._winid].linebreak = true
  -- `winfixheight` protects against `equalalways` redistributing
  -- height when sibling splits (permission-row, queue-strip) open
  -- belowright. Without it, the composer gets squeezed and our
  -- auto-resize doesn't fire (no TextChanged event on a
  -- sibling-open). `nvim_win_set_height` still works on a
  -- winfixheight window — the flag only blocks automatic equalize.
  -- Skip under a layout manager (edgy owns sizing).
  if not buffer_mod.layout_manager_active() then
    vim.wo[M._winid].winfixheight = true
    vim.wo[M._winid].winfixwidth = true
  end

  paint_indicator(instance_id)
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
---active instance.
---
---Daemon-mirror queue model: the daemon owns the queue (single
---mailbox, monotonic `enqueued_seq`, lock-protected). `prompts/send`
---auto-routes — daemon decides immediate dispatch vs append-to-tail
---based on its own busy-check. The plugin no longer pre-checks
---activity / parks on a local FIFO; we just fire and let the daemon
---reply with a `disposition: "sent" | "queued" | "drafted"` so we
---can emit the right `HyprpilotPrompt*` autocmd.
---
---Edit-slot route: when the captain edited a queued item via the
---queue strip's `edit` keymap, `M.set_text` stamped the
---`editing_queue_slot_by_instance[id]` pointer. The next submit
---fires `queue/edit` instead of `prompts/send`, preserving the
---slot's daemon-side `id` / `enqueued_seq` / `enqueued_at`. On
---success the slot pointer is cleared.
---
---`opts.with_config` overlays the captain's global baseline (the
---daemon's auto-spawn fallback uses it when no instance_id is yet
---live).
---@param text string?
---@param opts { instance_id?: string, attachments?: table[], with_config?: hyprpilot.ConfigPatch[] }?
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

  -- Pass text to the daemon byte-identical. Empty / whitespace-only
  -- guard removed: daemon handles empty input itself (mirrors the
  -- empty-thought design where stats ship even when text is blank),
  -- and adding a plugin-side guard would re-introduce the same
  -- silent-rewrite class of bug the trim removal closed.

  local attachments_snapshot = opts.attachments
  if attachments_snapshot == nil then
    local staged = attachments_by_instance[instance_id]
    if staged ~= nil and #staged > 0 then
      attachments_snapshot = vim.deepcopy(staged)
    end
  end

  local function clear_composer_state()
    if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end
    attachments_by_instance[instance_id] = nil
    paint_indicator(instance_id)
  end

  -- Edit-slot route: the captain pulled a queued item into the
  -- composer via the queue strip's `edit` keymap; submit means
  -- "save the edit", not
  -- "send a new prompt". Daemon's `queue/edit` preserves the
  -- slot's id / enqueued_seq / enqueued_at so the queue order
  -- stays intact.
  local edit_slot = editing_queue_slot_by_instance[instance_id]
  if edit_slot ~= nil and type(edit_slot.item_id) == "string" then
    require("hyprpilot.rpc.queue").edit(instance_id, edit_slot.item_id, {
      text = text,
      attachments = attachments_snapshot or {},
    }, function(err)
      if err == nil then
        editing_queue_slot_by_instance[instance_id] = nil
        clear_composer_state()
        pcall(vim.api.nvim_exec_autocmds, "User", {
          pattern = "HyprpilotQueueItemEdited",
          data = { instance_id = instance_id, bufnr = bufnr, item_id = edit_slot.item_id },
        })
        return
      end
      -- Item-gone recovery: daemon rejects with `invalid_params`
      -- + `"queue item not found: <id>"` when the slot vanished
      -- between the edit keymap and submit (drop / drop_all from
      -- the strip, queue/dispatch from another frontend, etc.).
      -- Drop the stale slot pointer and re-fire as a fresh
      -- `prompts/send` so the captain's typed text doesn't get
      -- lost — they hit submit, they get a submit.
      local missing = type(err.message) == "string" and err.message:find("queue item not found", 1, true) ~= nil
      if missing then
        log.info("composer.submit: queue/edit slot %s gone — falling through to prompts/send", edit_slot.item_id)
        editing_queue_slot_by_instance[instance_id] = nil
        M.submit(text, opts)
        return
      end
      -- Other errors: keep composer draft + slot pointer for retry.
      log.warn("composer.submit: queue/edit failed: %s — keeping composer draft for retry", err.message)
    end)
    return
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
  -- the request is still in flight.
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "HyprpilotComposerSubmitted",
    data = { instance_id = instance_id, bufnr = bufnr, text = text },
  })

  -- Capture the captain's current window + mode BEFORE the RPC
  -- fires. The disposition=queued branch below hydrates the queue
  -- strip → `open_aux_split` briefly steers focus through the chat
  -- window to mint the new strip split, and assorted autocmds /
  -- edgy layout passes can leave focus elsewhere by the time the
  -- captain's next keystroke lands. Restoring at the end of the
  -- callback chain keeps the captain glued to whatever surface
  -- they were on (composer in insert mode, typically).
  local prev_win = vim.api.nvim_get_current_win()
  local prev_mode = vim.api.nvim_get_mode().mode
  local function restore_focus()
    if not vim.api.nvim_win_is_valid(prev_win) then
      return
    end
    if vim.api.nvim_get_current_win() ~= prev_win then
      pcall(vim.api.nvim_set_current_win, prev_win)
    end
    -- Insert-mode submit (`<C-s>` from the composer) should leave
    -- the captain back in insert so they keep typing. Normal-mode
    -- submit (`<CR>`) shouldn't force insert.
    if prev_mode:match("^i") and prev_win == M._winid then
      pcall(vim.cmd, "startinsert")
    end
  end

  client.request("prompts/send", payload, nil, function(err, result)
    if err ~= nil then
      log.error("composer.submit: %s", err.message)
      return
    end

    -- Daemon-side disposition: `sent` = dispatched immediately,
    -- `queued` = appended to tail (auto-routed by daemon's
    -- busy-check), `drafted` = draft path (composer doesn't use).
    local disposition = (type(result) == "table" and type(result.disposition) == "string") and result.disposition or "sent"
    local accepted = type(result) ~= "table" or result.accepted ~= false

    if not accepted then
      log.warn("composer.submit: daemon rejected the prompt (disposition=%s) — leaving composer intact", disposition)
      return
    end

    clear_composer_state()

    if disposition == "queued" then
      log.info("composer.submit: daemon queued the prompt behind an in-flight turn")
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "HyprpilotPromptQueued",
        data = { instance_id = instance_id, bufnr = bufnr },
      })
      -- Defensive snapshot refresh — the daemon SHOULD emit a
      -- `queue_changed` event when the prompt lands on the tail,
      -- but if the event misses (debounce drop, partition, race
      -- with a turn-end), the strip stays stale. Wholesale-replace
      -- semantics make the duplicate refresh free when the event
      -- DOES land.
      pcall(function()
        require("hyprpilot.chat.queue-strip").hydrate(instance_id)
      end)
    end

    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "HyprpilotPromptDispatched",
      data = { instance_id = instance_id, bufnr = bufnr, disposition = disposition },
    })

    -- Two restorations: an immediate one for the sync path
    -- (composer.open / edgy nudge that ran during this callback)
    -- and a scheduled one to catch the deferred edgy layout pass
    -- (100ms) that fires after this callback returns.
    restore_focus()
    vim.defer_fn(restore_focus, 150)
  end)
end

---Submit the composer's contents as N separate prompts, one per
---non-blank line. Each line becomes its own `prompts/send` —
---daemon's queue is FIFO over the same socket, so the prompts
---land in line order (first dispatched immediately or queued,
---rest queued behind). Bulk-queue-from-composer for captains who
---paste a checklist and want each item as its own prompt.
---
---Attachments + edit-slot routing don't apply — this is a
---fire-many path. Edit-slot is cleared if set (per-line doesn't
---make sense for editing one queued item). Attachments are
---dropped (would otherwise be replicated on every line).
---
---No-op when the composer is empty / whitespace-only. Each
---per-line fire goes through the daemon's accept / queue /
---reject paths same as a single submit.
---@param opts? { instance_id?: string }
function M.submit_per_line(opts)
  opts = opts or {}
  local instance_id = opts.instance_id or window.active_instance()
  if instance_id == nil then
    log.warn("composer.submit_per_line: no active instance")
    return
  end

  local bufnr = buffers[instance_id]
  if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    log.warn("composer.submit_per_line: no composer buffer for %s", instance_id)
    return
  end

  local raw = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  if raw:match("^%s*$") then
    log.debug("composer.submit_per_line: composer empty / whitespace-only, no-op")
    return
  end

  -- Snapshot every non-blank line BEFORE clearing composer state
  -- so the buffer wipe doesn't race the per-line fire loop.
  local lines = {}
  for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
    if not line:match("^%s*$") then
      table.insert(lines, line)
    end
  end
  if #lines == 0 then
    return
  end

  -- Drop attachments + edit-slot pointer — neither makes sense
  -- when fanning out to N separate prompts.
  attachments_by_instance[instance_id] = nil
  editing_queue_slot_by_instance[instance_id] = nil
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
  paint_indicator(instance_id)

  log.info("composer.submit_per_line: firing %d prompts on instance=%s", #lines, instance_id)

  for _, line in ipairs(lines) do
    client.request("prompts/send", { instanceId = instance_id, text = line }, nil, function(err, result)
      if err ~= nil then
        log.warn("composer.submit_per_line: prompts/send failed for %q: %s", line, err.message)
        return
      end
      local disposition = (type(result) == "table" and type(result.disposition) == "string") and result.disposition or "sent"
      log.debug("composer.submit_per_line: %s — %q", disposition, line)
    end)
  end
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

  buffers[instance_id] = nil
  attachments_by_instance[instance_id] = nil
  editing_queue_slot_by_instance[instance_id] = nil
end

---Replace the composer buffer's content for `instance_id` with
---`text`. Used by the queue strip's `edit` keymap so a captain who
---wants to tweak a queued prompt before resubmit gets the prompt
---loaded into the composer (matching the desktop overlay's
---`onQueueEdit` behaviour) instead of an immediate dispatch.
---Opens the composer + drops the cursor at end-of-buffer in
---insert mode so the captain can keep typing immediately.
---
---Optional `opts.editing_queue_item_id`: when set, the next
---`M.submit` for this instance routes through `queue/edit`
---against the daemon (preserving the slot's id /
---enqueued_seq / enqueued_at) instead of `prompts/send`.
---`opts.editing_queue_attachments` pre-fills the staged
---attachments so the captain sees the originals + can drop /
---add before saving.
---@param instance_id string
---@param text string
---@param opts? { editing_queue_item_id?: string, editing_queue_attachments?: table[] }
function M.set_text(instance_id, text, opts)
  if type(text) ~= "string" then
    log.warn("composer.set_text: text must be a string")
    return
  end

  opts = opts or {}

  local bufnr = ensure_buffer(instance_id)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))

  -- Stamp the editing-slot pointer so the next submit routes
  -- through `queue/edit`. Cleared on submit success / wipe / a
  -- subsequent `set_text` without the opt (captain abandoned the
  -- edit and is starting a fresh prompt).
  if type(opts.editing_queue_item_id) == "string" and opts.editing_queue_item_id ~= "" then
    editing_queue_slot_by_instance[instance_id] = {
      item_id = opts.editing_queue_item_id,
      attachments = opts.editing_queue_attachments,
    }
    -- Pre-fill staged attachments from the queued item so the
    -- captain sees the originals and can drop / add before save.
    if type(opts.editing_queue_attachments) == "table" then
      attachments_by_instance[instance_id] = vim.deepcopy(opts.editing_queue_attachments)
    end
  else
    editing_queue_slot_by_instance[instance_id] = nil
  end

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
