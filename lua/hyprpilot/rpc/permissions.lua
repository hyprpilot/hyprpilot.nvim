--- Public Lua API for permission resolution.
---
--- Captains call `respond` from custom keybinds when they want to
--- bypass the buffer-local UI (for example, a leader-mapped
--- "approve everything pending" workflow). The chat surface uses the
--- same RPC under the hood so behaviour stays consistent.

local client = require("hyprpilot.client")
local log = require("hyprpilot.log")

local M = {}

---Send `optionId` for `requestId` to the daemon.
---
---`opts.feedback` (optional) is a free-form string forwarded to the
---agent on rejection. The daemon's `RespondParams` currently uses
---`deny_unknown_fields`, so we ONLY include `feedback` when the
---captain has opted in via `config.diff_preview.send_reject_feedback
---= true`. Until the matching daemon PR lands, the feedback string
---stays plugin-side; captains who flip the flag prematurely see
---their reject calls fail with `-32602`.
---
---@param request_id string
---@param option_id string
---@param opts_or_callback? { feedback?: string } | fun(err: hyprpilot.client.RpcError?, result: any?)
---@param callback? fun(err: hyprpilot.client.RpcError?, result: any?)
function M.respond(request_id, option_id, opts_or_callback, callback)
  if type(request_id) ~= "string" or request_id == "" then
    log.warn("permissions.respond: request_id must be a non-empty string")
    return
  end

  if type(option_id) ~= "string" or option_id == "" then
    log.warn("permissions.respond: option_id must be a non-empty string")
    return
  end

  -- Three call shapes today; back-compat with the original
  -- `(request_id, option_id, callback)` signature.
  local opts
  if type(opts_or_callback) == "function" then
    callback = opts_or_callback
    opts = nil
  else
    opts = opts_or_callback
  end

  local params = { requestId = request_id, optionId = option_id, focus = false }
  if type(opts) == "table" and type(opts.feedback) == "string" and opts.feedback ~= "" then
    local diff_cfg = (require("hyprpilot.config").options.diff_preview or {})
    if diff_cfg.send_reject_feedback == true then
      params.feedback = opts.feedback
    else
      log.debug("permissions.respond: feedback dropped (config.diff_preview.send_reject_feedback != true)")
    end
  end

  client.request("permissions/respond", params, nil, function(err, result)
    if callback ~= nil then
      callback(err, result)
    end
  end)
end

---Fetch the daemon's pending-permission queue. Filters by
---`instance_id` when provided.
---@param opts? { instance_id?: string }
---@param callback fun(err: hyprpilot.client.RpcError?, pending: table[]?)
function M.pending(opts, callback)
  local params = {}
  if opts ~= nil and opts.instance_id ~= nil then
    params.instanceId = opts.instance_id
  end

  client.request("permissions/pending", params, nil, function(err, result)
    if err ~= nil then
      callback(err, nil)
      return
    end

    callback(nil, (result and result.pending) or {})
  end)
end

return M
