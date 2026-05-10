"""Smoke tests for the bootstrap surface."""

from __future__ import annotations

from typing import Any

import pytest
from click.testing import CliRunner

from hyprpilot_nvim_mcp import __version__
from hyprpilot_nvim_mcp.cli import Server
from hyprpilot_nvim_mcp.nvim import NvimUnavailableError


def test_version_is_string() -> None:
    assert isinstance(__version__, str)
    assert __version__


def test_cli_help_advertises_options_and_envvars() -> None:
    result = CliRunner().invoke(Server.cli, ["--help"])

    assert result.exit_code == 0
    assert "MCP bridge from Neovim editor state" in result.output
    assert "--log-level" in result.output
    assert "HYPRPILOT_NVIM_MCP_LOG_LEVEL" in result.output
    assert "--nvim-listen-address" in result.output
    assert "NVIM_LISTEN_ADDRESS" in result.output


def test_cli_lists_run_subcommand() -> None:
    result = CliRunner().invoke(Server.cli, ["--help"])

    assert result.exit_code == 0
    assert "run" in result.output


def test_cli_version() -> None:
    result = CliRunner().invoke(Server.cli, ["--version"])

    assert result.exit_code == 0
    assert __version__ in result.output


def test_cli_run_subcommand_calls_serve(monkeypatch: pytest.MonkeyPatch) -> None:
    """The run subcommand instantiates Server and dispatches serve()."""
    called: dict[str, Any] = {}

    def _spy(self: Server) -> None:
        called["log_level"] = self.log_level
        called["nvim_listen_address"] = self.nvim_listen_address

    monkeypatch.setattr(Server, "serve", _spy)

    result = CliRunner().invoke(
        Server.cli,
        ["--log-level", "DEBUG", "run"],
        catch_exceptions=False,
    )

    assert result.exit_code == 0
    assert called["log_level"] == "DEBUG"
    assert called["nvim_listen_address"] is None


def test_cli_defaults_to_run_when_no_subcommand(monkeypatch: pytest.MonkeyPatch) -> None:
    """`uvx hyprpilot-nvim-mcp` (no args) still runs the server."""
    monkeypatch.setattr(Server, "serve", lambda self: None)

    result = CliRunner().invoke(Server.cli, [], catch_exceptions=False)

    assert result.exit_code == 0


def test_cli_resolves_options_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """click resolves env vars natively; no Config.from_env() layer needed."""
    monkeypatch.setenv("HYPRPILOT_NVIM_MCP_LOG_LEVEL", "debug")
    monkeypatch.setenv("NVIM_LISTEN_ADDRESS", "/tmp/nvim.sock")

    captured: dict[str, Any] = {}

    def _spy(self: Server) -> None:
        captured["log_level"] = self.log_level
        captured["nvim_listen_address"] = self.nvim_listen_address

    monkeypatch.setattr(Server, "serve", _spy)

    result = CliRunner().invoke(Server.cli, ["run"], catch_exceptions=False)

    assert result.exit_code == 0
    assert captured == {
        # click normalizes Choice values to the canonical case.
        "log_level": "DEBUG",
        "nvim_listen_address": "/tmp/nvim.sock",
    }


def test_cli_run_without_nvim_address_surfaces_clean_error() -> None:
    """Missing NVIM_LISTEN_ADDRESS should fail fast with a click error,
    not a raw exception."""
    result = CliRunner(env={"NVIM_LISTEN_ADDRESS": ""}).invoke(Server.cli, ["run"])

    assert result.exit_code != 0
    assert "NVIM_LISTEN_ADDRESS" in (result.output or "")


def test_nvim_wrapper_rejects_missing_address() -> None:
    """NvimWrapper construction with no address must raise immediately."""
    from hyprpilot_nvim_mcp.nvim import NvimWrapper

    with pytest.raises(NvimUnavailableError, match="NVIM_LISTEN_ADDRESS"):
        NvimWrapper(None)

    with pytest.raises(NvimUnavailableError, match="NVIM_LISTEN_ADDRESS"):
        NvimWrapper("")
