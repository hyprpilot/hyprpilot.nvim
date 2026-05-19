--- Behavioural tests for `permission_row::default_focused_idx`.
--- The daemon's `PermissionRequestSnapshot::default_option_id` is
--- the source of truth (see daemon's `pick_allow_once_id`, which
--- ships an id ONLY when the agent offered `kind == "allow_once"`
--- exactly). The plugin honours it verbatim when the id is in the
--- list, else renders no focused default — captain navigates with
--- <Tab> / <S-Tab>. No local fallback to `allow_always` / first
--- option / kind-prefix substring.

local T = MiniTest.new_set()

local OPTIONS = {
  { optionId = "allow-once", name = "Allow", kind = "allow_once" },
  { optionId = "allow-always", name = "Allow always", kind = "allow_always" },
  { optionId = "reject-once", name = "Reject", kind = "reject_once" },
}

T["enqueue: daemon-supplied default_option_id is honoured verbatim"] = function()
  local pr = require("hyprpilot.chat.permission-row")
  pr.reset()

  pr.enqueue("inst-1", {
    request_id = "req-default-pick",
    tool = "Bash",
    options = OPTIONS,
    default_option_id = "allow-once",
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  MiniTest.expect.equality(pr._queue[1].focused_idx, 1)

  pr.reset()
end

T["enqueue: missing default_option_id → nil focused_idx (no local fallback)"] = function()
  local pr = require("hyprpilot.chat.permission-row")
  pr.reset()

  pr.enqueue("inst-1", {
    request_id = "req-no-default",
    tool = "Bash",
    options = OPTIONS,
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  -- No daemon hint → no focused default. Captain navigates with
  -- <Tab> / <S-Tab>; never accidentally lands on `allow-always`
  -- or whatever the first option happens to be.
  MiniTest.expect.equality(pr._queue[1].focused_idx, nil)

  pr.reset()
end

T["enqueue: default_option_id pointing at unknown id → nil focused_idx (no crash, no fallback)"] = function()
  local pr = require("hyprpilot.chat.permission-row")
  pr.reset()

  pr.enqueue("inst-1", {
    request_id = "req-bad-default",
    tool = "Bash",
    options = OPTIONS,
    default_option_id = "ghost-option-not-in-list",
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  -- Stale / race id → no focused default. Captain navigates
  -- explicitly rather than picking a plausible-but-wrong fallback.
  MiniTest.expect.equality(pr._queue[1].focused_idx, nil)

  pr.reset()
end

return T
