-- Headless test bootstrap. Clones `mini.nvim` into a repo-local
-- `.testdeps/` cache (committed-out via .gitignore) on first run, then
-- adds the cache + the plugin under test to the runtimepath. Used by
-- `task test-lua` and CI; not loaded during normal editor sessions.

local repo_root = vim.fn.getcwd()
local deps_dir = repo_root .. "/.testdeps"
local mini_path = deps_dir .. "/mini.nvim"

if vim.fn.isdirectory(mini_path) == 0 then
  vim.fn.mkdir(deps_dir, "p")

  vim.notify("bootstrapping mini.nvim into " .. mini_path, vim.log.levels.INFO)

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
end

vim.opt.rtp:prepend(mini_path)
vim.opt.rtp:prepend(repo_root)

require("mini.test").setup({
  collect = {
    find_files = function()
      return vim.fn.glob(repo_root .. "/tests/test_*.lua", true, true)
    end,
  },
})
