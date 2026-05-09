"""Entry point for ``uvx hyprpilot-nvim-mcp``."""

from __future__ import annotations

from . import log
from .config import Config
from .server import mcp


def main() -> None:
    """Boot the MCP server on stdio transport."""
    cfg = Config.from_env()
    log.configure(cfg.log_level)
    logger = log.get("cli")
    logger.info("starting hyprpilot-nvim-mcp")

    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
