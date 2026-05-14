--- Behavioural tests for `permission_row::default_focused_idx`.
--- The daemon supplies a `default_option_id` hint on every
--- permission request snapshot (see
--- `PermissionRequestSnapshot::default_option_id` in
--- `src-tauri/src/adapters/permission.rs`); the row honours it
--- verbatim when the option is in the list, falls back to local
--- kind / name heuristics otherwise.

local T = MiniTest.new_set()

local OPTIONS = {
  { optionId = "allow-once", name = "Allow", kind = "allow_once" },
  { optionId = "allow-always", name = "Allow always", kind = "allow_always" },
  { optionId = "reject-once", name = "Reject", kind = "reject_once" },
}

T["enqueue: daemon-supplied default_option_id wins over local Allow heuristic"] = function()
  local pr = require("hyprpilot.chat.permission-row")
  pr.reset()

  pr.enqueue("inst-1", {
    request_id = "req-default-pick",
    tool = "Bash",
    options = OPTIONS,
    -- Daemon picked the second option (allow-always) — the local
    -- heuristic would have picked the first (allow-once). Test
    -- proves the daemon hint is honoured first.
    default_option_id = "allow-always",
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  MiniTest.expect.equality(pr._queue[1].focused_idx, 2)

  pr.reset()
end

T["enqueue: missing default_option_id → falls back to first allow-shaped option"] = function()
  local pr = require("hyprpilot.chat.permission-row")
  pr.reset()

  pr.enqueue("inst-1", {
    request_id = "req-no-default",
    tool = "Bash",
    options = OPTIONS,
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  -- No daemon hint → kind-based heuristic kicks in: first option
  -- with `kind:match("^allow")` is option 1.
  MiniTest.expect.equality(pr._queue[1].focused_idx, 1)

  pr.reset()
end

T["enqueue: default_option_id pointing at unknown id falls back to heuristic (no crash)"] = function()
  local pr = require("hyprpilot.chat.permission-row")
  pr.reset()

  pr.enqueue("inst-1", {
    request_id = "req-bad-default",
    tool = "Bash",
    options = OPTIONS,
    default_option_id = "ghost-option-not-in-list",
    formatted = { title = "ls", stats = {}, fields = {} },
  })

  -- Bad hint → local heuristic, picks first allow-kind option.
  MiniTest.expect.equality(pr._queue[1].focused_idx, 1)

  pr.reset()
end

return T
