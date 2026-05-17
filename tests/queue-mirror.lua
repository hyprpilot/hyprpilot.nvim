--- Behavioural tests for the daemon-mirror queue cache in
--- `chat/queue-strip.lua` + the composer edit-slot path that
--- routes the next submit through `queue/edit` instead of
--- `prompts/send`.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["queue-strip.handle_queue_changed: replaces the cache wholesale"] = function()
  local strip = require("hyprpilot.chat.queue-strip")
  strip._reset()

  strip.handle_queue_changed("inst-1", {
    { id = "i1", text = "first", enqueued_seq = 1, enqueued_at = 1 },
    { id = "i2", text = "second", enqueued_seq = 2, enqueued_at = 2 },
  })
  MiniTest.expect.equality(#strip.items("inst-1"), 2)

  -- Daemon emits a fresh full snapshot when an item is removed —
  -- our cache must wholesale-replace, not append.
  strip.handle_queue_changed("inst-1", {
    { id = "i2", text = "second", enqueued_seq = 2, enqueued_at = 2 },
  })
  MiniTest.expect.equality(#strip.items("inst-1"), 1)
  MiniTest.expect.equality(strip.items("inst-1")[1].id, "i2")

  strip._reset()
end

T["queue-strip.handle_queue_changed: empty list clears the instance"] = function()
  local strip = require("hyprpilot.chat.queue-strip")
  strip._reset()

  strip.handle_queue_changed("inst-1", {
    { id = "i1", text = "x", enqueued_seq = 1, enqueued_at = 1 },
  })
  strip.handle_queue_changed("inst-1", {})
  MiniTest.expect.equality(strip.has_items("inst-1"), false)

  strip._reset()
end

T["queue-strip.forget: drops the per-instance cache"] = function()
  local strip = require("hyprpilot.chat.queue-strip")
  strip._reset()

  strip.handle_queue_changed("inst-1", {
    { id = "i1", text = "x", enqueued_seq = 1, enqueued_at = 1 },
  })
  strip.forget("inst-1")
  MiniTest.expect.equality(strip.has_items("inst-1"), false)

  strip._reset()
end

T["composer.set_text(opts.editing_queue_item_id) stamps edit slot + pre-fills attachments"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  -- Mint composer buffer via the test seam.
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].filetype = "hyprpilot_composer"
  composer._register_buffer_for_tests(id, bufnr)

  composer.set_text(id, "edit me", {
    editing_queue_item_id = "queue-i1",
    editing_queue_attachments = { { path = "/tmp/orig.png", slug = "orig.png" } },
  })

  -- Buffer contents reflect the new text.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(lines[1], "edit me")

  -- Attachments staged from the queue item.
  local staged = composer.attachments(id)
  MiniTest.expect.equality(#staged, 1)
  MiniTest.expect.equality(staged[1].slug, "orig.png")

  composer.wipe(id)
end

T["composer.submit while edit-slot is set fires queue/edit, not prompts/send"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].filetype = "hyprpilot_composer"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "edited body" })
  composer._register_buffer_for_tests(id, bufnr)

  -- Stamp the edit slot via set_text (the only public path).
  composer.set_text(id, "edited body", { editing_queue_item_id = "queue-i1" })

  local restore_client, calls = helpers.stub_client_with({
    ["queue/edit"] = { result = { item = { id = "queue-i1", text = "edited body", enqueuedSeq = 1, enqueuedAt = 1 } } },
  })

  composer.submit(nil, { instance_id = id })

  -- Wire-side: queue/edit fired, prompts/send did NOT.
  local saw_edit, saw_send = false, false
  for _, c in ipairs(calls) do
    if c.method == "queue/edit" then
      saw_edit = true
    end
    if c.method == "prompts/send" then
      saw_send = true
    end
  end
  MiniTest.expect.equality(saw_edit, true)
  MiniTest.expect.equality(saw_send, false)
  MiniTest.expect.equality(calls[1].params.itemId, "queue-i1")
  MiniTest.expect.equality(calls[1].params.text, "edited body")

  composer.wipe(id)
  restore_client()
end

T["composer.submit fires prompts/send unconditionally (no plugin-side activity gate)"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].filetype = "hyprpilot_composer"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "while busy" })
  composer._register_buffer_for_tests(id, bufnr)

  -- Even with the instance marked busy, the plugin no longer pre-
  -- gates on activity — daemon's auto-route decides enqueue vs
  -- send-now and reports back via `disposition`.
  require("hyprpilot.status").set_activity(id, { kind = "streaming" })

  local restore_client, calls = helpers.stub_client_with({
    ["prompts/send"] = { result = { accepted = true, disposition = "queued" } },
    -- Submit-queued fires a defensive snapshot (via
    -- queue-strip.hydrate) so the strip reflects the dropped prompt
    -- even if the daemon's `queue_changed` event misses.
    ["instance/snapshot/queue"] = { result = { items = {} } },
  })

  composer.submit(nil, { instance_id = id })

  -- prompts/send fires first; instance/snapshot/queue follows from
  -- the queued-branch resync.
  MiniTest.expect.equality(#calls, 2)
  MiniTest.expect.equality(calls[1].method, "prompts/send")
  MiniTest.expect.equality(calls[2].method, "instance/snapshot/queue")

  require("hyprpilot.status").set_activity(id, { kind = "idle" })
  composer.wipe(id)
  restore_client()
end

return T
