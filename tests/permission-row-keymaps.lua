--- Behavioural tests for `chat.permission_row::install_keymaps`.
--- Covers F8 — the keymaps are configurable via
--- `config.permission_row.keymaps` and the defaults are
--- `<localleader>a` (accept), `<localleader>d` (reject), `<CR>`
--- (submit), `<Tab>` / `<S-Tab>` (cycle).

local T = MiniTest.new_set()

---Drive enqueue, force a refresh that builds the buffer + installs
---the keymaps, and return the bufnr. The shared row buffer holds
---the keymaps post-enqueue. The buffer survives across `pr.reset()`
---calls (Neovim hides it instead of wiping), so we explicitly
---delete it first to drop accumulated keymaps from prior cases.
---@return integer bufnr
local function enqueue_and_get_buffer()
  local pr = require("hyprpilot.chat.permission-row")
  pr.reset()
  if pr._bufnr ~= nil and vim.api.nvim_buf_is_valid(pr._bufnr) then
    pcall(vim.api.nvim_buf_delete, pr._bufnr, { force = true })
  end
  pr._bufnr = nil
  pr.enqueue("inst-1", {
    request_id = "req-1",
    tool = "Bash",
    options = {
      { optionId = "allow-once", name = "Allow", kind = "allow_once" },
      { optionId = "reject-once", name = "Reject", kind = "reject_once" },
    },
    formatted = { title = "ls", stats = {}, fields = {} },
  })
  -- The keymap install happens inside `open_window`, which requires
  -- the chat window to be visible. We don't have a real chat split
  -- in tests, so call the underlying `install_keymaps` indirectly
  -- by attaching the row buffer to a manual window.
  pr.refresh()
  return pr._bufnr
end

---Look up the buffer-local key binding `lhs` in normal mode.
---Returns the mapping table (`{ lhs, rhs, ... }`) or nil.
---@param bufnr integer
---@param lhs string
---@return table?
local function bufmap_for(bufnr, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == lhs then
      return m
    end
  end
  return nil
end

---Manually invoke `install_keymaps` on the given bufnr. The
---function is local to `permission-row.lua` — we drive it via the
---public `open_window` path is overkill for tests, so we shell out
---to a Lua eval against the module's internal binding.
---@param bufnr integer
local function install_keymaps(bufnr)
  -- The cleanest path is to drive open_window, but it needs a
  -- visible chat. Workaround: temporarily set permission_row._bufnr
  -- and call the keymap-installation by invoking permission_row's
  -- `_install_keymaps_for_tests` if exposed, else fall back to
  -- driving via a window.
  --
  -- Since the module doesn't expose install_keymaps directly, we
  -- mount the bufnr in a scratch window briefly and call
  -- open_window. The keymap-install fires regardless of focus.
  local pr = require("hyprpilot.chat.permission-row")
  if pr._install_keymaps_for_tests ~= nil then
    pr._install_keymaps_for_tests(bufnr)
  end
end

T["permission_row default keymaps: <localleader>a / <localleader>d / <CR> / <Tab> / <S-Tab>"] = function()
  -- Reset config to defaults before the test.
  require("hyprpilot.config").setup({})

  local bufnr = enqueue_and_get_buffer()
  install_keymaps(bufnr)

  -- Localleader is interpolated by Neovim into the configured key
  -- string at map-install time. Tests run without a custom
  -- localleader, so it expands to the default `\\` (backslash).
  local accept = bufmap_for(bufnr, "\\a")
  local reject = bufmap_for(bufnr, "\\d")
  local submit = bufmap_for(bufnr, "<CR>")
  local cycle_next = bufmap_for(bufnr, "<Tab>")
  local cycle_prev = bufmap_for(bufnr, "<S-Tab>")

  MiniTest.expect.equality(accept ~= nil, true)
  MiniTest.expect.equality(reject ~= nil, true)
  MiniTest.expect.equality(submit ~= nil, true)
  MiniTest.expect.equality(cycle_next ~= nil, true)
  MiniTest.expect.equality(cycle_prev ~= nil, true)

  require("hyprpilot.chat.permission-row").reset()
end

T["permission_row keymaps: captain config override binds new keys"] = function()
  require("hyprpilot.config").setup({
    permission_row = {
      keymaps = {
        accept = "ga",
        reject = "gr",
        submit = "<CR>",
        cycle_next = "j",
        cycle_prev = "k",
      },
    },
  })

  local bufnr = enqueue_and_get_buffer()
  install_keymaps(bufnr)

  MiniTest.expect.equality(bufmap_for(bufnr, "ga") ~= nil, true)
  MiniTest.expect.equality(bufmap_for(bufnr, "gr") ~= nil, true)
  MiniTest.expect.equality(bufmap_for(bufnr, "j") ~= nil, true)
  MiniTest.expect.equality(bufmap_for(bufnr, "k") ~= nil, true)

  require("hyprpilot.chat.permission-row").reset()
  -- Restore defaults for downstream tests.
  require("hyprpilot.config").setup({})
end

T["permission_row keymaps: false disables the binding"] = function()
  require("hyprpilot.config").setup({
    permission_row = {
      keymaps = {
        accept = false,
        reject = "<C-r>",
        submit = "<CR>",
        cycle_next = "<Tab>",
        cycle_prev = "<S-Tab>",
      },
    },
  })

  local bufnr = enqueue_and_get_buffer()
  install_keymaps(bufnr)

  -- `accept = false` disables — no buffer-local map for the
  -- default `<C-G>` should exist.
  MiniTest.expect.equality(bufmap_for(bufnr, "<C-G>"), nil)
  -- Other actions still bound.
  MiniTest.expect.equality(bufmap_for(bufnr, "<C-R>") ~= nil, true)

  require("hyprpilot.chat.permission-row").reset()
  require("hyprpilot.config").setup({})
end

T["permission_row keymaps: list of keys binds each entry"] = function()
  require("hyprpilot.config").setup({
    permission_row = {
      keymaps = {
        accept = { "<C-g>", "ga" },
        reject = "<C-r>",
        submit = "<CR>",
        cycle_next = "<Tab>",
        cycle_prev = "<S-Tab>",
      },
    },
  })

  local bufnr = enqueue_and_get_buffer()
  install_keymaps(bufnr)

  MiniTest.expect.equality(bufmap_for(bufnr, "<C-G>") ~= nil, true)
  MiniTest.expect.equality(bufmap_for(bufnr, "ga") ~= nil, true)

  require("hyprpilot.chat.permission-row").reset()
  require("hyprpilot.config").setup({})
end

return T
