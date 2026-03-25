# Dogtail UI Test Infrastructure for cmux-linux

## Context

The macOS cmux has 100 UI tests across 16 XCTest UI files that verify real user interactions — clicking buttons, typing in search fields, dragging sidebar handles, dismissing dialogs. The Linux port has zero UI tests. Unit tests (1,101 Zig tests) verify business logic but can't catch broken signal wiring, missing widget visibility, or keyboard shortcuts that don't reach their handlers.

Dogtail is a Python GUI testing framework that uses AT-SPI2 (Linux accessibility) to interact with GTK4 widgets. It's the tool Red Hat/Fedora uses for GNOME app testing. It supports Wayland via gnome-ponytail-daemon and runs headless via mutter.

## Scope

Port 91 of the 100 Mac UI tests. Skip 9 Sparkle/UpdatePill tests (macOS-only auto-update framework).

## File Structure

```
tests/ui/
├── conftest.py                    # pytest fixtures: launch cmux, AT-SPI connection, cleanup
├── helpers.py                     # Reusable: wait_for_widget(), send_shortcut(), poll_socket()
├── test_close_workspace.py        # 14 tests — Cmd+Shift+W confirm, Cmd+D confirm, close last tab
├── test_keyboard_navigation.py    # 17 tests — browser pane nav (Ctrl+Shift+H/J/K/L with splits)
├── test_menu_routing.py           # 10 tests — Cmd+N/W/Shift+W when WebView focused
├── test_sidebar.py                # 16 tests — resize handle, help menu, drag reorder, hover reveal
├── test_notifications.py          # 6 tests — multi-window routing, jump to unread
├── test_command_palette.py        # 2 tests — close other workspaces, multi-select summary
├── test_browser_omnibar.py        # 10 tests — suggestions alignment, Cmd+N/P nav, commit
├── test_browser_import.py         # 5 tests — wizard flow, checkboxes, hint dismissal
├── test_socket_automation.py      # 2 tests — socket toggle enable/disable
├── test_tab_drag.py               # 8 tests — tab reorder drag, minimal mode positioning
├── test_display_resolution.py     # 1 test — rapid resolution changes
└── run_headless.sh                # Headless runner: mutter --wayland --no-x11 --headless
```

## Prerequisites: Accessibility Labels

Dogtail finds widgets via AT-SPI names/roles. The current GTK widgets have no accessibility labels. Two kinds of changes needed:

### Static widgets (Blueprint files)

Add `accessible-name` to key widgets in `.blp` files:

**`src/apprt/gtk/ui/1.5/cmux-window.blp`:**
- `Gtk.ListBox sidebar_list` → `accessible-name: "Workspace List"`
- `Gtk.Button add_workspace_btn` → `accessible-name: "Add Workspace"` + `tooltip-text: "Add Workspace"`
- `Gtk.ToggleButton sidebar_toggle` → `accessible-name: "Toggle Sidebar"`
- `Gtk.Stack workspace_stack` → `accessible-name: "Workspace Content"`
- `Adw.OverlaySplitView split_view` → `accessible-name: "Main Layout"`

**`src/apprt/gtk/ui/1.5/command-palette.blp`:**
- `Gtk.SearchEntry search` → `accessible-name: "Command Palette Search"`
- `Gtk.ListView view` → `accessible-name: "Command Palette Results"`

**`src/apprt/gtk/ui/1.5/close-confirmation-dialog.blp`:**
- Ensure dialog buttons have labels (likely already have them via Adw.AlertDialog)

### Dynamic widgets (Zig code)

Call `widget.as(gtk.Widget).setName()` for programmatically created widgets:

**`src/cmux/gtk/window.zig`:**
- Workspace sidebar rows: `row.setName("sidebarWorkspace.<uuid>")`
- Sidebar resizer handle: `handle.setName("SidebarResizer")`
- Notification popover button: `btn.setName("NotificationBadge")`

**`src/cmux/gtk/notifications_page.zig`:**
- Notification rows: `row.setName("NotificationRow.<id>")`
- "Jump to Latest Unread" button: `btn.setName("JumpToUnread")`

**`src/apprt/gtk/class/command_palette.zig`:**
- Result rows: `row.setName("CommandPaletteRow.<index>")`

**`src/cmux/gtk/browser_panel_view.zig`:**
- Address bar: `entry.setName("BrowserOmnibar")`
- Suggestions popup: `popup.setName("BrowserOmnibarSuggestions")`

## Test Infrastructure

### conftest.py — Fixtures

```python
import pytest
import subprocess
import time
import dogtail.tree
import dogtail.config

dogtail.config.config.searchShowingOnly = False
dogtail.config.config.typingDelay = 0.03

@pytest.fixture(scope="session")
def cmux_app():
    """Launch cmux and return the AT-SPI application node."""
    proc = subprocess.Popen(
        ["./zig-out/bin/cmux"],
        env={**os.environ, "CMUX_UI_TEST": "1"}
    )
    time.sleep(2)  # Wait for window to appear
    app = dogtail.tree.root.application("cmux")
    yield app
    proc.terminate()
    proc.wait(timeout=5)

@pytest.fixture
def window(cmux_app):
    """Return the main window node."""
    return cmux_app.child(roleName="frame")
```

### helpers.py — Common Operations

```python
import dogtail.rawinput
import time

def wait_for_widget(parent, name=None, role=None, timeout=5):
    """Poll for a widget to appear, like XCTest's waitForExistence."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            pred = lambda w: True
            if name and role:
                pred = lambda w: w.name == name and w.roleName == role
            elif name:
                pred = lambda w: w.name == name
            elif role:
                pred = lambda w: w.roleName == role
            return parent.findChild(pred)
        except Exception:
            time.sleep(0.1)
    raise TimeoutError(f"Widget name={name} role={role} not found in {timeout}s")

def send_shortcut(*keys):
    """Send a keyboard shortcut (e.g., send_shortcut('ctrl', 'shift', 'p'))."""
    dogtail.rawinput.keyCombo('+'.join(keys))

def poll_socket(socket_path, command, timeout=3):
    """Send a V1 socket command and return the response."""
    import socket
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(socket_path)
    sock.sendall((command + "\n").encode())
    data = sock.recv(4096).decode()
    sock.close()
    return data
```

### Example Test — Close Workspace Confirmation

```python
def test_close_workspace_confirm_dialog_shows(window):
    """Port of testCmdShiftWShowsCloseWorkspaceConfirmationText."""
    send_shortcut('ctrl', 'shift', 'w')

    dialog = wait_for_widget(window, role="dialog", timeout=3)
    assert dialog is not None

    # Verify dialog text
    label = dialog.findChild(lambda w: "Close workspace" in w.name)
    assert label is not None

    # Click Cancel
    cancel = dialog.child("Cancel", roleName="push button")
    cancel.click()

    # Verify dialog dismissed
    time.sleep(0.3)
    try:
        window.findChild(lambda w: w.roleName == "dialog")
        assert False, "Dialog should have been dismissed"
    except:
        pass  # Expected — no dialog found
```

### Example Test — Sidebar Resize

```python
def test_sidebar_resizer_tracks_cursor(window):
    """Port of testSidebarResizerTracksCursor."""
    resizer = wait_for_widget(window, name="SidebarResizer")

    initial_x = resizer.position[0]

    # Drag right 80px
    dogtail.rawinput.drag(
        (resizer.position[0], resizer.position[1]),
        (resizer.position[0] + 80, resizer.position[1])
    )

    time.sleep(0.3)
    resizer = wait_for_widget(window, name="SidebarResizer")
    delta = resizer.position[0] - initial_x
    assert 40 <= delta <= 82
```

## Headless Runner

`tests/ui/run_headless.sh`:
```bash
#!/bin/bash
set -e

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
eval $(dbus-launch --auto-syntax)

# Build cmux
zig build -Dcmux=true -Dversion-string="0.1.0-dev"

# Run tests under headless mutter
mutter --wayland --no-x11 --sm-disable --headless -- \
    python -m pytest tests/ui/ -v --tb=short "$@"
```

## Test-to-Mac Mapping

| Mac UI Test File | Linux Test File | Tests | Notes |
|---|---|---|---|
| CloseWorkspaceCmdDUITests | test_close_workspace.py | 11 | Cmd+D → Ctrl+Shift+D |
| CloseWindowConfirmDialogUITests | test_close_workspace.py | 2 | |
| CloseWorkspaceConfirmDialogUITests | test_close_workspace.py | 1 | |
| BrowserPaneNavigationKeybindUITests | test_keyboard_navigation.py | 17 | Cmd+Ctrl → Ctrl+Shift+Alt |
| MenuKeyEquivalentRoutingUITests | test_menu_routing.py | 10 | |
| SidebarHelpMenuUITests | test_sidebar.py | 13 | Skip Sparkle "Check for Updates" (3) |
| SidebarResizeUITests | test_sidebar.py | 3 | |
| BonsplitTabDragUITests | test_tab_drag.py | 8 | Uses dogtail.rawinput.drag |
| BrowserOmnibarSuggestionsUITests | test_browser_omnibar.py | 10 | |
| MultiWindowNotificationsUITests | test_notifications.py | 5 | |
| JumpToUnreadUITests | test_notifications.py | 1 | |
| BrowserImportProfilesUITests | test_browser_import.py | 5 | |
| AutomationSocketUITests | test_socket_automation.py | 2 | |
| CloseWorkspacesConfirmDialogUITests | test_command_palette.py | 2 | |
| DisplayResolutionRegressionUITests | test_display_resolution.py | 1 | |
| UpdatePillUITests | *skipped* | 0 | Sparkle macOS-only (9 tests) |

## Dependencies

System packages (Arch Linux):
```
sudo pacman -S python python-pip at-spi2-core mutter accerciser
pip install dogtail pytest
```

For Wayland input automation: `gnome-ponytail-daemon` (AUR or built from source).

## Keyboard Shortcut Mapping

Mac shortcuts map to Linux:
- `Cmd` → `Ctrl+Shift` (primary modifier)
- `Cmd+Shift` → `Ctrl+Shift+Alt`
- `Cmd+Ctrl` → `Ctrl+Shift+Alt` (pane navigation)
- `Cmd+N` → `Ctrl+Shift+N`
- `Cmd+W` → `Ctrl+Shift+W`
- `Cmd+Shift+P` → `Ctrl+Shift+P`

## Verification

1. `./tests/ui/run_headless.sh` — runs all 91 UI tests headlessly
2. `pytest tests/ui/ -v` — runs with visible Wayland session (for debugging)
3. `accerciser` — interactive AT-SPI tree explorer (for writing new tests)

## Implementation Order

1. Add accessibility labels to Blueprint files + Zig dynamic widgets (~8 files)
2. Create `tests/ui/` infrastructure (conftest.py, helpers.py, run_headless.sh)
3. Port tests in parallel batches by file (5-6 files per batch)
4. Verify headless runner works end-to-end
