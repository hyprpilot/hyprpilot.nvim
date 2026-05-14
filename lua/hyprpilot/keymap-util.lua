--- Shared keymap-install helpers. Every plugin surface (permission
--- row, queue strip, chat keymaps, diff preview, composer) accepts
--- the same `string | string[] | false` per-action shape; this
--- module collapses the otherwise-byte-identical helper that lived
--- in three different files.
---
--- Composer's per-mode `{ normal = ..., insert = ... }` shape stays
--- in `ui/composer.lua` because it's a different action type — this
--- module is the normal-mode-only baseline, not a one-size-fits-all
--- abstraction.

local M = {}

---Bind one action to its configured key(s) on `bufnr`. `keys` is
---`false` / `nil` (disabled), a single key string, or a list of
---key strings — each list entry binds the same handler.
---
---Always sets `silent = true` and prefixes the description with
---`"hyprpilot: "` so `:nmap` and which-key trees group our
---bindings together.
---@param bufnr integer
---@param keys string | string[] | false | nil
---@param handler fun(): nil
---@param desc string                                   -- short verb-object phrase (e.g. "submit composer prompt")
function M.apply_action(bufnr, keys, handler, desc)
  if keys == false or keys == nil then
    return
  end
  if type(keys) == "string" then
    keys = { keys }
  end
  for _, key in ipairs(keys) do
    vim.keymap.set("n", key, handler, { buffer = bufnr, silent = true, desc = "hyprpilot: " .. desc })
  end
end

return M
