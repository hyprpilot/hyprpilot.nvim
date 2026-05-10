"""Discover Lua-side tools via `require('hyprpilot.mcp').list()` and
register a FastMCP dispatcher per tool that round-trips
`require('hyprpilot.mcp').call(name, args)` through `nvim.exec_lua`.

The Lua schema passes through verbatim as the FastMCP tool's
`parameters` dict — single source of truth for the agent's view.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from fastmcp import FastMCP
from fastmcp.tools.function_tool import FunctionTool

from . import log
from .nvim import NvimUnavailableError, NvimWrapper

LUA_LIST = "return require('hyprpilot.mcp').list()"
LUA_CALL = "return require('hyprpilot.mcp').call(...)"


def discover(nvim: NvimWrapper) -> list[dict[str, Any]]:
    """Query the Lua-side MCP registry. Returns an empty list when the
    plugin isn't loaded or nvim is unreachable."""
    logger = log.get("dispatcher")

    try:
        result = nvim.exec_lua(LUA_LIST)
    except NvimUnavailableError as exc:
        logger.warning("could not discover Lua tools: %s", exc)

        return []
    except Exception as exc:
        logger.warning("hyprpilot.mcp not loaded (plugin not installed?): %s", exc)

        return []

    if not isinstance(result, list):
        return []

    return result


def make_dispatcher(tool_name: str, nvim: NvimWrapper) -> Callable[..., Any]:
    """Build the dispatcher closure for one Lua tool."""

    def dispatch(**arguments: Any) -> Any:
        return nvim.exec_lua(LUA_CALL, [tool_name, arguments])

    dispatch.__name__ = tool_name

    return dispatch


def register_dynamic(mcp: FastMCP, nvim: NvimWrapper) -> dict[str, FunctionTool]:
    """Discover + register every Lua tool. Returns the name → tool map
    so callers (e.g. the `reload_dynamic_tools` management tool) can
    diff later."""
    logger = log.get("dispatcher")
    tools: dict[str, FunctionTool] = {}

    for entry in discover(nvim):
        name = entry.get("name")
        description = entry.get("description")
        schema = entry.get("schema") or {"type": "object"}

        if not isinstance(name, str) or not isinstance(description, str):
            logger.warning("skipping malformed tool entry: %s", entry)
            continue

        tool = FunctionTool(
            name=name,
            description=description,
            parameters=schema,
            fn=make_dispatcher(name, nvim),
        )

        mcp.add_tool(tool)
        tools[name] = tool

    if tools:
        logger.info("registered %d Lua tool(s): %s", len(tools), ", ".join(sorted(tools)))

    return tools
