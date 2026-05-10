# `hyprpilot-nvim-mcp` — implementation handoff

> **Status**: handoff doc, ready for an implementer (separate repo, separate
> ship cadence). Daemon-side surface is settled (`mcps.json` accepts stdio
> MCP entries today; no daemon code changes needed). This is a standalone
> Python project: a `uvx`-runnable MCP server that bridges Neovim's editor
> state into the agent's tool surface.

> **Goal**: a one-liner in the captain's `mcps.json` —
>
> ```json
> "neovim": {
>   "command": "uvx",
>   "args": ["hyprpilot-nvim-mcp"],
>   "env": { "NVIM_LISTEN_ADDRESS": "${NVIM_LISTEN_ADDRESS}" }
> }
> ```
>
> — and the agent gets a curated set of editor-state tools: current buffer
> contents + cursor + selection, open buffers, LSP definition / references /
> hover / diagnostics, treesitter symbols at the cursor, plus any
> user-defined tools the captain registered via the `hyprpilot.nvim`
> plugin's Lua API.

---

## Style anchor

**FastMCP** (`pip install fastmcp`, by jlowin / now upstreamed into the
official MCP Python SDK) is the canonical framework. Decorator-based
tool registration, auto-derived JSON schemas from type hints + docstrings.
The implementer's first read is the FastMCP quickstart
(<https://gofastmcp.com/getting-started/quickstart>) — internalise the
`@mcp.tool()` shape before scaffolding anything.

**pynvim** (<https://github.com/neovim/pynvim>) is the canonical Python
nvim client. msgpack-RPC over the listen socket; idiomatic Python API
for buffers, windows, LSP, autocmds, `exec_lua`. The README is sparse;
the test suite is where the patterns live —
<https://github.com/neovim/pynvim/tree/master/test>.

**uv** (Astral, <https://docs.astral.sh/uv/>) is the modern Python
package manager. `uv init` scaffolds; `pyproject.toml` declares deps;
`uvx <pkg>` is the no-install spawn idiom (PyPI fetch on first run,
cached afterward; same UX as `bunx` from the captain's lens). The
project uses `uv.lock` for reproducibility — committed.

**`ruff`** (Astral) for lint + format. Single binary, replaces black +
isort + flake8 + pylint. Configure in `pyproject.toml`'s `[tool.ruff]`
section. CI gate: `uv run ruff check && uv run ruff format --check`.

**Type hints + `mypy --strict`** — every public function annotated,
every internal helper too. mypy gate in CI: `uv run mypy src/`.

## Inspirations (not anchors)

- **Official MCP examples**
  (<https://github.com/modelcontextprotocol/python-sdk/tree/main/examples>)
  — canonical FastMCP shape. The "weather" and "everything" servers are
  the right starting templates.
- **`mcp-server-filesystem`**
  (<https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem>)
  — sane shape for "expose system state" servers; resource + tool
  patterns.
- **`hyprpilot.nvim` handoff plan**
  (`docs/plans/2026-05-09-nvim-plugin-handoff.md` in the main hyprpilot
  repo) — the Lua-side contract for `require('hyprpilot.mcp').list/call`
  is mirrored there. This server's job is to talk to that.

---

## Architecture

```
                 ┌──────────────────────────────────────────────┐
                 │  daemon (hyprpilot)                          │
                 │  spawns child via mcps.json:                 │
                 │      uvx hyprpilot-nvim-mcp                  │
                 └────────────────┬─────────────────────────────┘
                                  │ stdio (MCP JSON-RPC)
                                  ▼
                 ┌──────────────────────────────────────────────┐
                 │  hyprpilot-nvim-mcp                          │
                 │    FastMCP server (stdio transport)          │
                 │    ├── builtins: pure Python tools           │
                 │    │     (current_buffer, lsp_*, ts_*, etc.) │
                 │    └── dynamic: discovered from Lua at start │
                 └────────────────┬─────────────────────────────┘
                                  │ pynvim over $NVIM_LISTEN_ADDRESS
                                  ▼
                 ┌──────────────────────────────────────────────┐
                 │  Neovim (running, --listen <socket>)         │
                 │    ├── Lua plugin: hyprpilot.nvim            │
                 │    │     exposes require('hyprpilot.mcp')    │
                 │    │       .list()  → {name, desc, schema}[] │
                 │    │       .call(name, args) → result        │
                 │    └── builtins use editor state directly    │
                 │          (vim.api, vim.lsp.*, vim.treesitter)│
                 └──────────────────────────────────────────────┘
```

**Dep tree** (`pyproject.toml`):

```toml
[project]
name = "hyprpilot-nvim-mcp"
version = "0.1.0"
requires-python = ">=3.10"
dependencies = [
    "fastmcp>=2.0",
    "pynvim>=0.5",
]

[project.scripts]
hyprpilot-nvim-mcp = "hyprpilot_nvim_mcp.cli:main"

[dependency-groups]
dev = [
    "ruff>=0.6",
    "mypy>=1.10",
    "pytest>=8.0",
    "pytest-asyncio>=0.24",
]

[tool.ruff]
line-length = 100
target-version = "py310"

[tool.mypy]
strict = true
```

**Source layout**:

```
src/hyprpilot_nvim_mcp/
├── __init__.py
├── cli.py              -- entry point: uvx hyprpilot-nvim-mcp → main()
├── config.py           -- env var parsing + defaults (NVIM_LISTEN_ADDRESS, log level)
├── log.py              -- structured logging (stderr only — stdout is the MCP wire)
├── nvim.py             -- pynvim attach + reconnect loop + thread-safety wrapper
├── server.py           -- FastMCP instance + register_builtins() + register_dynamic()
├── tools/
│   ├── __init__.py
│   ├── buffer.py       -- current_buffer, open_buffers, buffer_lines
│   ├── lsp.py          -- lsp_definition, lsp_references, lsp_hover, diagnostics
│   ├── treesitter.py   -- ts_symbols_at_cursor, ts_node_at_cursor
│   └── exec_lua.py     -- exec_lua tool, gated behind --enable-exec-lua flag (DANGEROUS)
└── dynamic.py          -- talks to require('hyprpilot.mcp').list/call

tests/
├── test_buffer.py
├── test_lsp.py
├── test_treesitter.py
├── test_dynamic.py     -- mocks pynvim.exec_lua
└── conftest.py         -- shared pynvim fixture (boots headless nvim)
```

---

## Phases — bite-sized commits

Each phase ships as one commit, runs CI green (lint + type-check + tests),
optionally publishes a tagged pre-release to TestPyPI for the captain to
smoke-test via `uvx --from testpypi hyprpilot-nvim-mcp`.

### Phase 1 — `uv init` + smoke `tools/list`

**Files**: `pyproject.toml`, `src/hyprpilot_nvim_mcp/{__init__,cli,server}.py`,
`README.md`, `.github/workflows/ci.yml`, `.gitignore`.

**Steps**:

1. `uv init --package hyprpilot-nvim-mcp`. Fill in `pyproject.toml` per the
   shape above. Commit `uv.lock`.
2. `cli.py::main()` — parse `--log-level` (default INFO) + read
   `NVIM_LISTEN_ADDRESS` from env. Boot the FastMCP server with a single
   stub tool (`@mcp.tool() def ping() -> str: return "pong"`).
3. `mcp.run(transport="stdio")` blocks until daemon closes stdin.
4. Logging: configure `logging.basicConfig(stream=sys.stderr, ...)` —
   **stdout is reserved for MCP wire bytes**, never log to it.
5. `ci.yml` — checkout, `uv sync`, `uv run ruff check`,
   `uv run ruff format --check`, `uv run mypy src/`,
   `uv run pytest`.
6. README: install + run instructions, env vars list, link back to
   hyprpilot main repo.

**Verify**: `uvx --from . hyprpilot-nvim-mcp` boots; running
`echo '{"jsonrpc":"2.0","id":1,"method":"initialize",...}' | uvx ...`
returns the FastMCP capabilities dump; `tools/list` lists `ping`;
`tools/call` with `name=ping` returns `"pong"`.

### Phase 2 — pynvim attach + first builtin

**Files**: `nvim.py`, `tools/buffer.py`, `tests/test_buffer.py`,
`tests/conftest.py`.

**Steps**:

1. `nvim.py::get_nvim()` — singleton-ish wrapper:
   - First call: `pynvim.attach('socket', path=NVIM_LISTEN_ADDRESS)`.
     Raise a typed `NvimUnavailableError` with a clean message if the
     socket is missing or `connect` fails.
   - Cache the handle. Reconnect on RPC errors (broken pipe, EOF).
   - Wrap every `nvim.*` access in a `with self._lock` (pynvim is
     thread-unsafe by default; FastMCP's tool dispatch may run on
     multiple threads under load).
2. `tools/buffer.py::current_buffer(include_lines: bool = True) -> dict`:
   - `path: str` from `nvim.eval("expand('%:p')")`.
   - `cursor: tuple[int, int]` from `nvim.current.window.cursor`.
   - `filetype: str` from `nvim.current.buffer.options['filetype']`.
   - `lines: list[str]` (when `include_lines`) capped at 4 KiB; if
     truncated set `truncated: True` and report `total_lines`.
3. `tools/buffer.py::open_buffers() -> list[dict]` — list every loaded
   buffer's `{path, modified, filetype}`.
4. Register both via `mcp.add_tool(...)` from `server.py`.
5. `conftest.py` boots a headless nvim subprocess via `pynvim.attach`:

   ```python
   @pytest.fixture
   def nvim():
       proc = subprocess.Popen(["nvim", "--headless", "--embed",
                                "--clean"], stdin=PIPE, stdout=PIPE)
       n = pynvim.attach("child", argv=["nvim", "--embed", "--clean"])
       yield n
       n.quit("qa!")
   ```

   Then patch `nvim.get_nvim` to return this in tests.

**Verify**: `pytest tests/test_buffer.py` — assert `current_buffer`
returns the path of an opened test fixture file; `open_buffers` returns
N=1 entry. Manual smoke: spawn nvim with `nvim --listen /tmp/a.sock
README.md`, run `NVIM_LISTEN_ADDRESS=/tmp/a.sock uvx --from .
hyprpilot-nvim-mcp` from another terminal, send a `tools/call` for
`current_buffer` → see README.md.

### Phase 3 — LSP + treesitter + diagnostics builtins

**Files**: `tools/lsp.py`, `tools/treesitter.py`, plus tests.

**Steps**:

1. `lsp_definition(file: str | None, line: int | None, col: int | None) -> list[dict]`:
   - Defaults: current buffer + current cursor.
   - `nvim.exec_lua` call into `vim.lsp.buf_request_sync` with
     `textDocument/definition`. Return `[{file, line, col}, ...]`.
   - Same shape for `lsp_references`, `lsp_hover` (returns markdown
     contents), `lsp_workspace_symbols(query: str)`.
2. `diagnostics(severity: Literal["error","warn","info","hint"] | None = None) -> list[dict]`:
   - `nvim.exec_lua("return vim.diagnostic.get(0, ...)")` for current
     buffer, OR `nvim.exec_lua("return vim.diagnostic.get()")` for all.
   - Return list of `{file, line, col, severity, message, source, code}`.
3. `treesitter_symbols_at_cursor() -> dict`:
   - Walk the treesitter tree from cursor up; collect every node whose
     type is in `("function_definition", "function_declaration",
     "method_definition", "class_definition", "module", "namespace",
     ...)`. Return enclosing chain.
4. Tool docstrings drive the JSON Schema FastMCP exposes — every param
   gets a `:param foo: ...` line. Keep them tight; the agent reads
   these to decide when to call.

**Verify**: spawn a nvim with an LSP active (e.g. nvim + clangd on a C
file), run `lsp_definition` via the MCP wire, get back the right path +
line. Tests use a stubbed `vim.lsp.buf_request_sync` via `exec_lua`
mocks rather than real LSPs (real-LSP integration test belongs in a
separate manual harness).

### Phase 4 — Lua-side dynamic tool discovery

**Files**: `dynamic.py`, `tests/test_dynamic.py`.

This is the load-bearing extensibility hook — captains add their own
tools in nvim config, the agent sees them automatically.

**Steps**:

1. At server startup (`server.py::register_dynamic()`), call:

   ```python
   tools = nvim.exec_lua("""
       local ok, mod = pcall(require, 'hyprpilot.mcp')
       if not ok then return {} end
       return mod.list()
   """)
   ```

2. Each entry has `{name: str, description: str, schema: dict}`. For each:
   - Build a Python wrapper:

     ```python
     def make_dispatcher(tool_name: str):
         def call(arguments: dict) -> dict:
             return nvim.exec_lua(
                 "return require('hyprpilot.mcp').call(...)",
                 [tool_name, arguments]
             )
         return call
     ```

   - Register with FastMCP:

     ```python
     mcp.add_tool(
         name=entry["name"],
         description=entry["description"],
         input_schema=entry["schema"],
         fn=make_dispatcher(entry["name"]),
     )
     ```

3. **Refresh on demand** — expose a control tool
   `mcp__neovim__reload_dynamic_tools()` that re-runs discovery + diffs
   the current registration. Lets the captain add new tools without
   restarting the MCP server (which would tear down the daemon's MCP
   session).
4. Errors at the Lua boundary surface as `MCPToolError` with the Lua
   stack trace in the message — invaluable for debugging.

**Lua-side contract** the bridge depends on:

```lua
---@class hyprpilot.mcp.Tool
---@field name string         -- final segment; agent sees mcp__neovim__<name>
---@field description string  -- one-liner the agent reads to decide
---@field schema table        -- JSON Schema for input args
---@field handler fun(args: table): any  -- returns result; errors via error()

local M = {}
local registry = {} ---@type table<string, hyprpilot.mcp.Tool>

function M.register(tool)
  -- name, description, schema, handler validation here
  registry[tool.name] = tool
end

function M.list()
  local out = {}
  for _, t in pairs(registry) do
    table.insert(out, { name = t.name, description = t.description, schema = t.schema })
  end
  return out
end

function M.call(name, args)
  local tool = registry[name]
  if not tool then error("unknown tool: " .. name) end
  return tool.handler(args or {})
end

return M
```

The plugin ships this module; the bridge depends on its existence
(graceful fallback to "no dynamic tools" when the plugin isn't loaded).

**Verify**: with the plugin loaded + a test tool registered, the
bridge's `tools/list` includes it; `tools/call` round-trips args + result.

### Phase 5 — Polish

**Files**: `config.py`, `log.py`, error handling across the tree.

**Steps**:

1. `config.py` — parse env: `NVIM_LISTEN_ADDRESS` (required),
   `HYPRPILOT_NVIM_MCP_LOG_LEVEL` (default INFO),
   `HYPRPILOT_NVIM_MCP_ENABLE_EXEC_LUA` (default false — gates the
   raw `exec_lua` tool, which is a remote-code-execution surface).
2. `log.py` — structured stderr logging with `extra={"tool": ..., "args":
   ...}`. Format: `<ts> <level> <module> <msg> [<extra>]`.
3. `nvim.py` reconnect loop — exponential back-off (1s → 2s → 5s →
   10s → 30s cap) on connect refused / pipe broken. Surface via a
   `_meta.connected` field on the next tool result so the captain can
   see disconnected state without having to dig logs.
4. Per-tool error handling: never let a Python exception kill the
   server — convert to `MCPToolError(message, code=...)` with the
   appropriate `-32xxx` JSON-RPC code. Daemon's UI surfaces the
   message verbatim.
5. `:checkhealth` analogue — a `mcp__neovim__healthcheck()` tool that
   returns nvim version, plugin version (if loaded), socket address,
   listed dynamic tool count. The daemon's `/diag` consumer can call it.

**Verify**: kill nvim mid-call, watch the bridge reconnect cleanly;
trigger a deliberate Lua error in a registered tool, see the agent
receive a clean error message rather than the bridge crashing.

### Phase 6 — Publish

**Steps**:

1. Tag `v0.1.0`. GitHub Actions workflow:
   `uv build && uv publish` to PyPI on tag push (PyPI token in repo
   secrets, scoped to this project).
2. Captain updates `mcps.json`:

   ```json
   "neovim": {
     "command": "uvx",
     "args": ["hyprpilot-nvim-mcp@0.1.0"],
     "env": { "NVIM_LISTEN_ADDRESS": "${NVIM_LISTEN_ADDRESS}" }
   }
   ```

3. After captain confirms it works in their setup, drop the version
   pin (`uvx hyprpilot-nvim-mcp`) in the docs.

---

## Built-in tools (v0 set)

Eight tools ship out of the box. The implementer holds the line on
this set — every additional builtin is one more thing to maintain;
captains who want more register Lua-side.

| Tool name | Args | Returns |
| --- | --- | --- |
| `current_buffer` | `include_lines?: bool = true` | `{path, cursor:(row,col), filetype, lines?, total_lines?, truncated?}` |
| `open_buffers` | — | `[{path, modified, filetype}, ...]` |
| `buffer_lines` | `path: str, start: int = 0, end: int = -1` | `{lines: list[str], total: int}` |
| `lsp_definition` | `file?: str, line?: int, col?: int` | `[{file, line, col}, ...]` |
| `lsp_references` | same as above | same shape |
| `lsp_hover` | same as above | `{contents: str (markdown)}` |
| `diagnostics` | `severity?: "error"\|"warn"\|"info"\|"hint", scope?: "buffer"\|"workspace"="buffer"` | `[{file, line, col, severity, message, source, code}, ...]` |
| `treesitter_symbols_at_cursor` | — | `{chain: [{kind, name, range:{start,end}}, ...]}` (enclosing scope chain, outermost first) |

Plus one **dangerous** tool, gated:

| Tool | Args | Returns |
| --- | --- | --- |
| `exec_lua` (only when `HYPRPILOT_NVIM_MCP_ENABLE_EXEC_LUA=1`) | `code: str, args?: list` | result of `nvim.exec_lua(code, args)` |

`exec_lua` is the universal escape hatch — if a captain wants something
the builtins don't do AND can't be bothered registering a Lua tool,
they enable this and the agent has the full Lua surface. Off by
default; the README shouts about the security implications.

Plus one **management** tool always on:

| Tool | Args | Returns |
| --- | --- | --- |
| `reload_dynamic_tools` | — | `{added: list, removed: list, total: int}` |
| `healthcheck` | — | `{nvim_version, plugin_version?, socket, dynamic_tool_count, connected: bool}` |

---

## Verification matrix

Manual smoke checklist — what the implementer pastes into the
final PR description:

- [ ] `uv sync && uv run ruff check && uv run ruff format --check &&
      uv run mypy src/ && uv run pytest` — clean.
- [ ] `uvx --from . hyprpilot-nvim-mcp` boots; smoke MCP-via-stdio
      session works (initialize → tools/list → tools/call ping).
- [ ] Bridge attaches to a running nvim via `$NVIM_LISTEN_ADDRESS`;
      `current_buffer` returns the open file's path.
- [ ] LSP-active buffer (e.g. nvim + clangd on a `.c`); `lsp_definition`
      with cursor on a function name returns the def site.
- [ ] Captain registers a custom tool in their nvim config:
      ```lua
      require('hyprpilot.mcp').register({
        name = "git_blame_line",
        description = "Run git blame on the current line",
        schema = { type = "object" },
        handler = function(args) ... end,
      })
      ```
      Restart MCP server, see `mcp__neovim__git_blame_line` in the
      agent's tool list. Or call `reload_dynamic_tools` without
      restart.
- [ ] Kill nvim mid-call, see the bridge reconnect on next tool call;
      `_meta.connected: false` on the result during disconnect.
- [ ] Trigger a deliberate Lua error in a registered tool; agent
      receives a clean `MCPToolError` with the Lua trace, bridge stays
      up.
- [ ] `tools/list` from the agent's perspective: 8 builtins + 2
      management + N dynamic.

---

## What NOT to ship in v0

Defer until the core works:

- **Resources / Prompts** — FastMCP supports both. v0 is tools-only.
  Resources for buffer content + prompts for "summarize current
  buffer" are nice-to-haves; not blocking.
- **HTTP / SSE transport** — stdio only. The remote-bridge story
  belongs in the daemon, not duplicated here.
- **Multi-nvim** — one bridge instance attaches to one nvim socket.
  If the captain runs N nvim instances, that's N bridge instances
  configured in `mcps.json` (or one bridge that takes a list — but
  YAGNI).
- **Treesitter parser bundling** — rely on whatever the captain's
  nvim ships with. Bridge calls `vim.treesitter.*` and gets nothing
  back if the parser isn't installed; surface that as a clear error.
- **Buffer-pinning by id rather than path** — paths are the contract
  the agent uses. Buffer ids are an internal nvim detail.
- **Async tool handlers** — pynvim is sync; FastMCP tools can be
  async but there's no benefit when the underlying transport is sync
  msgpack-RPC. Stick with sync.

---

## Style invariants

Pin these in the implementer's brain:

- **stdout is sacred**. Logs to stderr only. The MCP wire is on
  stdout; one stray `print()` corrupts the daemon's parser. Every
  module imports `from .log import log` — never `print`.
- **`mypy --strict` from day one**. Untyped Python is a footgun;
  this project's whole point is being a structured tool layer. No
  `# type: ignore` without a comment explaining why.
- **One function per tool**. Tools live in `tools/<group>.py`; each
  is a top-level function with a docstring + type hints. FastMCP
  reads both for the JSON Schema. No clever metaprogramming.
- **Errors are values**. Wrap every `nvim.*` call site to translate
  pynvim exceptions → typed `MCPToolError`. The daemon never sees a
  Python traceback; the captain reads clean messages in the chat
  surface.
- **Reconnect, don't crash**. nvim quitting / restarting is normal.
  The bridge survives it.
- **Tests run headless**. `conftest.py` boots `nvim --headless
  --embed --clean` per fixture. CI runs on Linux + macOS via GitHub
  Actions matrix.
- **uv.lock is committed**. Reproducible installs across the
  captain's machines.
- **`pyproject.toml` is the single source of truth** for deps,
  scripts, lint config, mypy config. No `setup.py`, no `setup.cfg`,
  no `requirements.txt`.

---

## Repo layout summary

Final tree:

```
hyprpilot-nvim-mcp/
├── pyproject.toml
├── uv.lock
├── README.md
├── LICENSE
├── .github/workflows/{ci.yml,publish.yml}
├── src/hyprpilot_nvim_mcp/
│   ├── __init__.py
│   ├── cli.py
│   ├── config.py
│   ├── log.py
│   ├── nvim.py
│   ├── server.py
│   ├── dynamic.py
│   └── tools/
│       ├── __init__.py
│       ├── buffer.py
│       ├── lsp.py
│       ├── treesitter.py
│       └── exec_lua.py
└── tests/
    ├── conftest.py
    ├── test_cli.py
    ├── test_buffer.py
    ├── test_lsp.py
    ├── test_treesitter.py
    └── test_dynamic.py
```

~12 source files, ~6 test files, ~600-900 lines total Python.
