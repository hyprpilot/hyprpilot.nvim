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

---Resolve the configured composer height to a concrete line count.
---@return integer
local function resolve_height()
  local raw = (config.options.composer or {}).height

  if type(raw) == "function" then
    local ok, value = pcall(raw, vim.o.lines)

    if ok and type(value) == "number" then
      return math.max(1, math.floor(value))
    end

    log.warn("composer: height function returned %s; falling back to 5", vim.inspect(value))

    return 5
  end

  if type(raw) == "number" then
    return math.max(1, math.floor(raw))
  end

  return 5
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
      end
    end
  end
end

local function ensure_buffer(instance_id)
  local existing = buffers[instance_id]

  if existing ~= nil and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end

  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_name(bufnr, "hyprpilot://composer/" .. instance_id)
  vim.bo[bufnr].filetype = "hyprpilot_input"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false

  local keymaps = (config.options.composer or {}).keymaps or {}

  apply_action(bufnr, keymaps.submit, function()
    M.submit()
  end, "submit prompt")

  apply_action(bufnr, keymaps.cancel, function()
    M.cancel()
  end, "cancel in-flight")

  apply_action(bufnr, keymaps.close, function()
    M.close()
  end, "close composer")

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

---Repaint the per-instance attachment indicator on the composer
---buffer's first line. No-op when the composer buffer doesn't exist
---yet (next `open` will paint).
---@param instance_id string
local function paint_indicator(instance_id)
  local bufnr = buffers[instance_id]
  if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, INDICATOR_NS, 0, -1)

  local list = attachments_by_instance[instance_id] or {}
  if #list == 0 then
    return
  end

  local labels = {}
  for _, a in ipairs(list) do
    table.insert(labels, a.title ~= nil and a.title ~= "" and a.title or a.slug)
  end

  local label = string.format("[%d attached: %s]", #list, table.concat(labels, ", "))

  pcall(vim.api.nvim_buf_set_extmark, bufnr, INDICATOR_NS, 0, 0, {
    virt_text = { { label, "HyprpilotComposerAttachments" } },
    virt_text_pos = "right_align",
  })
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
---@param bufnr? integer
---@param opts? { instance_id?: string, title?: string }
---@return hyprpilot.composer.Attachment?
function M.attach_buffer(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    log.warn("composer.attach_buffer: invalid bufnr=%s", bufnr)
    return nil
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    log.warn("composer.attach_buffer: bufnr=%s has no name (write it first)", bufnr)
    return nil
  end

  return M.attach(vim.tbl_extend("force", { path = path }, opts or {}))
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

  return M.attach({
    path = path,
    instance_id = opts.instance_id,
    title = opts.title,
    mime = "image/png",
  })
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
      vim.api.nvim_set_current_win(M._winid)
      vim.cmd("startinsert")
    end

    paint_indicator(instance_id)
    return
  end

  vim.api.nvim_set_current_win(window._winid)
  vim.cmd(string.format("belowright %dsplit", resolve_height()))

  M._winid = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(M._winid, bufnr)
  vim.wo[M._winid].number = false
  vim.wo[M._winid].relativenumber = false
  vim.wo[M._winid].signcolumn = "no"
  vim.wo[M._winid].wrap = true
  vim.wo[M._winid].linebreak = true

  paint_indicator(instance_id)

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
---@param text string?
---@param opts { instance_id?: string }?
function M.submit(text, opts)
  local instance_id = (opts or {}).instance_id or window.active_instance()

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
  end

  text = text:gsub("^%s+", ""):gsub("%s+$", "")

  if text == "" then
    return
  end

  local payload = { instanceId = instance_id, text = text }

  local staged = attachments_by_instance[instance_id]
  if staged ~= nil and #staged > 0 then
    payload.attachments = vim.deepcopy(staged)
  end

  client.request("prompts/send", payload, nil, function(err, _result)
    if err ~= nil then
      log.error("composer.submit: %s", err.message)

      return
    end

    if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end

    attachments_by_instance[instance_id] = nil
    paint_indicator(instance_id)
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

  client.notify("prompts/cancel", { instanceId = id })
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
end

return M
