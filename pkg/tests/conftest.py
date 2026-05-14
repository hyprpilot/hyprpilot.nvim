"""Pytest fixtures for tests that need a real Neovim attached.

The integration tests in this package spawn a headless `nvim --embed
--clean` via pynvim's child-process attach, then put the repo-root
`lua/` on the runtime path so `require("hyprpilot.*")` resolves
against the working tree (no install dance, no LSP, no plugins
beyond hyprpilot itself).

Pure unit tests (the CLI option parser, `NvimWrapper` construction
guards) don't need this fixture and won't pull it in.
"""

from __future__ import annotations

import shutil
from collections.abc import Generator
from pathlib import Path

import pynvim
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


@pytest.fixture
def nvim() -> Generator[pynvim.Nvim]:
    """Spawn headless nvim --embed --clean with the repo's `lua/`
    on `runtimepath`. Skipped when `nvim` isn't on PATH (CI without
    the binary, dev container without Neovim installed).
    """
    if shutil.which("nvim") is None:
        pytest.skip("nvim not on PATH")

    # `--embed` swaps stdio to msgpack-RPC; `--headless` keeps the
    # UI off; `--clean` skips user config so the test doesn't pick up
    # the captain's plugins / shada / etc.
    handle = pynvim.attach(
        "child",
        argv=["nvim", "--embed", "--headless", "--clean", "-n"],
    )
    try:
        # Make `require("hyprpilot.*")` resolve against the working
        # tree. `prepend` so a stray system-installed copy can't
        # override us.
        handle.exec_lua(
            "vim.opt.rtp:prepend(...)",
            [str(REPO_ROOT)],
        )
        yield handle
    finally:
        handle.close()
