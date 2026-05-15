--- Behavioural tests for `chat.window.close(instance_id)`'s
--- per-instance cleanup cascade. `hp.close(id)` must wipe every
--- piece of plugin state belonging to that instance, not just the
--- chat buffer — otherwise the captain accumulates orphan composer
--- buffers + stale permission-queue entries every spawn-and-close
--- cycle.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["window.close cascades into composer.wipe (composer buffer drops with chat buffer)"] = function()
  local window = require("hyprpilot.chat.window")
  local composer = require("hyprpilot.composer")
  local buffer = require("hyprpilot.chat.buffer")

  local id = helpers.unique_id()
  local chat_buf = buffer.create(id)
  window.register({ bufnr = chat_buf, instance_id = id }, { activate = true })

  -- The composer module mints the per-instance buffer lazily on
  -- `open()`. Opening the split needs a real chat window which the
  -- test env lacks — drop a stand-in buffer with the canonical
  -- name + stage an attachment so the wipe path has both pieces of
  -- state to clean. The window.close cascade calls composer.wipe(id),
  -- which finds the buffer via the in-module `buffers[id]` map OR
  -- (via this branch) the named one we stood up here.
  local composer_buf_name = "hyprpilot://composer/" .. id
  local stub_composer_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(stub_composer_buf, composer_buf_name)
  vim.bo[stub_composer_buf].filetype = "hyprpilot_input"

  -- Push the stub into composer's internal map so `composer.wipe`
  -- finds it. Mirrors what the real `ensure_buffer` path does
  -- (it sets `buffers[id] = bufnr`).
  composer._register_buffer_for_tests(id, stub_composer_buf)

  composer.attach({ path = "/tmp/leak-probe.txt", instance_id = id })

  local found_before = buffer.find_by_name(composer_buf_name)
  MiniTest.expect.equality(found_before ~= nil, true)

  window.close(id)

  -- After window.close: the composer buffer for `id` must be gone.
  local found_after = buffer.find_by_name(composer_buf_name)
  MiniTest.expect.equality(found_after, nil)

  -- Staged attachments dropped too (composer.wipe clears them).
  MiniTest.expect.equality(#composer.attachments(id), 0)

  -- Chat buffer also wiped — pre-existing behaviour, regression
  -- guard.
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(chat_buf), false)
end

T["window.close drops permission-row queue entries for the closed instance"] = function()
  local window = require("hyprpilot.chat.window")
  local permission_row = require("hyprpilot.chat.permission-row")
  local buffer = require("hyprpilot.chat.buffer")

  local id_a = helpers.unique_id()
  local id_b = helpers.unique_id()
  window.register({ bufnr = buffer.create(id_a), instance_id = id_a }, { activate = true })
  window.register({ bufnr = buffer.create(id_b), instance_id = id_b }, { activate = true })

  permission_row.reset()
  permission_row.enqueue(id_a, {
    request_id = "req-a",
    tool = "Bash",
    options = { { optionId = "allow", name = "Allow", kind = "allow_once" } },
    formatted = { title = "x", stats = {}, fields = {} },
  })
  permission_row.enqueue(id_b, {
    request_id = "req-b",
    tool = "Bash",
    options = { { optionId = "allow", name = "Allow", kind = "allow_once" } },
    formatted = { title = "y", stats = {}, fields = {} },
  })

  MiniTest.expect.equality(#permission_row._queue, 2)

  window.close(id_a)

  -- Only instance B's entry remains.
  MiniTest.expect.equality(#permission_row._queue, 1)
  MiniTest.expect.equality(permission_row._queue[1].instance_id, id_b)

  permission_row.reset()
  window.close(id_b)
end

return T
