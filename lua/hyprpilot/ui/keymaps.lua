--- Shared keymap-install helpers. Every plugin surface (permission
--- row, queue strip, chat keymaps, diff preview, composer) accepts
--- the same `string | string[] | false` per-action shape; this
--- module collapses the otherwise-byte-identical helper that lived
--- in three different files.
---
--- Composer's per-mode `{ normal = ..., insert = ... }` shape stays
--- in `composer/init.lua` because it's a different action type — this
--- module is the normal-mode-only baseline, not a one-size-fits-all
--- abstraction.

local M = {}

---@param keys string | string[] | false | nil
---@return string[]
local function as_list(keys)
  if keys == false or keys == nil then
    return {}
  end
  if type(keys) == "string" then
    return { keys }
  end
  if type(keys) == "table" then
    return keys
  end
  return {}
end

---@param key string
---@return string
function M.display_key(key)
  local out = key
  out = out:gsub("<[Ll]ocal[Ll]eader>", vim.g.maplocalleader or "\\")
  out = out:gsub("<[Ll]eader>", vim.g.mapleader or "\\")
  return out
end

---@param keys string | string[] | false | nil
---@return string?
function M.first_display_key(keys)
  local list = as_list(keys)
  local key = list[1]
  if type(key) ~= "string" or key == "" then
    return nil
  end
  return M.display_key(key)
end

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
  for _, key in ipairs(as_list(keys)) do
    vim.keymap.set("n", key, handler, { buffer = bufnr, silent = true, desc = "hyprpilot: " .. desc })
  end
end

return M
