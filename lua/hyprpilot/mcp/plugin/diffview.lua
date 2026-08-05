--- `plugin_diffview_*` MCP tools — the diff the captain is looking at,
--- and the ability to put one in front of them. Wire from your config:
---
---     require("hyprpilot.mcp.plugin.diffview").register()
---
--- The diff *content* is better obtained from `git` directly; what
--- diffview adds is framing — which subset the captain opened, which
--- file they are on, which files they marked. `plugin_diffview_open`
--- takes explicit `paths`, so the agent can put exactly the files it
--- wants discussed on screen instead of describing them in prose.
---
--- `selection_get` / `selection_set` need the `diffview.api` module,
--- which only the diffview+ fork ships; they skip themselves on
--- upstream diffview rather than erroring at registration.

local plugin = require("hyprpilot.mcp.plugin")

local M = {}

---The diff view on the current tabpage, or nil when the captain isn't
---in one.
---@return table?
local function current_view()
  local lib = plugin.optional("diffview.lib")
  if lib == nil then
    return nil
  end
  local ok, view = pcall(lib.get_current_view)
  if not ok then
    return nil
  end

  return view
end

---@param entry table
---@return table
local function file_item(entry)
  local stats = entry.stats or {}

  return {
    path = entry.path,
    old_path = entry.oldpath,
    status = entry.status,
    kind = entry.kind,
    commit = entry.commit ~= nil and entry.commit.hash or nil,
    additions = stats.additions,
    deletions = stats.deletions,
    conflicts = stats.conflicts,
  }
end

M.tools = {}

M.tools.files = {
  name = "plugin_diffview_files",
  description = "List the files in the diff view the captain has open, with status and per-file added / deleted counts. Reflects the revision range they chose, not the repo's raw state — use `git` when you want the diff content itself.",
  schema = { type = "object", additionalProperties = false },
  handler = function()
    local view = current_view()
    if view == nil or view.files == nil then
      return { json = { open = false, reason = "no diffview open on the current tabpage" } }
    end

    local files = {}
    for _, entry in view.files:iter() do
      table.insert(files, file_item(entry))
    end

    return { json = { open = true, files = files, count = #files } }
  end,
}

M.tools.current = {
  name = "plugin_diffview_current",
  description = "Return the file the captain is currently looking at inside the diff view — the one their cursor or panel selection is on. Hunk-level detail is not available.",
  schema = { type = "object", additionalProperties = false },
  handler = function()
    local view = current_view()
    if view == nil then
      return { json = { open = false, reason = "no diffview open on the current tabpage" } }
    end

    local entry = view.cur_entry
    if entry == nil and type(view.infer_cur_file) == "function" then
      local ok, inferred = pcall(view.infer_cur_file, view, false)
      if ok then
        entry = inferred
      end
    end
    if entry == nil then
      return { json = { open = true, file = nil, reason = "no file focused in the diff view" } }
    end

    return { json = { open = true, file = file_item(entry) } }
  end,
}

M.tools.open = {
  name = "plugin_diffview_open",
  description = "Open a diff in the captain's editor. `paths` scopes it to the files worth discussing, so the agent can put an exact set of changes on screen instead of describing them. Reuses a matching open view rather than duplicating it.",
  schema = {
    type = "object",
    properties = {
      revision = {
        type = "string",
        description = "Revision or range, exactly as `:DiffviewOpen` takes it — `HEAD~2`, `main..feature`, `--cached`. Omit for the working tree.",
      },
      paths = {
        type = "array",
        items = { type = "string" },
        description = "Restrict the view to these files (absolute or cwd-relative). Omit for every changed file.",
      },
    },
    additionalProperties = false,
  },
  handler = function(args)
    local argv = {}
    if type(args.revision) == "string" and args.revision ~= "" then
      table.insert(argv, args.revision)
    end
    if type(args.paths) == "table" and #args.paths > 0 then
      table.insert(argv, "--")
      for _, path in ipairs(args.paths) do
        if type(path) == "string" and path ~= "" then
          table.insert(argv, path)
        end
      end
    end

    local ok, open_err = pcall(require("diffview").open, argv)
    if not ok then
      return plugin.err("diffview open failed: " .. tostring(open_err))
    end

    return { json = { opened = true, revision = args.revision, paths = args.paths } }
  end,
}

M.tools.close = {
  name = "plugin_diffview_close",
  description = "Close the diff view on the current tabpage. Refuses while a stage buffer has unsaved changes unless `force` is set.",
  schema = {
    type = "object",
    properties = {
      force = {
        type = "boolean",
        description = "Close even with modified stage buffers. Defaults to false.",
      },
    },
    additionalProperties = false,
  },
  handler = function(args)
    local ok, closed = pcall(require("diffview").close, nil, { force = args.force == true })
    if not ok then
      return plugin.err("diffview close failed: " .. tostring(closed))
    end

    return { json = { closed = closed ~= false } }
  end,
}

M.tools.selection_get = {
  name = "plugin_diffview_selection_get",
  description = "Return the files the captain has marked in the diff view's panel. This is human intent the agent cannot learn any other way — act on the marked set rather than guessing which files they meant.",
  schema = { type = "object", additionalProperties = false },
  handler = function()
    local api = plugin.optional("diffview.api")
    if api == nil or api.selections == nil then
      return plugin.err("selections need the diffview+ fork (dlyongemallo/diffview-plus.nvim)")
    end

    local ok, selected = pcall(api.selections.get)
    if not ok then
      return plugin.err("could not read diffview selections: " .. tostring(selected))
    end

    return { json = { selections = selected or {}, count = #(selected or {}) } }
  end,
}

M.tools.selection_set = {
  name = "plugin_diffview_selection_set",
  description = "Mark a set of files in the diff view's panel, replacing whatever was marked. Use it to hand a shortlist back to the captain — the files an audit flagged, the ones a change should touch.",
  schema = {
    type = "object",
    properties = {
      paths = {
        type = "array",
        items = { type = "string" },
        description = "Repo-relative paths to mark. An empty array clears the selection.",
      },
    },
    required = { "paths" },
    additionalProperties = false,
  },
  handler = function(args)
    local api = plugin.optional("diffview.api")
    if api == nil or api.selections == nil then
      return plugin.err("selections need the diffview+ fork (dlyongemallo/diffview-plus.nvim)")
    end
    if type(args.paths) ~= "table" then
      return plugin.err("paths must be an array")
    end

    local ok, set_err
    if #args.paths == 0 then
      ok, set_err = pcall(api.selections.clear)
    else
      ok, set_err = pcall(api.selections.set, args.paths)
    end
    if not ok then
      return plugin.err("could not set diffview selections: " .. tostring(set_err))
    end

    return { json = { marked = #args.paths } }
  end,
}

M.register = plugin.registrar(M.tools, "diffview")

return M
