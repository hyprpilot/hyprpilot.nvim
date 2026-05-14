-- Headless test bootstrap. Each `task test-lua` invocation gets a
-- fresh ephemeral `mini.nvim` clone in a Neovim-managed temp dir;
-- nvim wipes it on exit, leaving the repo (and the user's cache /
-- data dirs) untouched. Adds the clone + the plugin under test to
-- the runtimepath, then hands off to `mini.test`.

local repo_root = vim.fn.getcwd()
local tmp_dir = vim.fn.tempname()
local mini_path = tmp_dir .. "/mini.nvim"

vim.fn.mkdir(tmp_dir, "p")

vim.notify("cloning mini.nvim into " .. mini_path, vim.log.levels.INFO)

local result = vim.fn.system({
  "git",
  "clone",
  "--depth=1",
  "--filter=blob:none",
  "https://github.com/echasnovski/mini.nvim",
  mini_path,
})

if vim.v.shell_error ~= 0 then
  vim.notify("mini.nvim clone failed:\n" .. result, vim.log.levels.ERROR)
  vim.cmd("cquit 1")
end

vim.opt.rtp:prepend(mini_path)
vim.opt.rtp:prepend(repo_root)

require("mini.test").setup({
  collect = {
    find_files = function()
      -- Every `tests/*.lua` is a test module (the `test_` prefix was
      -- dropped because the directory already names them as tests).
      -- `helpers.lua` is excluded — it's a shared helper module, not
      -- a test file (it doesn't return a MiniTest set).
      local files = vim.fn.glob(repo_root .. "/tests/*.lua", true, true)
      return vim.tbl_filter(function(path)
        return not path:match("/helpers%.lua$")
      end, files)
    end,
  },
})
