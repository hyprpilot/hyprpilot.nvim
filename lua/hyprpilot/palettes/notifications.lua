--- Notifications palette — picker over the daemon's authoritative
--- needs-attention list (`notification/daemon.lua` mirror). Mirrors
--- the desktop overlay's notifications leaf so muscle memory carries
--- across frontends.
---
--- Picking an instance row: switches the chat to that instance and
--- focuses chat. Daemon's `acp:instances-focused` listener then
--- clears the entry automatically — no explicit `notifications/clear`
--- needed.
---
--- Synthetic top row (`__dismiss_all__`): fires
--- `notifications/clear_all` so the captain can wipe the whole set in
--- one round-trip. Daemon broadcast updates the local mirror.

local daemon = require("hyprpilot.notification.daemon")
local log = require("hyprpilot.log")
local pickers = require("hyprpilot.palettes.pickers")
local window = require("hyprpilot.chat.window")

local M = {}

local DISMISS_ALL_ID = "__dismiss_all__"

---@class hyprpilot.palettes.notifications.Opts
---@field on_pick? fun(entry: hyprpilot.NotificationEntry): nil   -- override for the per-instance pick; default switches + focuses chat
---@field picker? "auto" | "snacks" | "vim.ui.select"

---Pretty-print a reasons array for the row label / preview.
---@param reasons string[]?
---@return string
local function format_reasons(reasons)
  if type(reasons) ~= "table" or #reasons == 0 then
    return "(no reason)"
  end
  -- Wire names are snake_case; map to short captain-readable
  -- labels. Unknown variants pass through verbatim so a future
  -- daemon-added reason stays visible.
  local labels = {
    turn_ended = "turn ended",
    permission_requested = "permission",
    instance_error = "error",
  }
  local out = {}
  for _, r in ipairs(reasons) do
    table.insert(out, labels[r] or r)
  end
  return table.concat(out, " · ")
end

---@param item table
---@return string
local function format_item(item)
  if item.instance_id == DISMISS_ALL_ID then
    return string.format("[!] dismiss all (%d)", item._count or 0)
  end
  return string.format("[%s] %s", format_reasons(item.reasons), item.instance_id)
end

---@param item table
---@return { lines: string[], ft: string }
local function format_preview(item)
  if item.instance_id == DISMISS_ALL_ID then
    return {
      lines = {
        "# dismiss all",
        "",
        string.format("Clears %d notification entr%s in one round-trip.", item._count or 0, (item._count == 1) and "y" or "ies"),
        "",
        "Daemon broadcasts the post-clear empty list; mirror updates from the broadcast.",
      },
      ft = "markdown",
    }
  end

  local lines = { "# " .. item.instance_id, "" }
  table.insert(lines, string.format("- **reasons:** %s", format_reasons(item.reasons)))
  if type(item.since) == "number" and item.since > 0 then
    local since_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(item.since / 1000))
    table.insert(lines, string.format("- **since:** `%s`", since_iso))
  end
  return { lines = lines, ft = "markdown" }
end

---Open the notifications palette. No-op + log when nothing pending.
---@param opts? hyprpilot.palettes.notifications.Opts
function M.open(opts)
  opts = opts or {}

  local entries = daemon.list()
  if #entries == 0 then
    log.warn("palettes.notifications: nothing needs attention")
    return
  end

  -- Synthetic dismiss-all row at the top — matches the desktop
  -- overlay's notifications leaf shape. Sentinel `instance_id`
  -- prevents the on_pick from trying to switch to a real
  -- instance.
  local items = { { instance_id = DISMISS_ALL_ID, _count = #entries } }
  for _, entry in ipairs(entries) do
    table.insert(items, entry)
  end

  local commit = opts.on_pick
    or function(entry)
      -- Switch the chat to the picked instance and steer focus to
      -- the chat split. Daemon clears the entry from the broadcast
      -- triggered by `instances/focus` (we don't fire that RPC
      -- ourselves here — `window.switch` is local-state, and the
      -- daemon's auto-clear hooks on permission-resolve / prompt-
      -- send / clean Ended cover the steady-state clears). For the
      -- pure-switch case the captain may want an explicit dismiss
      -- — they can re-open the picker + pick "dismiss all" or hit
      -- the per-instance dismiss keymap (future).
      window.switch(entry.instance_id)
      require("hyprpilot.ui.window").focus({ target = "chat" })
    end

  pickers.open({
    items = items,
    title = "notifications",
    kind = "hyprpilot.notifications",
    picker = opts.picker,
    format_item = format_item,
    preview = format_preview,
    on_pick = function(choice)
      if choice.instance_id == DISMISS_ALL_ID then
        daemon.dismiss_all()
        return
      end
      commit(choice)
    end,
  })
end

M.format_item = format_item
M.format_preview = format_preview
M.DISMISS_ALL_ID = DISMISS_ALL_ID

return M
