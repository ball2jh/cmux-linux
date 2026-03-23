#!/usr/bin/env python3
"""Status, progress, and log tests."""

import sys
sys.path.insert(0, ".")
from cmux_client import CmuxClient


def test_set_status():
    c = CmuxClient()
    result = c.set_status("branch", "main")
    assert result == "ok"
    print("  PASS: set-status")


def test_list_status():
    c = CmuxClient()
    c.set_status("build", "passing")
    status = c.list_status()
    assert "build" in status and "passing" in status, f"status not found: {status}"
    print("  PASS: list-status")


def test_clear_status():
    c = CmuxClient()
    c.set_status("temp", "value")
    c.clear_status("temp")
    status = c.list_status()
    assert "temp" not in status, f"temp should be cleared: {status}"
    print("  PASS: clear-status")


def test_set_progress():
    c = CmuxClient()
    result = c.set_progress("deploy", "75")
    assert result == "ok"
    print("  PASS: set-progress")


def test_log():
    c = CmuxClient()
    result = c.log("Build started")
    assert result == "ok"
    print("  PASS: log")


def test_list_log():
    c = CmuxClient()
    c.log("Log entry test")
    logs = c.list_log()
    assert "Log entry test" in logs, f"log entry not found: {logs}"
    print("  PASS: list-log")


def test_sidebar_state():
    c = CmuxClient()
    state = c.sidebar_state()
    assert "workspaces" in state, f"should have workspaces: {state}"
    assert "ports" in state, f"should have ports: {state}"
    assert "unread_notifications" in state, f"should have unread: {state}"
    print(f"  PASS: sidebar-state (workspaces={len(state['workspaces'])}, ports={len(state['ports'])})")


def test_tree():
    c = CmuxClient()
    tree = c.tree()
    assert "cmux" in tree, f"tree should mention cmux: {tree}"
    assert "workspace" in tree.lower(), f"tree should show workspaces: {tree}"
    print("  PASS: tree")


if __name__ == "__main__":
    print("=== test_status ===")
    test_set_status()
    test_list_status()
    test_clear_status()
    test_set_progress()
    test_log()
    test_list_log()
    test_sidebar_state()
    test_tree()
    print("ALL PASSED")
