"""Browser import profiles wizard UI tests.

Ported from cmuxUITests/BrowserImportProfilesUITests.swift (5 tests).
"""

import json
import time
import uuid

from dogtail.predicate import GenericPredicate
from dogtail.rawinput import keyCombo

from helpers import (
    load_json,
    poll_socket,
    send_v2,
    wait_for_widget,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _poll_until(timeout, predicate, interval=0.15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def _find_optional(parent, name, role=None):
    pred = GenericPredicate(name=name, roleName=role or "")
    try:
        return parent.findChild(pred, retry=False, requireResult=False)
    except Exception:
        return None


def _setup_import_env(socket_path):
    """Configure the browser import test fixture via V2 socket."""
    fixture = {
        "browserName": "Helium",
        "profiles": ["You", "austin"],
    }
    destinations = ["Default"]
    send_v2(
        socket_path,
        "debug.set_env",
        {
            "CMUX_UI_TEST_BROWSER_IMPORT_FIXTURE": json.dumps(fixture),
            "CMUX_UI_TEST_BROWSER_IMPORT_DESTINATIONS": json.dumps(destinations),
            "CMUX_UI_TEST_BROWSER_IMPORT_MODE": "capture-only",
            "CMUX_UI_TEST_BROWSER_IMPORT_HINT_VARIANT": "inlineStrip",
            "CMUX_UI_TEST_BROWSER_IMPORT_HINT_SHOW": "1",
            "CMUX_UI_TEST_BROWSER_IMPORT_HINT_DISMISSED": "0",
            "CMUX_UI_TEST_BROWSER_IMPORT_HINT_OPEN_BLANK_BROWSER": "1",
        },
        timeout=5,
    )


def _open_import_wizard(window, socket_path, capture_path=None):
    """Open the browser import wizard from the blank-tab import hint.

    Returns the capture_path used for verifying wizard output.
    """
    if capture_path is None:
        capture_path = f"/tmp/cmux-ui-test-browser-import-{uuid.uuid4().hex}.json"

    # Set capture path
    send_v2(
        socket_path,
        "debug.set_env",
        {"CMUX_UI_TEST_BROWSER_IMPORT_CAPTURE_PATH": capture_path},
        timeout=3,
    )

    # Open the import wizard via the blank-tab hint button
    hint_btn = wait_for_widget(
        window,
        name="BrowserImportHintImportButton",
        role="push button",
        timeout=5,
    )
    hint_btn.click()

    # Wait for wizard to appear
    wizard_opened = _poll_until(
        5,
        lambda: (
            _find_optional(window, "Next", "push button") is not None
            or _find_optional(window, "Import Browser Data") is not None
        ),
    )
    assert wizard_opened, "Expected the import wizard to open"

    return capture_path


def _wait_for_captured_selection(capture_path, timeout=5):
    """Wait for the captured selection JSON to appear at *capture_path*."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = load_json(capture_path)
        if data is not None and data:
            return data
        time.sleep(0.2)
    return None


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestBrowserImportProfiles:
    """Tests ported from BrowserImportProfilesUITests."""

    def test_multiple_source_profiles_default_to_separate_destinations(
        self, window, socket_path
    ):
        """Step 3 should default to separate profiles with individual
        destination popups per source profile."""
        _setup_import_env(socket_path)
        capture_path = _open_import_wizard(window, socket_path)

        # Click Next twice to reach Step 3
        next_btn = wait_for_widget(
            window, name="Next", role="push button", timeout=5
        )
        next_btn.click()
        time.sleep(0.3)

        next_btn = wait_for_widget(
            window, name="Next", role="push button", timeout=5
        )
        next_btn.click()
        time.sleep(0.3)

        # Verify Step 3 shows separate-profiles default
        separate_radio = wait_for_widget(
            window, name="Separate profiles", role="radio button", timeout=5
        )
        assert separate_radio is not None

        merge_radio = _find_optional(
            window, "Merge into one", "radio button"
        )
        assert merge_radio is not None, "Expected Merge into one radio button"

        # Verify per-profile destination popups
        popup_you = _find_optional(
            window, "BrowserImportDestinationPopup-you"
        )
        popup_austin = _find_optional(
            window, "BrowserImportDestinationPopup-austin"
        )
        assert popup_you is not None, "Expected destination popup for 'you'"
        assert popup_austin is not None, "Expected destination popup for 'austin'"

        # Click Start Import
        start_btn = wait_for_widget(
            window, name="Start Import", role="push button", timeout=5
        )
        start_btn.click()

        # Verify captured selection
        capture = _wait_for_captured_selection(capture_path)
        assert capture is not None, "Expected captured selection"
        assert capture.get("mode") == "separateProfiles"
        assert capture.get("scope") == "cookiesAndHistory"

        entries = capture.get("entries", [])
        assert len(entries) == 2
        assert entries[0].get("sourceProfiles") == ["You"]
        assert entries[0].get("destinationKind") == "create"
        assert entries[0].get("destinationName") == "You"
        assert entries[1].get("sourceProfiles") == ["austin"]
        assert entries[1].get("destinationKind") == "create"
        assert entries[1].get("destinationName") == "austin"

    def test_merge_mode_captures_single_merged_destination(
        self, window, socket_path
    ):
        """Selecting Merge into one should produce a single merged entry."""
        _setup_import_env(socket_path)
        capture_path = _open_import_wizard(window, socket_path)

        # Navigate to Step 3
        for _ in range(2):
            next_btn = wait_for_widget(
                window, name="Next", role="push button", timeout=5
            )
            next_btn.click()
            time.sleep(0.3)

        # Click "Merge into one"
        merge_radio = wait_for_widget(
            window, name="Merge into one", role="radio button", timeout=5
        )
        merge_radio.click()
        time.sleep(0.3)

        # Should show single merged destination popup
        merge_popup = _find_optional(
            window, "BrowserImportDestinationPopup-merge"
        )
        assert merge_popup is not None, (
            "Expected merge mode to show the single destination popup"
        )

        start_btn = wait_for_widget(
            window, name="Start Import", role="push button", timeout=5
        )
        start_btn.click()

        capture = _wait_for_captured_selection(capture_path)
        assert capture is not None
        assert capture.get("mode") == "mergeIntoOne"

        entries = capture.get("entries", [])
        assert len(entries) == 1
        assert entries[0].get("sourceProfiles") == ["You", "austin"]
        assert entries[0].get("destinationKind") == "existing"
        assert entries[0].get("destinationName") == "Default"

    def test_additional_data_selection_captures_everything_scope(
        self, window, socket_path
    ):
        """Checking the additional data checkbox should set scope to
        'everything'."""
        _setup_import_env(socket_path)
        capture_path = _open_import_wizard(window, socket_path)

        # Navigate to Step 3
        for _ in range(2):
            next_btn = wait_for_widget(
                window, name="Next", role="push button", timeout=5
            )
            next_btn.click()
            time.sleep(0.3)

        # Uncheck cookies and history, check additional data
        cookies_cb = wait_for_widget(
            window, name="BrowserImportCookiesCheckbox", role="check box", timeout=5
        )
        cookies_cb.click()

        history_cb = wait_for_widget(
            window, name="BrowserImportHistoryCheckbox", role="check box", timeout=5
        )
        history_cb.click()

        additional_cb = wait_for_widget(
            window,
            name="BrowserImportAdditionalDataCheckbox",
            role="check box",
            timeout=5,
        )
        additional_cb.click()

        start_btn = wait_for_widget(
            window, name="Start Import", role="push button", timeout=5
        )
        start_btn.click()

        capture = _wait_for_captured_selection(capture_path)
        assert capture is not None
        assert capture.get("scope") == "everything"

    def test_blank_browser_import_hint_can_open_browser_settings(
        self, window, socket_path
    ):
        """The blank-tab import hint Settings button should open the
        Browser Settings and scroll to the import section."""
        _setup_import_env(socket_path)

        # Wait for the hint to appear
        hint_visible = _poll_until(
            5,
            lambda: _find_optional(
                window, "BrowserImportHintImportButton", "push button"
            ) is not None,
        )
        assert hint_visible, "Expected the blank browser import hint to appear"

        settings_btn = wait_for_widget(
            window,
            name="BrowserImportHintSettingsButton",
            role="push button",
            timeout=5,
        )
        settings_btn.click()

        import_section = wait_for_widget(
            window,
            name="SettingsBrowserImportSection",
            timeout=5,
        )
        choose_btn = wait_for_widget(
            window,
            name="SettingsBrowserImportChooseButton",
            role="push button",
            timeout=5,
        )

        assert import_section is not None, (
            "Expected Browser Settings to scroll to the import section"
        )
        assert choose_btn is not None, (
            "Expected Browser Settings to expose the import actions"
        )

    def test_blank_browser_import_hint_can_be_dismissed(
        self, window, socket_path
    ):
        """The blank-tab import hint should disappear after clicking
        the dismiss button."""
        _setup_import_env(socket_path)

        # Wait for hint
        hint_visible = _poll_until(
            5,
            lambda: _find_optional(
                window, "BrowserImportHintDismissButton", "push button"
            ) is not None,
        )
        assert hint_visible, "Expected hint dismiss button"

        dismiss_btn = wait_for_widget(
            window,
            name="BrowserImportHintDismissButton",
            role="push button",
            timeout=5,
        )
        dismiss_btn.click()

        dismissed = _poll_until(
            2,
            lambda: _find_optional(
                window, "BrowserImportHintDismissButton", "push button"
            ) is None,
        )
        assert dismissed, (
            "Expected the blank-tab import hint to disappear after dismissal"
        )
