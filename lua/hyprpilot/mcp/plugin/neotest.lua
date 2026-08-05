--- `plugin_neotest_*` MCP tools — the test suite's state as the
--- captain's editor already knows it. Wire from your config:
---
---     require("hyprpilot.mcp.plugin.neotest").register()
---
--- Reads neotest's state consumer rather than re-running anything, so
--- the agent sees the results of the run the captain triggered instead
--- of paying for a second suite run to learn the same thing.

local plugin = require("hyprpilot.mcp.plugin")

local M = {}

---Resolve the adapter to read. Neotest keys all its state by adapter
---id, and a project can have several (go + jest in one repo), so a
---missing `adapter` means "every one of them".
---@param state table
---@param wanted string?
---@return string[]?, string?
local function adapter_ids(state, wanted)
  local ids = state.adapter_ids()
  if #ids == 0 then
    return nil, "no neotest adapter is active — open a test file first"
  end
  if wanted == nil then
    return ids, nil
  end
  if not vim.tbl_contains(ids, wanted) then
    return nil, string.format("unknown adapter %q; active: %s", wanted, table.concat(ids, ", "))
  end

  return { wanted }, nil
end

M.tools = {}

M.tools.status = {
  name = "plugin_neotest_status",
  description = "Return pass / fail / skipped / running counts for the test suite as neotest currently knows it, per adapter. Reflects the captain's last run — it does not run anything.",
  schema = {
    type = "object",
    properties = {
      adapter = {
        type = "string",
        description = "Adapter id to report on. Omit for every active adapter.",
      },
      path = {
        type = "string",
        description = "Scope the counts to one file's buffer. Omit for the whole suite.",
      },
    },
    additionalProperties = false,
  },
  handler = function(args)
    local state = require("neotest").state
    local ids, why = adapter_ids(state, args.adapter)
    if ids == nil then
      return plugin.err(why)
    end

    local buffer
    if type(args.path) == "string" and args.path ~= "" then
      buffer = vim.fn.bufnr(vim.fs.normalize(args.path))
      if buffer == -1 then
        return plugin.err("file is not open in a buffer: " .. args.path)
      end
    end

    local adapters = {}
    for _, id in ipairs(ids) do
      local counts = state.status_counts(id, { buffer = buffer })
      if counts ~= nil then
        table.insert(adapters, {
          adapter = id,
          total = counts.total,
          passed = counts.passed,
          failed = counts.failed,
          skipped = counts.skipped,
          running = counts.running,
        })
      end
    end

    return { json = { adapters = adapters } }
  end,
}

M.tools.positions = {
  name = "plugin_neotest_positions",
  description = "List the tests neotest has discovered, with their file and line range. Use it to name a test precisely before running it, or to find which test covers a line.",
  schema = {
    type = "object",
    properties = {
      adapter = {
        type = "string",
        description = "Adapter id to read. Omit for every active adapter.",
      },
      path = {
        type = "string",
        description = "Scope to one file's buffer. Omit for the whole suite.",
      },
      max_results = {
        type = "integer",
        description = "Cap on positions returned. Default 200.",
      },
    },
    additionalProperties = false,
  },
  handler = function(args)
    local state = require("neotest").state
    local ids, why = adapter_ids(state, args.adapter)
    if ids == nil then
      return plugin.err(why)
    end

    local buffer
    if type(args.path) == "string" and args.path ~= "" then
      buffer = vim.fn.bufnr(vim.fs.normalize(args.path))
      if buffer == -1 then
        return plugin.err("file is not open in a buffer: " .. args.path)
      end
    end

    local cap = (type(args.max_results) == "number" and args.max_results >= 1) and math.floor(args.max_results) or 200
    local positions = {}
    for _, id in ipairs(ids) do
      local tree = state.positions(id, { buffer = buffer })
      if tree ~= nil then
        -- The tree mixes directories, files, namespaces and tests; only
        -- the leaves are runnable, and only they carry a useful range.
        for _, node in tree:iter_nodes() do
          local data = node:data()
          if data.type == "test" or data.type == "namespace" then
            table.insert(positions, {
              adapter = id,
              id = data.id,
              name = data.name,
              type = data.type,
              path = data.path,
              line = data.range ~= nil and data.range[1] or nil,
              end_line = data.range ~= nil and data.range[3] or nil,
            })
          end
        end
      end
    end

    return {
      json = {
        positions = vim.list_slice(positions, 1, cap),
        count = math.min(#positions, cap),
        truncated = #positions > cap,
      },
    }
  end,
}

M.tools.run = {
  name = "plugin_neotest_run",
  description = "Run tests in the captain's editor — the whole suite, one file, or one position id from `plugin_neotest_positions`. Returns once the run is queued; poll `plugin_neotest_status` for results.",
  schema = {
    type = "object",
    properties = {
      position_id = {
        type = "string",
        description = "Position id (or file path) to run. Omit to run the nearest test to the captain's cursor.",
      },
      suite = {
        type = "boolean",
        description = "Run the entire suite instead. Overrides `position_id`.",
      },
      strategy = {
        type = "string",
        description = "Neotest strategy, e.g. `integrated` (default) or `dap` to run under the debugger.",
      },
    },
    additionalProperties = false,
  },
  handler = function(args)
    local run = require("neotest").run
    local opts = { strategy = args.strategy }

    local target
    if args.suite == true then
      opts.suite = true
    elseif type(args.position_id) == "string" and args.position_id ~= "" then
      target = args.position_id
    end

    -- Neotest drives the run asynchronously and reports through its own
    -- UI; the agent reads the outcome back through `status`.
    local ok, run_err = pcall(function()
      if target ~= nil then
        run.run(vim.tbl_extend("force", { target }, opts))
      else
        run.run(opts)
      end
    end)
    if not ok then
      return plugin.err("neotest run failed: " .. tostring(run_err))
    end

    return { json = { queued = true, position_id = target, suite = args.suite == true } }
  end,
}

M.register = plugin.registrar(M.tools, "neotest")

return M
