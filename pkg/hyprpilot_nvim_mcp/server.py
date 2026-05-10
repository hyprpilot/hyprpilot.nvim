"""FastMCP server instance. Tools register against this at startup
(see ``cli.Server.serve``)."""

from __future__ import annotations

from fastmcp import FastMCP

from . import __version__

mcp: FastMCP = FastMCP(name="hyprpilot-nvim-mcp", version=__version__)
