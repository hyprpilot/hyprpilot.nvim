--- Buffer-local keymaps for the chat surface. Wired from
--- `chat/buffer.lua::create` so every per-instance chat buffer
--- (and the placeholder) picks them up on mint.
---
--- Today: `gf` only. Chat content carries file refs the way agents
--- and the renderer spell them — backtick-wrapped, sometimes with
--- a `:line` (or `:line-range`) suffix, sometimes relative to cwd
--- (the renderer's `paste_buffer` / `### adapter` rows / agent text
--- citations). Stock `gf` stops at `:` and chokes on backticks, so
--- we ship a custom handler that parses the common shapes and
--- opens the file at the right row.

local config = require("hyprpilot.config")
local log = require("hyprpilot.log")

local M = {}

---Path/line patterns the handler accepts:
---   path                            (bare)
---   path:LINE                       (jump to LINE)
---   path:LINE-END                   (jump to LINE, range is informational)
---   `path`                          (markdown code span — strip backticks)
---   `path:LINE`                     (same with line)
---Returns the resolved absolute path + optional line number, or
---nil when the token under the cursor doesn't look like a path.
---@param line string
---@param col integer  -- 0-indexed byte column the cursor is on
---@return string? path, integer? line_no
local function parse_ref_at(line, col)
  -- Walk left + right from `col` to find a contiguous non-space,
  -- non-backtick token. Backticks are common around paths in
  -- markdown code spans (`lua/foo.lua`) — exclude them from the
  -- token so the caller doesn't have to strip.
  if line == "" then
    return nil, nil
  end

  local lo = col + 1
  while lo > 1 do
    local ch = line:sub(lo - 1, lo - 1)
    if ch == "" or ch:match("[%s`]") ~= nil then
      break
    end
    lo = lo - 1
  end

  local hi = col + 1
  while hi <= #line do
    local ch = line:sub(hi, hi)
    if ch == "" or ch:match("[%s`]") ~= nil then
      break
    end
    hi = hi + 1
  end

  if hi <= lo then
    return nil, nil
  end

  local token = line:sub(lo, hi - 1)
  if token == "" then
    return nil, nil
  end

  -- Strip a trailing colon-then-non-number tail (e.g. `path:` from
  -- `path: more text`). The line-number variants land in the
  -- (path, line, end?) captures below.
  local path, line_no = token:match("^(.-):(%d+)%-?%d*:?$")
  if path == nil then
    path = token:match("^([^:]+):?$") or token
  end

  if path == nil or path == "" then
    return nil, nil
  end

  -- Resolve relative paths against cwd. Absolute paths and `~/...`
  -- pass through `vim.fs.normalize`.
  local resolved = vim.fs.normalize(path)
  if resolved:sub(1, 1) ~= "/" then
    resolved = vim.fs.normalize(vim.fn.getcwd() .. "/" .. resolved)
  end

  if vim.fn.filereadable(resolved) ~= 1 then
    return nil, nil
  end

  return resolved, line_no ~= nil and tonumber(line_no) or nil
end

---`gf` handler — opens the file ref under the cursor in the last
---non-chat window the captain came from (or a fresh split when no
---suitable window exists). Logs at debug + no-op on a non-path
---token instead of throwing.
local function goto_file()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local path, line_no = parse_ref_at(line, cursor[2])

  if path == nil then
    log.debug("chat.keymaps: gf no file ref under cursor (line=%q col=%d)", line, cursor[2])
    return
  end

  -- Prefer the captain's prior window (the one `ui.window.focus`
  -- stashes when they jump into chrome). Falls back to a vsplit
  -- when no prior window or it's no longer valid.
  local target_win
  local stashed = (package.loaded["hyprpilot.ui.window"] or {})._prev_winid
  if stashed ~= nil and vim.api.nvim_win_is_valid(stashed) then
    target_win = stashed
  end

  if target_win == nil then
    vim.cmd("vsplit")
    target_win = vim.api.nvim_get_current_win()
  end

  -- `gf` targets a captain file buffer; third-party `BufEnter *`
  -- hooks can throw if their treesitter parser isn't available for
  -- the resolved buffer's filetype. Absorb so the keymap fails
  -- gracefully instead of bubbling through the chat buffer's
  -- keymap layer.
  local ok, err = pcall(vim.api.nvim_set_current_win, target_win)
  if not ok then
    log.warn("chat.keymaps.gf: nvim_set_current_win failed: %s", err)
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  if line_no ~= nil then
    pcall(vim.api.nvim_win_set_cursor, target_win, { line_no, 0 })
    vim.cmd("normal! zz")
  end
end

local apply = require("hyprpilot.ui.keymaps").apply_action

---Collect every tracked extmark row of a given category for the
---current buffer's render state. `category` is `"turn"` (uses the
---per-layout `pilot_header_mark`) or `"section"` (uses each
---`section.head_mark`). Returns rows sorted ascending; positions
---read fresh from extmarks so they reflect the live buffer.
---@param bufnr integer
---@param category "turn" | "section"
---@return integer[]
local function anchor_rows(bufnr, category)
  local render = require("hyprpilot.chat.render")
  local state = render.state_for_bufnr(bufnr)
  if state == nil then
    return {}
  end
  local rows = {}
  for _, layout in pairs(state.turn_layouts) do
    if category == "turn" then
      if layout.pilot_header_mark ~= nil then
        local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, render.NS, layout.pilot_header_mark, {})
        if pos[1] ~= nil then
          table.insert(rows, pos[1])
        end
      end
    elseif category == "section" and type(layout.sections) == "table" then
      for _, section in pairs(layout.sections) do
        local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, render.NS, section.head_mark, {})
        if pos[1] ~= nil then
          table.insert(rows, pos[1])
        end
      end
    end
  end
  table.sort(rows)
  return rows
end

---Move the cursor to the next/previous anchor row of `category`,
---relative to the current cursor row. `direction` is `1` (next) or
---`-1` (prev). No-op when nothing's tracked yet (empty chat).
---@param category "turn" | "section"
---@param direction integer
local function jump(category, direction)
  local bufnr = vim.api.nvim_get_current_buf()
  local rows = anchor_rows(bufnr, category)
  if #rows == 0 then
    return
  end
  -- Cursor is 1-indexed; extmarks are 0-indexed.
  local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
  local target = nil
  if direction > 0 then
    for _, r in ipairs(rows) do
      if r > cur then
        target = r
        break
      end
    end
  else
    for i = #rows, 1, -1 do
      if rows[i] < cur then
        target = rows[i]
        break
      end
    end
  end
  if target == nil then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { target + 1, 0 })
  vim.cmd("normal! zz")
end

---Auto load-older on scroll-up. The chat snapshot only carries the
---most recent N items by default (`state.snapshot_limit`); when
---the captain scrolls toward the top of the buffer we pre-emptively
---fetch the next page so they don't bottom out at line 1 with
---untouched history below the cut. Throttled by `state._load_older_lock`
---so a fast `<C-u>` doesn't spam the daemon — the lock releases
---when the in-flight hydrate replies (or errors).
---@param bufnr integer
local function maybe_load_older(bufnr)
  local state = require("hyprpilot.chat.render").state_for_bufnr(bufnr)
  if state == nil or state.has_more ~= true then
    return
  end
  if state._load_older_lock == true then
    return
  end
  -- Window check: top-visible line (`w0`) within 3 rows of the
  -- buffer top. Use the current window since the autocmd fires
  -- with the chat buffer focused (any window showing it counts).
  local winid = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then
    return
  end
  if vim.fn.line("w0") > 3 then
    return
  end
  state._load_older_lock = true
  require("hyprpilot.chat.events").load_older(state.instance_id, nil, function()
    state._load_older_lock = false
  end)
end

---Wire chat-buffer keymaps + autocmds onto `bufnr`. Called from
---`chat/buffer.lua::create`. Idempotent — re-running just resets
---the buffer-local mappings (vim handles dedup) and re-creates the
---autocmd group.
---@param bufnr integer
function M.attach(bufnr)
  local keymaps = (config.options.chat or {}).keymaps or {}
  apply(bufnr, keymaps.goto_file, goto_file, "open file ref under cursor")

  -- Turn / section jump pairs. Disable with `keymaps.next_turn =
  -- false` etc. The `[`/`]` family follows vim's standard
  -- next-of-kind convention (`]m` = next method, `]s` = next misspelled
  -- word) so the chat keymaps stay learnable.
  apply(bufnr, keymaps.next_turn, function()
    jump("turn", 1)
  end, "jump to next turn header")
  apply(bufnr, keymaps.prev_turn, function()
    jump("turn", -1)
  end, "jump to previous turn header")
  apply(bufnr, keymaps.next_section, function()
    jump("section", 1)
  end, "jump to next section header")
  apply(bufnr, keymaps.prev_section, function()
    jump("section", -1)
  end, "jump to previous section header")

  -- Auto load-older when cursor lands near the top. `CursorMoved`
  -- fires for both keystroke navigation and `<C-b>` / `<C-u>`
  -- jumps, so the captain doesn't need to remember a manual
  -- "page up" keymap. The throttle inside `maybe_load_older`
  -- keeps a fast scroll from queuing N daemon requests.
  local group = vim.api.nvim_create_augroup("HyprpilotChatPagination_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      maybe_load_older(bufnr)
    end,
  })
end

M._parse_ref_at = parse_ref_at

return M
