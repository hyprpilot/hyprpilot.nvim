-- Every buffer the plugin owns gets a `hyprpilot*` filetype so the
-- captain can hang ftplugin overrides off it. Without registering
-- those names as aliases for an actual treesitter parser, third-
-- party FileType / BufEnter listeners (markview.nvim, render-markdown)
-- that call `vim.treesitter.start(bufnr)` blow up because no parser
-- exists for the literal filetype string. Aliasing to markdown gives
-- them a parser AND gets us free markdown highlight on tool / prose
-- bodies, composer drafts, and permission row chrome.
vim.treesitter.language.register("markdown", "hyprpilot")
vim.treesitter.language.register("markdown", "hyprpilot_input")
vim.treesitter.language.register("markdown", "hyprpilot_permission_row")
vim.treesitter.language.register("markdown", "hyprpilot_header")

require("hyprpilot.highlights").setup()

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("HyprpilotHighlights", { clear = true }),
  callback = function()
    require("hyprpilot.highlights").setup()
  end,
})
