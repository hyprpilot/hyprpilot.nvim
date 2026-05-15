-- Every buffer the plugin owns gets a `hyprpilot*` filetype so the
-- captain can hang ftplugin overrides off it. Without registering
-- those names as aliases for an actual treesitter parser, third-
-- party `FileType` / `BufEnter` listeners that call
-- `vim.treesitter.start(bufnr)` blow up because no parser exists
-- for the literal filetype string. Aliasing to markdown gives them
-- a parser AND gets us free markdown highlight on tool / prose
-- bodies, composer drafts, and permission row chrome.
--
-- Adding a new plugin-owned filetype: append to this list AND set
-- `vim.bo[bufnr].filetype = "hyprpilot_<name>"` at the buffer mint
-- site. The two have to stay in sync — a missing register call
-- blows up third-party `BufEnter` autocmds, and a registered
-- filetype that's never assigned is dead code.
for _, ft in ipairs({
  "hyprpilot", -- chat buffer (per-instance markdown transcript)
  "hyprpilot_composer", -- composer (captain's typing surface)
  "hyprpilot_header", -- pinned 1-row header above the chat
  "hyprpilot_permission_row", -- pinned permission button strip
  "hyprpilot_queue_strip", -- pinned queue band between row + composer
}) do
  vim.treesitter.language.register("markdown", ft)
end

require("hyprpilot.ui.highlights").setup()

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("HyprpilotHighlights", { clear = true }),
  callback = function()
    require("hyprpilot.ui.highlights").setup()
  end,
})
