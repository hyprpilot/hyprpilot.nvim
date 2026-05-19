--- Behavioural tests for `composer.set_text` — the public hook the
--- queue strip's `edit` keymap calls to drop a parked prompt back into
--- the composer for editing (matching the desktop overlay's
--- `onQueueEdit` UX).

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["composer.set_text: replaces the per-instance buffer's lines with `text`"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()

  -- Stand up a stub composer buffer the same way `ensure_buffer`
  -- would, so `set_text` finds it without needing a chat split.
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "hyprpilot://composer/" .. id)
  vim.bo[bufnr].filetype = "hyprpilot_composer"
  composer._register_buffer_for_tests(id, bufnr)

  -- Pre-load some stale text so we can prove the replacement is
  -- destructive (not append).
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "stale content" })

  composer.set_text(id, "first line\nsecond line")

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(lines[1], "first line")
  MiniTest.expect.equality(lines[2], "second line")
  MiniTest.expect.equality(#lines, 2)

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

T["composer.set_text: non-string text → warns + no buffer change"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "hyprpilot://composer/" .. id)
  vim.bo[bufnr].filetype = "hyprpilot_composer"
  composer._register_buffer_for_tests(id, bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "untouched" })

  composer.set_text(id, nil)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(lines[1], "untouched")

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

return T
