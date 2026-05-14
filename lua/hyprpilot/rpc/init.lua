--- RPC handler registry — wires daemon-side JSON-RPC notifications
--- to the plugin's UI operations. Each sub-module under
--- `lua/hyprpilot/rpc/` exposes a `register()` that subscribes its
--- method bindings via `client.on_notification`.
---
--- Today only `rpc.window` ships (focus / toggle / show / hide). Add
--- new modules as the daemon-driven surface grows (e.g.,
--- `rpc.composer` for prompt injection, `rpc.permissions` for
--- approve / reject side channels).

local M = {}

---Register every rpc handler module. Called once from `setup()`
---after `log` + `config` are wired. `client.on_notification`
---accumulates without de-duping, so don't call this twice in one
---process — `setup()` is the single registration point.
function M.register()
  require("hyprpilot.rpc.window").register()
end

return M
