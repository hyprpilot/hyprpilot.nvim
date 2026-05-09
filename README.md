# hyprpilot.nvim

Neovim frontend for the [`hyprpilot`](https://github.com/hyprpilot/hyprpilot)
daemon — drive an AI agent from a buffer, stream output live, answer
permission prompts, switch mode/model, restore sessions. All over the
daemon's Unix socket at `$XDG_RUNTIME_DIR/hyprpilot.sock`.

> [!IMPORTANT]
> This plugin is in early bootstrap. Only the setup chain, logger, and
> `:checkhealth` skeleton are wired today. The transport, chat buffer,
> and event subscription land in follow-up PRs (see
> [`docs/plans/2026-05-09-nvim-plugin-handoff.md`](docs/plans/2026-05-09-nvim-plugin-handoff.md)).

## Installation

### lazy.nvim

```lua
return {
  "hyprpilot/hyprpilot.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {},
}
```

## Configuration

```lua
require("hyprpilot").setup({
  log_level = vim.log.levels.INFO,
  socket = nil, -- defaults to $XDG_RUNTIME_DIR/hyprpilot.sock
})
```

## Health check

```vim
:checkhealth hyprpilot
```

Verifies `plenary.nvim` is loaded, Neovim version is supported, and the
daemon socket is reachable.

## License

[MIT](LICENSE)
