"""Integration tests for the FastMCP dispatcher against a real
headless Neovim that has the `hyprpilot.mcp` Lua module loaded.

These tests cover the wire that matters most: the Python bridge
queries `require('hyprpilot.mcp').list()`, sees whatever the captain
registered on the Lua side (including the built-in
`mcp/{lsp,editor,open}.lua` categories), and round-trips
`require('hyprpilot.mcp').call(name, args)` for every invocation.
The schemas, descriptions, and tool names should pass through
verbatim — the FastMCP `FunctionTool` carries `parameters=schema`
straight from Lua to the agent.

Pure unit tests (CLI parsing, `NvimWrapper` construction) live in
`test_smoke.py` and don't require the `nvim` fixture.
"""

from __future__ import annotations

from typing import Any

import pynvim
import pytest
from fastmcp import FastMCP

from hyprpilot_nvim_mcp.dispatcher import discover, register_dynamic
from hyprpilot_nvim_mcp.nvim import NvimWrapper


class _DirectNvim(NvimWrapper):
    """Subclass that bypasses the listen-address attach path so the
    integration tests can hand it a pre-built `pynvim.Nvim` from the
    `nvim` fixture. The base class is built around socket attach +
    reconnect-on-broken-pipe; for tests, we own the lifetime."""

    def __init__(self, handle: pynvim.Nvim) -> None:
        # Skip super().__init__ — it raises on missing listen address.
        # Set the attributes the base class would set so `_attach()`
        # short-circuits to our pre-built handle.
        import threading

        from hyprpilot_nvim_mcp import log

        self._listen_address = "<embedded>"
        self._lock = threading.Lock()
        self._nvim = handle
        self._log = log.get("nvim-test")


def test_register_all_categories_surface_through_discover(nvim: pynvim.Nvim) -> None:
    """Captain calls `register_all()` for each built-in category;
    the Python-side `discover()` must surface every tool name with
    a non-empty description and an `object`-typed schema."""
    nvim.exec_lua(
        """
        require("hyprpilot.mcp.lsp").register_all()
        require("hyprpilot.mcp.editor").register_all()
        require("hyprpilot.mcp.open").register_all()
        """,
        [],
    )

    listing = discover(_DirectNvim(nvim))

    names = sorted(entry["name"] for entry in listing)

    # Every category contributes at least one tool. Spot-check the
    # representative ones the captain explicitly listed as required.
    for required in (
        "lsp_definition",
        "lsp_hover",
        "lsp_references",
        "lsp_document_symbols",
        "lsp_code_actions",
        "lsp_rename",
        "lsp_ensure_loaded",
        "diagnostics_get",
        "editor_cursor",
        "editor_buffers",
        "editor_read",
        "open_url",
    ):
        assert required in names, f"missing tool {required} in discover() output"

    # Schema invariants: object type, non-empty description.
    for entry in listing:
        assert isinstance(entry["description"], str) and entry["description"]
        assert entry["schema"]["type"] == "object"


def test_register_dynamic_creates_one_function_tool_per_lua_entry(
    nvim: pynvim.Nvim,
) -> None:
    """`register_dynamic` builds the FastMCP `FunctionTool` per Lua
    tool. The schema passes through verbatim (we don't synthesize it
    from Python type hints)."""
    nvim.exec_lua("require('hyprpilot.mcp.editor').register_all()", [])

    mcp = FastMCP("test")
    tools = register_dynamic(mcp, _DirectNvim(nvim))

    assert "editor_cursor" in tools
    assert "editor_read" in tools

    # The dispatcher carries the Lua schema verbatim. `editor_read`
    # requires `path`; the FunctionTool's parameters dict should
    # preserve that.
    read_tool = tools["editor_read"]
    assert read_tool.parameters["type"] == "object"
    assert "path" in read_tool.parameters["required"]


def test_dispatch_round_trip_returns_lua_result(nvim: pynvim.Nvim) -> None:
    """End-to-end: register an editor_cursor tool on the Lua side,
    call it via the Python dispatcher, verify the JSON payload
    survives the round-trip."""
    nvim.exec_lua("require('hyprpilot.mcp.editor').register_all()", [])

    mcp = FastMCP("test")
    tools = register_dynamic(mcp, _DirectNvim(nvim))

    # `editor_cursor` takes no args. The dispatcher closes over the
    # NvimWrapper and round-trips through `exec_lua`.
    result: Any = tools["editor_cursor"].fn()

    # Lua handler returns `{ json = { bufnr, path, ... } }` — pynvim
    # decodes maps as dicts.
    assert "json" in result
    assert "bufnr" in result["json"]
    assert "line" in result["json"]
    assert isinstance(result["json"]["line"], int)


def test_dispatch_round_trip_carries_arguments(nvim: pynvim.Nvim) -> None:
    """Arguments survive the JSON ↔ msgpack ↔ Lua-table boundary."""
    # Register a small custom tool so we don't depend on a real LSP
    # server / file system fixture.
    nvim.exec_lua(
        """
        require("hyprpilot.mcp").register({
          name = "demo_echo",
          description = "Echo back the args.",
          schema = { type = "object", additionalProperties = true },
          handler = function(args)
            return { json = args }
          end,
        })
        """,
        [],
    )

    mcp = FastMCP("test")
    tools = register_dynamic(mcp, _DirectNvim(nvim))
    assert "demo_echo" in tools

    result: Any = tools["demo_echo"].fn(text="hello", count=42)
    assert result["json"]["text"] == "hello"
    assert result["json"]["count"] == 42


def test_unregister_removes_tool_from_subsequent_discover(nvim: pynvim.Nvim) -> None:
    """The reload management surface relies on `discover()` reflecting
    captain-driven `unregister()` calls."""
    nvim.exec_lua("require('hyprpilot.mcp.open').register_all()", [])
    wrapper = _DirectNvim(nvim)

    names_before = {entry["name"] for entry in discover(wrapper)}
    assert "open_url" in names_before

    nvim.exec_lua("require('hyprpilot.mcp').unregister('open_url')", [])

    names_after = {entry["name"] for entry in discover(wrapper)}
    assert "open_url" not in names_after


def test_discover_with_empty_registry_returns_empty_list(nvim: pynvim.Nvim) -> None:
    """No `register_all()` call → no captain tools. The bridge surfaces
    its built-in management tools separately; this list is just the
    Lua-side surface."""
    # Reset the registry (some other test in the same nvim might
    # have populated it; the fixture is per-test so this is a fresh
    # nvim, but be explicit).
    nvim.exec_lua("require('hyprpilot.mcp')._reset()", [])

    listing = discover(_DirectNvim(nvim))
    assert listing == []


def test_dispatch_propagates_lua_handler_error(nvim: pynvim.Nvim) -> None:
    """Lua handler that returns `{ is_error = true, text = '...' }`
    surfaces verbatim — Python doesn't second-guess it."""
    nvim.exec_lua(
        """
        require("hyprpilot.mcp").register({
          name = "demo_fail",
          description = "Always returns is_error.",
          schema = { type = "object" },
          handler = function()
            return { is_error = true, text = "intentional failure" }
          end,
        })
        """,
        [],
    )

    mcp = FastMCP("test")
    tools = register_dynamic(mcp, _DirectNvim(nvim))

    result: Any = tools["demo_fail"].fn()
    assert result["is_error"] is True
    assert "intentional failure" in result["text"]


@pytest.mark.parametrize(
    "category_module",
    [
        "hyprpilot.mcp.lsp",
        "hyprpilot.mcp.editor",
        "hyprpilot.mcp.open",
    ],
)
def test_each_category_has_register_all_idempotent(nvim: pynvim.Nvim, category_module: str) -> None:
    """Calling `register_all()` twice is a no-op (overwrite semantics
    on the registry side). The captain's hot-reload workflow depends
    on this."""
    nvim.exec_lua(f"require('{category_module}').register_all()", [])
    first = discover(_DirectNvim(nvim))

    nvim.exec_lua(f"require('{category_module}').register_all()", [])
    second = discover(_DirectNvim(nvim))

    # Same set of names (some other category may also be registered;
    # we only assert this category's tools didn't double up).
    first_names = {entry["name"] for entry in first}
    second_names = {entry["name"] for entry in second}
    assert first_names == second_names
