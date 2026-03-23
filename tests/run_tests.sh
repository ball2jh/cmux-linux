#!/bin/bash
# Run all cmux-linux socket tests.
# Usage: ./run_tests.sh [cmux-binary-path]
#
# Starts cmux, waits for the socket, runs all tests, then kills cmux.

set -e

CMUX="${1:-cmux}"
SOCKET="/tmp/cmux-$(id -u).sock"

echo "=== cmux-linux test runner ==="
echo "Binary: $CMUX"
echo "Socket: $SOCKET"

# Clean up old socket
rm -f "$SOCKET"

# Start cmux in background
$CMUX &>/tmp/cmux-test-runner.log &
CMUX_PID=$!
echo "Started cmux (PID=$CMUX_PID)"

# Wait for socket to appear
for i in $(seq 1 30); do
    if [ -S "$SOCKET" ]; then
        echo "Socket ready after ${i}s"
        break
    fi
    sleep 1
done

if [ ! -S "$SOCKET" ]; then
    echo "ERROR: Socket did not appear after 30s"
    kill $CMUX_PID 2>/dev/null
    exit 1
fi

# Run tests
cd "$(dirname "$0")"
PASSED=0
FAILED=0
ERRORS=""

for test_file in test_*.py; do
    echo ""
    echo "--- Running $test_file ---"
    if python3 "$test_file" 2>&1; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        ERRORS="$ERRORS\n  FAIL: $test_file"
    fi
done

# Clean up
echo ""
echo "--- Stopping cmux ---"
kill $CMUX_PID 2>/dev/null
wait $CMUX_PID 2>/dev/null || true

# Summary
echo ""
echo "=== Test Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
if [ $FAILED -gt 0 ]; then
    echo -e "Failures:$ERRORS"
    exit 1
else
    echo "ALL TEST SUITES PASSED"
fi
