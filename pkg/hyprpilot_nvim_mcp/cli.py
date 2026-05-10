"""Entry point for ``uvx hyprpilot-nvim-mcp``.

Class-based click CLI: ``Server`` owns the runtime state (log config,
parsed options, FastMCP instance handle, nvim wrapper, dispatcher
registry), and ``Server.cli`` is the click group dispatched from the
``hyprpilot-nvim-mcp`` console script.
"""

from __future__ import annotations

import logging
from typing import Any

import click

from . import __version__, log
from .dispatcher import register_dynamic
from .nvim import NvimUnavailableError, NvimWrapper
from .server import mcp
from .tools import exec_lua as exec_lua_tool
from .tools import healthcheck as healthcheck_tool
from .tools import reload as reload_tool

# Standard logging level names, sourced from Python's logging module
# itself (skipping NOTSET == 0 and the WARN alias).
LOG_LEVELS: list[str] = sorted(
    name for name, value in logging._nameToLevel.items() if value > 0 and name != "WARN"
)


class Server:
    """Runtime container for the MCP server.

    Constructed once by the click group from parsed options + envvars; each
    subcommand receives this instance via ``click.pass_obj``.
    """

    def __init__(
        self,
        *,
        log_level: str,
        nvim_listen_address: str | None,
        enable_exec_lua: bool,
    ) -> None:
        self.log_level = log_level
        self.nvim_listen_address = nvim_listen_address
        self.enable_exec_lua = enable_exec_lua

        log.configure(log_level)
        self._log = log.get("server")

    def serve(self) -> None:
        """Run the FastMCP server on stdio. Blocks until the daemon disconnects."""
        self._log.info("starting hyprpilot-nvim-mcp v%s", __version__)
        self._log.debug(
            "nvim_listen_address=%s enable_exec_lua=%s",
            self.nvim_listen_address,
            self.enable_exec_lua,
        )

        nvim = NvimWrapper(self.nvim_listen_address)

        registry: dict[str, Any] = register_dynamic(mcp, nvim)
        healthcheck_tool.register(mcp, nvim, lambda: len(registry))
        reload_tool.register(mcp, nvim, registry)

        if self.enable_exec_lua:
            self._log.warning("exec_lua tool ENABLED — RCE surface is open")
            exec_lua_tool.register(mcp, nvim)

        mcp.run(transport="stdio")

    # ── CLI ───────────────────────────────────────────────────────

    @click.group(
        context_settings={"help_option_names": ["-h", "--help"]},
        invoke_without_command=True,
    )
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
    @click.option(
        "--nvim-listen-address",
        type=click.STRING,
        default=None,
        envvar="NVIM_LISTEN_ADDRESS",
        show_envvar=True,
        help="Path to the running Neovim's listen socket.",
    )
    @click.option(
        "--enable-exec-lua/--no-enable-exec-lua",
        default=False,
        envvar="HYPRPILOT_NVIM_MCP_ENABLE_EXEC_LUA",
        show_envvar=True,
        help="Enable the exec_lua tool (RCE surface — leave off unless you know why).",
    )
    @click.pass_context
    def cli(
        ctx: click.Context,
        log_level: str,
        nvim_listen_address: str | None,
        enable_exec_lua: bool,
    ) -> None:
        """hyprpilot-nvim-mcp — MCP bridge from Neovim editor state into the agent."""
        ctx.obj = Server(
            log_level=log_level,
            nvim_listen_address=nvim_listen_address,
            enable_exec_lua=enable_exec_lua,
        )

        if ctx.invoked_subcommand is None:
            ctx.invoke(Server.cmd_run)

    @cli.command("run")
    @click.pass_obj
    def cmd_run(server: Server) -> None:
        """Run the MCP server on stdio (default when no subcommand is given)."""
        try:
            server.serve()
        except NvimUnavailableError as exc:
            raise click.ClickException(str(exc)) from exc


def main() -> None:
    """Backwards-compatible entry shim for ``python -m hyprpilot_nvim_mcp.cli``."""
    Server.cli()


if __name__ == "__main__":
    main()
