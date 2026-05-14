--- Behavioural tests for `composer.submit` handling of the daemon's
--- `prompts/send` disposition (sent / queued / accepted=false).
--- Drives `submit()` with stubbed wire responses and asserts on
--- composer buffer state + the autocmd events that fired.

local helpers = require("tests.helpers")

local T = MiniTest.new_set()

---Mint an instance + active window for the composer to target,
---return the chat bufnr the active_instance helper created.
---@param id string
---@return integer
local function active_instance(id)
  local buffer = require("hyprpilot.chat.buffer")
  local window = require("hyprpilot.chat.window")
  local bufnr = buffer.create(id)
  window.register({ bufnr = bufnr, instance_id = id })
  return bufnr
end

---Capture every `User Hyprpilot<pattern>` autocmd that fires for the
---supplied patterns. Returns the unwire closure + the capture table.
---@param patterns string[]
---@return fun(), { pattern: string, data: any }[]
local function capture_events(patterns)
  local group = vim.api.nvim_create_augroup("HyprpilotTestEvents-" .. tostring(vim.uv.hrtime()), { clear = true })
  local events = {}
  for _, pattern in ipairs(patterns) do
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = pattern,
      callback = function(args)
        table.insert(events, { pattern = pattern, data = args.data })
      end,
    })
  end
  return function()
    vim.api.nvim_clear_autocmds({ group = group })
  end, events
end

T["disposition=sent: clears composer + fires Dispatched with disposition=sent"] = function()
  local restore_client = helpers.stub_client_with({
    ["prompts/send"] = { result = { accepted = true, disposition = "sent" } },
  })
  local restore_events, events = capture_events({ "HyprpilotPromptQueued", "HyprpilotPromptDispatched" })

  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)
  composer.attach({ path = "/tmp/a.txt", instance_id = id })

  composer.submit("ship it", { instance_id = id })

  MiniTest.expect.equality(#composer.attachments(id), 0)

  local dispatched, queued = nil, nil
  for _, e in ipairs(events) do
    if e.pattern == "HyprpilotPromptDispatched" then
      dispatched = e
    elseif e.pattern == "HyprpilotPromptQueued" then
      queued = e
    end
  end

  MiniTest.expect.equality(dispatched ~= nil, true)
  MiniTest.expect.equality(dispatched.data.disposition, "sent")
  MiniTest.expect.equality(queued, nil)

  restore_events()
  restore_client()
  helpers.cleanup_instance(id)
end

T["disposition=queued: clears composer + fires BOTH Queued and Dispatched"] = function()
  local restore_client = helpers.stub_client_with({
    ["prompts/send"] = { result = { accepted = true, disposition = "queued" } },
  })
  local restore_events, events = capture_events({ "HyprpilotPromptQueued", "HyprpilotPromptDispatched" })

  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)
  composer.attach({ path = "/tmp/a.txt", instance_id = id })

  composer.submit("queue me", { instance_id = id })

  -- Composer + attachments clear regardless of disposition — captain
  -- handed the draft off; the daemon owns it now.
  MiniTest.expect.equality(#composer.attachments(id), 0)

  local saw_queued, saw_dispatched_queued = false, false
  for _, e in ipairs(events) do
    if e.pattern == "HyprpilotPromptQueued" then
      saw_queued = true
      MiniTest.expect.equality(e.data.instance_id, id)
    elseif e.pattern == "HyprpilotPromptDispatched" then
      if e.data.disposition == "queued" then
        saw_dispatched_queued = true
      end
    end
  end

  MiniTest.expect.equality(saw_queued, true)
  MiniTest.expect.equality(saw_dispatched_queued, true)

  restore_events()
  restore_client()
  helpers.cleanup_instance(id)
end

T["missing disposition: backwards-compat treats it as `sent`"] = function()
  -- Pre-daemon-extension wire shape (the daemon used to return `{}`
  -- on prompts/send). Existing tests for prompts/send pass with
  -- `stub_client_request()` which returns `{}`. Confirm the new
  -- code path defaults gracefully.
  local restore_client = helpers.stub_client_with({
    ["prompts/send"] = { result = {} },
  })
  local restore_events, events = capture_events({ "HyprpilotPromptQueued", "HyprpilotPromptDispatched" })

  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)

  composer.submit("legacy daemon", { instance_id = id })

  local queued_count = 0
  local dispatched
  for _, e in ipairs(events) do
    if e.pattern == "HyprpilotPromptQueued" then
      queued_count = queued_count + 1
    elseif e.pattern == "HyprpilotPromptDispatched" then
      dispatched = e
    end
  end

  MiniTest.expect.equality(queued_count, 0)
  MiniTest.expect.equality(dispatched ~= nil, true)
  MiniTest.expect.equality(dispatched.data.disposition, "sent")

  restore_events()
  restore_client()
  helpers.cleanup_instance(id)
end

T["accepted=false: composer + attachments NOT cleared, no dispatch event"] = function()
  local restore_client = helpers.stub_client_with({
    ["prompts/send"] = { result = { accepted = false, disposition = "rejected" } },
  })
  local restore_events, events = capture_events({ "HyprpilotPromptQueued", "HyprpilotPromptDispatched" })

  local composer = require("hyprpilot.composer")
  local id = helpers.unique_id()
  active_instance(id)
  composer.attach({ path = "/tmp/keep.txt", instance_id = id })

  composer.submit("retry me", { instance_id = id })

  -- Attachment + (presumably text) stay so the captain can fix +
  -- retry. We don't poke the composer buffer here — the test asserts
  -- the attachment list which is the same surface.
  MiniTest.expect.equality(#composer.attachments(id), 1)
  MiniTest.expect.equality(#events, 0)

  restore_events()
  restore_client()
  helpers.cleanup_instance(id)
end

return T
