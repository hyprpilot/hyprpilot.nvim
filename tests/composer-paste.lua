--- Behavioural tests for `composer.paste_buffer` / `paste_selection`.
--- Cases mint a source buffer (named so the relative-path header has
--- something to render), then drive the paste APIs and assert on the
--- composer buffer's lines.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

local function active_instance(id)
  local buffer = require("hyprpilot.chat.buffer")
  local window = require("hyprpilot.chat.window")
  local bufnr = buffer.create(id)
  window.register({ bufnr = bufnr, instance_id = id }, { activate = true })
  return bufnr
end

---Read the composer's per-instance buffer lines via the public
---`ensure_buffer` path (exposed through `_register_buffer_for_tests`
---in the inverse direction). Here we just grep buffer list by name.
---@param instance_id string
---@return string[]
local function read_composer(instance_id)
  local name = "hyprpilot://composer/" .. instance_id
  local bufnr = require("hyprpilot.chat.buffer").find_by_name(name)
  if bufnr == nil then
    return {}
  end
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---Mint a named source buffer with `lines` and filetype `ft`. Uses an
---absolute path under the cwd so the cwd-relative form is deterministic.
---@param ft string
---@param lines string[]
---@return integer bufnr, string relpath
local function mint_source(ft, lines)
  local bufnr = vim.api.nvim_create_buf(false, false)
  local name = vim.fn.getcwd() .. "/" .. helpers.unique_id() .. "-" .. ft .. ".tmp"
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].filetype = ft
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr, vim.fn.fnamemodify(name, ":.")
end

T["paste_buffer: appends a fenced block with cwd-relative path header + filetype"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)

  local source, relpath = mint_source("lua", { "local x = 1", "return x" })
  composer.paste_buffer(source, { instance_id = id })

  local lines = read_composer(id)
  MiniTest.expect.equality(lines[1], string.format("`%s`:", relpath))
  MiniTest.expect.equality(lines[2], "```lua")
  MiniTest.expect.equality(lines[3], "local x = 1")
  MiniTest.expect.equality(lines[4], "return x")
  MiniTest.expect.equality(lines[5], "```")

  vim.api.nvim_buf_delete(source, { force = true })
  composer.wipe(id)
  helpers.cleanup_instance(id)
end

T["paste_buffer: existing composer content gets a blank-line separator"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)

  -- Prime the composer with a single line so the next paste must
  -- prepend a blank separator.
  local name = "hyprpilot://composer/" .. id
  local cbuf = require("hyprpilot.chat.buffer").find_by_name(name)
    or (function()
      local b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(b, name)
      composer._register_buffer_for_tests(id, b)
      return b
    end)()
  vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, { "hello daemon" })

  local source = mint_source("python", { "print('hi')" })
  composer.paste_buffer(source, { instance_id = id })

  local lines = read_composer(id)
  MiniTest.expect.equality(lines[1], "hello daemon")
  MiniTest.expect.equality(lines[2], "")
  MiniTest.expect.equality(lines[3]:sub(1, 1), "`")
  MiniTest.expect.equality(lines[4], "```python")

  vim.api.nvim_buf_delete(source, { force = true })
  composer.wipe(id)
  helpers.cleanup_instance(id)
end

T["paste_buffer: unnamed source buffer pastes without a header line"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)

  local source = vim.api.nvim_create_buf(false, true)
  vim.bo[source].filetype = "go"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "package main" })

  composer.paste_buffer(source, { instance_id = id })

  local lines = read_composer(id)
  MiniTest.expect.equality(lines[1], "```go")
  MiniTest.expect.equality(lines[2], "package main")
  MiniTest.expect.equality(lines[3], "```")

  vim.api.nvim_buf_delete(source, { force = true })
  composer.wipe(id)
  helpers.cleanup_instance(id)
end

T["paste_selection: reads `<,> marks and emits a path:start-end header"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)

  local source, relpath = mint_source("rust", {
    "fn main() {",
    "    let x = 1;",
    "    let y = 2;",
    '    println!("{}", x + y);',
    "}",
  })

  vim.api.nvim_set_current_buf(source)
  vim.api.nvim_buf_set_mark(source, "<", 2, 0, {})
  vim.api.nvim_buf_set_mark(source, ">", 4, 0, {})

  composer.paste_selection({ instance_id = id })

  local lines = read_composer(id)
  MiniTest.expect.equality(lines[1], string.format("`%s:2-4`:", relpath))
  MiniTest.expect.equality(lines[2], "```rust")
  MiniTest.expect.equality(lines[3], "    let x = 1;")
  MiniTest.expect.equality(lines[4], "    let y = 2;")
  MiniTest.expect.equality(lines[5], '    println!("{}", x + y);')
  MiniTest.expect.equality(lines[6], "```")

  vim.api.nvim_buf_delete(source, { force = true })
  composer.wipe(id)
  helpers.cleanup_instance(id)
end

T["paste_selection: no visual marks → warn + no-op"] = function()
  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)

  local source = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(source)
  -- Marks deliberately unset.
  composer.paste_selection({ instance_id = id })

  local lines = read_composer(id)
  -- No composer buffer should have been minted with content.
  local empty = (#lines == 0) or (#lines == 1 and lines[1] == "")
  MiniTest.expect.equality(empty, true)

  vim.api.nvim_buf_delete(source, { force = true })
  composer.wipe(id)
  helpers.cleanup_instance(id)
end

return T
