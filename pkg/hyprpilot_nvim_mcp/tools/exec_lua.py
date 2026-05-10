"""`exec_lua` MCP tool — gated escape hatch for arbitrary Lua execution.

DISABLED by default. Enable via `--enable-exec-lua` /
`HYPRPILOT_NVIM_MCP_ENABLE_EXEC_LUA=1`. When enabled, the agent can
execute any Lua against the captain's nvim — same threat model as
giving the agent a shell.
"""

from __future__ import annotations

from typing import Any

from fastmcp import FastMCP

from ..nvim import NvimWrapper


def register(mcp: FastMCP, nvim: NvimWrapper) -> None:
    @mcp.tool(
        name="exec_lua",
        description=(
            "Execute arbitrary Lua against the running Neovim. "
            "DANGEROUS: this is a remote-code-execution surface — only enabled "
            "when --enable-exec-lua / HYPRPILOT_NVIM_MCP_ENABLE_EXEC_LUA=1 is set."
        ),
    )
    def exec_lua(code: str, args: list[Any] | None = None) -> Any:
        """Run `code` against nvim.

        :param code: Lua source. The last expression is the return value.
        :param args: arguments accessible inside Lua via the `...` varargs.
        """
        return nvim.exec_lua(code, args or [])
