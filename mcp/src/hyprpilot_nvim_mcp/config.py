"""Environment-variable configuration."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    """Runtime configuration parsed from environment variables."""

    nvim_listen_address: str | None
    log_level: str
    enable_exec_lua: bool

    @classmethod
    def from_env(cls) -> Config:
        """Build a Config from the process environment."""
        return cls(
            nvim_listen_address=os.environ.get("NVIM_LISTEN_ADDRESS"),
            log_level=os.environ.get("HYPRPILOT_NVIM_MCP_LOG_LEVEL", "INFO"),
            enable_exec_lua=_truthy(os.environ.get("HYPRPILOT_NVIM_MCP_ENABLE_EXEC_LUA", "0")),
        )


def _truthy(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}
