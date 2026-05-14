--- Behavioural tests for the composer's attachment surface. Cases
--- drive `attach` / `detach` / `submit` and assert on the staged
--- list, the composer-buffer indicator, and the wire payload sent
--- through `client.request` (stubbed to capture).

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

local function active_instance(id)
  -- Force `window.active_instance()` to return `id` by registering
  -- a state with the window module — same path the real composer
  -- relies on.
  local buffer = require("hyprpilot.chat.buffer")
  local window = require("hyprpilot.chat.window")
  local bufnr = buffer.create(id)
  window.register({ bufnr = bufnr, instance_id = id })
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
