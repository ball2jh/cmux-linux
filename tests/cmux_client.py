"""
cmux socket client library for testing.
Connects to the cmux Unix socket and sends V1/V2 commands.
"""

import socket
import json
import os
import time


class CmuxClient:
    """Client for the cmux socket control API."""

    def __init__(self, socket_path=None, timeout=5.0):
        if socket_path is None:
            env_path = os.environ.get("CMUX_SOCKET_PATH") or os.environ.get("CMUX_SOCKET")
            if env_path:
                socket_path = env_path
            else:
                uid = os.getuid()
                socket_path = f"/tmp/cmux-{uid}.sock"
        self.socket_path = socket_path
        self.timeout = timeout

    def _connect(self):
        """Create a new socket connection."""
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.socket_path)
        return s

    def send_v1(self, command, args=""):
        """Send a V1 text command and return the response."""
        s = self._connect()
        try:
            line = f"{command} {args}".strip() + "\n" if args else f"{command}\n"
            s.send(line.encode())
            time.sleep(0.3)
            data = s.recv(65536).decode().strip()
            return data
        finally:
            s.close()

    def send_v2(self, method, params=None):
        """Send a V2 JSON-RPC request and return parsed response."""
        s = self._connect()
        try:
            req = {"id": "1", "method": method}
            if params:
                req["params"] = params
            s.send((json.dumps(req) + "\n").encode())
            time.sleep(0.3)
            data = s.recv(65536).decode().strip()
            return json.loads(data)
        finally:
            s.close()

    # --- Convenience methods ---

    def ping(self):
        return self.send_v1("ping")

    def version(self):
        return self.send_v1("version")

    def identify(self):
        return self.send_v1("identify")

    def capabilities(self):
        return self.send_v1("capabilities")

    def send(self, text):
        return self.send_v1("send", text)

    def send_key(self, key):
        return self.send_v1("send-key", key)

    def read_screen(self):
        return self.send_v1("read-screen")

    def new_window(self):
        return self.send_v1("new-window")

    def list_windows(self):
        return self.send_v1("list-windows")

    def current_window(self):
        return self.send_v1("current-window")

    def new_tab(self):
        return self.send_v1("new-tab")

    def new_split(self, direction="right"):
        return self.send_v1("new-split", direction)

    def list_panes(self):
        return self.send_v1("list-panes")

    def focus_pane(self, direction="next"):
        return self.send_v1("focus-pane", direction)

    def list_workspaces(self):
        return self.send_v1("list-workspaces")

    def new_workspace(self, name="workspace"):
        return self.send_v1("new-workspace", name)

    def select_workspace(self, ws_id):
        return self.send_v1("select-workspace", str(ws_id))

    def current_workspace(self):
        return self.send_v1("current-workspace")

    def close_workspace(self, ws_id):
        return self.send_v1("close-workspace", str(ws_id))

    def rename_workspace(self, ws_id, name):
        return self.send_v1(f"rename-workspace", f"{ws_id} {name}")

    def notify(self, title, body=""):
        return self.send_v1("notify", f"{title} {body}".strip())

    def list_notifications(self):
        return self.send_v1("list-notifications")

    def clear_notifications(self):
        return self.send_v1("clear-notifications")

    def set_status(self, key, value):
        return self.send_v1("set-status", f"{key} {value}")

    def list_status(self):
        return self.send_v1("list-status")

    def clear_status(self, key=""):
        return self.send_v1("clear-status", key)

    def set_progress(self, key, percent):
        return self.send_v1("set-progress", f"{key} {percent}")

    def log(self, message):
        return self.send_v1("log", message)

    def list_log(self):
        return self.send_v1("list-log")

    def list_ports(self):
        return self.send_v1("list-ports")

    def sidebar_state(self):
        resp = self.send_v1("sidebar-state")
        return json.loads(resp)

    def tree(self):
        return self.send_v1("tree")

    def open_browser(self, url="about:blank"):
        return self.send_v1("open-browser", url)

    def get_url(self, browser_id):
        return self.send_v1("get-url", str(browser_id))

    def quit(self):
        return self.send_v1("quit")
