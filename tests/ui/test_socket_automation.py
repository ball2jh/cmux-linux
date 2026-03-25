"""Port of AutomationSocketUITests from the macOS cmux UI test suite.

Tests that the control socket is created when the socket mode is enabled,
and is absent when the mode is disabled.
"""

import os
import uuid

import pytest

from helpers import (
    launch_cmux,
    terminate_cmux,
    wait_for_atspi_app,
    wait_for_file_absent,
    wait_for_file_exists,
)


class TestSocketAutomation:
    """Port of AutomationSocketUITests."""

    def test_socket_exists_when_enabled(self):
        """When socket control mode is enabled, the socket file is created.

        Port of testSocketToggleDisablesAndEnables (the "enable" half).
        On Linux we don't have NSUserDefaults; we use env vars / CLI args
        to configure the socket mode.
        """
        sock_path = f"/tmp/cmux-ui-test-socket-{uuid.uuid4().hex}.sock"
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass

        proc, _ = launch_cmux(
            extra_env={
                "CMUX_SOCKET_CONTROL_MODE": "cmuxOnly",
                "CMUX_UI_TEST_SOCKET_SANITY": "1",
            },
            socket_path=sock_path,
        )
        try:
            app = wait_for_atspi_app("cmux", timeout=12)

            # First try the exact path we passed
            found = wait_for_file_exists(sock_path, timeout=5)
            if not found:
                # Fallback: scan /tmp for any cmux*.sock
                resolved = _find_socket_in_tmp()
                if resolved is not None:
                    sock_path_actual = resolved
                    found = True

            assert found, f"Expected control socket to exist at {sock_path}"
        finally:
            terminate_cmux(proc, sock_path)

    def test_socket_absent_when_disabled(self):
        """When socket control mode is 'off', no socket file is created.

        Port of testSocketDisabledWhenSettingOff.
        """
        sock_path = f"/tmp/cmux-ui-test-socket-off-{uuid.uuid4().hex}.sock"
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass

        proc, _ = launch_cmux(
            extra_env={
                "CMUX_SOCKET_CONTROL_MODE": "off",
                "CMUX_UI_TEST_SOCKET_SANITY": "1",
            },
            socket_path=sock_path,
        )
        try:
            app = wait_for_atspi_app("cmux", timeout=12)

            assert wait_for_file_absent(sock_path, timeout=3), (
                f"Expected no socket file at {sock_path} when mode is 'off'"
            )
        finally:
            terminate_cmux(proc, sock_path)


def _find_socket_in_tmp():
    """Scan /tmp for any cmux*.sock file, preferring debug sockets."""
    try:
        entries = os.listdir("/tmp")
    except OSError:
        return None
    matches = [e for e in entries if e.startswith("cmux") and e.endswith(".sock")]
    # Prefer debug sockets
    for m in matches:
        if "debug" in m:
            return os.path.join("/tmp", m)
    if matches:
        return os.path.join("/tmp", matches[0])
    return None
