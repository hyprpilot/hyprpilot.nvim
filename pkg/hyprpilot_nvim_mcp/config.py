"""Environment-variable configuration."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    """Runtime configuration parsed from environment variables.

    ``log_level`` is not part of this — the CLI (click) owns it via
    ``--log-level`` / ``HYPRPILOT_NVIM_MCP_LOG_LEVEL``.
    """

    nvim_listen_address: str | None
    enable_exec_lua: bool

    @classmethod
    def from_env(cls) -> Config:
        """Build a Config from the process environment."""
        return cls(
            nvim_listen_address=os.environ.get("NVIM_LISTEN_ADDRESS"),
            enable_exec_lua=_truthy(os.environ.get("HYPRPILOT_NVIM_MCP_ENABLE_EXEC_LUA", "0")),
        )


def _truthy(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}
