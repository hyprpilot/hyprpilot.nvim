"""Smoke tests for the bootstrap surface."""

from __future__ import annotations

from click.testing import CliRunner

from hyprpilot_nvim_mcp import __version__
from hyprpilot_nvim_mcp.cli import main
from hyprpilot_nvim_mcp.config import Config
from hyprpilot_nvim_mcp.server import ping


def test_version_is_string() -> None:
    assert isinstance(__version__, str)
    assert __version__


def test_ping_returns_pong() -> None:
    assert ping() == "pong"


def test_config_from_env_defaults(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    monkeypatch.delenv("NVIM_LISTEN_ADDRESS", raising=False)
    monkeypatch.delenv("HYPRPILOT_NVIM_MCP_ENABLE_EXEC_LUA", raising=False)

    cfg = Config.from_env()

    assert cfg.nvim_listen_address is None
    assert cfg.enable_exec_lua is False


def test_config_enable_exec_lua_truthy(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    monkeypatch.setenv("HYPRPILOT_NVIM_MCP_ENABLE_EXEC_LUA", "1")

    assert Config.from_env().enable_exec_lua is True


def test_cli_help() -> None:
    result = CliRunner().invoke(main, ["--help"])

    assert result.exit_code == 0
    assert "--log-level" in result.output
    assert "Run the hyprpilot-nvim-mcp server" in result.output


def test_cli_version() -> None:
    result = CliRunner().invoke(main, ["--version"])

    assert result.exit_code == 0
    assert __version__ in result.output
