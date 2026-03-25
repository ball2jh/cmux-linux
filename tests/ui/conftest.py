"""Pytest fixtures for cmux Dogtail UI tests."""

import sys
from pathlib import Path

# Ensure tests/ui/ is on the import path so `from helpers import ...` works.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import os
import signal
import subprocess
import time
import uuid

import pytest

# ---------------------------------------------------------------------------
# Dogtail configuration — must happen before any dogtail import that caches it
# ---------------------------------------------------------------------------
from dogtail.config import config as dogtail_config

dogtail_config.searchShowingOnly = False
dogtail_config.typingDelay = 0.03

from dogtail.tree import root  # noqa: E402 — must import after config


# ---------------------------------------------------------------------------
# Helpers local to conftest
# ---------------------------------------------------------------------------

_PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_BINARY_PATH = os.path.join(_PROJECT_ROOT, "zig-out", "bin", "cmux")


def _build_cmux() -> None:
    """Build cmux with -Dcmux=true unless CMUX_SKIP_BUILD is set or binary exists."""
    if os.environ.get("CMUX_SKIP_BUILD") == "1":
        if not os.path.isfile(_BINARY_PATH):
            raise FileNotFoundError(f"CMUX_SKIP_BUILD=1 but binary not found: {_BINARY_PATH}")
        return
    if os.path.isfile(_BINARY_PATH) and os.environ.get("CMUX_FORCE_BUILD") != "1":
        # Use existing binary by default — set CMUX_FORCE_BUILD=1 to rebuild
        return
    subprocess.check_call(
        ["zig", "build", "-Dcmux=true", "-Dversion-string=0.1.0-dev"],
        cwd=_PROJECT_ROOT,
        timeout=300,
    )


def _wait_for_atspi_app(app_name: str, timeout: float = 15.0):
    """Poll the AT-SPI tree until the application node appears."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            node = root.application(app_name)
            if node is not None:
                return node
        except Exception:
            pass
        time.sleep(0.3)
    raise RuntimeError(
        f"AT-SPI application '{app_name}' did not appear within {timeout}s"
    )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def cmux_app():
    """Build cmux, launch it with CMUX_UI_TEST=1, yield the AT-SPI app node.

    The process is terminated on teardown.
    """
    _build_cmux()

    socket_path = f"/tmp/cmux-ui-test-{uuid.uuid4().hex}.sock"
    env = os.environ.copy()
    env["CMUX_UI_TEST"] = "1"
    env["CMUX_SOCKET_PATH"] = socket_path
    # Enable accessibility
    env["GTK_A11Y"] = "atspi"  # GTK4 accessibility backend
    env["DBUS_SESSION_BUS_ADDRESS"] = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")

    proc = subprocess.Popen(
        [_BINARY_PATH],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    try:
        app_node = _wait_for_atspi_app("cmux")
        # Stash the socket path and process on the node for fixture consumers
        app_node._cmux_socket_path = socket_path
        app_node._cmux_process = proc
        yield app_node
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
        # Clean up socket file
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass


@pytest.fixture
def window(cmux_app):
    """Return the main window (frame) node from the cmux application."""
    from dogtail.predicate import GenericPredicate

    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        try:
            win = cmux_app.findChild(
                GenericPredicate(roleName="frame"), retry=False
            )
            if win is not None:
                return win
        except Exception:
            pass
        time.sleep(0.3)
    raise RuntimeError("Could not find a frame (window) in the cmux application")


@pytest.fixture
def socket_path(cmux_app):
    """Return the Unix socket path for the running cmux instance."""
    return cmux_app._cmux_socket_path
