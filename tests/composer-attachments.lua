--- Behavioural tests for the composer's attachment surface. Cases
--- drive `attach` / `detach` / `submit` and assert on the staged
--- list, the composer-buffer indicator, and the wire payload sent
--- through `client.request` (stubbed to capture).

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

local function active_instance(id)
  -- Force `window.active_instance()` to return `id` by registering
  -- a state with the window module — same path the real composer
  -- relies on. Pass `activate = true` because `register` no longer
  -- promotes implicitly (a background spawn shouldn't flip the
  -- captain's active instance pointer).
  local buffer = require("hyprpilot.chat.buffer")
  local window = require("hyprpilot.chat.window")
  local bufnr = buffer.create(id)
  window.register({ bufnr = bufnr, instance_id = id }, { activate = true })
  return bufnr
end

T["attach / detach / attachments stage and clear by slug"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)

  composer.clear_attachments(id)

  composer.attach({ path = "/tmp/diagram.png", title = "Architecture" })
  composer.attach({ path = "/tmp/notes.md" })

  local list = composer.attachments(id)
  MiniTest.expect.equality(#list, 2)
  MiniTest.expect.equality(list[1].path, "/tmp/diagram.png")
  MiniTest.expect.equality(list[1].title, "Architecture")
  MiniTest.expect.equality(list[1].mime, "image/png")
  MiniTest.expect.equality(list[2].slug, "notes.md")
  MiniTest.expect.equality(list[2].mime, "text/markdown")

  composer.detach("notes.md")
  MiniTest.expect.equality(#composer.attachments(id), 1)

  composer.clear_attachments(id)
  MiniTest.expect.equality(#composer.attachments(id), 0)

  helpers.cleanup_instance(id)
end

T["attach with the same slug refreshes instead of duplicating"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)
  composer.clear_attachments(id)

  composer.attach({ path = "/tmp/a.txt", slug = "a", title = "first" })
  composer.attach({ path = "/tmp/a.txt", slug = "a", title = "refreshed" })

  local list = composer.attachments(id)
  MiniTest.expect.equality(#list, 1)
  MiniTest.expect.equality(list[1].title, "refreshed")

  composer.clear_attachments(id)
  helpers.cleanup_instance(id)
end

T["attach uses unique slugs when the basename collides"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)
  composer.clear_attachments(id)

  composer.attach({ path = "/tmp/foo/log.txt" })
  composer.attach({ path = "/tmp/bar/log.txt" })

  local list = composer.attachments(id)
  MiniTest.expect.equality(#list, 2)
  MiniTest.expect.equality(list[1].slug, "log.txt")
  MiniTest.expect.equality(list[2].slug, "log.txt-2")

  composer.clear_attachments(id)
  helpers.cleanup_instance(id)
end

T["attach skips with a warn on missing path"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)
  composer.clear_attachments(id)

  local out = composer.attach({})
  MiniTest.expect.equality(out, nil)
  MiniTest.expect.equality(#composer.attachments(id), 0)

  helpers.cleanup_instance(id)
end

T["submit includes attachments in the wire payload + clears on success"] = function()
  local restore, calls = helpers.stub_client_request()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  local bufnr = active_instance(id)
  composer.clear_attachments(id)

  composer.attach({ path = "/tmp/img.png" })
  composer.submit("ship it", { instance_id = id })

  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].method, "prompts/send")
  MiniTest.expect.equality(calls[1].params.text, "ship it")
  MiniTest.expect.equality(#calls[1].params.attachments, 1)
  MiniTest.expect.equality(calls[1].params.attachments[1].path, "/tmp/img.png")

  -- Stub callback fires with success → attachments should be cleared.
  MiniTest.expect.equality(#composer.attachments(id), 0)

  restore()
  -- Local cleanup: the cleanup_instance helper wipes the buffer the
  -- active_instance() helper created.
  local _ = bufnr
  helpers.cleanup_instance(id)
end

T["submit forwards with_config as withConfig on prompts/send"] = function()
  local restore, calls = helpers.stub_client_request()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)

  composer.submit("ship it", {
    instance_id = id,
    with_config = { { mcps = { { id = "fs", enabled = true } } } },
  })

  MiniTest.expect.equality(calls[1].method, "prompts/send")
  MiniTest.expect.equality(#calls[1].params.withConfig, 1)
  MiniTest.expect.equality(calls[1].params.withConfig[1].mcps[1].id, "fs")

  restore()
  helpers.cleanup_instance(id)
end

T["submit omits withConfig from prompts/send when with_config is a map (warn + skip)"] = function()
  local restore, calls = helpers.stub_client_request()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)

  composer.submit("ship it", {
    instance_id = id,
    -- map-shaped (single patch object) instead of list-of-patches.
    with_config = { agents = { { id = "code" } } },
  })

  MiniTest.expect.equality(calls[1].params.withConfig, nil)

  restore()
  helpers.cleanup_instance(id)
end

T["submit without attachments omits the wire field"] = function()
  local restore, calls = helpers.stub_client_request()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)
  composer.clear_attachments(id)

  composer.submit("plain text", { instance_id = id })

  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].params.attachments, nil)

  restore()
  helpers.cleanup_instance(id)
end

T["attach renders virt_lines anchored to the composer's last buffer line"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)
  composer.clear_attachments(id)

  -- Mint the composer buffer via the test seam so the indicator has
  -- a buffer to paint on without needing a real window stack.
  local name = "hyprpilot://composer/" .. id
  local cbuf = require("hyprpilot.chat.buffer").find_by_name(name)
    or (function()
      local b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(b, name)
      composer._register_buffer_for_tests(id, b)
      return b
    end)()
  vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, { "writing this prompt", "across two lines" })

  composer.attach({ path = "/tmp/diagram.png", title = "Architecture" })
  composer.attach({ path = "/tmp/notes.md" })

  local ns = vim.api.nvim_get_namespaces()["hyprpilot.composer.attachments"]
  MiniTest.expect.equality(ns ~= nil, true)

  local marks = vim.api.nvim_buf_get_extmarks(cbuf, ns, 0, -1, { details = true })
  MiniTest.expect.equality(#marks, 1)

  local row = marks[1][2]
  local details = marks[1][4]
  -- Anchored to the last real line (0-indexed) so the stack stays at
  -- the bottom of the visible composer.
  MiniTest.expect.equality(row, vim.api.nvim_buf_line_count(cbuf) - 1)
  MiniTest.expect.equality(#details.virt_lines, 2)
  MiniTest.expect.equality(details.virt_lines[1][1][1], "  - Architecture")
  MiniTest.expect.equality(details.virt_lines[2][1][1], "  - notes.md")

  composer.clear_attachments(id)
  -- After clear, the namespace should hold no extmarks.
  MiniTest.expect.equality(#vim.api.nvim_buf_get_extmarks(cbuf, ns, 0, -1, {}), 0)

  composer.wipe(id)
  helpers.cleanup_instance(id)
end

--- Helpers for attach_file cases below — write a temp file with the
--- given contents (and optional extension) and return its absolute
--- path. Each test cleans up via os.remove.
local function write_tmp(contents, ext)
  local path = vim.fn.tempname() .. (ext or "")
  local fd = vim.uv.fs_open(path, "w", 420)
  vim.uv.fs_write(fd, contents, 0)
  vim.uv.fs_close(fd)
  return path
end

T["attach_file: text mime → ships body as readfile content"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)
  composer.clear_attachments(id)

  local path = write_tmp("alpha\nbeta\ngamma", ".md")
  local entry = composer.attach_file(path)

  MiniTest.expect.equality(entry ~= nil, true)
  MiniTest.expect.equality(entry.mime, "text/markdown")
  MiniTest.expect.equality(entry.body, "alpha\nbeta\ngamma")
  MiniTest.expect.equality(entry.data, nil)

  os.remove(path)
  composer.clear_attachments(id)
  helpers.cleanup_instance(id)
end

T["attach_file: binary mime → ships data as base64"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)
  composer.clear_attachments(id)

  -- 1×1 transparent PNG (smallest possible).
  local png = "\137PNG\r\n\26\n\0\0\0\rIHDR\0\0\0\1\0\0\0\1\8\6\0\0\0\31\21\196\137\0\0\0\rIDATx\156c\0\1\0\0\5\0\1\13\10\45\180\0\0\0\0IEND\174B`\130"
  local path = write_tmp(png, ".png")
  local entry = composer.attach_file(path)

  MiniTest.expect.equality(entry ~= nil, true)
  MiniTest.expect.equality(entry.mime, "image/png")
  MiniTest.expect.equality(entry.body, nil)
  MiniTest.expect.equality(type(entry.data), "string")
  MiniTest.expect.equality(#entry.data > 0, true)

  os.remove(path)
  composer.clear_attachments(id)
  helpers.cleanup_instance(id)
end

T["attach_file: unknown extension → null-byte sniff routes text vs binary"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)
  composer.clear_attachments(id)

  -- Plain ASCII, unknown extension → sniff says "text" → body.
  local text_path = write_tmp("hello world", ".unknown")
  local text_entry = composer.attach_file(text_path)
  MiniTest.expect.equality(text_entry.body, "hello world")
  MiniTest.expect.equality(text_entry.data, nil)

  -- Contains a null byte → sniff says "binary" → data + octet-stream.
  local bin_path = write_tmp("AB\0CD", ".unknown")
  local bin_entry = composer.attach_file(bin_path)
  MiniTest.expect.equality(bin_entry.mime, "application/octet-stream")
  MiniTest.expect.equality(bin_entry.body, nil)
  MiniTest.expect.equality(type(bin_entry.data), "string")

  os.remove(text_path)
  os.remove(bin_path)
  composer.clear_attachments(id)
  helpers.cleanup_instance(id)
end

T["attach_file: rejects oversize files via composer.attach.max_bytes"] = function()
  local composer = require("hyprpilot.composer")
  local config = require("hyprpilot.config")
  local id = helpers.unique_id()
  active_instance(id)
  composer.clear_attachments(id)

  local original = config.options.composer.attach.max_bytes
  config.options.composer.attach.max_bytes = 4 -- 4 bytes ceiling

  local path = write_tmp("this is more than four bytes", ".txt")
  local entry = composer.attach_file(path)

  MiniTest.expect.equality(entry, nil)
  MiniTest.expect.equality(#composer.attachments(id), 0)

  config.options.composer.attach.max_bytes = original
  os.remove(path)
  composer.clear_attachments(id)
  helpers.cleanup_instance(id)
end

T["attach_file: missing path returns nil + warn"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)
  composer.clear_attachments(id)

  local missing = vim.fn.tempname() .. "-does-not-exist"
  local entry = composer.attach_file(missing)
  MiniTest.expect.equality(entry, nil)

  composer.clear_attachments(id)
  helpers.cleanup_instance(id)
end

T["wipe drops staged attachments alongside the buffer"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)
  composer.clear_attachments(id)

  composer.attach({ path = "/tmp/x.txt" })
  composer.wipe(id)

  MiniTest.expect.equality(#composer.attachments(id), 0)
  helpers.cleanup_instance(id)
end

return T
