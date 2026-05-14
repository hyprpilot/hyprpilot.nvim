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

  -- `gf` targets a captain file buffer; markview / render-markdown
  -- hooks bound to `BufEnter *` can throw if their treesitter parser
  -- isn't available for the resolved buffer's filetype. Absorb so the
  -- keymap fails gracefully instead of bubbling through the chat
  -- buffer's keymap layer.
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

---Apply one binding: spec is `string | string[] | false`. `false`
---disables the action; the rest become buffer-local normal-mode
---keymaps pointing at `handler`.
---@param bufnr integer
---@param spec string | string[] | false | nil
---@param handler fun(): nil
---@param desc string
local function apply(bufnr, spec, handler, desc)
  if spec == false or spec == nil then
    return
  end
  if type(spec) == "string" then
    spec = { spec }
  end
  for _, key in ipairs(spec) do
    vim.keymap.set("n", key, handler, { buffer = bufnr, desc = "hyprpilot: " .. desc, silent = true })
  end
end

---Wire chat-buffer keymaps onto `bufnr`. Called from
---`chat/buffer.lua::create`. Idempotent — re-running just resets
---the buffer-local mappings (vim handles dedup).
---@param bufnr integer
function M.attach(bufnr)
  local keymaps = (config.options.chat or {}).keymaps or {}
  apply(bufnr, keymaps.goto_file, goto_file, "open file ref under cursor")
end

M._parse_ref_at = parse_ref_at

return M
