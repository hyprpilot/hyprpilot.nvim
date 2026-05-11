vim.treesitter.language.register("markdown", "hyprpilot")

require("hyprpilot.highlights").setup()

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("HyprpilotHighlights", { clear = true }),
  callback = function()
    require("hyprpilot.highlights").setup()
  end,
})
