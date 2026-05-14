--- Regression tests for `permission-row`'s default-focus matcher.
--- The daemon's `PermissionOptionView.kind` field is wire-normalised
--- to `allow_*` / `reject_*` and is the canonical allow/reject
--- discriminator. Our matcher MUST prefer `kind` over the more
--- fragile `optionId` / `name` heuristics so it stays in lockstep
--- with new vendor variants (e.g. `allow_session`).

local T = MiniTest.new_set()

T["enqueue focuses the option whose `kind` starts with `allow` (even when id is opaque)"] = function()
  local pr = require("hyprpilot.chat.permission-row")
  pr.reset()

  -- Vendor-style options: opaque ids, neutral names, but `kind`
  -- carries the daemon-normalised classification. The matcher must
  -- pick option 2 because that's the one with `kind = allow_once`.
  pr.enqueue("inst-1", {
    request_id = "req-kind",
    tool = "Bash",
    options = {
      { optionId = "opt-abc", name = "X", kind = "reject_once" },
      { optionId = "opt-def", name = "Y", kind = "allow_once" },
      { optionId = "opt-ghi", name = "Z", kind = "reject_always" },
    },
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  MiniTest.expect.equality(#pr._queue, 1)
  MiniTest.expect.equality(pr._queue[1].focused_idx, 2)

  pr.reset()
end

T["enqueue falls back to id/name when `kind` is empty (defensive)"] = function()
  local pr = require("hyprpilot.chat.permission-row")
  pr.reset()

  pr.enqueue("inst-1", {
    request_id = "req-fallback",
    tool = "Bash",
    options = {
      { optionId = "deny-once", name = "Deny" }, -- no kind
      { optionId = "allow-once", name = "Allow" }, -- no kind, but id matches
    },
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  MiniTest.expect.equality(pr._queue[1].focused_idx, 2)

  pr.reset()
end

T["enqueue picks `allow_session` / future variants via the prefix match"] = function()
  -- Forward-compat: daemon may add `allow_session` / `allow_workspace`
  -- variants. As long as they start with `allow`, the matcher picks
  -- them — same contract as the daemon's `is_allow_kind`.
  local pr = require("hyprpilot.chat.permission-row")
  pr.reset()

  pr.enqueue("inst-1", {
    request_id = "req-future",
    tool = "Bash",
    options = {
      { optionId = "future-x", name = "Just this once", kind = "reject_once" },
      { optionId = "future-y", name = "For this session", kind = "allow_session" },
    },
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  MiniTest.expect.equality(pr._queue[1].focused_idx, 2)

  pr.reset()
end

return T
