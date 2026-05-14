--- Behavioural tests for `chat/keymaps.lua` — exercises the
--- `gf` ref-parser against real chat-content shapes and a few
--- adversarial inputs. The keymap-binding path is smoke-tested by
--- asserting the keymap exists on a freshly minted chat buffer.

local T = MiniTest.new_set()

local keymaps = require("hyprpilot.chat.keymaps")
local parse = keymaps._parse_ref_at

---Mint a real file under cwd so the parser's `filereadable` check
---passes. Returns the relative path + absolute path + a cleanup.
---@param contents string
---@return string rel_path, string abs_path, fun()
local function mint_temp_file(contents)
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  local rel = "tmp-" .. tostring(vim.uv.hrtime()) .. ".lua"
  local abs = tmpdir .. "/" .. rel
  local fh = assert(io.open(abs, "w"))
  fh:write(contents)
  fh:close()

  -- Tests run from the plugin repo root; chdir to the temp dir so
  -- the relative-path branch in `parse_ref_at` resolves correctly.
  local original_cwd = vim.fn.getcwd()
  vim.cmd("lcd " .. vim.fn.fnameescape(tmpdir))

  return rel, abs, function()
    vim.cmd("lcd " .. vim.fn.fnameescape(original_cwd))
    pcall(os.remove, abs)
    pcall(vim.fn.delete, tmpdir, "rf")
  end
end

T["gf: parses bare relative path under cursor"] = function()
  local rel, abs, cleanup = mint_temp_file("local x = 1\n")
  local line = "see " .. rel .. " for the impl"
  local col = #"see " + 1 -- inside the path

  local resolved, line_no = parse(line, col)
  MiniTest.expect.equality(resolved, abs)
  MiniTest.expect.equality(line_no, nil)

  cleanup()
end

T["gf: parses path:LINE (jump to that line)"] = function()
  local rel, abs, cleanup = mint_temp_file("line 1\nline 2\nline 3\n")
  local line = "see `" .. rel .. ":2` for that"
  local col = #"see `" + 1

  local resolved, line_no = parse(line, col)
  MiniTest.expect.equality(resolved, abs)
  MiniTest.expect.equality(line_no, 2)

  cleanup()
end

T["gf: parses path:start-end (range — picks the start line)"] = function()
  local rel, abs, cleanup = mint_temp_file("a\nb\nc\nd\ne\n")
  local line = string.format("`%s:3-5`", rel)
  local col = 5

  local resolved, line_no = parse(line, col)
  MiniTest.expect.equality(resolved, abs)
  MiniTest.expect.equality(line_no, 3)

  cleanup()
end

T["gf: backtick-wrapped path resolves cleanly"] = function()
  local rel, abs, cleanup = mint_temp_file("body\n")
  local line = "edit `" .. rel .. "` to fix"
  local col = #"edit `" + 2 -- inside the backticked token

  local resolved, _ = parse(line, col)
  MiniTest.expect.equality(resolved, abs)

  cleanup()
end

T["gf: returns nil when no path-shaped token sits under the cursor"] = function()
  local line = "this is just prose with no file ref"
  local resolved, _ = parse(line, 5)
  MiniTest.expect.equality(resolved, nil)
end

T["gf: returns nil when the parsed token doesn't exist on disk"] = function()
  local line = "see `does/not/exist.lua` for the impl"
  local resolved, _ = parse(line, 8)
  MiniTest.expect.equality(resolved, nil)
end

T["chat/buffer.create wires the goto_file keymap on the new buffer"] = function()
  local buffer = require("hyprpilot.chat.buffer")
  local id = "test-keymap-" .. tostring(vim.uv.hrtime())
  local bufnr = buffer.create(id)

  local found_gf = false
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if mapping.lhs == "gf" then
      found_gf = true
      break
    end
  end
  MiniTest.expect.equality(found_gf, true)

  buffer.wipe(bufnr)
end

return T
