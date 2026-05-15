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

  -- Per-turn section headers (### tasks / ### thoughts / ### tools)
  HyprpilotSectionHeader = "Title",

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

  -- Header buffer (pinned single-line bar above the chat split).
  -- `HyprpilotHeader` is the background fill via `line_hl_group`; per-
  -- segment groups paint each pill on top. Links are chosen so the
  -- bar reads cohesively against a stock colorscheme (each pill picks
  -- up its semantic colour from the syntax / diagnostic palette).
  HyprpilotHeader = "StatusLine",
  HyprpilotHeaderBrand = "Title",
  HyprpilotHeaderEmpty = "Comment",
  HyprpilotHeaderState = "WarningMsg",
  HyprpilotHeaderName = "Identifier",
  HyprpilotHeaderProfile = "Constant",
  HyprpilotHeaderProvider = "Type",
  HyprpilotHeaderModel = "Function",
  HyprpilotHeaderMode = "Special",
  HyprpilotHeaderUsage = "Number",
  HyprpilotHeaderCount = "Comment",
  HyprpilotHeaderSeparator = "NonText",
  -- Per-instance lifecycle status pill (leftmost). Color-coded by
  -- state so the captain reads "is this instance live, booting,
  -- ended, or errored" at a glance — diagnostic palette mirrors
  -- the LSP signs they're already trained on.
  HyprpilotHeaderStatusStarting = "DiagnosticInfo",
  HyprpilotHeaderStatusRunning = "DiagnosticOk",
  HyprpilotHeaderStatusEnded = "Comment",
  HyprpilotHeaderStatusError = "DiagnosticError",
  -- Activity pills (kept for backwards compatibility — header no
  -- longer paints them but captains may still hook the groups).
  HyprpilotHeaderActivity = "DiagnosticHint",
  HyprpilotHeaderActivityStreaming = "DiagnosticInfo",
  HyprpilotHeaderActivityThinking = "DiagnosticHint",
  HyprpilotHeaderActivityTool = "Function",
  HyprpilotHeaderActivityPermission = "DiagnosticWarn",

  -- Permission row (pinned single-line bar between chat and composer
  -- while at least one permission is pending)
  HyprpilotPermissionRow = "WarningMsg",
  HyprpilotPermissionDiffIndicator = "Special",

  -- Queue strip (pinned bar between permission row and composer
  -- while at least one prompt is queued for the active instance).
  HyprpilotQueueStripHeader = "Comment",
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
