"""Port of CloseWorkspaceCmdDUITests, CloseWindowConfirmDialogUITests,
CloseWorkspaceConfirmDialogUITests, and CloseWorkspacesConfirmDialogUITests
from the macOS cmux UI test suite.

Keyboard mapping (Mac -> Linux):
    Cmd+W           -> Ctrl+Shift+W     (close workspace)
    Cmd+Shift+W     -> Ctrl+Shift+Alt+W (close window)
    Cmd+Ctrl+W      -> Ctrl+Shift+Alt+W (close window — same target on Linux)
    Cmd+D           -> Ctrl+Shift+D     (confirm destructive close)
    Cmd+N           -> Ctrl+Shift+N     (new window)
    Cmd+Shift+P     -> Ctrl+Shift+P     (command palette)
    Ctrl+D          -> Ctrl+D           (EOF / shell exit — unchanged)
"""

import json
import os
import time
import uuid

import pytest

from helpers import (
    BINARY_PATH,
    launch_cmux,
    load_json,
    poll_socket,
    send_shortcut,
    terminate_cmux,
    wait_for_atspi_app,
    wait_for_atspi_app_gone,
    wait_for_json,
    wait_for_json_key,
    wait_for_socket_pong,
    wait_for_widget,
    wait_for_widget_gone,
    wait_for_workspace_count,
    workspace_count,
)


# ===================================================================
# Helpers local to this module
# ===================================================================


def _find_dialog(app, text):
    """Return the first dialog/alert child whose label matches *text*."""
    from dogtail.predicate import GenericPredicate

    for role in ("dialog", "alert"):
        try:
            dlg = app.findChild(
                GenericPredicate(roleName=role), retry=False, requireResult=False
            )
            if dlg is not None:
                try:
                    label = dlg.findChild(
                        GenericPredicate(name=text), retry=False, requireResult=False
                    )
                    if label is not None:
                        return dlg
                except Exception:
                    pass
        except Exception:
            pass
    # Fallback: look for any static text with the expected string
    try:
        label = app.findChild(
            GenericPredicate(name=text), retry=False, requireResult=False
        )
        if label is not None:
            # Walk up to find the enclosing dialog
            node = label
            while node.parent is not None:
                if node.roleName in ("dialog", "alert"):
                    return node
                node = node.parent
    except Exception:
        pass
    return None


def _is_dialog_present(app, text):
    """Return ``True`` if a dialog containing *text* exists."""
    return _find_dialog(app, text) is not None


def _wait_for_dialog(app, text, timeout=5):
    """Poll until a dialog with *text* appears. Returns the dialog node."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        dlg = _find_dialog(app, text)
        if dlg is not None:
            return dlg
        time.sleep(0.15)
    return None


def _wait_for_dialog_gone(app, text, timeout=5):
    """Poll until no dialog with *text* is present."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not _is_dialog_present(app, text):
            return True
        time.sleep(0.15)
    return False


def _click_button_in_dialog(app, dialog_text, button_name):
    """Click a named button inside the dialog matching *dialog_text*."""
    from dogtail.predicate import GenericPredicate

    dlg = _find_dialog(app, dialog_text)
    if dlg is not None:
        try:
            btn = dlg.findChild(
                GenericPredicate(name=button_name, roleName="push button"),
                retry=False,
            )
            btn.click()
            return
        except Exception:
            pass
    # Fallback: any dialog with that button
    for role in ("dialog", "alert"):
        try:
            dlg = app.findChild(
                GenericPredicate(roleName=role), retry=False, requireResult=False
            )
            if dlg is not None:
                btn = dlg.findChild(
                    GenericPredicate(name=button_name, roleName="push button"),
                    retry=False,
                    requireResult=False,
                )
                if btn is not None:
                    btn.click()
                    return
        except Exception:
            pass


def _has_any_window(app):
    """Return ``True`` if the application has at least one frame (window)."""
    from dogtail.predicate import GenericPredicate

    try:
        win = app.findChild(
            GenericPredicate(roleName="frame"), retry=False, requireResult=False
        )
        return win is not None
    except Exception:
        return False


def _wait_for_no_window(app, timeout=6):
    """Poll until no frame exists in the application."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not _has_any_window(app):
            return True
        time.sleep(0.15)
    return False


def _wait_for_window(app, timeout=6):
    """Poll until at least one frame exists in the application."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if _has_any_window(app):
            return True
        time.sleep(0.15)
    return False


# ===================================================================
# CloseWindowConfirmDialogUITests
# ===================================================================


class TestCloseWindowConfirmDialog:
    """Port of CloseWindowConfirmDialogUITests."""

    def test_close_window_shortcut_shows_confirmation(self):
        """Ctrl+Shift+Alt+W shows the 'Close window?' confirmation dialog.

        Port of testCmdCtrlWShowsCloseWindowConfirmationText.
        """
        proc, sock = launch_cmux()
        try:
            app = wait_for_atspi_app("cmux")
            assert _wait_for_window(app, timeout=12), "Window did not appear"

            # Ctrl+Shift+Alt+W  =  Mac's Cmd+Ctrl+W  (close window)
            send_shortcut("<Ctrl><Shift><Alt>w")

            dlg = _wait_for_dialog(app, "Close window?", timeout=5)
            assert dlg is not None, (
                "Expected Ctrl+Shift+Alt+W to show the close window confirmation dialog"
            )

            _click_button_in_dialog(app, "Close window?", "Cancel")

            assert not _is_dialog_present(app, "Close window?"), (
                "Expected close window dialog to dismiss after clicking Cancel"
            )
            assert _has_any_window(app), (
                "Expected the window to remain open after cancelling close"
            )
        finally:
            terminate_cmux(proc, sock)

    def test_return_confirms_close_window_dialog(self):
        """Return key confirms the 'Close window?' dialog and closes the window.

        Port of testReturnConfirmsCloseWindowDialog.
        """
        proc, sock = launch_cmux()
        try:
            app = wait_for_atspi_app("cmux")
            assert _wait_for_window(app, timeout=12), "Window did not appear"

            send_shortcut("<Ctrl><Shift><Alt>w")

            dlg = _wait_for_dialog(app, "Close window?", timeout=5)
            assert dlg is not None, (
                "Expected Ctrl+Shift+Alt+W to show the close window confirmation dialog"
            )

            send_shortcut("Return")

            assert _wait_for_dialog_gone(app, "Close window?", timeout=5), (
                "Expected Return to dismiss the close window confirmation dialog"
            )
            assert _wait_for_no_window(app, timeout=5), (
                "Expected Return to confirm window close"
            )
        finally:
            terminate_cmux(proc, sock)


# ===================================================================
# CloseWorkspaceConfirmDialogUITests
# ===================================================================


class TestCloseWorkspaceConfirmDialog:
    """Port of CloseWorkspaceConfirmDialogUITests."""

    def test_close_workspace_shortcut_shows_confirmation(self):
        """Ctrl+Shift+W shows the 'Close workspace?' confirmation dialog.

        Port of testCmdShiftWShowsCloseWorkspaceConfirmationText.
        """
        proc, sock = launch_cmux(
            extra_env={"CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE": "1"}
        )
        try:
            app = wait_for_atspi_app("cmux")
            assert _wait_for_window(app, timeout=12), "Window did not appear"

            # Ctrl+Shift+W  =  Mac's Cmd+Shift+W  (close workspace)
            send_shortcut("<Ctrl><Shift>w")

            dlg = _wait_for_dialog(app, "Close workspace?", timeout=5)
            assert dlg is not None, (
                "Expected Ctrl+Shift+W to show the close workspace confirmation dialog"
            )

            _click_button_in_dialog(app, "Close workspace?", "Cancel")

            assert not _is_dialog_present(app, "Close workspace?"), (
                "Expected close workspace dialog to dismiss after clicking Cancel"
            )
        finally:
            terminate_cmux(proc, sock)


# ===================================================================
# CloseWorkspacesConfirmDialogUITests
# ===================================================================


class TestCloseWorkspacesConfirmDialog:
    """Port of CloseWorkspacesConfirmDialogUITests."""

    def test_command_palette_close_other_workspaces_shows_summary_dialog(self):
        """'Close Other Workspaces' from the command palette shows aggregated dialog.

        Port of testCommandPaletteCloseOtherWorkspacesShowsSingleSummaryDialog.
        """
        sock_path = f"/tmp/cmux-ui-test-close-workspaces-{uuid.uuid4().hex}.sock"
        proc, _ = launch_cmux(
            extra_env={
                "CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE": "1",
            },
            socket_path=sock_path,
        )
        try:
            app = wait_for_atspi_app("cmux")
            assert _wait_for_window(app, timeout=12), "Window did not appear"
            assert wait_for_socket_pong(sock_path, timeout=12), (
                f"Socket did not respond at {sock_path}"
            )

            # Create two additional workspaces (total = 3)
            resp1 = poll_socket(sock_path, "new_workspace")
            assert resp1 is not None and resp1.startswith("OK"), (
                f"new_workspace failed: {resp1}"
            )
            resp2 = poll_socket(sock_path, "new_workspace")
            assert resp2 is not None and resp2.startswith("OK"), (
                f"new_workspace failed: {resp2}"
            )
            assert wait_for_workspace_count(sock_path, 3, timeout=5), (
                f"Expected 3 workspaces, got {workspace_count(sock_path)}"
            )
            poll_socket(sock_path, "select_workspace 1")

            # Open command palette: Ctrl+Shift+P
            send_shortcut("<Ctrl><Shift>p")

            # Type the command and execute
            search_field = wait_for_widget(
                app, name="CommandPaletteSearchField", timeout=5
            )
            search_field.click()
            from dogtail.rawinput import typeText

            typeText("Close Other Workspaces")
            time.sleep(0.3)

            # Try to click the result button, else press Return
            from dogtail.predicate import GenericPredicate

            try:
                btn = app.findChild(
                    GenericPredicate(name="Close Other Workspaces", roleName="push button"),
                    retry=False,
                    requireResult=False,
                )
                if btn is not None:
                    btn.click()
                else:
                    send_shortcut("Return")
            except Exception:
                send_shortcut("Return")

            dlg = _wait_for_dialog(app, "Close workspaces?", timeout=5)
            assert dlg is not None, (
                "Expected a single aggregated close-workspaces dialog"
            )

            _click_button_in_dialog(app, "Close workspaces?", "Cancel")

            assert not _is_dialog_present(app, "Close workspaces?"), (
                "Expected aggregated close-workspaces dialog to dismiss after Cancel"
            )
            assert wait_for_workspace_count(sock_path, 3, timeout=5), (
                f"Expected all 3 workspaces to remain after cancelling, got {workspace_count(sock_path)}"
            )
        finally:
            terminate_cmux(proc, sock_path)

    def test_close_workspace_shortcut_uses_multi_selection_summary_dialog(self):
        """Ctrl+Shift+W with multi-selected sidebar items uses aggregated dialog.

        Port of testCmdShiftWUsesSidebarMultiSelectionSummaryDialog.
        """
        sock_path = f"/tmp/cmux-ui-test-close-workspaces-multi-{uuid.uuid4().hex}.sock"
        proc, _ = launch_cmux(
            extra_env={
                "CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE": "1",
                "CMUX_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES": "0,1",
            },
            socket_path=sock_path,
        )
        try:
            app = wait_for_atspi_app("cmux")
            assert _wait_for_window(app, timeout=12), "Window did not appear"
            assert wait_for_socket_pong(sock_path, timeout=12), (
                f"Socket did not respond at {sock_path}"
            )

            resp = poll_socket(sock_path, "new_workspace")
            assert resp is not None and resp.startswith("OK"), (
                f"new_workspace failed: {resp}"
            )
            assert wait_for_workspace_count(sock_path, 2, timeout=5), (
                f"Expected 2 workspaces, got {workspace_count(sock_path)}"
            )

            # Ctrl+Shift+W with multi-select
            send_shortcut("<Ctrl><Shift>w")

            dlg = _wait_for_dialog(app, "Close workspaces?", timeout=5)
            assert dlg is not None, (
                "Expected Ctrl+Shift+W to use the aggregated close-workspaces dialog "
                "for sidebar multi-selection"
            )

            _click_button_in_dialog(app, "Close workspaces?", "Cancel")

            assert not _is_dialog_present(app, "Close workspaces?"), (
                "Expected aggregated close-workspaces dialog to dismiss after Cancel"
            )
            assert wait_for_workspace_count(sock_path, 2, timeout=5), (
                f"Expected both workspaces to remain after cancelling, got {workspace_count(sock_path)}"
            )
        finally:
            terminate_cmux(proc, sock_path)


# ===================================================================
# CloseWorkspaceCmdDUITests
# ===================================================================


class TestCloseWorkspaceCmdD:
    """Port of CloseWorkspaceCmdDUITests."""

    def test_ctrl_shift_d_confirms_close_last_workspace_closes_window(self):
        """Ctrl+Shift+D confirms the close-workspace dialog and closes the window.

        Port of testCmdDConfirmsCloseWhenClosingLastWorkspaceClosesWindow.
        """
        proc, sock = launch_cmux(
            extra_env={"CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE": "1"}
        )
        try:
            app = wait_for_atspi_app("cmux")
            assert _wait_for_window(app, timeout=12), "Window did not appear"

            # Close workspace: Ctrl+Shift+W  (Mac: Cmd+Shift+W)
            send_shortcut("<Ctrl><Shift>w")
            assert _wait_for_dialog(app, "Close workspace?", timeout=5) is not None

            # Confirm: Ctrl+Shift+D  (Mac: Cmd+D)
            send_shortcut("<Ctrl><Shift>d")

            assert _wait_for_no_window(app, timeout=6), (
                "Expected Ctrl+Shift+D to confirm close and close the last window"
            )
        finally:
            terminate_cmux(proc, sock)

    def test_ctrl_shift_w_closing_last_tab_keeps_window_open(self):
        """Closing the last tab keeps the workspace window open.

        Port of testCmdWClosingLastTabKeepsWorkspaceWindowOpen.
        Mac uses Cmd+W for close-tab; Linux uses Ctrl+Shift+W.
        """
        data_path = f"/tmp/cmux-ui-test-keyequiv-{uuid.uuid4().hex}.json"
        proc, sock = launch_cmux(
            extra_env={"CMUX_UI_TEST_KEYEQUIV_PATH": data_path}
        )
        try:
            app = wait_for_atspi_app("cmux")
            assert _wait_for_window(app, timeout=12), "Window did not appear"

            baseline = 0
            data = load_json(data_path)
            if data and "closePanelInvocations" in data:
                baseline = int(data["closePanelInvocations"])

            # Close tab: Ctrl+Shift+W  (Mac: Cmd+W)
            send_shortcut("<Ctrl><Shift>w")

            # Wait for close-panel invocation counter to increment
            deadline = time.monotonic() + 5
            routed = False
            while time.monotonic() < deadline:
                data = load_json(data_path)
                if data and int(data.get("closePanelInvocations", 0)) >= baseline + 1:
                    routed = True
                    break
                time.sleep(0.2)
            assert routed, "Expected Ctrl+Shift+W to route through close-current-tab action"

            # If a close-tab confirmation appeared, confirm it
            dlg = _wait_for_dialog(app, "Close tab?", timeout=5)
            if dlg is not None:
                _click_button_in_dialog(app, "Close tab?", "Close")
                assert not _is_dialog_present(app, "Close tab?"), (
                    "Expected close tab dialog to dismiss after confirming"
                )

            assert _wait_for_window(app, timeout=6), (
                "Expected the workspace window to remain open after closing the last tab"
            )
        finally:
            terminate_cmux(proc, sock)
            try:
                os.unlink(data_path)
            except FileNotFoundError:
                pass

    def test_ctrl_shift_n_opens_new_window_when_none_open(self):
        """Ctrl+Shift+N opens a new window after all windows are closed.

        Port of testCmdNOpensNewWindowWhenNoWindowsOpen.
        """
        proc, sock = launch_cmux(
            extra_env={"CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE": "1"}
        )
        try:
            app = wait_for_atspi_app("cmux")
            assert _wait_for_window(app, timeout=12), "Window did not appear"

            # Close the only workspace+window
            send_shortcut("<Ctrl><Shift>w")
            assert _wait_for_dialog(app, "Close workspace?", timeout=5) is not None
            send_shortcut("<Ctrl><Shift>d")
            assert _wait_for_no_window(app, timeout=6), "Last window did not close"

            # Open new window: Ctrl+Shift+N  (Mac: Cmd+N)
            send_shortcut("<Ctrl><Shift>n")

            assert _wait_for_window(app, timeout=6), (
                "Expected Ctrl+Shift+N to open a new window when no windows are open"
            )
        finally:
            terminate_cmux(proc, sock)

    def test_child_exit_in_horizontal_split_closes_only_exited_pane(self):
        """Auto-triggered child exit in a horizontal split closes only the exited pane.

        Port of testChildExitInHorizontalSplitClosesOnlyExitedPane.
        Runs multiple attempts to catch timing-sensitive regressions.
        """
        attempts = 8
        for attempt in range(1, attempts + 1):
            data_path = f"/tmp/cmux-ui-test-child-exit-split-{uuid.uuid4().hex}.json"
            proc, sock = launch_cmux(
                extra_env={
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH": data_path,
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT": "lr",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT": "1",
                },
            )
            try:
                data = wait_for_json(data_path, timeout=12)
                assert data is not None, (
                    f"Attempt {attempt}: expected child-exit test data at {data_path}"
                )
                done = wait_for_json_key(data_path, "done", "1", timeout=12)
                assert done is not None, (
                    f"Attempt {attempt}: timed out waiting for done=1. data={load_json(data_path)}"
                )

                assert done.get("setupError", "") == "", (
                    f"Attempt {attempt}: setup failed: {done.get('setupError')}"
                )
                ws_after = int(done.get("workspaceCountAfter", -1))
                panel_after = int(done.get("panelCountAfter", -1))
                closed_ws = done.get("closedWorkspace") == "1"
                timed_out = done.get("timedOut") == "1"

                assert not timed_out, (
                    f"Attempt {attempt}: timed out waiting for child-exit close. data={done}"
                )
                assert ws_after == 1, (
                    f"Attempt {attempt}: expected workspace to remain open. data={done}"
                )
                assert panel_after == 1, (
                    f"Attempt {attempt}: expected only exited pane to close. data={done}"
                )
                assert not closed_ws, (
                    f"Attempt {attempt}: expected workspace/window to stay open. data={done}"
                )
            finally:
                terminate_cmux(proc, sock)
                try:
                    os.unlink(data_path)
                except FileNotFoundError:
                    pass

    def test_ctrl_d_in_horizontal_split_closes_only_focused_pane(self):
        """Ctrl+D in a horizontal split closes only the focused pane.

        Port of testCtrlDFromKeyboardInHorizontalSplitClosesOnlyFocusedPane.
        """
        data_path = f"/tmp/cmux-ui-test-child-exit-keyboard-{uuid.uuid4().hex}.json"
        proc, sock = launch_cmux(
            extra_env={
                "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP": "1",
                "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH": data_path,
            },
        )
        try:
            app = wait_for_atspi_app("cmux")

            data = wait_for_json(data_path, timeout=12)
            assert data is not None, (
                f"Expected keyboard child-exit setup data at {data_path}"
            )
            ready = wait_for_json_key(data_path, "ready", "1", timeout=12)
            assert ready is not None, (
                f"Timed out waiting for ready=1. data={load_json(data_path)}"
            )
            assert ready.get("setupError", "") == "", (
                f"Setup failed: {ready.get('setupError')}"
            )

            right_panel = ready.get("rightPanelId", "")
            assert right_panel, f"Missing rightPanelId in setup data. data={ready}"

            # Verify preconditions
            assert ready.get("focusedPanelBefore") == right_panel, (
                f"Expected target pane to be focused before Ctrl+D. data={ready}"
            )

            # Ctrl+D (unchanged — sends EOF to shell)
            send_shortcut("<Ctrl>d")

            done = wait_for_json_key(data_path, "done", "1", timeout=10)
            assert done is not None, (
                f"Timed out waiting for done=1 after Ctrl+D. data={load_json(data_path)}"
            )

            ws_after = int(done.get("workspaceCountAfter", -1))
            panel_after = int(done.get("panelCountAfter", -1))
            closed_ws = done.get("closedWorkspace") == "1"
            timed_out = done.get("timedOut") == "1"
            focused_after = done.get("focusedPanelAfter", "")
            first_resp_after = done.get("firstResponderPanelAfter", "")

            assert not timed_out, f"Ctrl+D test timed out. data={done}"
            assert not closed_ws, (
                f"Ctrl+D should not close workspace when another pane remains. data={done}"
            )
            assert ws_after == 1, (
                f"Expected workspace to remain open after Ctrl+D in split. data={done}"
            )
            assert panel_after == 1, (
                f"Expected only exited pane to close after Ctrl+D in split. data={done}"
            )
            if focused_after or first_resp_after:
                assert first_resp_after == focused_after, (
                    f"Expected first responder and focused panel to converge. data={done}"
                )
        finally:
            terminate_cmux(proc, sock)
            try:
                os.unlink(data_path)
            except FileNotFoundError:
                pass

    def test_ctrl_d_in_three_pane_layout_closes_only_focused_pane(self):
        """Ctrl+D in a three-pane layout closes only the focused pane.

        Port of testCtrlDFromKeyboardInThreePaneLayoutClosesOnlyFocusedPane.
        """
        data_path = f"/tmp/cmux-ui-test-child-exit-keyboard-tree-{uuid.uuid4().hex}.json"
        proc, sock = launch_cmux(
            extra_env={
                "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP": "1",
                "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH": data_path,
                "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT": "lr_left_vertical",
                "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER": "2",
                "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER": "1",
                "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT": "1",
            },
        )
        try:
            data = wait_for_json(data_path, timeout=12)
            assert data is not None, (
                f"Expected keyboard child-exit setup data at {data_path}"
            )
            ready = wait_for_json_key(data_path, "ready", "1", timeout=12)
            assert ready is not None, (
                f"Timed out waiting for ready=1. data={load_json(data_path)}"
            )
            assert ready.get("setupError", "") == "", (
                f"Setup failed: {ready.get('setupError')}"
            )

            right_panel = ready.get("rightPanelId", "")
            assert right_panel, f"Missing rightPanelId. data={ready}"
            assert ready.get("focusedPanelBefore") == right_panel

            done = wait_for_json_key(data_path, "done", "1", timeout=10)
            assert done is not None, (
                f"Timed out waiting for done=1. data={load_json(data_path)}"
            )

            ws_after = int(done.get("workspaceCountAfter", -1))
            panel_after = int(done.get("panelCountAfter", -1))
            closed_ws = done.get("closedWorkspace") == "1"
            timed_out = done.get("timedOut") == "1"
            focused_after = done.get("focusedPanelAfter", "")
            first_resp_after = done.get("firstResponderPanelAfter", "")

            assert not timed_out, f"Ctrl+D test timed out. data={done}"
            assert not closed_ws, (
                f"Ctrl+D should not close workspace when multiple panes remain. data={done}"
            )
            assert ws_after == 1, (
                f"Expected workspace to remain open in three-pane layout. data={done}"
            )
            assert panel_after == 2, (
                f"Expected only focused pane to close in three-pane layout. data={done}"
            )
            if focused_after or first_resp_after:
                assert first_resp_after == focused_after, (
                    f"Expected focus to converge in three-pane layout. data={done}"
                )
        finally:
            terminate_cmux(proc, sock)
            try:
                os.unlink(data_path)
            except FileNotFoundError:
                pass

    def test_ctrl_d_after_closing_right_column_in_2x2_keeps_workspace(self):
        """Ctrl+D after closing the right column in a 2x2 grid keeps the workspace open.

        Port of testCtrlDAfterClosingRightColumnIn2x2KeepsWorkspaceOpen.
        """
        attempts = 8
        for attempt in range(1, attempts + 1):
            data_path = f"/tmp/cmux-ui-test-child-exit-keyboard-2x2-{uuid.uuid4().hex}.json"
            proc, sock = launch_cmux(
                extra_env={
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH": data_path,
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT": "lrtd_close_right_then_exit_top_left",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER": "0",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT": "1",
                },
            )
            try:
                app = wait_for_atspi_app("cmux")
                data = wait_for_json(data_path, timeout=12)
                assert data is not None, (
                    f"Attempt {attempt}: expected setup data at {data_path}"
                )
                ready = wait_for_json_key(data_path, "ready", "1", timeout=12)
                assert ready is not None, (
                    f"Attempt {attempt}: timed out waiting for ready=1. data={load_json(data_path)}"
                )
                assert ready.get("setupError", "") == ""

                panels_before = int(ready.get("panelCountBeforeCtrlD", -1))
                exit_panel = ready.get("exitPanelId", "")
                assert panels_before == 2, (
                    f"Attempt {attempt}: expected 2 panels before Ctrl+D. data={ready}"
                )
                assert exit_panel, (
                    f"Attempt {attempt}: missing exitPanelId. data={ready}"
                )
                assert ready.get("focusedPanelBefore") == exit_panel

                send_shortcut("<Ctrl>d")

                done = wait_for_json_key(data_path, "done", "1", timeout=10)
                assert done is not None, (
                    f"Attempt {attempt}: timed out waiting for done=1. data={load_json(data_path)}"
                )

                ws_after = int(done.get("workspaceCountAfter", -1))
                panel_after = int(done.get("panelCountAfter", -1))
                closed_ws = done.get("closedWorkspace") == "1"
                timed_out = done.get("timedOut") == "1"

                assert not timed_out, f"Attempt {attempt}: timed out. data={done}"
                assert not closed_ws, (
                    f"Attempt {attempt}: should not close workspace. data={done}"
                )
                assert ws_after == 1, (
                    f"Attempt {attempt}: workspace should remain. data={done}"
                )
                assert panel_after == 1, (
                    f"Attempt {attempt}: only focused pane should close. data={done}"
                )
            finally:
                terminate_cmux(proc, sock)
                try:
                    os.unlink(data_path)
                except FileNotFoundError:
                    pass

    def test_ctrl_d_after_closing_bottom_row_in_2x2_keeps_workspace(self):
        """Ctrl+D after closing the bottom row in a 2x2 grid keeps the workspace open.

        Port of testCtrlDAfterClosingBottomRowIn2x2KeepsWorkspaceOpen.
        """
        attempts = 8
        for attempt in range(1, attempts + 1):
            data_path = f"/tmp/cmux-ui-test-child-exit-keyboard-2x2-bottom-{uuid.uuid4().hex}.json"
            proc, sock = launch_cmux(
                extra_env={
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH": data_path,
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT": "tdlr_close_bottom_then_exit_top_left",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER": "0",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT": "1",
                },
            )
            try:
                app = wait_for_atspi_app("cmux")
                data = wait_for_json(data_path, timeout=12)
                assert data is not None, (
                    f"Attempt {attempt}: expected setup data at {data_path}"
                )
                ready = wait_for_json_key(data_path, "ready", "1", timeout=12)
                assert ready is not None, (
                    f"Attempt {attempt}: timed out waiting for ready=1. data={load_json(data_path)}"
                )
                assert ready.get("setupError", "") == ""

                panels_before = int(ready.get("panelCountBeforeCtrlD", -1))
                exit_panel = ready.get("exitPanelId", "")
                assert panels_before == 2, (
                    f"Attempt {attempt}: expected 2 panels before Ctrl+D. data={ready}"
                )
                assert exit_panel, (
                    f"Attempt {attempt}: missing exitPanelId. data={ready}"
                )
                assert ready.get("focusedPanelBefore") == exit_panel

                send_shortcut("<Ctrl>d")

                done = wait_for_json_key(data_path, "done", "1", timeout=10)
                assert done is not None, (
                    f"Attempt {attempt}: timed out waiting for done=1. data={load_json(data_path)}"
                )

                ws_after = int(done.get("workspaceCountAfter", -1))
                panel_after = int(done.get("panelCountAfter", -1))
                closed_ws = done.get("closedWorkspace") == "1"
                timed_out = done.get("timedOut") == "1"

                assert not timed_out, f"Attempt {attempt}: timed out. data={done}"
                assert not closed_ws, (
                    f"Attempt {attempt}: should not close workspace. data={done}"
                )
                assert ws_after == 1, (
                    f"Attempt {attempt}: workspace should remain. data={done}"
                )
                assert panel_after == 1, (
                    f"Attempt {attempt}: only focused pane should close. data={done}"
                )
            finally:
                terminate_cmux(proc, sock)
                try:
                    os.unlink(data_path)
                except FileNotFoundError:
                    pass

    def test_ctrl_d_real_keyboard_after_closing_right_in_2x2_keeps_workspace(self):
        """Real keyboard Ctrl+D after closing the right column in a 2x2 keeps workspace open.

        Port of testCtrlDFromRealKeyboardAfterClosingRightColumnIn2x2KeepsWorkspaceOpen.
        """
        attempts = 8
        for attempt in range(1, attempts + 1):
            data_path = f"/tmp/cmux-ui-test-child-exit-keyboard-2x2-realkey-{uuid.uuid4().hex}.json"
            proc, sock = launch_cmux(
                extra_env={
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH": data_path,
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT": "lrtd_close_right_then_exit_top_left",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER": "0",
                },
            )
            try:
                app = wait_for_atspi_app("cmux")
                data = wait_for_json(data_path, timeout=12)
                assert data is not None, (
                    f"Attempt {attempt}: expected setup data at {data_path}"
                )
                ready = wait_for_json_key(data_path, "ready", "1", timeout=12)
                assert ready is not None, (
                    f"Attempt {attempt}: timed out waiting for ready=1. data={load_json(data_path)}"
                )
                assert ready.get("setupError", "") == ""

                panels_before = int(ready.get("panelCountBeforeCtrlD", -1))
                exit_panel = ready.get("exitPanelId", "")
                assert panels_before == 2, (
                    f"Attempt {attempt}: expected 2 panels before Ctrl+D. data={ready}"
                )
                assert exit_panel, (
                    f"Attempt {attempt}: missing exitPanelId. data={ready}"
                )
                assert ready.get("focusedPanelBefore") == exit_panel

                send_shortcut("<Ctrl>d")

                done = wait_for_json_key(data_path, "done", "1", timeout=10)
                assert done is not None, (
                    f"Attempt {attempt}: timed out after Ctrl+D. data={load_json(data_path)}"
                )

                ws_after = int(done.get("workspaceCountAfter", -1))
                panel_after = int(done.get("panelCountAfter", -1))
                closed_ws = done.get("closedWorkspace") == "1"
                timed_out = done.get("timedOut") == "1"

                assert not timed_out, f"Attempt {attempt}: timed out. data={done}"
                assert not closed_ws, (
                    f"Attempt {attempt}: should not close workspace. data={done}"
                )
                assert ws_after == 1, (
                    f"Attempt {attempt}: workspace should remain. data={done}"
                )
                assert panel_after == 1, (
                    f"Attempt {attempt}: only focused pane should close. data={done}"
                )
                assert _wait_for_window(app, timeout=2), (
                    f"Attempt {attempt}: window should remain after Ctrl+D. data={done}"
                )

                show_count = done.get("probeShowChildExitedCount")
                if show_count is not None:
                    assert int(show_count) == 1, (
                        f"Attempt {attempt}: expected exactly one SHOW_CHILD_EXITED. data={done}"
                    )
                key_count = done.get("probeKeyDownCount")
                if key_count is not None:
                    assert int(key_count) == 1, (
                        f"Attempt {attempt}: expected exactly one keyDown. data={done}"
                    )

                focused_after = done.get("focusedPanelAfter", "")
                first_resp_after = done.get("firstResponderPanelAfter", "")
                if focused_after or first_resp_after:
                    assert first_resp_after == focused_after, (
                        f"Attempt {attempt}: focus should converge. data={done}"
                    )
            finally:
                terminate_cmux(proc, sock)
                try:
                    os.unlink(data_path)
                except FileNotFoundError:
                    pass

    def test_ctrl_d_real_keyboard_in_horizontal_split_keeps_window(self):
        """Real keyboard Ctrl+D in a horizontal split keeps the window open.

        Port of testCtrlDFromRealKeyboardInHorizontalSplitKeepsWindowOpen.
        """
        attempts = 12
        for attempt in range(1, attempts + 1):
            data_path = f"/tmp/cmux-ui-test-child-exit-keyboard-lr-realkey-{uuid.uuid4().hex}.json"
            proc, sock = launch_cmux(
                extra_env={
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH": data_path,
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT": "lr",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER": "0",
                },
            )
            try:
                app = wait_for_atspi_app("cmux")
                data = wait_for_json(data_path, timeout=12)
                assert data is not None, (
                    f"Attempt {attempt}: expected setup data at {data_path}"
                )
                ready = wait_for_json_key(data_path, "ready", "1", timeout=12)
                assert ready is not None, (
                    f"Attempt {attempt}: timed out waiting for ready=1. data={load_json(data_path)}"
                )
                assert ready.get("setupError", "") == ""

                panels_before = int(ready.get("panelCountBeforeCtrlD", -1))
                exit_panel = ready.get("exitPanelId", "")
                assert panels_before == 2, (
                    f"Attempt {attempt}: expected 2 panels. data={ready}"
                )
                assert exit_panel, (
                    f"Attempt {attempt}: missing exitPanelId. data={ready}"
                )
                assert ready.get("focusedPanelBefore") == exit_panel

                send_shortcut("<Ctrl>d")

                done = wait_for_json_key(data_path, "done", "1", timeout=10)
                assert done is not None, (
                    f"Attempt {attempt}: timed out after Ctrl+D. data={load_json(data_path)}"
                )

                ws_after = int(done.get("workspaceCountAfter", -1))
                panel_after = int(done.get("panelCountAfter", -1))
                closed_ws = done.get("closedWorkspace") == "1"
                timed_out = done.get("timedOut") == "1"

                assert not timed_out, f"Attempt {attempt}: timed out. data={done}"
                assert not closed_ws, (
                    f"Attempt {attempt}: should not close workspace. data={done}"
                )
                assert ws_after == 1, (
                    f"Attempt {attempt}: workspace should remain. data={done}"
                )
                assert panel_after == 1, (
                    f"Attempt {attempt}: only focused pane should close. data={done}"
                )
                assert _wait_for_window(app, timeout=2), (
                    f"Attempt {attempt}: window should remain. data={done}"
                )

                show_count = done.get("probeShowChildExitedCount")
                if show_count is not None:
                    assert int(show_count) == 1, (
                        f"Attempt {attempt}: expected one SHOW_CHILD_EXITED. data={done}"
                    )
                key_count = done.get("probeKeyDownCount")
                if key_count is not None:
                    assert int(key_count) == 1, (
                        f"Attempt {attempt}: expected one keyDown. data={done}"
                    )

                focused_after = done.get("focusedPanelAfter", "")
                first_resp_after = done.get("firstResponderPanelAfter", "")
                if focused_after or first_resp_after:
                    assert first_resp_after == focused_after, (
                        f"Attempt {attempt}: focus should converge. data={done}"
                    )
            finally:
                terminate_cmux(proc, sock)
                try:
                    os.unlink(data_path)
                except FileNotFoundError:
                    pass

    def test_ctrl_d_early_during_split_startup_keeps_window(self):
        """Early Ctrl+D during split startup keeps the window open.

        Port of testCtrlDEarlyDuringSplitStartupKeepsWindowOpen.
        """
        attempts = 12
        for attempt in range(1, attempts + 1):
            data_path = f"/tmp/cmux-ui-test-child-exit-keyboard-lr-early-ctrl-{uuid.uuid4().hex}.json"
            proc, sock = launch_cmux(
                extra_env={
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH": data_path,
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT": "lr",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT": "1",
                    "CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_TRIGGER_MODE": "early_ctrl_d",
                },
            )
            try:
                app = wait_for_atspi_app("cmux")
                data = wait_for_json(data_path, timeout=12)
                assert data is not None, (
                    f"Attempt {attempt}: expected early Ctrl+D setup data at {data_path}"
                )

                done = wait_for_json_key(data_path, "done", "1", timeout=10)
                assert done is not None, (
                    f"Attempt {attempt}: timed out after early Ctrl+D. data={load_json(data_path)}"
                )
                assert done.get("setupError", "") == "", (
                    f"Attempt {attempt}: setup failed: {done.get('setupError')}"
                )

                ws_after = int(done.get("workspaceCountAfter", -1))
                panel_after = int(done.get("panelCountAfter", -1))
                closed_ws = done.get("closedWorkspace") == "1"
                timed_out = done.get("timedOut") == "1"
                trigger_mode = done.get("autoTriggerMode", "")

                assert not timed_out, (
                    f"Attempt {attempt}: early Ctrl+D timed out. data={done}"
                )
                assert trigger_mode == "strict_early_ctrl_d", (
                    f"Attempt {attempt}: expected strict early Ctrl+D trigger mode. data={done}"
                )
                assert not closed_ws, (
                    f"Attempt {attempt}: workspace should stay open. data={done}"
                )
                assert ws_after == 1, (
                    f"Attempt {attempt}: workspace should remain. data={done}"
                )
                assert panel_after == 1, (
                    f"Attempt {attempt}: only focused pane should close. data={done}"
                )

                show_count = done.get("probeShowChildExitedCount")
                if show_count is not None:
                    assert int(show_count) == 1, (
                        f"Attempt {attempt}: expected one SHOW_CHILD_EXITED. data={done}"
                    )

                exit_panel = done.get("exitPanelId", "")
                probe_surface = done.get("probeShowChildExitedSurfaceId", "")
                if exit_panel and probe_surface:
                    assert probe_surface == exit_panel, (
                        f"Attempt {attempt}: SHOW_CHILD_EXITED should target split pane. data={done}"
                    )

                workspace_id = done.get("workspaceId", "")
                probe_tab = done.get("probeShowChildExitedTabId", "")
                if workspace_id and probe_tab:
                    assert probe_tab == workspace_id, (
                        f"Attempt {attempt}: SHOW_CHILD_EXITED should target active workspace. data={done}"
                    )

                assert _wait_for_window(app, timeout=2), (
                    f"Attempt {attempt}: window should remain after early Ctrl+D. data={done}"
                )
            finally:
                terminate_cmux(proc, sock)
                try:
                    os.unlink(data_path)
                except FileNotFoundError:
                    pass
