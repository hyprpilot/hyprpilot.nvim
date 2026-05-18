--- Generic clipboard probe + save_as helper. Lists every mime
--- type the system clipboard currently advertises; the caller
--- picks the best one for its use case and writes the content
--- straight to disk. No assumptions about images-vs-text — works
--- for PNG / JPEG / SVG / PDF / WebP / HTML / Markdown / plain
--- text / arbitrary binary on hosts whose clipboard backends
--- expose them.
---
--- Backends (resolved in order, first hit wins):
---   Windows / WSL   → `powershell.exe`
---   macOS           → `pbpaste` (text) + `osascript` (mime probe + binary)
---   Wayland Linux   → `wl-paste`
---   X11 Linux       → `xclip`
---
--- macOS uses the standard system tools end-to-end: `pbpaste` for
--- text round-trips and `osascript` for mime enumeration via
--- `clipboard info` + per-class extraction
--- (`the clipboard as «class PNGf»` / `«class PDF »` / …). No
--- extra third-party binaries required.
---
--- Pure functions, no module state beyond a single cached backend
--- resolution. Caller decides where to save (typically
--- `vim.fn.tempname()` + a generated basename with the right
--- extension for the picked mime).

local log = require("hyprpilot.log")

local M = {}

--- Cached clipboard backend. The probe is `executable()` +
--- env-var lookups so it's cheap, but cache anyway to keep
--- `attach_clipboard` branch-free on the common path.
---@type string?
local _cached_cmd = nil

---True when `name` is executable on PATH.
---@param name string
---@return boolean
local function has(name)
  return vim.fn.executable(name) == 1
end

---Detect which clipboard backend is available. Returns the
---backend's primary binary (`powershell.exe`, `pbpaste`,
---`wl-paste`, `xclip`) or nil when nothing usable resolves.
---@return string?
function M.resolve_cmd()
  if _cached_cmd ~= nil then
    return _cached_cmd
  end

  local sys = vim.uv.os_uname().sysname or ""
  if (sys:match("Windows") or vim.fn.has("wsl") == 1) and has("powershell.exe") then
    _cached_cmd = "powershell.exe"
  elseif sys == "Darwin" and has("pbpaste") then
    _cached_cmd = "pbpaste"
  elseif os.getenv("WAYLAND_DISPLAY") ~= nil and has("wl-paste") then
    _cached_cmd = "wl-paste"
  elseif os.getenv("DISPLAY") ~= nil and has("xclip") then
    _cached_cmd = "xclip"
  end

  return _cached_cmd
end

---List the mime types the system clipboard currently advertises.
---Sorted in backend-native order (which is typically the clipboard
---owner's preference order — first entry is the source's
---highest-fidelity offering). Returns an empty list when the
---clipboard is empty OR no backend resolves.
---@return string[]
function M.list_mime_types()
  local cmd = M.resolve_cmd()
  if cmd == nil then
    return {}
  end

  if cmd == "xclip" then
    -- `xclip -t TARGETS -o` returns one mime per line.
    local out = vim.system({ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" }, { text = true }):wait()
    if out.code ~= 0 then
      return {}
    end
    return vim.split(out.stdout or "", "\n", { plain = true, trimempty = true })
  end

  if cmd == "wl-paste" then
    local out = vim.system({ "wl-paste", "--list-types" }, { text = true }):wait()
    if out.code ~= 0 then
      return {}
    end
    return vim.split(out.stdout or "", "\n", { plain = true, trimempty = true })
  end

  if cmd == "pbpaste" then
    -- macOS: `osascript -e 'clipboard info'` returns the full mime
    -- class list (PNGf, TIFF, PDF, RTF, HTML, utf8, …). Translate
    -- each AppleScript class to its mime equivalent.
    local types = {}
    local probe = [[
      set out to ""
      set clipInfo to clipboard info
      repeat with c in clipInfo
        set out to out & (item 1 of c) & linefeed
      end repeat
      return out
    ]]
    local osa = vim.system({ "osascript", "-e", probe }, { text = true }):wait()
    if osa.code == 0 then
      for _, t in ipairs(vim.split(osa.stdout or "", "\n", { plain = true, trimempty = true })) do
        local mime = M._osa_class_to_mime(t)
        if mime ~= nil then
          table.insert(types, mime)
        end
      end
    end
    -- Belt + braces: `pbpaste` with no args returns the text
    -- representation. If it's non-empty and `text/plain` didn't
    -- already land via the osascript probe, add it — covers older
    -- macOS / minimal hosts where `clipboard info` returns nothing
    -- usable.
    local has_text = false
    for _, m in ipairs(types) do
      if m == "text/plain" then
        has_text = true
        break
      end
    end
    if not has_text then
      local pb = vim.system({ "pbpaste" }, { text = true }):wait()
      if pb.code == 0 and (pb.stdout or "") ~= "" then
        table.insert(types, "text/plain")
      end
    end
    return types
  end

  if cmd == "powershell.exe" then
    -- Probe via `Get-Clipboard -Format <kind>` + ContainsImage /
    -- ContainsText / ContainsFileDropList. Returns the supported
    -- subset in priority order.
    local script = [[
      Add-Type -AssemblyName System.Windows.Forms
      $cb = [System.Windows.Forms.Clipboard]
      if ($cb::ContainsImage()) { Write-Output 'image/png' }
      if ($cb::ContainsFileDropList()) { Write-Output 'text/uri-list' }
      if ($cb::ContainsText()) { Write-Output 'text/plain' }
    ]]
    local out = vim.system({ "powershell.exe", "-NoProfile", "-Command", script }, { text = true }):wait()
    if out.code ~= 0 then
      return {}
    end
    return vim.split(out.stdout or "", "\n", { plain = true, trimempty = true })
  end

  return {}
end

---Translate an AppleScript clipboard-info class identifier into
---a mime type. Covers the common ones; unknown classes return nil
---(caller drops them from the listed-types set).
---@param class_name string
---@return string?
function M._osa_class_to_mime(class_name)
  local map = {
    ["«class PNGf»"] = "image/png",
    ["«class TIFF»"] = "image/tiff",
    ["«class jp2 »"] = "image/jp2",
    ["«class JPEG»"] = "image/jpeg",
    ["«class PDF »"] = "application/pdf",
    ["«class RTF »"] = "application/rtf",
    ["«class HTML»"] = "text/html",
    ["«class utf8»"] = "text/plain",
    ["«class ut16»"] = "text/plain",
    ["string"] = "text/plain",
    ["Unicode text"] = "text/plain",
  }
  return map[class_name]
end

---Save the clipboard's `mime_type` payload to `path`. Returns
---true on success, false on any failure (mime not on clipboard,
---backend missing, exec failure, IO failure). Caller is
---responsible for the containing directory existing.
---@param mime_type string                    -- one of the entries from `list_mime_types()`
---@param path string                         -- absolute file path
---@return boolean ok
function M.save_as(mime_type, path)
  if type(mime_type) ~= "string" or mime_type == "" then
    log.warn("composer.clipboard.save_as: mime_type must be a non-empty string")
    return false
  end
  if type(path) ~= "string" or path == "" then
    log.warn("composer.clipboard.save_as: path must be a non-empty string")
    return false
  end

  local cmd = M.resolve_cmd()
  if cmd == nil then
    log.debug("composer.clipboard.save_as: no backend on PATH")
    return false
  end

  if cmd == "xclip" then
    local out = vim.system({ "xclip", "-selection", "clipboard", "-o", "-t", mime_type }, { text = false }):wait()
    if out.code ~= 0 or out.stdout == nil or out.stdout == "" then
      log.warn("composer.clipboard.save_as: xclip(%s) exited %d", mime_type, out.code)
      return false
    end
    return M._write_bytes(path, out.stdout)
  end

  if cmd == "wl-paste" then
    local out = vim.system({ "wl-paste", "--type", mime_type }, { text = false }):wait()
    if out.code ~= 0 or out.stdout == nil or out.stdout == "" then
      log.warn("composer.clipboard.save_as: wl-paste(%s) exited %d", mime_type, out.code)
      return false
    end
    return M._write_bytes(path, out.stdout)
  end

  if cmd == "pbpaste" then
    -- macOS: text goes through `pbpaste`, everything else through
    -- `osascript`'s `the clipboard as «class XYZ»` + binary write.
    if mime_type == "text/plain" then
      local out = vim.system({ "pbpaste" }, { text = true }):wait()
      if out.code ~= 0 then
        return false
      end
      return M._write_bytes(path, out.stdout or "")
    end
    local cls = M._mime_to_osa_class(mime_type)
    if cls == nil then
      log.warn("composer.clipboard.save_as: no osascript class for mime=%s", mime_type)
      return false
    end
    local script = string.format(
      "set the_data to (the clipboard as %s)\n"
        .. "set the_file to open for access POSIX file %q with write permission\n"
        .. "set eof of the_file to 0\n"
        .. "write the_data to the_file\n"
        .. "close access the_file",
      cls,
      path
    )
    local out = vim.system({ "osascript", "-e", script }, { text = true }):wait()
    if out.code ~= 0 then
      log.warn("composer.clipboard.save_as: osascript(%s) exited %d (%s)", mime_type, out.code, tostring(out.stderr))
      return false
    end
    return true
  end

  if cmd == "powershell.exe" then
    local escaped = path:gsub("'", "''")
    local script
    if mime_type == "image/png" then
      script = string.format(
        "Add-Type -AssemblyName System.Windows.Forms; "
          .. "if ([System.Windows.Forms.Clipboard]::ContainsImage()) { "
          .. "[System.Windows.Forms.Clipboard]::GetImage().Save('%s') } else { exit 1 }",
        escaped
      )
    elseif mime_type == "text/plain" then
      script = string.format(
        "Add-Type -AssemblyName System.Windows.Forms; "
          .. "if ([System.Windows.Forms.Clipboard]::ContainsText()) { "
          .. "[System.IO.File]::WriteAllText('%s', [System.Windows.Forms.Clipboard]::GetText()) } else { exit 1 }",
        escaped
      )
    else
      log.warn("composer.clipboard.save_as: no powershell backend for mime=%s", mime_type)
      return false
    end
    local out = vim.system({ "powershell.exe", "-NoProfile", "-Command", script }):wait()
    if out.code ~= 0 then
      log.warn("composer.clipboard.save_as: powershell(%s) exited %d (%s)", mime_type, out.code, tostring(out.stderr))
      return false
    end
    return true
  end

  return false
end

---Translate a mime type into the AppleScript clipboard class
---identifier. Inverse of `_osa_class_to_mime`. Returns nil for
---mime types macOS doesn't natively address as a clipboard class.
---@param mime_type string
---@return string?
function M._mime_to_osa_class(mime_type)
  local map = {
    ["image/png"] = "«class PNGf»",
    ["image/tiff"] = "«class TIFF»",
    ["image/jpeg"] = "«class JPEG»",
    ["application/pdf"] = "«class PDF »",
    ["application/rtf"] = "«class RTF »",
    ["text/html"] = "«class HTML»",
    ["text/plain"] = "«class utf8»",
  }
  return map[mime_type]
end

---Default mime-type → file-extension map. Used when the caller
---doesn't supply its own and just wants a sensible basename for a
---given mime. Returns nil for unknown mimes so the caller can
---fall back to a generic `.bin`.
---@param mime_type string
---@return string?
function M.extension_for(mime_type)
  local map = {
    ["image/png"] = "png",
    ["image/jpeg"] = "jpg",
    ["image/jp2"] = "jp2",
    ["image/gif"] = "gif",
    ["image/webp"] = "webp",
    ["image/tiff"] = "tiff",
    ["image/svg+xml"] = "svg",
    ["image/bmp"] = "bmp",
    ["application/pdf"] = "pdf",
    ["application/rtf"] = "rtf",
    ["application/zip"] = "zip",
    ["application/json"] = "json",
    ["application/yaml"] = "yaml",
    ["text/html"] = "html",
    ["text/markdown"] = "md",
    ["text/csv"] = "csv",
    ["text/uri-list"] = "uri",
    ["text/plain"] = "txt",
  }
  return map[mime_type] or map[mime_type:lower()]
end

---Pick the highest-fidelity mime from `available` according to a
---fixed preference order. The captain pasted from a source that
---advertised multiple formats (e.g. screenshot: `image/png` +
---`image/tiff` + `text/plain` filename); we want the rendered
---bitmap not the filename. Returns nil when `available` has no
---supported entry — caller falls back to text-register.
---@param available string[]
---@return string?
function M.pick_best_mime(available)
  if type(available) ~= "table" or #available == 0 then
    return nil
  end
  -- Lookup table for O(1) membership.
  local present = {}
  for _, m in ipairs(available) do
    present[m] = true
  end
  -- Preference order: images first (binary, lossless first),
  -- then richer documents (PDF), then HTML, then markdown / text.
  -- Uri-list at the tail because file references are usually only
  -- useful when nothing else attaches.
  local prefer = {
    "image/png",
    "image/webp",
    "image/jpeg",
    "image/jp2",
    "image/tiff",
    "image/gif",
    "image/svg+xml",
    "image/bmp",
    "application/pdf",
    "application/rtf",
    "text/html",
    "text/markdown",
    "text/csv",
    "application/json",
    "application/yaml",
    "text/plain",
    "text/uri-list",
  }
  for _, m in ipairs(prefer) do
    if present[m] then
      return m
    end
  end
  -- Nothing on the preference list matched, but `available` is
  -- non-empty — return the first entry verbatim so unusual but
  -- valid mimes still attach.
  return available[1]
end

---Write `bytes` (raw string, may contain NULs) to `path` via
---`vim.uv.fs_open` + `fs_write`. Returns true on success, false on
---any IO error. Mode 0o600 (captain-only).
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

---Reset the cached backend. Test-only — flips a captain who
---toggles `$WAYLAND_DISPLAY` mid-session out of the stale cache.
function M._reset_cache()
  _cached_cmd = nil
end

return M
