"""Stderr-only structured logging.

stdout is reserved for the MCP wire protocol — never log there.
"""

from __future__ import annotations

import logging
import sys

_LOGGER_NAME = "hyprpilot_nvim_mcp"
_FORMAT = "%(asctime)s %(levelname)-5s %(name)s %(message)s"


def configure(level: str | int = "INFO") -> None:
    """Configure stderr logging once at startup."""
    root = logging.getLogger(_LOGGER_NAME)

    if root.handlers:
        return

    handler = logging.StreamHandler(stream=sys.stderr)
    handler.setFormatter(logging.Formatter(_FORMAT))
    root.addHandler(handler)
    root.setLevel(level)
    root.propagate = False


def get(name: str | None = None) -> logging.Logger:
    """Return a logger under the package namespace."""
    if name is None:
        return logging.getLogger(_LOGGER_NAME)

    return logging.getLogger(f"{_LOGGER_NAME}.{name}")
