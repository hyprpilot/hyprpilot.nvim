"""Entry point for ``uvx hyprpilot-nvim-mcp``."""

from __future__ import annotations

import click

from . import __version__, log
from .server import mcp

LOG_LEVELS = ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"]


@click.command(context_settings={"help_option_names": ["-h", "--help"]})
@click.version_option(__version__, prog_name="hyprpilot-nvim-mcp")
@click.option(
    "--log-level",
    type=click.Choice(LOG_LEVELS, case_sensitive=False),
    default="INFO",
    show_default=True,
    envvar="HYPRPILOT_NVIM_MCP_LOG_LEVEL",
    show_envvar=True,
    help="Stderr log level.",
)
def main(log_level: str) -> None:
    """Run the hyprpilot-nvim-mcp server on stdio."""
    log.configure(log_level.upper())
    log.get("cli").info("starting hyprpilot-nvim-mcp v%s", __version__)

    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
