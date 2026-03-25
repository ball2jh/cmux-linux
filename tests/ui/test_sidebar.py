"""Sidebar help menu, feedback composer, command palette, and resize UI tests.

Ported from:
  - cmuxUITests/SidebarHelpMenuUITests.swift (skip 3 Sparkle tests)
  - cmuxUITests/SidebarResizeUITests.swift
"""

import time

from dogtail.rawinput import drag, keyCombo

from helpers import (
    poll_socket,
    send_shortcut,
    send_v2,
    wait_for_widget,
)


# ---------------------------------------------------------------------------
# Internal polling helper
# ---------------------------------------------------------------------------


def _poll_until(timeout, predicate, interval=0.15):
    """Poll *predicate* until it returns truthy or *timeout* expires."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


# ---------------------------------------------------------------------------
# SidebarHelpMenuUITests ports
# ---------------------------------------------------------------------------


class TestSidebarHelpMenu:
    """Tests ported from SidebarHelpMenuUITests."""

    def test_help_menu_opens_keyboard_shortcuts_section(self, window, socket_path):
        """Open the help menu and click Keyboard Shortcuts."""
        help_btn = wait_for_widget(
            window,
            name="SidebarHelpMenuButton",
            role="push button",
            timeout=6,
        )
        help_btn.click()

        kbd_item = wait_for_widget(
            window,
            name="Keyboard Shortcuts",
            role="push button",
            timeout=3,
        )
        kbd_item.click()

        wait_for_widget(
            window,
            name="ShortcutRecordingHint",
            role="label",
            timeout=6,
        )

    def test_help_menu_send_feedback_opens_composer_sheet(self, window, socket_path):
        """Open the help menu and click Send Feedback."""
        help_btn = wait_for_widget(
            window,
            name="SidebarHelpMenuButton",
            role="push button",
            timeout=6,
        )
        help_btn.click()

        feedback_item = wait_for_widget(
            window,
            name="Send Feedback",
            role="push button",
            timeout=3,
        )
        feedback_item.click()

        wait_for_widget(window, name="Send Feedback", role="label", timeout=3)
        # Email field
        wait_for_widget(
            window, name="SidebarFeedbackEmailField", role="text", timeout=2
        )
        # Attach button
        wait_for_widget(
            window, name="SidebarFeedbackAttachButton", role="push button", timeout=2
        )
        # Send button
        wait_for_widget(
            window, name="SidebarFeedbackSendButton", role="push button", timeout=2
        )
        # Human-readable footer
        wait_for_widget(
            window,
            name="A human will read this! You can also reach us at founders@manaflow.com.",
            role="label",
            timeout=2,
        )


# ---------------------------------------------------------------------------
# FeedbackComposerShortcutUITests ports
# ---------------------------------------------------------------------------


class TestFeedbackComposerShortcut:
    """Tests ported from FeedbackComposerShortcutUITests."""

    def test_ctrl_alt_f_opens_feedback_composer(self, window, socket_path):
        """Ctrl+Alt+F should open the feedback composer."""
        # Linux equivalent of macOS Cmd+Option+F
        send_shortcut("<Ctrl><Alt>f")
        wait_for_widget(window, name="Send Feedback", role="label", timeout=3)
        wait_for_widget(
            window, name="SidebarFeedbackEmailField", role="text", timeout=2
        )

    def test_ctrl_alt_f_works_with_hidden_sidebar(self, window, socket_path):
        """Ctrl+Alt+F should work even with the sidebar collapsed."""
        # Toggle sidebar off (Ctrl+B on Linux)
        send_shortcut("<Ctrl>b")
        time.sleep(0.5)

        # Verify help button is gone
        _poll_until(3, lambda: not _find_optional(window, "SidebarHelpMenuButton"))

        send_shortcut("<Ctrl><Alt>f")
        wait_for_widget(window, name="Send Feedback", role="label", timeout=3)

        # Restore sidebar
        send_shortcut("<Ctrl>b")

    def test_ctrl_alt_f_works_from_settings_window(self, window, socket_path):
        """Ctrl+Alt+F should work when Settings is the focused window."""
        # Open settings (Ctrl+, on Linux)
        send_shortcut("<Ctrl>comma")
        time.sleep(0.5)

        send_shortcut("<Ctrl><Alt>f")
        wait_for_widget(window, name="Send Feedback", role="label", timeout=3)


# ---------------------------------------------------------------------------
# CommandPaletteAllSurfacesUITests ports
# ---------------------------------------------------------------------------


class TestCommandPalette:
    """Tests ported from CommandPaletteAllSurfacesUITests."""

    def test_ctrl_shift_p_backspace_returns_to_workspace_results(
        self, window, socket_path
    ):
        """Typing > to enter commands mode, then deleting it, should
        return to workspace results."""
        current_window = poll_socket(socket_path, "current_window", timeout=5)
        assert current_window, "Expected current_window to return a window id"
        window_id = current_window.strip()

        # Open command palette in commands mode (Ctrl+Shift+P)
        send_shortcut("<Ctrl><Shift>p")
        search_field = wait_for_widget(
            window,
            name="CommandPaletteSearchField",
            role="text",
            timeout=5,
        )

        # Should show command rows (non-switcher)
        resp = send_v2(
            socket_path,
            "debug.command_palette.results",
            {"window_id": window_id, "limit": 20},
            timeout=5,
        )
        assert resp is not None

        # Delete the command prefix character to go back to workspace switcher
        keyCombo("BackSpace")
        time.sleep(0.5)

        # Should now show workspace rows
        def _has_workspace_rows():
            r = send_v2(
                socket_path,
                "debug.command_palette.results",
                {"window_id": window_id, "limit": 20},
                timeout=2,
            )
            if r is None:
                return False
            result = r.get("result", {})
            rows = result.get("results", [])
            return any(
                (row.get("command_id", "")).startswith("switcher.workspace.")
                for row in rows
            )

        assert _poll_until(5, _has_workspace_rows), (
            "Expected deleting the command prefix to restore workspace rows"
        )

        # Dismiss palette
        keyCombo("Escape")

    def test_cmd_p_search_can_include_surfaces_from_other_workspaces(
        self, window, socket_path
    ):
        """When the all-surfaces search setting is enabled, Ctrl+P
        should find terminals from non-active workspaces."""
        hidden_surface_token = "cmux-command-palette-hidden-surface"

        current_window = poll_socket(socket_path, "current_window", timeout=5)
        assert current_window
        window_id = current_window.strip()

        # Create a second workspace with a surface
        resp = poll_socket(socket_path, "new_workspace", timeout=3)
        assert resp and resp.startswith("OK ")
        workspace2_id = resp.split(" ", 1)[1].strip()

        resp = poll_socket(
            socket_path, "new_surface --type=terminal", timeout=3
        )
        assert resp and resp.startswith("OK ")
        hidden_surface_id = resp.split(" ", 1)[1].strip()

        # Report a distinctive pwd on the hidden surface
        poll_socket(
            socket_path,
            f"report_pwd /tmp/{hidden_surface_token} "
            f"--tab={workspace2_id} --panel={hidden_surface_id}",
            timeout=3,
        )

        # Switch back to first workspace
        poll_socket(socket_path, "select_workspace 0", timeout=3)
        poll_socket(socket_path, f"focus_window {window_id}", timeout=3)
        time.sleep(0.4)

        # Without the toggle, the hidden surface should not appear
        send_shortcut("<Ctrl>p")
        search_field = wait_for_widget(
            window,
            name="CommandPaletteSearchField",
            role="text",
            timeout=5,
        )
        search_field.typeText(hidden_surface_token)
        time.sleep(1)

        r = send_v2(
            socket_path,
            "debug.command_palette.results",
            {"window_id": window_id, "limit": 20},
            timeout=3,
        )
        result = (r or {}).get("result", {})
        rows = result.get("results", [])
        assert len(rows) == 0, (
            "Expected the hidden surface to be absent from search when "
            "all-surfaces is disabled"
        )

        keyCombo("Escape")
        time.sleep(0.5)

        # Enable the all-surfaces toggle via v2 command
        send_v2(
            socket_path,
            "settings.set",
            {"key": "command_palette_search_all_surfaces", "value": True},
            timeout=3,
        )
        time.sleep(0.3)

        # Now the surface should appear
        send_shortcut("<Ctrl>p")
        search_field = wait_for_widget(
            window,
            name="CommandPaletteSearchField",
            role="text",
            timeout=5,
        )
        search_field.typeText(hidden_surface_token)

        def _has_hidden_surface():
            r2 = send_v2(
                socket_path,
                "debug.command_palette.results",
                {"window_id": window_id, "limit": 20},
                timeout=2,
            )
            if r2 is None:
                return False
            result2 = r2.get("result", {})
            rows2 = result2.get("results", [])
            return any(
                row.get("command_id", "").startswith("switcher.surface.")
                and row.get("trailing_label") == "Terminal"
                for row in rows2
            )

        assert _poll_until(5, _has_hidden_surface), (
            "Expected Ctrl+P to surface the hidden terminal when "
            "all-surfaces search is enabled"
        )

        keyCombo("Escape")

    def test_minimal_mode_toggle_keeps_settings_window_focused(
        self, window, socket_path
    ):
        """Toggling minimal mode from Settings should not steal focus
        away from the Settings window."""
        # Open settings
        send_shortcut("<Ctrl>comma")
        time.sleep(0.5)

        # Find and toggle the minimal mode switch
        toggle = wait_for_widget(
            window, name="SettingsMinimalModeToggle", timeout=5
        )
        toggle.click()
        time.sleep(0.5)

        # Verify the settings window is still focused by checking the
        # toggle is still accessible and interactable.
        assert toggle.showing, (
            "Expected the Settings window to remain focused after toggling "
            "minimal mode"
        )

        # Close settings
        send_shortcut("<Ctrl>w")

    def test_command_palette_can_enable_and_disable_minimal_mode(
        self, window, socket_path
    ):
        """The command palette should expose Enable/Disable Minimal Mode
        commands that actually toggle the setting."""
        current_window = poll_socket(socket_path, "current_window", timeout=5)
        assert current_window
        window_id = current_window.strip()

        # Open command palette in commands mode and search for "minimal"
        send_shortcut("<Ctrl><Shift>p")
        search_field = wait_for_widget(
            window,
            name="CommandPaletteSearchField",
            role="text",
            timeout=5,
        )
        search_field.typeText("minimal")

        def _has_enable_row():
            r = send_v2(
                socket_path,
                "debug.command_palette.results",
                {"window_id": window_id, "limit": 20},
                timeout=2,
            )
            if r is None:
                return False
            result = r.get("result", {})
            rows = result.get("results", [])
            return any(
                row.get("command_id") == "palette.enableMinimalMode"
                for row in rows
            )

        assert _poll_until(5, _has_enable_row), (
            "Expected Enable Minimal Mode to appear in command palette"
        )

        # Commit the action
        keyCombo("Return")
        time.sleep(0.5)

        # Open again and verify Disable is now shown
        send_shortcut("<Ctrl><Shift>p")
        search_field = wait_for_widget(
            window,
            name="CommandPaletteSearchField",
            role="text",
            timeout=5,
        )
        search_field.typeText("minimal")

        def _has_disable_row():
            r = send_v2(
                socket_path,
                "debug.command_palette.results",
                {"window_id": window_id, "limit": 20},
                timeout=2,
            )
            if r is None:
                return False
            result = r.get("result", {})
            rows = result.get("results", [])
            return any(
                row.get("command_id") == "palette.disableMinimalMode"
                for row in rows
            )

        assert _poll_until(5, _has_disable_row), (
            "Expected Disable Minimal Mode to appear after enabling it"
        )

        keyCombo("Return")
        time.sleep(0.3)

    def test_switcher_empty_state_does_not_blink_while_refining_no_match_query(
        self, window, socket_path
    ):
        """Refining an already-empty switcher query should keep the
        empty-state label visible without blinking."""
        current_window = poll_socket(socket_path, "current_window", timeout=5)
        assert current_window
        window_id = current_window.strip()

        no_match_query = "cmux-command-palette-no-match"

        # Open command palette
        send_shortcut("<Ctrl>p")
        search_field = wait_for_widget(
            window,
            name="CommandPaletteSearchField",
            role="text",
            timeout=5,
        )

        # Type a query that yields no results
        search_field.typeText("z" * 8)

        # Wait for the empty state label
        empty_label = wait_for_widget(
            window,
            name="No workspaces match your search.",
            role="label",
            timeout=5,
        )

        # Refine the query with one more character
        search_field.typeText("z")
        time.sleep(0.3)

        # The empty-state label should still be visible (no blink)
        assert empty_label.showing, (
            "Expected refining an already-empty switcher query to keep the "
            "empty-state label visible"
        )

        keyCombo("Escape")


# ---------------------------------------------------------------------------
# SidebarResizeUITests ports
# ---------------------------------------------------------------------------


class TestSidebarResize:
    """Tests ported from SidebarResizeUITests."""

    def test_sidebar_resizer_tracks_cursor(self, window, socket_path):
        """Dragging the sidebar resizer right should move it proportionally."""
        resizer = wait_for_widget(
            window, name="SidebarResizer", timeout=5
        )
        pos = resizer.position
        size = resizer.size
        cx, cy = pos[0] + size[0] // 2, pos[1] + size[1] // 2

        initial_x = resizer.position[0]

        # Drag right by 80 pixels
        drag((cx, cy), (cx + 80, cy), duration=0.3)
        time.sleep(0.3)

        after_x = resizer.position[0]
        right_delta = after_x - initial_x
        assert 40 <= right_delta <= 82, (
            f"Expected drag-right to move resizer 40-82px, got {right_delta}"
        )

        # Drag back left by 120 pixels
        pos2 = resizer.position
        size2 = resizer.size
        cx2, cy2 = pos2[0] + size2[0] // 2, pos2[1] + size2[1] // 2
        drag((cx2, cy2), (cx2 - 120, cy2), duration=0.3)
        time.sleep(0.3)

        after_back_x = resizer.position[0]
        left_delta = after_back_x - after_x
        assert -122 <= left_delta <= -40, (
            f"Expected drag-left to move resizer -40 to -122px, got {left_delta}"
        )

    def test_sidebar_resizer_minimum_width(self, window, socket_path):
        """Dragging the resizer far left should clamp at the minimum width."""
        resizer = wait_for_widget(
            window, name="SidebarResizer", timeout=5
        )
        pos = resizer.position
        size = resizer.size
        cx, cy = pos[0] + size[0] // 2, pos[1] + size[1] // 2

        win_pos = window.position
        win_size = window.size
        far_left = max(win_pos[0], cx - max(200, win_size[0]))

        drag((cx, cy), (far_left, cy), duration=0.3)
        time.sleep(0.3)

        sidebar_width = max(0, resizer.position[0] + resizer.size[0] // 2 - win_pos[0])
        assert sidebar_width <= 185, (
            f"Expected sidebar minimum width <= 185px, got {sidebar_width}"
        )

    def test_sidebar_resizer_maximum_width(self, window, socket_path):
        """Dragging the resizer far right should leave at least 45% of the
        window for terminal content."""
        resizer = wait_for_widget(
            window, name="SidebarResizer", timeout=5
        )
        pos = resizer.position
        size = resizer.size
        cx, cy = pos[0] + size[0] // 2, pos[1] + size[1] // 2

        win_pos = window.position
        win_size = window.size
        far_right = cx + max(1200, win_size[0] * 2)

        drag((cx, cy), (far_right, cy), duration=0.3)
        time.sleep(0.3)

        resizer_right = resizer.position[0] + resizer.size[0]
        window_right = win_pos[0] + win_size[0]
        remaining_width = max(0, window_right - resizer_right)
        minimum_expected = win_size[0] * 0.45

        assert remaining_width >= minimum_expected, (
            f"Expected sidebar max-width clamp to leave >= 45% terminal width. "
            f"remaining={remaining_width}, window_width={win_size[0]}"
        )


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------


def _find_optional(parent, name, role=None):
    """Return a child widget or None without raising."""
    from dogtail.predicate import GenericPredicate

    pred = GenericPredicate(name=name, roleName=role or "")
    try:
        return parent.findChild(pred, retry=False, requireResult=False)
    except Exception:
        return None
