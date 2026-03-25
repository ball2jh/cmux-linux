"""Common helpers for cmux Dogtail UI tests."""

import json
import os
import signal
import socket
import subprocess
import time
import uuid

from dogtail.predicate import GenericPredicate
from dogtail.rawinput import keyCombo


# ---------------------------------------------------------------------------
# Project paths
# ---------------------------------------------------------------------------

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BINARY_PATH = os.path.join(PROJECT_ROOT, "zig-out", "bin", "cmux")


# ---------------------------------------------------------------------------
# Widget polling
# ---------------------------------------------------------------------------


def wait_for_widget(parent, name=None, role=None, timeout=5):
    """Poll until a widget matching *name* and/or *role* appears under *parent*.

    Returns the widget node, or raises ``TimeoutError``.
    """
    pred = GenericPredicate(name=name or "", roleName=role or "")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            child = parent.findChild(pred, retry=False, requireResult=False)
            if child is not None:
                return child
        except Exception:
            pass
        time.sleep(0.15)
    raise TimeoutError(
        f"Widget (name={name!r}, role={role!r}) did not appear within {timeout}s"
    )


def wait_for_widget_gone(parent, name=None, role=None, timeout=5):
    """Poll until a widget matching *name* and/or *role* disappears from *parent*.

    Returns ``True`` on success, or raises ``TimeoutError``.
    """
    pred = GenericPredicate(name=name or "", roleName=role or "")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            child = parent.findChild(pred, retry=False, requireResult=False)
            if child is None:
                return True
        except Exception:
            return True
        time.sleep(0.15)
    raise TimeoutError(
        f"Widget (name={name!r}, role={role!r}) still present after {timeout}s"
    )


# ---------------------------------------------------------------------------
# Keyboard
# ---------------------------------------------------------------------------


def send_shortcut(*keys):
    """Send a keyboard shortcut via dogtail.

    Example::

        send_shortcut("Ctrl", "Shift", "w")
    """
    combo = "+".join(keys)
    # dogtail.rawinput.keyCombo expects e.g. "<Ctrl><Shift>w"
    # but also accepts the "+" separated form.
    keyCombo(combo)


# ---------------------------------------------------------------------------
# Socket helpers
# ---------------------------------------------------------------------------


def poll_socket(socket_path, command, timeout=3):
    """Send a V1 (line protocol) command to the cmux Unix socket.

    Returns the response string (stripped), or ``None`` on failure.
    """
    deadline = time.monotonic() + timeout
    last_err = None
    while time.monotonic() < deadline:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(max(0.5, deadline - time.monotonic()))
            sock.connect(socket_path)
            sock.sendall((command + "\n").encode())
            # Read until the peer closes or we get a full line.
            chunks = []
            while True:
                data = sock.recv(4096)
                if not data:
                    break
                chunks.append(data)
            sock.close()
            return b"".join(chunks).decode().strip()
        except Exception as exc:
            last_err = exc
            time.sleep(0.2)
    return None


def send_v2(socket_path, method, params=None, timeout=3):
    """Send a V2 JSON-RPC request to the cmux Unix socket.

    Returns the parsed JSON response dict, or ``None`` on failure.
    """
    request = {
        "jsonrpc": "2.0",
        "id": uuid.uuid4().hex[:8],
        "method": method,
    }
    if params is not None:
        request["params"] = params
    payload = json.dumps(request) + "\n"

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(max(0.5, deadline - time.monotonic()))
            sock.connect(socket_path)
            sock.sendall(payload.encode())
            chunks = []
            while True:
                data = sock.recv(4096)
                if not data:
                    break
                chunks.append(data)
            sock.close()
            raw = b"".join(chunks).decode().strip()
            return json.loads(raw)
        except Exception:
            time.sleep(0.2)
    return None


# ---------------------------------------------------------------------------
# Socket polling convenience
# ---------------------------------------------------------------------------


def wait_for_socket_pong(socket_path, timeout=12):
    """Block until ``ping`` returns ``PONG`` from the V1 socket."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        resp = poll_socket(socket_path, "ping", timeout=1)
        if resp == "PONG":
            return True
        time.sleep(0.3)
    return False


def workspace_count(socket_path):
    """Return the number of workspaces reported by ``list_workspaces``."""
    resp = poll_socket(socket_path, "list_workspaces", timeout=2)
    if resp is None or resp == "No workspaces":
        return 0
    return len([line for line in resp.split("\n") if line.strip()])


def wait_for_workspace_count(socket_path, expected, timeout=5):
    """Poll until the workspace count matches *expected*."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if workspace_count(socket_path) == expected:
            return True
        time.sleep(0.3)
    return False


# ---------------------------------------------------------------------------
# Process launch helpers (for tests that need isolated instances)
# ---------------------------------------------------------------------------


def launch_cmux(extra_env=None, socket_path=None):
    """Launch a fresh cmux process with the given extra env vars.

    Returns ``(proc, socket_path)``.
    """
    if socket_path is None:
        socket_path = f"/tmp/cmux-ui-test-{uuid.uuid4().hex}.sock"

    env = os.environ.copy()
    env["CMUX_UI_TEST"] = "1"
    env["CMUX_SOCKET_PATH"] = socket_path
    env["GTK_A11Y"] = "atspi"  # GTK4 accessibility backend
    if extra_env:
        env.update(extra_env)

    proc = subprocess.Popen(
        [BINARY_PATH],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return proc, socket_path


def terminate_cmux(proc, socket_path=None):
    """Gracefully terminate a cmux process and clean up the socket."""
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=3)
    if socket_path:
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass


def wait_for_atspi_app(app_name, timeout=15.0):
    """Poll the AT-SPI tree until the named application node appears."""
    from dogtail.tree import root

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


def wait_for_atspi_app_gone(app_name, timeout=10.0):
    """Poll the AT-SPI tree until the named application node disappears."""
    from dogtail.tree import root

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            node = root.application(app_name)
            if node is None:
                return True
        except Exception:
            return True
        time.sleep(0.3)
    return False


# ---------------------------------------------------------------------------
# File-based JSON data helpers (for tests using data-path patterns)
# ---------------------------------------------------------------------------


def load_json(path):
    """Load and return a JSON dict from *path*, or ``None`` if unavailable."""
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def wait_for_json(path, timeout=12):
    """Block until a valid JSON file appears at *path*."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = load_json(path)
        if data is not None:
            return data
        time.sleep(0.3)
    return None


def wait_for_json_key(path, key, value, timeout=12):
    """Block until *path* contains JSON where ``data[key] == value``."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = load_json(path)
        if data is not None and data.get(key) == value:
            return data
        time.sleep(0.3)
    return None


def wait_for_file_exists(path, timeout=5):
    """Block until a file appears at *path*."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return True
        time.sleep(0.2)
    return False


def wait_for_file_absent(path, timeout=5):
    """Block until no file exists at *path*."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not os.path.exists(path):
            return True
        time.sleep(0.2)
    return False
