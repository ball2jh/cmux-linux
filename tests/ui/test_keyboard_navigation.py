"""Dogtail UI tests for browser pane navigation keybinds.

Ported from:
  cmux-macos/cmuxUITests/BrowserPaneNavigationKeybindUITests.swift

Tests verify that split-pane navigation shortcuts (Ctrl+Shift+Alt+H/J/K/L)
move focus between panes, including when the WebKitGTK view has focus.
Additional tests cover Escape from omnibar, Cmd+L → browser opening,
split (Ctrl+D / Ctrl+Shift+D), zoom toggle, find-field persistence, and
command-palette dismissal on browser click.

On Linux the Mac shortcuts map as follows:
    Cmd+Ctrl+H → Ctrl+Shift+Alt+Left  (or Ctrl+Shift+Alt+h)
    Cmd+Ctrl+J → Ctrl+Shift+Alt+Down
    Cmd+Ctrl+K → Ctrl+Shift+Alt+Up
    Cmd+Ctrl+L → Ctrl+Shift+Alt+Right (or Ctrl+Shift+Alt+l)
    Cmd+L      → Ctrl+l               (address bar focus)
    Cmd+D      → Ctrl+d               (split right)
    Cmd+Shift+D → Ctrl+Shift+d        (split down)
    Cmd+Shift+Enter → Ctrl+Shift+Return (zoom toggle)
    Cmd+R      → Ctrl+r               (rename palette)
    Cmd+F      → Ctrl+f               (find)
    Cmd+Option+← → Ctrl+Alt+Left      (pane switch via arrows)
    Cmd+Option+→ → Ctrl+Alt+Right
    Cmd+Shift+L → Ctrl+Shift+l        (open browser in focused pane)
"""

import json
import os
import tempfile
import time
import uuid

import pytest

from helpers import (
    load_json,
    poll_socket,
    send_shortcut,
    wait_for_json,
    wait_for_json_key,
    wait_for_socket_pong,
    wait_for_widget,
    wait_for_widget_gone,
)


# ---------------------------------------------------------------------------
# Data-file polling helpers (mirror Mac waitForDataMatch)
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
            except (KeyError, TypeError):
                pass
        time.sleep(0.25)
    return False


# ---------------------------------------------------------------------------
# Shortcut senders
# ---------------------------------------------------------------------------

def _goto_split_left():
    """Ctrl+Shift+Alt+H — move focus to left pane."""
    send_shortcut("Ctrl", "Shift", "Alt", "h")


def _goto_split_right():
    """Ctrl+Shift+Alt+L — move focus to right pane."""
    send_shortcut("Ctrl", "Shift", "Alt", "l")


def _goto_split_down():
    """Ctrl+Shift+Alt+J — move focus to pane below."""
    send_shortcut("Ctrl", "Shift", "Alt", "j")


def _goto_split_up():
    """Ctrl+Shift+Alt+K — move focus to pane above."""
    send_shortcut("Ctrl", "Shift", "Alt", "k")


def _focus_address_bar():
    """Ctrl+L — focus the browser omnibar."""
    send_shortcut("Ctrl", "l")


def _press_escape():
    """Press Escape."""
    from dogtail.rawinput import pressKey
    pressKey("Escape")


def _split_right():
    """Ctrl+D — split right."""
    send_shortcut("Ctrl", "d")


def _split_down():
    """Ctrl+Shift+D — split down."""
    send_shortcut("Ctrl", "Shift", "d")


def _zoom_toggle():
    """Ctrl+Shift+Return — toggle zoom on focused pane."""
    send_shortcut("Ctrl", "Shift", "Return")


def _open_rename_palette():
    """Ctrl+R — open rename command palette."""
    send_shortcut("Ctrl", "r")


def _open_find():
    """Ctrl+F — open find field."""
    send_shortcut("Ctrl", "f")


def _open_browser_in_pane():
    """Ctrl+Shift+L — open browser in the currently focused pane."""
    send_shortcut("Ctrl", "Shift", "l")


def _pane_left_arrows():
    """Ctrl+Alt+Left — move focus left via arrow shortcut."""
    send_shortcut("Ctrl", "Alt", "Left")


def _pane_right_arrows():
    """Ctrl+Alt+Right — move focus right via arrow shortcut."""
    send_shortcut("Ctrl", "Alt", "Right")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def data_path(tmp_path):
    """Return a unique JSON data path for the goto_split test harness."""
    return str(tmp_path / f"goto-split-{uuid.uuid4().hex}.json")


@pytest.fixture
def goto_split_env(data_path, socket_path):
    """Return the env dict fragment for goto_split test harness setup."""
    return {
        "CMUX_UI_TEST_GOTO_SPLIT_SETUP": "1",
        "CMUX_UI_TEST_GOTO_SPLIT_PATH": data_path,
        "CMUX_UI_TEST_FOCUS_SHORTCUTS": "1",
        "CMUX_SOCKET_PATH": socket_path,
    }


# ---------------------------------------------------------------------------
# Tests — ported from BrowserPaneNavigationKeybindUITests.swift
# ---------------------------------------------------------------------------


class TestGotoSplitLeftWhenWebViewFocused:
    """Mac: testCmdCtrlHMovesLeftWhenWebViewFocused"""

    def test_ctrl_shift_alt_h_moves_left(self, window, socket_path, data_path):
        """Ctrl+Shift+Alt+H moves focus to the left (terminal) pane when
        the WebKitGTK view has focus."""
        setup = _wait_for_data_keys(
            data_path,
            ["terminalPaneId", "browserPaneId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None, "goto_split setup data not written"
        assert setup["webViewFocused"] == "true", "WebKitGTK should be focused"

        expected_terminal = setup["terminalPaneId"]
        _goto_split_left()

        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("lastMoveDirection") == "left"
                and d.get("focusedPaneId") == expected_terminal
            ),
            timeout=5.0,
        ), "Ctrl+Shift+Alt+H should move focus to left pane (terminal)"


class TestGotoSplitLeftViaGhosttyConfig:
    """Mac: testCmdCtrlHMovesLeftWhenWebViewFocusedUsingGhosttyConfigKeybind"""

    def test_ghostty_config_keybind_moves_left(self, window, socket_path,
                                                data_path):
        """Ctrl+Shift+Alt+H moves focus left even when bound via Ghostty
        config (keybind = ...) rather than cmux built-in shortcuts."""
        setup = _wait_for_data_keys(
            data_path,
            [
                "terminalPaneId",
                "browserPaneId",
                "webViewFocused",
                "ghosttyGotoSplitLeftShortcut",
            ],
            timeout=10.0,
        )
        assert setup is not None, "goto_split setup data not written"
        assert setup["webViewFocused"] == "true"
        assert setup.get("ghosttyGotoSplitLeftShortcut"), \
            "Ghostty trigger metadata should be present"

        expected_terminal = setup["terminalPaneId"]
        _goto_split_left()

        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("lastMoveDirection") == "left"
                and d.get("focusedPaneId") == expected_terminal
            ),
            timeout=5.0,
        ), "Ctrl+Shift+Alt+H should move left via Ghostty config trigger"


class TestEscapeLeavesOmnibar:
    """Mac: testEscapeLeavesOmnibarAndFocusesWebView"""

    def test_escape_returns_focus_to_webview(self, window, socket_path,
                                             data_path):
        """Pressing Escape after Ctrl+L should dismiss the omnibar and
        return focus to the WebKitGTK view."""
        setup = _wait_for_data_keys(
            data_path,
            ["browserPanelId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None, "goto_split setup data not written"
        assert setup["webViewFocused"] == "true"

        # Ctrl+L focuses the omnibar.
        _focus_address_bar()
        assert _wait_for_data_match(
            data_path,
            lambda d: d.get("webViewFocusedAfterAddressBarFocus") == "false",
            timeout=5.0,
        ), "Ctrl+L should focus omnibar (WebKitGTK not focused)"

        # Escape should return focus to the web view.  Send twice — the first
        # may only clear suggestions (Chrome-like two-stage escape).
        _press_escape()
        if not _wait_for_data_match(
            data_path,
            lambda d: d.get("webViewFocusedAfterAddressBarExit") == "true",
            timeout=2.0,
        ):
            _press_escape()

        assert _wait_for_data_match(
            data_path,
            lambda d: d.get("webViewFocusedAfterAddressBarExit") == "true",
            timeout=5.0,
        ), "Escape should return focus to WebKitGTK"


class TestEscapeRestoresPageInput:
    """Mac: testEscapeRestoresFocusedPageInputAfterCmdL"""

    def test_escape_restores_focused_input(self, window, socket_path,
                                           data_path):
        """After Ctrl+L → Escape, focus should return to the previously
        focused page input element (not just the web view in general)."""
        setup = _wait_for_data_keys(
            data_path,
            [
                "browserPanelId",
                "webViewFocused",
                "webInputFocusSeeded",
                "webInputFocusElementId",
                "webInputFocusSecondaryElementId",
            ],
            timeout=12.0,
        )
        assert setup is not None, "setup data with input focus not written"
        assert setup["webViewFocused"] == "true"
        assert setup["webInputFocusSeeded"] == "true"

        expected_input_id = setup["webInputFocusElementId"]
        assert expected_input_id, "webInputFocusElementId should be non-empty"

        # Ctrl+L to focus omnibar.
        _focus_address_bar()
        assert _wait_for_data_match(
            data_path,
            lambda d: d.get("webViewFocusedAfterAddressBarFocus") == "false",
            timeout=5.0,
        ), "Ctrl+L should focus omnibar"

        # Escape to restore page input focus.
        _press_escape()
        if not _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("webViewFocusedAfterAddressBarExit") == "true"
                and d.get("addressBarExitActiveElementId") == expected_input_id
                and d.get("addressBarExitActiveElementEditable") == "true"
            ),
            timeout=2.0,
        ):
            _press_escape()

        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("webViewFocusedAfterAddressBarExit") == "true"
                and d.get("addressBarExitActiveElementId") == expected_input_id
                and d.get("addressBarExitActiveElementEditable") == "true"
            ),
            timeout=6.0,
        ), f"Escape should restore focus to page input {expected_input_id}"


class TestCtrlLOpensBrowserWhenTerminalFocused:
    """Mac: testCmdLOpensBrowserWhenTerminalFocused"""

    def test_ctrl_l_on_terminal_opens_browser(self, window, socket_path,
                                              data_path):
        """When the terminal pane is focused, Ctrl+L should open a new
        browser in that pane and focus the omnibar."""
        setup = _wait_for_data_keys(
            data_path,
            ["browserPanelId", "terminalPaneId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None

        original_browser_id = setup["browserPanelId"]
        expected_terminal = setup["terminalPaneId"]

        # Move focus to terminal pane.
        _goto_split_left()
        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("lastMoveDirection") == "left"
                and d.get("focusedPaneId") == expected_terminal
            ),
            timeout=5.0,
        )

        # Ctrl+L should open a new browser in the terminal pane.
        _focus_address_bar()
        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("webViewFocusedAfterAddressBarFocus") == "false"
                and d.get("webViewFocusedAfterAddressBarFocusPanelId") is not None
                and d.get("webViewFocusedAfterAddressBarFocusPanelId")
                != original_browser_id
            ),
            timeout=5.0,
        ), "Ctrl+L on terminal should open a new browser and focus omnibar"


class TestClickingOmnibarFocusesBrowserPane:
    """Mac: testClickingOmnibarFocusesBrowserPane"""

    def test_omnibar_click_focuses_browser(self, window, socket_path,
                                           data_path):
        """Clicking the omnibar should move pane focus to the browser
        so that a subsequent Ctrl+L stays on the existing browser."""
        setup = _wait_for_data_keys(
            data_path,
            ["browserPanelId", "terminalPaneId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None

        expected_browser_id = setup["browserPanelId"]
        expected_terminal = setup["terminalPaneId"]

        # Move focus away from browser to terminal.
        _goto_split_left()
        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("lastMoveDirection") == "left"
                and d.get("focusedPaneId") == expected_terminal
            ),
            timeout=5.0,
        )

        # Click the omnibar via AT-SPI.
        omnibar = wait_for_widget(window, name="BrowserOmnibarTextField",
                                  role="text", timeout=6)
        omnibar.click()

        # Ctrl+L should now stay on the existing browser panel.
        _focus_address_bar()
        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("webViewFocusedAfterAddressBarFocus") == "false"
                and d.get("webViewFocusedAfterAddressBarFocusPanelId")
                == expected_browser_id
            ),
            timeout=5.0,
        ), "Omnibar click should focus browser panel so Ctrl+L stays on it"


class TestClickBrowserDismissesCommandPalette:
    """Mac: testClickingBrowserDismissesCommandPaletteAndKeepsBrowserFocus"""

    def test_clicking_browser_dismisses_palette(self, window, socket_path,
                                                data_path):
        """Clicking the browser pane content while the rename command palette
        is open should dismiss the palette and keep browser focus."""
        setup = _wait_for_data_keys(
            data_path,
            ["browserPanelId", "terminalPaneId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None

        expected_browser_id = setup["browserPanelId"]
        expected_terminal = setup["terminalPaneId"]

        # Move focus to terminal so Ctrl+R opens rename overlay.
        _goto_split_left()
        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("lastMoveDirection") == "left"
                and d.get("focusedPaneId") == expected_terminal
            ),
            timeout=5.0,
        )

        # Open rename palette.
        _open_rename_palette()
        rename_field = wait_for_widget(
            window, name="CommandPaletteRenameField", role="text", timeout=5
        )
        assert rename_field is not None, "Ctrl+R should open rename palette"

        # Click browser pane content to dismiss.
        browser_pane = wait_for_widget(
            window,
            name=f"BrowserPanelContent.{expected_browser_id}",
            timeout=5,
        )
        assert browser_pane is not None, "Browser pane content should exist"
        browser_pane.click()

        wait_for_widget_gone(
            window, name="CommandPaletteRenameField", role="text", timeout=5
        )

        # Ctrl+L should stay on existing browser.
        _focus_address_bar()
        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("webViewFocusedAfterAddressBarFocus") == "false"
                and d.get("webViewFocusedAfterAddressBarFocusPanelId")
                == expected_browser_id
            ),
            timeout=5.0,
        ), "Clicking browser should dismiss palette and keep browser focus"


class TestSplitRightWhenWebViewFocused:
    """Mac: testCmdDSplitsRightWhenWebViewFocused"""

    def test_ctrl_d_splits_right(self, window, socket_path, data_path):
        """Ctrl+D should split right while the WebKitGTK view is focused."""
        setup = _wait_for_data_keys(
            data_path,
            ["webViewFocused", "initialPaneCount"],
            timeout=10.0,
        )
        assert setup is not None
        assert setup["webViewFocused"] == "true"
        initial = int(setup["initialPaneCount"])
        assert initial >= 2

        _split_right()

        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("lastSplitDirection") == "right"
                and int(d.get("paneCountAfterSplit", "0")) == initial + 1
            ),
            timeout=5.0,
        ), "Ctrl+D should split right while WebKitGTK is focused"


class TestSplitDownWhenWebViewFocused:
    """Mac: testCmdShiftDSplitsDownWhenWebViewFocused"""

    def test_ctrl_shift_d_splits_down(self, window, socket_path, data_path):
        """Ctrl+Shift+D should split down while the WebKitGTK view is focused."""
        setup = _wait_for_data_keys(
            data_path,
            ["webViewFocused", "initialPaneCount"],
            timeout=10.0,
        )
        assert setup is not None
        assert setup["webViewFocused"] == "true"
        initial = int(setup["initialPaneCount"])
        assert initial >= 2

        _split_down()

        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("lastSplitDirection") == "down"
                and int(d.get("paneCountAfterSplit", "0")) == initial + 1
            ),
            timeout=5.0,
        ), "Ctrl+Shift+D should split down while WebKitGTK is focused"


class TestZoomRoundTripKeepsOmnibarHittable:
    """Mac: testCmdShiftEnterKeepsBrowserOmnibarHittableAcrossZoomRoundTripWhenWebViewFocused"""

    def test_zoom_toggle_preserves_omnibar(self, window, socket_path,
                                           data_path):
        """Ctrl+Shift+Return zoom toggle should not break the browser
        omnibar — it must remain visible and functional afterward."""
        setup = _wait_for_data_keys(
            data_path,
            ["browserPanelId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None
        assert setup["webViewFocused"] == "true"

        omnibar = wait_for_widget(window, name="BrowserOmnibarTextField",
                                  role="text", timeout=6)
        assert omnibar is not None

        # Zoom in.
        _zoom_toggle()
        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("splitZoomedAfterToggle") == "true"
                and d.get("otherTerminalHostHiddenAfterToggle") == "true"
                and d.get("otherTerminalVisibleFlagAfterToggle") == "false"
            ),
            timeout=8.0,
        ), "Ctrl+Shift+Return should zoom in and hide terminal portal"

        # Zoom out.
        _zoom_toggle()
        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("splitZoomedAfterToggle") == "false"
                and d.get("otherTerminalHostHiddenAfterToggle") == "false"
                and d.get("otherTerminalVisibleFlagAfterToggle") == "true"
            ),
            timeout=8.0,
        ), "Ctrl+Shift+Return should zoom out and restore terminal portal"

        # Omnibar should still be findable and functional.
        omnibar2 = wait_for_widget(window, name="BrowserOmnibarTextField",
                                   role="text", timeout=6)
        assert omnibar2 is not None, \
            "Browser omnibar should exist after zoom round-trip"


class TestZoomHidesBrowserWhenTerminalZooms:
    """Mac: testCmdShiftEnterHidesBrowserPortalWhenTerminalPaneZooms"""

    def test_terminal_zoom_hides_browser(self, window, socket_path,
                                         data_path):
        """When the terminal pane is zoomed, the browser portal should be
        hidden; unzoom should restore it."""
        setup = _wait_for_data_keys(
            data_path,
            ["terminalPaneId", "browserPanelId", "webViewFocused"],
            timeout=10.0,
        )
        assert setup is not None

        expected_terminal = setup["terminalPaneId"]

        # Focus terminal.
        _goto_split_left()
        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("focusedPaneId") == expected_terminal
                and d.get("focusedPanelKind") == "terminal"
            ),
            timeout=5.0,
        )

        # Zoom in.
        _zoom_toggle()
        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("splitZoomedAfterToggle") == "true"
                and d.get("browserContainerHiddenAfterToggle") == "true"
                and d.get("browserVisibleFlagAfterToggle") == "false"
            ),
            timeout=8.0,
        ), "Zoom on terminal pane should hide browser portal"

        # Zoom out.
        _zoom_toggle()
        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("splitZoomedAfterToggle") == "false"
                and d.get("browserContainerHiddenAfterToggle") == "false"
                and d.get("browserVisibleFlagAfterToggle") == "true"
            ),
            timeout=8.0,
        ), "Unzoom should restore browser portal"


class TestSplitRightWhenOmnibarFocused:
    """Mac: testCmdDSplitsRightWhenOmnibarFocused"""

    def test_ctrl_d_splits_right_omnibar(self, window, socket_path, data_path):
        """Ctrl+D should split right even when the omnibar has focus."""
        setup = _wait_for_data_keys(
            data_path,
            ["webViewFocused", "initialPaneCount"],
            timeout=10.0,
        )
        assert setup is not None
        initial = int(setup["initialPaneCount"])
        assert initial >= 2

        # Focus the omnibar first.
        _focus_address_bar()
        assert _wait_for_data_match(
            data_path,
            lambda d: d.get("webViewFocusedAfterAddressBarFocus") == "false",
            timeout=5.0,
        )

        _split_right()

        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("lastSplitDirection") == "right"
                and int(d.get("paneCountAfterSplit", "0")) == initial + 1
            ),
            timeout=5.0,
        ), "Ctrl+D should split right while omnibar is focused"


class TestSplitDownWhenOmnibarFocused:
    """Mac: testCmdShiftDSplitsDownWhenOmnibarFocused"""

    def test_ctrl_shift_d_splits_down_omnibar(self, window, socket_path,
                                              data_path):
        """Ctrl+Shift+D should split down even when the omnibar has focus."""
        setup = _wait_for_data_keys(
            data_path,
            ["webViewFocused", "initialPaneCount"],
            timeout=10.0,
        )
        assert setup is not None
        initial = int(setup["initialPaneCount"])
        assert initial >= 2

        _focus_address_bar()
        assert _wait_for_data_match(
            data_path,
            lambda d: d.get("webViewFocusedAfterAddressBarFocus") == "false",
            timeout=5.0,
        )

        _split_down()

        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("lastSplitDirection") == "down"
                and int(d.get("paneCountAfterSplit", "0")) == initial + 1
            ),
            timeout=5.0,
        ), "Ctrl+Shift+D should split down while omnibar is focused"


class TestFindFocusPersistenceCmdOptionArrows:
    """Mac: testCmdOptionPaneSwitchPreservesFindFieldFocus"""

    def test_find_focus_persists_arrows(self, window, socket_path, data_path):
        """Switching panes via Ctrl+Alt+Left/Right should preserve find
        field focus in each pane independently."""
        _run_find_focus_persistence(
            window, data_path, route="arrows", autofocus_race=False
        )


class TestFindFocusPersistenceCmdCtrlLetters:
    """Mac: testCmdCtrlPaneSwitchPreservesFindFieldFocus"""

    def test_find_focus_persists_letters(self, window, socket_path, data_path):
        """Switching panes via Ctrl+Shift+Alt+H/L should preserve find
        field focus in each pane independently."""
        _run_find_focus_persistence(
            window, data_path, route="letters", autofocus_race=False
        )


class TestFindFocusPersistenceAutofocusRace:
    """Mac: testCmdOptionPaneSwitchPreservesFindFieldFocusDuringPageAutofocusRace"""

    def test_find_focus_autofocus_race(self, window, socket_path, data_path):
        """Find field focus should survive even when the page fires a delayed
        autofocus that would normally steal focus."""
        _run_find_focus_persistence(
            window, data_path, route="arrows", autofocus_race=True
        )


class TestFindFieldAfterSplitAndBrowserOpen:
    """Mac: testCmdFFocusesBrowserFindFieldAfterCmdDCmdLNavigation"""

    def test_ctrl_f_focuses_browser_find(self, window, socket_path, data_path):
        """After Ctrl+D (split), Ctrl+L (browser), navigate, Ctrl+F should
        focus the browser find field — not the omnibar."""
        # Wait for recording-only setup.
        _wait_for_data_keys(data_path, ["initialPaneCount"], timeout=10.0)

        # Ctrl+D to split.
        _split_right()
        assert _wait_for_data_match(
            data_path,
            lambda d: (
                d.get("lastSplitDirection") == "right"
                and int(d.get("paneCountAfterSplit", "0")) >= 2
            ),
            timeout=6.0,
        )

        # Ctrl+L to open browser.
        _focus_address_bar()
        omnibar = wait_for_widget(window, name="BrowserOmnibarTextField",
                                  role="text", timeout=8)
        assert omnibar is not None

        # Navigate to example.com.
        from dogtail.rawinput import typeText, pressKey
        send_shortcut("Ctrl", "a")
        pressKey("Delete")
        typeText("example.com")
        pressKey("Return")

        # Wait for navigation.
        time.sleep(3.0)

        # Ctrl+F to open find.
        _open_find()
        find_field = wait_for_widget(window, name="BrowserFindSearchTextField",
                                     role="text", timeout=6)
        assert find_field is not None, \
            "Ctrl+F should open browser find field after Ctrl+D, Ctrl+L, navigate"

        # Type into find field — should not go to omnibar.
        typeText("needle")
        time.sleep(0.5)

        # Verify find field got the text (not omnibar).
        # Read back via data file if available.
        data = load_json(data_path)
        if data and "browserFindNeedle" in data:
            assert data["browserFindNeedle"] == "needle" or "needle" in data.get(
                "browserFindNeedle", ""
            ), "Typed text should go to find field, not omnibar"


# ---------------------------------------------------------------------------
# Shared find-focus persistence scenario
# ---------------------------------------------------------------------------


def _focus_left(route):
    if route == "arrows":
        _pane_left_arrows()
    else:
        _goto_split_left()


def _focus_right(route):
    if route == "arrows":
        _pane_right_arrows()
    else:
        _goto_split_right()


def _run_find_focus_persistence(window, data_path, route, autofocus_race):
    """Shared implementation for the three find-focus persistence tests.

    Matches Mac ``runFindFocusPersistenceScenario``.
    """
    from dogtail.rawinput import typeText, pressKey

    # Wait for initial setup.
    _wait_for_data_keys(data_path, ["initialPaneCount"], timeout=10.0)

    # Split right.
    _split_right()
    _focus_right(route)

    # Open browser in right pane.
    _open_browser_in_pane()
    omnibar = wait_for_widget(window, name="BrowserOmnibarTextField",
                              role="text", timeout=8)
    assert omnibar is not None

    # Navigate.
    send_shortcut("Ctrl", "a")
    pressKey("Delete")
    if autofocus_race:
        # data: URL with delayed autofocus
        typeText(
            "data:text/html,%3Cinput%20id%3D%22q%22%3E%3Cscript%3E"
            "setTimeout%28function%28%29%7Bdocument.getElementById"
            "%28%22q%22%29.focus%28%29%3Blocation.hash%3D%22focused"
            "%22%3B%7D%2C700%29%3B%3C%2Fscript%3E"
        )
    else:
        typeText("example.com")
    pressKey("Return")
    time.sleep(3.0)

    # Left terminal: Ctrl+F then type "la".
    _focus_left(route)
    assert _wait_for_data_match(
        data_path,
        lambda d: d.get("focusedPanelKind") == "terminal",
        timeout=6.0,
    )
    _open_find()
    typeText("la")

    # Right browser: Ctrl+F then type "am".
    _focus_right(route)
    assert _wait_for_data_match(
        data_path,
        lambda d: (
            d.get("lastMoveDirection") == "right"
            and d.get("focusedPanelKind") == "browser"
            and d.get("terminalFindNeedle") == "la"
        ),
        timeout=6.0,
    ), "Terminal find query should persist as 'la' after focusing browser"

    _open_find()
    typeText("am")

    # Left terminal: typing should continue in terminal find.
    _focus_left(route)
    assert _wait_for_data_match(
        data_path,
        lambda d: (
            d.get("lastMoveDirection") == "left"
            and d.get("focusedPanelKind") == "terminal"
            and d.get("browserFindNeedle") == "am"
        ),
        timeout=6.0,
    ), "Browser find query should persist as 'am' after returning left"
    typeText("foo")

    # Right browser: typing should continue in browser find.
    _focus_right(route)
    assert _wait_for_data_match(
        data_path,
        lambda d: (
            d.get("lastMoveDirection") == "right"
            and d.get("focusedPanelKind") == "browser"
            and d.get("terminalFindNeedle") == "lafoo"
        ),
        timeout=6.0,
    ), "Terminal find query should become 'lafoo'"
    typeText("do")

    # Move left once more to capture final browser find state.
    _focus_left(route)
    assert _wait_for_data_match(
        data_path,
        lambda d: (
            d.get("lastMoveDirection") == "left"
            and d.get("focusedPanelKind") == "terminal"
            and d.get("browserFindNeedle") == "amdo"
        ),
        timeout=6.0,
    ), "Browser find query should become 'amdo'"
