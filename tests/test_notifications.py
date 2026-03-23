#!/usr/bin/env python3
"""Notification system tests."""

import sys
sys.path.insert(0, ".")
from cmux_client import CmuxClient


def test_notify():
    c = CmuxClient()
    result = c.notify("Test", "body")
    assert result == "ok", f"notify should return ok: {result}"
    print("  PASS: notify")


def test_list_notifications():
    c = CmuxClient()
    c.notify("ListTest", "content")
    notifs = c.list_notifications()
    assert "ListTest" in notifs, f"notification should appear in list: {notifs}"
    print("  PASS: list-notifications")


def test_clear_notifications():
    c = CmuxClient()
    c.notify("ClearTest")
    c.clear_notifications()
    notifs = c.list_notifications()
    assert notifs == "" or "ClearTest" not in notifs, f"should be cleared: {notifs}"
    print("  PASS: clear-notifications")


def test_v2_notification_create():
    c = CmuxClient()
    r = c.send_v2("notification.create", {"title": "V2Test", "body": "hello"})
    assert r["ok"] is True
    print("  PASS: V2 notification.create")


def test_v2_notification_unread_count():
    c = CmuxClient()
    c.clear_notifications()
    c.send_v2("notification.create", {"title": "Unread1"})
    c.send_v2("notification.create", {"title": "Unread2"})
    r = c.send_v2("notification.unread_count")
    assert r["ok"] is True
    assert r["result"] >= 2, f"should have at least 2 unread: {r}"
    print(f"  PASS: V2 notification.unread_count = {r['result']}")


def test_v2_notification_list():
    c = CmuxClient()
    r = c.send_v2("notification.list")
    assert r["ok"] is True
    assert isinstance(r["result"], list)
    print(f"  PASS: V2 notification.list ({len(r['result'])} items)")


if __name__ == "__main__":
    print("=== test_notifications ===")
    test_notify()
    test_list_notifications()
    test_clear_notifications()
    test_v2_notification_create()
    test_v2_notification_unread_count()
    test_v2_notification_list()
    print("ALL PASSED")
