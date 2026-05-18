--- Internal clipboard probe + save_image helper. Mirrors the
--- shell-out approach `img-clip.nvim` uses (xclip / wl-paste /
--- pngpaste / powershell.exe) but inline so the plugin doesn't
--- carry an external Neovim dependency just for the
--- "is the clipboard an image, and if so write it to a temp file"
--- two-call surface that `composer.attach_clipboard` consumes.
---
--- Pure functions, no module state. Caller decides where to save
--- (typically `vim.fn.tempname()` + a deterministic basename).

local log = require("hyprpilot.log")

local M = {}

--- Resolved clipboard backend keyed by the binary we run. Cached
--- across calls — the probe is `executable()` + env-var lookups,
--- cheap to redo, but cache anyway to keep `attach_clipboard`
--- branch-free on the common path.
---@type string?
local _cached_cmd = nil

---True when `name` is executable on PATH. Wraps `vim.fn.executable`
---which returns 1 for found, 0 for not.
---@param name string
---@return boolean
local function has(name)
  return vim.fn.executable(name) == 1
end

---Detect which clipboard backend is available on this host.
---Resolution order matches `img-clip`:
---   Windows / WSL  → `powershell.exe`
---   macOS          → `pngpaste`
---   Wayland Linux  → `wl-paste` (requires `$WAYLAND_DISPLAY`)
---   X11 Linux      → `xclip` (requires `$DISPLAY`)
---Returns nil when nothing usable is on PATH — caller falls
---through to the text path.
---@return string?
function M.resolve_cmd()
  if _cached_cmd ~= nil then
    return _cached_cmd
  end

  local sys = vim.uv.os_uname().sysname or ""
  if (sys:match("Windows") or vim.fn.has("wsl") == 1) and has("powershell.exe") then
    _cached_cmd = "powershell.exe"
  elseif sys == "Darwin" and has("pngpaste") then
    _cached_cmd = "pngpaste"
  elseif os.getenv("WAYLAND_DISPLAY") ~= nil and has("wl-paste") then
    _cached_cmd = "wl-paste"
  elseif os.getenv("DISPLAY") ~= nil and has("xclip") then
    _cached_cmd = "xclip"
  end

  return _cached_cmd
end

---True when the system clipboard currently holds a PNG image.
---Probes via `--list-types` (wl-paste) / `-t TARGETS -o` (xclip) /
---empty-pipe exit code (pngpaste) / GetImage hit (powershell).
---Returns false when no backend resolves OR the probe says the
---clipboard holds text / nothing / a non-PNG image.
---@return boolean
function M.content_is_image()
  local cmd = M.resolve_cmd()
  if cmd == nil then
    return false
  end

  if cmd == "xclip" then
    local out = vim.system({ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" }, { text = true }):wait()
    return out.code == 0 and (out.stdout or ""):find("image/png", 1, true) ~= nil
  end

  if cmd == "wl-paste" then
    local out = vim.system({ "wl-paste", "--list-types" }, { text = true }):wait()
    return out.code == 0 and (out.stdout or ""):find("image/png", 1, true) ~= nil
  end

  if cmd == "pngpaste" then
    -- pngpaste exits non-zero when the clipboard isn't a PNG. Pipe
    -- to /dev/null so we don't spew the image bytes into the
    -- captured stdout for nothing.
    local out = vim.system({ "pngpaste", "-" }, { text = false }):wait()
    return out.code == 0
  end

  if cmd == "powershell.exe" then
    local out = vim
      .system(
        { "powershell.exe", "-NoProfile", "-Command", "Add-Type -AssemblyName System.Windows.Forms; if ([System.Windows.Forms.Clipboard]::ContainsImage()) { 'yes' }" },
        { text = true }
      )
      :wait()
    return out.code == 0 and (out.stdout or ""):find("yes", 1, true) ~= nil
  end

  return false
end

---Write the system clipboard's PNG image to `path`. Returns true
---on success, false on any failure (no backend, empty clipboard,
---non-PNG content, exec failure). Caller is responsible for the
---containing directory existing (use `vim.fn.mkdir(dir, "p")`).
---@param path string                       -- absolute file path
---@return boolean ok
function M.save_image(path)
  if type(path) ~= "string" or path == "" then
    log.warn("composer.clipboard.save_image: path must be a non-empty string")
    return false
  end

  local cmd = M.resolve_cmd()
  if cmd == nil then
    log.debug("composer.clipboard.save_image: no clipboard backend on PATH")
    return false
  end

  if cmd == "xclip" then
    -- `xclip -o -t image/png` writes raw PNG to stdout — capture
    -- as binary (text = false) and write the bytes to `path`.
    local out = vim.system({ "xclip", "-selection", "clipboard", "-o", "-t", "image/png" }, { text = false }):wait()
    if out.code ~= 0 or out.stdout == nil or out.stdout == "" then
      log.warn("composer.clipboard.save_image: xclip exited %d", out.code)
      return false
    end
    return M._write_bytes(path, out.stdout)
  end

  if cmd == "wl-paste" then
    local out = vim.system({ "wl-paste", "--type", "image/png" }, { text = false }):wait()
    if out.code ~= 0 or out.stdout == nil or out.stdout == "" then
      log.warn("composer.clipboard.save_image: wl-paste exited %d", out.code)
      return false
    end
    return M._write_bytes(path, out.stdout)
  end

  if cmd == "pngpaste" then
    -- `pngpaste <path>` writes directly to the target file.
    local out = vim.system({ "pngpaste", path }):wait()
    if out.code ~= 0 then
      log.warn("composer.clipboard.save_image: pngpaste exited %d (%s)", out.code, tostring(out.stderr))
      return false
    end
    return true
  end

  if cmd == "powershell.exe" then
    -- Quote the path with single quotes — powershell treats single-
    -- quoted strings as literal. Escape any embedded single quote.
    local escaped = path:gsub("'", "''")
    local script = string.format(
      "Add-Type -AssemblyName System.Windows.Forms; "
        .. "if ([System.Windows.Forms.Clipboard]::ContainsImage()) { "
        .. "[System.Windows.Forms.Clipboard]::GetImage().Save('%s') } else { exit 1 }",
      escaped
    )
    local out = vim.system({ "powershell.exe", "-NoProfile", "-Command", script }):wait()
    if out.code ~= 0 then
      log.warn("composer.clipboard.save_image: powershell exited %d (%s)", out.code, tostring(out.stderr))
      return false
    end
    return true
  end

  return false
end

---Write `bytes` (raw string, may contain NULs) to `path` via
---`vim.uv.fs_open` + `fs_write`. Returns true on success, false
---on any IO error. Mode 0o600 (captain-only) since these are
---temp clipboard payloads, not shared.
---@param path string
---@param bytes string
---@return boolean ok
function M._write_bytes(path, bytes)
  local fd, open_err = vim.uv.fs_open(path, "w", tonumber("600", 8))
  if fd == nil then
    log.warn("composer.clipboard._write_bytes: fs_open(%s) failed: %s", path, tostring(open_err))
    return false
  end
  local _, write_err = vim.uv.fs_write(fd, bytes, 0)
  vim.uv.fs_close(fd)
  if write_err ~= nil then
    log.warn("composer.clipboard._write_bytes: fs_write(%s) failed: %s", path, tostring(write_err))
    return false
  end
  return true
end

---Reset the cached backend. Test-only — flips a captain who toggles
---`$WAYLAND_DISPLAY` mid-session out of the stale cache.
function M._reset_cache()
  _cached_cmd = nil
end

return M
