--- Regression tests for `permission-row`'s default-focus matcher.
--- The daemon's `PermissionRequestSnapshot::default_option_id` is
--- the source of truth (see daemon's `pick_allow_once_id`, which
--- ships an id ONLY when the agent offered `kind == "allow_once"`
--- exactly). The plugin honours it verbatim or renders no default
--- focus — no local fallback to `allow_always`, vendor variants,
--- or first-option-overall.

local T = MiniTest.new_set()

T["enqueue focuses the option whose id matches daemon default_option_id"] = function()
  local pr = require("hyprpilot.chat.permission-row")
  pr.reset()

  pr.enqueue("inst-1", {
    request_id = "req-daemon-id",
    tool = "Bash",
    default_option_id = "opt-def",
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

T["enqueue renders no focused default when daemon omits default_option_id"] = function()
  -- Daemon drops `default_option_id` when the agent offers no
  -- `allow_once` (e.g., only `allow_always` + `reject_once`). The
  -- plugin must NOT fall back to `allow_always` or to the first
  -- option overall — captain navigates with <Tab> / <S-Tab>.
  local pr = require("hyprpilot.chat.permission-row")
  pr.reset()

  pr.enqueue("inst-1", {
    request_id = "req-no-default",
    tool = "Bash",
    options = {
      { optionId = "opt-allow-always", name = "Allow forever", kind = "allow_always" },
      { optionId = "opt-reject", name = "Deny", kind = "reject_once" },
    },
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  MiniTest.expect.equality(#pr._queue, 1)
  MiniTest.expect.equality(pr._queue[1].focused_idx, nil)

  pr.reset()
end

T["enqueue renders no focused default when daemon id is not in options"] = function()
  -- Defensive: daemon shipped an id that doesn't match any offered
  -- option (race / stale event). Captain navigates explicitly
  -- rather than picking some plausible-but-wrong fallback.
  local pr = require("hyprpilot.chat.permission-row")
  pr.reset()

  pr.enqueue("inst-1", {
    request_id = "req-stale-id",
    tool = "Bash",
    default_option_id = "opt-gone",
    options = {
      { optionId = "opt-a", name = "A", kind = "allow_once" },
      { optionId = "opt-b", name = "B", kind = "reject_once" },
    },
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  MiniTest.expect.equality(pr._queue[1].focused_idx, nil)

  pr.reset()
end

return T
