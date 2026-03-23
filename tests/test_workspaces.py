#!/usr/bin/env python3
"""Workspace management tests."""

import sys
sys.path.insert(0, ".")
from cmux_client import CmuxClient


def test_list_workspaces():
    c = CmuxClient()
    ws = c.list_workspaces()
    assert "default" in ws, f"should have default workspace: {ws}"
    print("  PASS: list-workspaces")


def test_new_workspace():
    c = CmuxClient()
    ws_id = c.new_workspace("test-ws")
    assert ws_id.isdigit(), f"new-workspace should return numeric ID: {ws_id}"
    ws = c.list_workspaces()
    assert "test-ws" in ws, f"new workspace should appear in list: {ws}"
    print(f"  PASS: new-workspace (id={ws_id})")


def test_select_workspace():
    c = CmuxClient()
    ws_id = c.new_workspace("select-test")
    result = c.select_workspace(ws_id)
    assert result == "ok", f"select-workspace should return ok: {result}"
    current = c.current_workspace()
    assert current == ws_id, f"current should be {ws_id}: {current}"
    print("  PASS: select-workspace")


def test_rename_workspace():
    c = CmuxClient()
    ws_id = c.new_workspace("rename-me")
    result = c.rename_workspace(ws_id, "renamed")
    assert result == "ok", f"rename should return ok: {result}"
    ws = c.list_workspaces()
    assert "renamed" in ws, f"renamed workspace should appear: {ws}"
    print("  PASS: rename-workspace")


def test_close_workspace():
    c = CmuxClient()
    ws_id = c.new_workspace("close-me")
    result = c.close_workspace(ws_id)
    assert result == "ok", f"close should return ok: {result}"
    ws = c.list_workspaces()
    assert "close-me" not in ws, f"closed workspace should not appear: {ws}"
    print("  PASS: close-workspace")


def test_current_workspace():
    c = CmuxClient()
    current = c.current_workspace()
    assert current.isdigit(), f"current-workspace should return numeric ID: {current}"
    print(f"  PASS: current-workspace (id={current})")


def test_v2_workspace_list():
    c = CmuxClient()
    r = c.send_v2("workspace.list")
    assert r["ok"] is True
    assert isinstance(r["result"], list), f"result should be array: {r}"
    assert len(r["result"]) > 0, "should have at least one workspace"
    assert "name" in r["result"][0], f"workspace should have name: {r}"
    print("  PASS: V2 workspace.list")


def test_v2_workspace_create():
    c = CmuxClient()
    r = c.send_v2("workspace.create", {"name": "v2-test"})
    assert r["ok"] is True
    assert isinstance(r["result"], int), f"should return workspace ID: {r}"
    print(f"  PASS: V2 workspace.create (id={r['result']})")


def test_v2_workspace_action():
    c = CmuxClient()
    # Create a second workspace so we can navigate
    c.send_v2("workspace.create", {"name": "action-test"})
    r = c.send_v2("workspace.action", {"action": "next"})
    assert r["ok"] is True
    print("  PASS: V2 workspace.action")


if __name__ == "__main__":
    print("=== test_workspaces ===")
    test_list_workspaces()
    test_new_workspace()
    test_select_workspace()
    test_rename_workspace()
    test_close_workspace()
    test_current_workspace()
    test_v2_workspace_list()
    test_v2_workspace_create()
    test_v2_workspace_action()
    print("ALL PASSED")
