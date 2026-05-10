"""FastMCP server instance and tool registration."""

from __future__ import annotations

from fastmcp import FastMCP

from . import __version__

mcp: FastMCP = FastMCP(name="hyprpilot-nvim-mcp", version=__version__)


@mcp.tool()
def ping() -> str:
    """Liveness check. Returns ``"pong"``."""
    return "pong"
