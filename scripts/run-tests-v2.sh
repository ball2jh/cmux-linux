#!/usr/bin/env bash
set -euo pipefail

# Integration test runner for cmux-linux.
# Builds cmux, launches it, and runs each tests_v2/test_*.py file.

cd "$(dirname "$0")/.."

CMUX_BIN="./zig-out/bin/cmux"
RUN_TAG="tests-v2"
CMUX_PID=""

echo "== build =="
zig build -Dcmux=true -Dversion-string="0.1.0-test"

if [ ! -x "$CMUX_BIN" ]; then
  echo "ERROR: cmux binary not found at $CMUX_BIN" >&2
  exit 1
fi

cleanup() {
  if [ -n "$CMUX_PID" ] && kill -0 "$CMUX_PID" 2>/dev/null; then
    kill "$CMUX_PID" || true
    wait "$CMUX_PID" 2>/dev/null || true
  fi
  rm -f /tmp/cmux*.sock || true
  CMUX_PID=""
}

launch_and_wait() {
  cleanup

  # Wait briefly for the previous instance to fully terminate.
  for _ in $(seq 1 50); do
    pgrep -x cmux >/dev/null 2>&1 || break
    sleep 0.1
  done

  # Launch with test mode enabled.
  CMUX_TAG="$RUN_TAG" CMUX_UI_TEST_MODE=1 "$CMUX_BIN" >/dev/null 2>&1 &
  CMUX_PID=$!

  SOCK=""
  for _ in $(seq 1 120); do
    SOCK=$(ls -t /tmp/cmux-debug*.sock /tmp/cmux*.sock 2>/dev/null | head -1 || true)
    if [ -n "$SOCK" ] && [ -S "$SOCK" ]; then
      break
    fi
    sleep 0.25
  done

  if [ -z "$SOCK" ] || [ ! -S "$SOCK" ]; then
    echo "ERROR: Socket not ready (looked for /tmp/cmux*.sock)" >&2
    exit 1
  fi
  export CMUX_SOCKET_PATH="$SOCK"
  export CMUX_SOCKET="$SOCK"

  echo "== wait ready =="
  python3 - <<'PY'
import time
import os
import sys

sys.path.insert(0, os.path.join(os.getcwd(), "tests_v2"))
from cmux import cmux  # type: ignore

deadline = time.time() + 30.0
last = None
client = None
while time.time() < deadline:
    try:
        client = cmux()
        client.connect()
        break
    except Exception as e:
        last = e
        time.sleep(0.1)
else:
    raise SystemExit(f"ERROR: Socket path exists but connect keeps failing: {last}")

workspace_ready = False
while time.time() < deadline:
    try:
        _ = client.current_workspace()
        workspace_ready = True
        break
    except Exception as e:
        last = e
        time.sleep(0.1)

if not workspace_ready:
    print(f"WARN: continuing without workspace-ready state: {last}")

# Use a fresh connection to avoid stale-listener races where the first connection succeeds but
# immediate reconnects fail with ECONNREFUSED.
probe_deadline = time.time() + 10.0
while time.time() < probe_deadline:
    probe = None
    try:
        probe = cmux()
        probe.connect()
        if not probe.ping():
            raise RuntimeError("ping returned false")
        print("ready")
        break
    except Exception as e:
        last = e
        time.sleep(0.1)
    finally:
        if probe is not None:
            try:
                probe.close()
            except Exception:
                pass
else:
    raise SystemExit(f"ERROR: Ready-check reconnect/ping failed: {last}")

# Force a single fresh workspace so startup-state restoration doesn't leave tests
# with extra pre-existing workspaces that make ordering-dependent tests flaky.
bootstrap_last = None
for _ in range(3):
    try:
        existing_ids = []
        try:
            existing_ids = [row[1] for row in client.list_workspaces() if len(row) >= 2]
        except Exception:
            existing_ids = []

        ws_id = client.new_workspace()
        client.select_workspace(ws_id)

        for old_id in existing_ids:
            if old_id == ws_id:
                continue
            try:
                client.close_workspace(old_id)
            except Exception:
                pass

        surfaces = client.list_surfaces()
        if not surfaces:
            raise RuntimeError("new workspace has no surfaces")
        client.focus_surface(0)
        break
    except Exception as e:
        bootstrap_last = e
        time.sleep(0.2)
else:
    raise SystemExit(f"ERROR: Failed to bootstrap fresh terminal workspace: {bootstrap_last}")

if client is not None:
    try:
        client.close()
    except Exception:
        pass
PY
}

run_test_with_retry() {
  local f="$1"
  local attempts=3
  local n=1

  while [ "$n" -le "$attempts" ]; do
    echo "RUN  $f (attempt $n/$attempts)"
    if python3 "$f"; then
      return 0
    fi

    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi

    echo "WARN: attempt $n failed for $f; relaunching and retrying" >&2
    echo "== relaunch (retry) =="
    launch_and_wait
    n=$((n + 1))
  done

  return 1
}

# Ensure cleanup runs on exit.
trap cleanup EXIT

echo "== tests (v2) =="
fail=0
for f in tests_v2/test_*.py; do
  [ -f "$f" ] || continue

  base=$(basename "$f")

  echo "== launch ($base) =="
  launch_and_wait
  if ! run_test_with_retry "$f"; then
    echo "FAIL $f" >&2
    fail=1
    break
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "== all tests passed =="
else
  echo "== tests failed =="
fi

exit "$fail"
