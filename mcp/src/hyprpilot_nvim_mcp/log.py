"""Stderr-only structured logging via rich.

stdout is reserved for the MCP wire protocol — never log there. The rich
``Console`` is bound to stderr at module import; ``configure()`` wires the
``RichHandler`` and exception hook so tracebacks land on stderr too.
"""

from __future__ import annotations

import logging

from rich.console import Console
from rich.logging import RichHandler
from rich.traceback import install as install_rich_traceback

_LOGGER_NAME = "hyprpilot_nvim_mcp"

console: Console = Console(stderr=True)


def configure(level: str | int = "INFO") -> None:
    """Configure stderr logging once at startup. Safe to call repeatedly."""
    root = logging.getLogger(_LOGGER_NAME)

    if root.handlers:
        root.setLevel(level)

        return

    handler = RichHandler(
        console=console,
        show_time=True,
        show_level=True,
        show_path=False,
        markup=False,
        rich_tracebacks=True,
    )
    handler.setFormatter(logging.Formatter("%(message)s"))
    root.addHandler(handler)
    root.setLevel(level)
    root.propagate = False

    install_rich_traceback(console=console, show_locals=False)


def get(name: str | None = None) -> logging.Logger:
    """Return a logger under the package namespace."""
    if name is None:
        return logging.getLogger(_LOGGER_NAME)

    return logging.getLogger(f"{_LOGGER_NAME}.{name}")
