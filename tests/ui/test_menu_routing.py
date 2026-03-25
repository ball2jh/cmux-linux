"""Dogtail UI tests for menu key equivalent routing.

Ported from:
  cmux-macos/cmuxUITests/MenuKeyEquivalentRoutingUITests.swift

Tests verify that global shortcuts (Ctrl+Shift+N, Ctrl+Shift+W,
Ctrl+Shift+Alt+W) reach the application menu actions even when the
WebKitGTK view has keyboard focus — i.e. WebKit does not swallow them.

On Linux the Mac shortcuts map as follows:
    Cmd+N       → Ctrl+Shift+N        (new workspace / add tab)
    Cmd+W       → Ctrl+Shift+W        (close focused panel)
    Cmd+Shift+W → Ctrl+Shift+Alt+W    (close workspace)
    Cmd+Shift+[ → Ctrl+Shift+bracketleft  (prev surface)
    Cmd+Shift+] → Ctrl+Shift+bracketright (next surface)
    Cmd+L       → Ctrl+l              (focus address bar)

The test harness writes invocation counters to a JSON data file so the
test can verify the action actually fired (not just that a key was sent).
"""

import json
import os
import time
import uuid

import pytest

from helpers import (
    load_json,
    poll_socket,
    send_shortcut,
    wait_for_json,
    wait_for_widget,
    wait_for_widget_gone,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _wait_for_data_keys(path, keys, timeout=10.0):
    """Block until the JSON at *path* contains all *keys*."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = load_json(path)
        if data is not None and all(k in data for k in keys):
            return data
        time.sleep(0.25)
    return None


def _wait_for_data_match(path, predicate, timeout=5.0):
    """Block until predicate(data_dict) is True for the JSON file at *path*."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = load_json(path)
        if data is not None:
            try:
                if predicate(data):
                    return True
            except (KeyError, TypeError, ValueError):
                pass
        time.sleep(0.25)
    return False


def _wait_for_keyequiv_int(keyequiv_path, key, at_least, timeout=5.0):
    """Block until keyequiv_path JSON has int(data[key]) >= at_least."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = load_json(keyequiv_path)
        if data is not None:
            try:
                if int(data.get(key, "0")) >= at_least:
                    return True
            except (ValueError, TypeError):
                pass
        time.sleep(0.25)
    return False


def _refocus_webview(window, goto_split_path):
    """Refocus the WebKitGTK view via Ctrl+L then Escape.

    Mirrors Mac ``refocusWebView`` helper.
    """
    from dogtail.rawinput import pressKey

    # Ctrl+L focuses omnibar (WebKit no longer focused).
    send_shortcut("Ctrl", "l")
    assert _wait_for_data_match(
        goto_split_path,
        lambda d: d.get("webViewFocusedAfterAddressBarFocus") == "false",
        timeout=5.0,
    ), "Ctrl+L should focus omnibar (WebKit not first responder)"

    # Escape returns focus to WebKit.  Send twice for Chrome-like two-stage.
    pressKey("Escape")
    if not _wait_for_data_match(
        goto_split_path,
        lambda d: d.get("webViewFocusedAfterAddressBarExit") == "true",
        timeout=2.0,
    ):
        pressKey("Escape")
    assert _wait_for_data_match(
        goto_split_path,
        lambda d: d.get("webViewFocusedAfterAddressBarExit") == "true",
        timeout=5.0,
    ), "Escape should return focus to WebKit"


def _prev_surface():
    """Ctrl+Shift+BracketLeft — previous surface (tab switch)."""
    send_shortcut("Ctrl", "Shift", "bracketleft")


def _next_surface():
    """Ctrl+Shift+BracketRight — next surface (tab switch)."""
    send_shortcut("Ctrl", "Shift", "bracketright")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def goto_split_path(tmp_path):
    return str(tmp_path / f"goto-split-{uuid.uuid4().hex}.json")


@pytest.fixture
def keyequiv_path(tmp_path):
    return str(tmp_path / f"keyequiv-{uuid.uuid4().hex}.json")


# ---------------------------------------------------------------------------
# Tests — ported from MenuKeyEquivalentRoutingUITests.swift
# ---------------------------------------------------------------------------


class TestNewWorkspaceWhenWebViewFocused:
    """Mac: testCmdNWorksWhenWebViewFocusedAfterTabSwitch"""

    def test_ctrl_shift_n_creates_tab(self, window, socket_path,
                                      goto_split_path, keyequiv_path):
        """Ctrl+Shift+N should reach the app and create a new tab/workspace
        even when the WebKitGTK view has keyboard focus after a tab switch."""
        setup = _wait_for_data_keys(
            goto_split_path,
            ["browserPanelId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None, "goto_split setup data not written"
        assert setup.get("webViewFocused") == "true"

        # Tab switch away and back (repro setup).
        _prev_surface()
        _next_surface()

        # Re-focus WebKit.
        _refocus_webview(window, goto_split_path)

        baseline = 0
        data = load_json(keyequiv_path)
        if data:
            try:
                baseline = int(data.get("addTabInvocations", "0"))
            except (ValueError, TypeError):
                pass

        send_shortcut("Ctrl", "Shift", "n")

        assert _wait_for_keyequiv_int(
            keyequiv_path, "addTabInvocations", baseline + 1, timeout=5.0
        ), ("Ctrl+Shift+N should create a new tab even when WebKitGTK "
            "is focused")


class TestCloseWhenWebViewFocused:
    """Mac: testCmdWWorksWhenWebViewFocusedAfterTabSwitch"""

    def test_ctrl_shift_w_closes_panel(self, window, socket_path,
                                       goto_split_path, keyequiv_path):
        """Ctrl+Shift+W should close the focused panel even when the
        WebKitGTK view has keyboard focus after a tab switch."""
        setup = _wait_for_data_keys(
            goto_split_path,
            ["browserPanelId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None
        assert setup.get("webViewFocused") == "true"

        _prev_surface()
        _next_surface()
        _refocus_webview(window, goto_split_path)

        baseline = 0
        data = load_json(keyequiv_path)
        if data:
            try:
                baseline = int(data.get("closePanelInvocations", "0"))
            except (ValueError, TypeError):
                pass

        send_shortcut("Ctrl", "Shift", "w")

        assert _wait_for_keyequiv_int(
            keyequiv_path, "closePanelInvocations", baseline + 1, timeout=5.0
        ), ("Ctrl+Shift+W should close the focused tab even when WebKitGTK "
            "is focused")


class TestCloseWorkspaceWhenWebViewFocused:
    """Mac: testCmdShiftWWorksWhenWebViewFocusedAfterTabSwitch"""

    def test_ctrl_shift_alt_w_closes_workspace(self, window, socket_path,
                                               goto_split_path,
                                               keyequiv_path):
        """Ctrl+Shift+Alt+W should close the current workspace even when the
        WebKitGTK view has keyboard focus after a tab switch."""
        setup = _wait_for_data_keys(
            goto_split_path,
            ["browserPanelId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None
        assert setup.get("webViewFocused") == "true"

        _prev_surface()
        _next_surface()
        _refocus_webview(window, goto_split_path)

        baseline = 0
        data = load_json(keyequiv_path)
        if data:
            try:
                baseline = int(data.get("closeTabInvocations", "0"))
            except (ValueError, TypeError):
                pass

        send_shortcut("Ctrl", "Shift", "Alt", "w")

        assert _wait_for_keyequiv_int(
            keyequiv_path, "closeTabInvocations", baseline + 1, timeout=6.0
        ), ("Ctrl+Shift+Alt+W should close the workspace even when "
            "WebKitGTK is focused")


class TestNewWorkspaceWithoutTabSwitch:
    """Variant: Ctrl+Shift+N without prior tab switch — baseline routing."""

    def test_ctrl_shift_n_baseline(self, window, socket_path,
                                   goto_split_path, keyequiv_path):
        """Ctrl+Shift+N should work even without a prior tab switch cycle."""
        setup = _wait_for_data_keys(
            goto_split_path,
            ["browserPanelId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None
        assert setup.get("webViewFocused") == "true"

        baseline = 0
        data = load_json(keyequiv_path)
        if data:
            try:
                baseline = int(data.get("addTabInvocations", "0"))
            except (ValueError, TypeError):
                pass

        send_shortcut("Ctrl", "Shift", "n")

        assert _wait_for_keyequiv_int(
            keyequiv_path, "addTabInvocations", baseline + 1, timeout=5.0
        ), "Ctrl+Shift+N should create a tab without prior tab switch"


class TestCloseWithoutTabSwitch:
    """Variant: Ctrl+Shift+W without prior tab switch — baseline routing."""

    def test_ctrl_shift_w_baseline(self, window, socket_path,
                                   goto_split_path, keyequiv_path):
        """Ctrl+Shift+W should close the panel without a prior tab switch."""
        setup = _wait_for_data_keys(
            goto_split_path,
            ["browserPanelId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None
        assert setup.get("webViewFocused") == "true"

        baseline = 0
        data = load_json(keyequiv_path)
        if data:
            try:
                baseline = int(data.get("closePanelInvocations", "0"))
            except (ValueError, TypeError):
                pass

        send_shortcut("Ctrl", "Shift", "w")

        assert _wait_for_keyequiv_int(
            keyequiv_path, "closePanelInvocations", baseline + 1, timeout=5.0
        ), "Ctrl+Shift+W should close panel without prior tab switch"


class TestCloseWorkspaceWithoutTabSwitch:
    """Variant: Ctrl+Shift+Alt+W without prior tab switch — baseline."""

    def test_ctrl_shift_alt_w_baseline(self, window, socket_path,
                                       goto_split_path, keyequiv_path):
        """Ctrl+Shift+Alt+W should close workspace without prior tab switch."""
        setup = _wait_for_data_keys(
            goto_split_path,
            ["browserPanelId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None
        assert setup.get("webViewFocused") == "true"

        baseline = 0
        data = load_json(keyequiv_path)
        if data:
            try:
                baseline = int(data.get("closeTabInvocations", "0"))
            except (ValueError, TypeError):
                pass

        send_shortcut("Ctrl", "Shift", "Alt", "w")

        assert _wait_for_keyequiv_int(
            keyequiv_path, "closeTabInvocations", baseline + 1, timeout=6.0
        ), "Ctrl+Shift+Alt+W should close workspace without prior tab switch"


class TestNewAfterMultipleTabSwitches:
    """Variant: multiple tab switches before Ctrl+Shift+N."""

    def test_ctrl_shift_n_after_double_switch(self, window, socket_path,
                                              goto_split_path, keyequiv_path):
        """Ctrl+Shift+N should work after switching tabs twice."""
        setup = _wait_for_data_keys(
            goto_split_path,
            ["browserPanelId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None
        assert setup.get("webViewFocused") == "true"

        # Switch away and back twice.
        _prev_surface()
        _next_surface()
        _prev_surface()
        _next_surface()

        _refocus_webview(window, goto_split_path)

        baseline = 0
        data = load_json(keyequiv_path)
        if data:
            try:
                baseline = int(data.get("addTabInvocations", "0"))
            except (ValueError, TypeError):
                pass

        send_shortcut("Ctrl", "Shift", "n")

        assert _wait_for_keyequiv_int(
            keyequiv_path, "addTabInvocations", baseline + 1, timeout=5.0
        ), "Ctrl+Shift+N should work after multiple tab switches"


class TestCloseAfterMultipleTabSwitches:
    """Variant: multiple tab switches before Ctrl+Shift+W."""

    def test_ctrl_shift_w_after_double_switch(self, window, socket_path,
                                              goto_split_path, keyequiv_path):
        """Ctrl+Shift+W should work after switching tabs twice."""
        setup = _wait_for_data_keys(
            goto_split_path,
            ["browserPanelId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None
        assert setup.get("webViewFocused") == "true"

        _prev_surface()
        _next_surface()
        _prev_surface()
        _next_surface()

        _refocus_webview(window, goto_split_path)

        baseline = 0
        data = load_json(keyequiv_path)
        if data:
            try:
                baseline = int(data.get("closePanelInvocations", "0"))
            except (ValueError, TypeError):
                pass

        send_shortcut("Ctrl", "Shift", "w")

        assert _wait_for_keyequiv_int(
            keyequiv_path, "closePanelInvocations", baseline + 1, timeout=5.0
        ), "Ctrl+Shift+W should work after multiple tab switches"


class TestCloseWorkspaceAfterMultipleTabSwitches:
    """Variant: multiple tab switches before Ctrl+Shift+Alt+W."""

    def test_ctrl_shift_alt_w_after_double_switch(self, window, socket_path,
                                                  goto_split_path,
                                                  keyequiv_path):
        """Ctrl+Shift+Alt+W should work after switching tabs twice."""
        setup = _wait_for_data_keys(
            goto_split_path,
            ["browserPanelId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None
        assert setup.get("webViewFocused") == "true"

        _prev_surface()
        _next_surface()
        _prev_surface()
        _next_surface()

        _refocus_webview(window, goto_split_path)

        baseline = 0
        data = load_json(keyequiv_path)
        if data:
            try:
                baseline = int(data.get("closeTabInvocations", "0"))
            except (ValueError, TypeError):
                pass

        send_shortcut("Ctrl", "Shift", "Alt", "w")

        assert _wait_for_keyequiv_int(
            keyequiv_path, "closeTabInvocations", baseline + 1, timeout=6.0
        ), "Ctrl+Shift+Alt+W should work after multiple tab switches"


class TestAllThreeShortcutsInSequence:
    """Variant: fire all three shortcuts in sequence within one session."""

    def test_sequential_n_w_shift_w(self, window, socket_path,
                                    goto_split_path, keyequiv_path):
        """Ctrl+Shift+N, Ctrl+Shift+W, and Ctrl+Shift+Alt+W should each
        work when fired back-to-back in a single session with the
        WebKitGTK view focused."""
        setup = _wait_for_data_keys(
            goto_split_path,
            ["browserPanelId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None
        assert setup.get("webViewFocused") == "true"

        _prev_surface()
        _next_surface()
        _refocus_webview(window, goto_split_path)

        # --- Ctrl+Shift+N ---
        add_baseline = 0
        data = load_json(keyequiv_path)
        if data:
            try:
                add_baseline = int(data.get("addTabInvocations", "0"))
            except (ValueError, TypeError):
                pass

        send_shortcut("Ctrl", "Shift", "n")

        assert _wait_for_keyequiv_int(
            keyequiv_path, "addTabInvocations", add_baseline + 1, timeout=5.0
        ), "Ctrl+Shift+N should fire in sequential test"

        # --- Ctrl+Shift+W ---
        close_baseline = 0
        data = load_json(keyequiv_path)
        if data:
            try:
                close_baseline = int(data.get("closePanelInvocations", "0"))
            except (ValueError, TypeError):
                pass

        send_shortcut("Ctrl", "Shift", "w")

        assert _wait_for_keyequiv_int(
            keyequiv_path, "closePanelInvocations", close_baseline + 1,
            timeout=5.0,
        ), "Ctrl+Shift+W should fire in sequential test"

        # --- Ctrl+Shift+Alt+W ---
        tab_baseline = 0
        data = load_json(keyequiv_path)
        if data:
            try:
                tab_baseline = int(data.get("closeTabInvocations", "0"))
            except (ValueError, TypeError):
                pass

        send_shortcut("Ctrl", "Shift", "Alt", "w")

        assert _wait_for_keyequiv_int(
            keyequiv_path, "closeTabInvocations", tab_baseline + 1,
            timeout=6.0,
        ), "Ctrl+Shift+Alt+W should fire in sequential test"
