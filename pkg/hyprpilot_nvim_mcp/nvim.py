"""pynvim attach + thread-safe accessor with reconnect-on-disconnect.

`pynvim` is not thread-safe by default; FastMCP's tool dispatch can run
on multiple threads under load. Every accessor serializes through a
lock, and broken-pipe errors clear the cached handle so the next call
re-attaches transparently.
"""

from __future__ import annotations

import contextlib
import threading
from typing import Any

import pynvim

from . import log


class NvimUnavailableError(RuntimeError):
    """Raised when the bridge cannot reach the configured nvim socket."""


class NvimWrapper:
    """Lazy attach + thread-safe access. Reconnects on broken pipes."""

    def __init__(self, listen_address: str | None) -> None:
        if not listen_address:
            raise NvimUnavailableError(
                "NVIM_LISTEN_ADDRESS is unset. Pass --nvim-listen-address or set the env var."
            )

        self._listen_address = listen_address
        self._lock = threading.Lock()
        self._nvim: pynvim.Nvim | None = None
        self._log = log.get("nvim")

    @property
    def listen_address(self) -> str:
        return self._listen_address

    def _attach(self) -> pynvim.Nvim:
        if self._nvim is not None:
            return self._nvim

        self._log.info("attaching to nvim at %s", self._listen_address)

        try:
            self._nvim = pynvim.attach("socket", path=self._listen_address)
        except Exception as exc:
            raise NvimUnavailableError(
                f"could not attach to nvim at {self._listen_address}: {exc}"
            ) from exc

        return self._nvim

    def _reset_on_disconnect(self, exc: Exception) -> None:
        self._log.warning("nvim disconnected, will retry on next call: %s", exc)

        self._nvim = None

    def exec_lua(self, code: str, args: list[Any] | None = None) -> Any:
        """Run `code` with `args` exposed as the Lua vararg `...`.

        pynvim's `Nvim.exec_lua(code, *args)` signature expects each
        Lua vararg as a separate Python positional. Passing the
        whole list as a single arg (`exec_lua(code, args)`) packs
        the list itself into the Lua vararg — `...` becomes one
        table value, not N values, so a dispatcher like
        `return require('mod').call(...)` ends up calling
        `call({tool_name, args_dict})` instead of
        `call(tool_name, args_dict)`. The splat below restores the
        intended one-vararg-per-arg shape.
        """
        with self._lock:
            try:
                return self._attach().exec_lua(code, *(args or []))
            except (BrokenPipeError, EOFError, OSError) as exc:
                self._reset_on_disconnect(exc)

                raise NvimUnavailableError(f"nvim disconnected: {exc}") from exc

    def call(self, name: str, *args: Any) -> Any:
        """Invoke a Vimscript function by name."""
        with self._lock:
            try:
                return self._attach().call(name, *args)
            except (BrokenPipeError, EOFError, OSError) as exc:
                self._reset_on_disconnect(exc)

                raise NvimUnavailableError(f"nvim disconnected: {exc}") from exc

    def is_connected(self) -> bool:
        return self._nvim is not None

    def disconnect(self) -> None:
        """Close the underlying connection. Mostly for tests."""
        with self._lock:
            if self._nvim is not None:
                with contextlib.suppress(Exception):
                    self._nvim.close()

                self._nvim = None
