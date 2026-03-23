#!/usr/bin/env python3
"""Basic socket connectivity and system commands."""

import sys
sys.path.insert(0, ".")
from cmux_client import CmuxClient


def test_ping():
    c = CmuxClient()
    assert c.ping() == "pong", "ping should return pong"
    print("  PASS: ping")


def test_version():
    c = CmuxClient()
    v = c.version()
    assert len(v) > 0, "version should be non-empty"
    assert "." in v, f"version should contain a dot: {v}"
    print(f"  PASS: version = {v}")


def test_identify():
    c = CmuxClient()
    ident = c.identify()
    assert "cmux-linux" in ident, f"identify should contain cmux-linux: {ident}"
    assert "gtk" in ident, f"identify should contain gtk: {ident}"
    print(f"  PASS: identify = {ident}")


def test_capabilities():
    c = CmuxClient()
    caps = c.capabilities()
    for feature in ["v1", "v2", "send", "notifications", "workspaces"]:
        assert feature in caps, f"capabilities should include {feature}: {caps}"
    print(f"  PASS: capabilities")


def test_v2_ping():
    c = CmuxClient()
    r = c.send_v2("system.ping")
    assert r["ok"] is True, f"V2 ping should succeed: {r}"
    assert r["result"] == "pong", f"V2 ping result should be pong: {r}"
    print("  PASS: V2 system.ping")


def test_v2_version():
    c = CmuxClient()
    r = c.send_v2("system.version")
    assert r["ok"] is True, f"V2 version should succeed: {r}"
    print(f"  PASS: V2 system.version = {r['result']}")


def test_v2_capabilities():
    c = CmuxClient()
    r = c.send_v2("system.capabilities")
    assert r["ok"] is True, f"V2 capabilities should succeed: {r}"
    assert "v1" in r["result"], f"V2 caps should include v1: {r}"
    print("  PASS: V2 system.capabilities")


def test_v2_identify():
    c = CmuxClient()
    r = c.send_v2("system.identify")
    assert r["ok"] is True, f"V2 identify should succeed: {r}"
    assert r["result"]["app"] == "cmux-linux", f"app should be cmux-linux: {r}"
    assert r["result"]["platform"] == "linux", f"platform should be linux: {r}"
    print("  PASS: V2 system.identify")


def test_v2_unknown_method():
    c = CmuxClient()
    r = c.send_v2("nonexistent.method")
    assert r["ok"] is False, "unknown method should fail"
    assert r["error"]["code"] == "method_not_found", f"error code: {r}"
    print("  PASS: V2 unknown method returns error")


if __name__ == "__main__":
    print("=== test_socket_basic ===")
    test_ping()
    test_version()
    test_identify()
    test_capabilities()
    test_v2_ping()
    test_v2_version()
    test_v2_capabilities()
    test_v2_identify()
    test_v2_unknown_method()
    print("ALL PASSED")
