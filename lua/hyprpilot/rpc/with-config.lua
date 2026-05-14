--- Shared `with_config` helper. Every spawn-bearing RPC the
--- daemon exposes (`instances/spawn`, `instances/focus` with
--- `ensure=true`, `prompts/send`) accepts a `withConfig` array of
--- strategic-merge patches that overlay onto the resolved config
--- before the agent boots.
---
--- This module merges the captain's GLOBAL
--- `config.options.with_config` (a baseline overlay set once in
--- `setup({})`) with per-call patches in declaration order
--- (global FIRST, per-call AFTER). The daemon applies patches
--- last-wins for conflicting strategic-merge directives, so per-
--- call entries override the global baseline.
---
--- Validation is the daemon's job — bad patch shapes come back
--- as `-32602` from the wire, with a richer error than anything
--- we could synthesise here. We just merge and forward.

local config = require("hyprpilot.config")

local M = {}

---Resolve the effective `withConfig` for an outgoing RPC.
---Concatenates `config.options.with_config` (global) and the
---per-call list. Returns nil when neither contributes any
---patches, so callers can stamp with one
---`if patches ~= nil then params.withConfig = patches end`.
---@param per_call hyprpilot.ConfigPatch[]?
---@return hyprpilot.ConfigPatch[]?
function M.resolve(per_call)
  local merged = {}
  if type(config.options.with_config) == "table" then
    vim.list_extend(merged, config.options.with_config)
  end
  if type(per_call) == "table" then
    vim.list_extend(merged, per_call)
  end
  if #merged == 0 then
    return nil
  end
  return merged
end

---Stamp the resolved `withConfig` onto `params` in-place. Skips
---the field entirely when nothing to send so the daemon's
---`#[serde(default)]` doesn't have to discriminate `null` vs
---absent. Returns `params` for call-chaining convenience.
---@param params table
---@param per_call hyprpilot.ConfigPatch[]?
---@return table
function M.apply(params, per_call)
  local resolved = M.resolve(per_call)
  if resolved ~= nil then
    params.withConfig = resolved
  end
  return params
end

return M
