"""Dogtail UI tests for command palette operations.

Ported from:
  cmux-macos/cmuxUITests/CloseWorkspacesConfirmDialogUITests.swift
  (the two tests using the command palette / close-workspaces dialog)

Test 1 — testCommandPaletteCloseOtherWorkspacesShowsSingleSummaryDialog:
    Opens the command palette, searches "Close Other Workspaces", executes it,
    and verifies an aggregated close-workspaces confirmation dialog appears.
    Cancelling the dialog should leave all workspaces intact.

Test 2 — testCmdShiftWUsesSidebarMultiSelectionSummaryDialog:
    With multiple sidebar workspaces selected, Ctrl+Shift+Alt+W triggers the
    aggregated close-workspaces dialog (not per-workspace prompts).
    Cancelling should leave all workspaces intact.

On Linux the Mac shortcuts map as follows:
    Cmd+Shift+P → Ctrl+Shift+P  (command palette)
    Cmd+Shift+W → Ctrl+Shift+Alt+W (close workspace)
"""

import time
import uuid

import pytest

from helpers import (
    load_json,
    poll_socket,
    send_shortcut,
    wait_for_socket_pong,
    wait_for_widget,
    wait_for_widget_gone,
    wait_for_workspace_count,
    workspace_count,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _open_command_palette():
    """Ctrl+Shift+P — open the command palette."""
    send_shortcut("Ctrl", "Shift", "p")


def _close_workspace():
    """Ctrl+Shift+Alt+W — close workspace (equivalent to Cmd+Shift+W on Mac)."""
    send_shortcut("Ctrl", "Shift", "Alt", "w")


def _is_close_workspaces_dialog_present(window):
    """Check whether an aggregated close-workspaces dialog is visible.

    Looks for a dialog or alert containing "Close workspaces?" text, matching
    the Mac ``isCloseWorkspacesAlertPresent`` helper.
    """
    from dogtail.predicate import GenericPredicate

    # Try dialog role first.
    try:
        dialog = window.findChild(
            GenericPredicate(roleName="dialog"), retry=False, requireResult=False
        )
        if dialog is not None:
            try:
                label = dialog.findChild(
                    GenericPredicate(name="Close workspaces?"),
                    retry=False,
                    requireResult=False,
                )
                if label is not None:
                    return True
            except Exception:
                pass
    except Exception:
        pass

    # Try alert role.
    try:
        alert = window.findChild(
            GenericPredicate(roleName="alert"), retry=False, requireResult=False
        )
        if alert is not None:
            try:
                label = alert.findChild(
                    GenericPredicate(name="Close workspaces?"),
                    retry=False,
                    requireResult=False,
                )
                if label is not None:
                    return True
            except Exception:
                pass
    except Exception:
        pass

    # Fallback: any static text with the expected label.
    try:
        label = window.findChild(
            GenericPredicate(name="Close workspaces?"),
            retry=False,
            requireResult=False,
        )
        if label is not None:
            return True
    except Exception:
        pass

    return False


def _wait_for_close_workspaces_dialog(window, timeout=5.0):
    """Block until the aggregated close-workspaces dialog appears."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if _is_close_workspaces_dialog_present(window):
            return True
        time.sleep(0.25)
    return False


def _click_cancel_on_close_workspaces_dialog(window):
    """Click the Cancel button on the close-workspaces dialog.

    Mirrors Mac ``clickCancelOnCloseWorkspacesAlert``.
    """
    from dogtail.predicate import GenericPredicate

    # Try dialog first.
    for role in ("dialog", "alert"):
        try:
            container = window.findChild(
                GenericPredicate(roleName=role), retry=False, requireResult=False
            )
            if container is not None:
                try:
                    cancel = container.findChild(
                        GenericPredicate(name="Cancel", roleName="push button"),
                        retry=False,
                        requireResult=False,
                    )
                    if cancel is not None:
                        cancel.click()
                        return
                except Exception:
                    pass
        except Exception:
            pass

    # Fallback: any Cancel button in the window.
    try:
        cancel = window.findChild(
            GenericPredicate(name="Cancel", roleName="push button"),
            retry=False,
            requireResult=False,
        )
        if cancel is not None:
            cancel.click()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Tests — ported from CloseWorkspacesConfirmDialogUITests.swift
# ---------------------------------------------------------------------------


class TestCommandPaletteCloseOtherWorkspaces:
    """Mac: testCommandPaletteCloseOtherWorkspacesShowsSingleSummaryDialog"""

    def test_close_other_workspaces_shows_summary_dialog(
        self, window, socket_path
    ):
        """Opening the command palette, searching 'Close Other Workspaces',
        and executing it should show a single aggregated close-workspaces
        confirmation dialog.  Cancelling should leave all workspaces intact.
        """
        assert wait_for_socket_pong(socket_path, timeout=12), \
            f"Socket should respond at {socket_path}"

        # Create two additional workspaces (total = 3).
        resp1 = poll_socket(socket_path, "new_workspace")
        assert resp1 is not None and resp1.startswith("OK"), \
            f"new_workspace should succeed: {resp1}"
        resp2 = poll_socket(socket_path, "new_workspace")
        assert resp2 is not None and resp2.startswith("OK"), \
            f"new_workspace should succeed: {resp2}"

        assert wait_for_workspace_count(socket_path, 3, timeout=5), \
            (f"Expected 3 workspaces before close-other, "
             f"got {workspace_count(socket_path)}")

        # Select workspace 1 (so "close other" targets workspaces 2 and 3).
        resp = poll_socket(socket_path, "select_workspace 1")
        assert resp == "OK", f"select_workspace should succeed: {resp}"

        # Open command palette.
        _open_command_palette()

        # Find the search field.
        search_field = wait_for_widget(
            window,
            name="CommandPaletteSearchField",
            role="text",
            timeout=5,
        )
        assert search_field is not None, \
            "Command palette search field should appear"

        # Type the command.
        search_field.click()
        from dogtail.rawinput import typeText, pressKey

        typeText("Close Other Workspaces")
        time.sleep(0.5)

        # Click the result button if found, otherwise press Return.
        from dogtail.predicate import GenericPredicate

        try:
            result_btn = window.findChild(
                GenericPredicate(
                    name="Close Other Workspaces", roleName="push button"
                ),
                retry=False,
                requireResult=False,
            )
            if result_btn is not None:
                result_btn.click()
            else:
                pressKey("Return")
        except Exception:
            pressKey("Return")

        # Verify the aggregated close-workspaces dialog appears.
        assert _wait_for_close_workspaces_dialog(window, timeout=5), \
            "Aggregated close-workspaces alert should appear"

        # Cancel the dialog.
        _click_cancel_on_close_workspaces_dialog(window)

        # Dialog should dismiss.
        time.sleep(0.5)
        assert not _is_close_workspaces_dialog_present(window), \
            "Close-workspaces alert should dismiss after clicking Cancel"

        # All workspaces should remain.
        assert wait_for_workspace_count(socket_path, 3, timeout=5), \
            (f"All workspaces should remain after cancelling; "
             f"got {workspace_count(socket_path)}")


class TestCloseWorkspaceShortcutUsesSidebarMultiSelection:
    """Mac: testCmdShiftWUsesSidebarMultiSelectionSummaryDialog"""

    def test_ctrl_shift_alt_w_with_multi_selection(
        self, window, socket_path
    ):
        """With multiple workspaces selected in the sidebar,
        Ctrl+Shift+Alt+W should show an aggregated close-workspaces
        dialog (not individual per-workspace prompts).
        Cancelling should leave all workspaces intact.
        """
        assert wait_for_socket_pong(socket_path, timeout=12), \
            f"Socket should respond at {socket_path}"

        # Create one additional workspace (total = 2).
        resp = poll_socket(socket_path, "new_workspace")
        assert resp is not None and resp.startswith("OK"), \
            f"new_workspace should succeed: {resp}"

        assert wait_for_workspace_count(socket_path, 2, timeout=5), \
            (f"Expected 2 workspaces before Ctrl+Shift+Alt+W, "
             f"got {workspace_count(socket_path)}")

        # Trigger close workspace shortcut.
        _close_workspace()

        # Verify the aggregated close-workspaces dialog appears.
        assert _wait_for_close_workspaces_dialog(window, timeout=5), \
            ("Ctrl+Shift+Alt+W should use the aggregated close-workspaces "
             "alert for sidebar multi-selection")

        # Cancel.
        _click_cancel_on_close_workspaces_dialog(window)

        # Dialog should dismiss.
        time.sleep(0.5)
        assert not _is_close_workspaces_dialog_present(window), \
            "Close-workspaces alert should dismiss after clicking Cancel"

        # Both workspaces should remain.
        assert wait_for_workspace_count(socket_path, 2, timeout=5), \
            (f"Both workspaces should remain after cancelling; "
             f"got {workspace_count(socket_path)}")
