"""`reload_dynamic_tools` MCP tool — re-discover Lua tools and diff
against the currently-registered set. Adds new tools, removes departed
ones."""

from __future__ import annotations

from typing import Any

from fastmcp import FastMCP

from .. import log
from ..dispatcher import discover, make_dispatcher
from ..nvim import NvimWrapper


def register(
    mcp: FastMCP,
    nvim: NvimWrapper,
    registry: dict[str, Any],
) -> None:
    """Wire the `reload_dynamic_tools` tool. `registry` is the live
    `name → FunctionTool` map maintained by `Server`."""

    logger = log.get("reload")

    @mcp.tool(
        name="reload_dynamic_tools",
        description="Re-discover Lua-registered tools and refresh the MCP tool list.",
    )
    def reload_dynamic_tools() -> dict[str, Any]:
        """Returns ``{added: list, removed: list, total: int}``."""
        from fastmcp.tools.function_tool import FunctionTool

        discovered: dict[str, dict[str, Any]] = {}
        for entry in discover(nvim):
            entry_name = entry.get("name")
            if isinstance(entry_name, str):
                discovered[entry_name] = entry

        added: list[str] = []
        removed: list[str] = []

        for name in list(registry):
            if name not in discovered:
                mcp.remove_tool(name)
                del registry[name]
                removed.append(name)

        for name, entry in discovered.items():
            if name in registry:
                continue

            tool = FunctionTool(
                name=name,
                description=entry.get("description") or "",
                parameters=entry.get("schema") or {"type": "object"},
                fn=make_dispatcher(name, nvim),
            )

            mcp.add_tool(tool)
            registry[name] = tool
            added.append(name)

        if added or removed:
            logger.info("reload: +%d / -%d (total %d)", len(added), len(removed), len(registry))

        return {
            "added": sorted(added),
            "removed": sorted(removed),
            "total": len(registry),
        }
