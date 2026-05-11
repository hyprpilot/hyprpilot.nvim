--- Default highlight groups for the chat surface.
---
--- Every group is registered with `default = true` + `link = "..."`,
--- so a captain who already styles `Diagnostic*` / `Pmenu*` / etc.
--- inherits sensible colours without lifting a finger, and a captain
--- who wants to override just calls `nvim_set_hl(0, "Hyprpilot...",
--- {...})` to break the link.
---
--- The render module applies these via `line_hl_group` extmarks at
--- write time; nothing here knows about the buffer.

local M = {}

---@type table<string, string>
M.LINKS = {
  -- Tool-call block
  HyprpilotToolHeader = "Function",
  HyprpilotToolStatusOk = "DiagnosticOk",
  HyprpilotToolStatusFail = "DiagnosticError",
  HyprpilotToolStatusRunning = "DiagnosticInfo",
  HyprpilotToolStatusPending = "DiagnosticHint",
  HyprpilotToolBody = "Comment",

  -- Plan block
  HyprpilotPlanHeader = "Title",
  HyprpilotPlanStepDone = "Comment",
  HyprpilotPlanStepInProgress = "Function",
  HyprpilotPlanStepPending = "Identifier",

  -- Thought block
  HyprpilotThoughtHeader = "Conceal",
  HyprpilotThoughtBody = "Comment",

  -- Permission block
  HyprpilotPermissionHeader = "WarningMsg",
  HyprpilotPermissionBody = "Comment",
  HyprpilotPermissionButton = "Pmenu",
  HyprpilotPermissionButtonFocused = "PmenuSel",
  HyprpilotPermissionResolved = "Comment",

  -- Turn-end chip
  HyprpilotTurnEndOk = "DiagnosticOk",
  HyprpilotTurnEndError = "DiagnosticError",
  HyprpilotTurnEndCancelled = "DiagnosticWarn",

  -- Composer
  HyprpilotComposerAttachments = "Comment",

  -- Header buffer (pinned single-line bar above the chat split)
  HyprpilotHeader = "StatusLine",
}

---Apply (or re-apply) every default highlight link. Idempotent —
---calling on `ColorScheme` re-establishes the links after a theme
---swap that wiped the namespace.
function M.setup()
  for name, target in pairs(M.LINKS) do
    vim.api.nvim_set_hl(0, name, { default = true, link = target })
  end
end

return M
