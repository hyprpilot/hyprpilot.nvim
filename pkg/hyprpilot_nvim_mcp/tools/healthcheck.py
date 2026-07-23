"""`healthcheck` MCP tool — diagnostic snapshot for /diag consumers."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from fastmcp import FastMCP

from .. import __version__
from ..nvim import NvimUnavailableError, NvimWrapper


def register(mcp: FastMCP, nvim: NvimWrapper, registered_count_fn: Callable[[], int]) -> None:
    """Wire the `healthcheck` tool. `registered_count_fn` returns the
    current count of dynamically-registered Lua tools (closes over
    server state)."""

    @mcp.tool(name="healthcheck", description="Return a diagnostic snapshot of the MCP bridge.")
    def healthcheck() -> dict[str, Any]:
        """Return MCP server + nvim connection state."""
        nvim_version: str | None = None
        connected = nvim.is_connected()

        try:
            nvim_version = str(nvim.exec_lua("return tostring(vim.version())"))
            connected = True
        except NvimUnavailableError:
            connected = False

        return {
            "bridge_version": __version__,
            "socket": nvim.listen_address,
            "connected": connected,
            "nvim_version": nvim_version,
            "registered_tool_count": registered_count_fn(),
        }
