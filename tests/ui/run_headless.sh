#!/bin/bash
# Run cmux UI tests in a headless Wayland session.
#
# Uses the user's D-Bus session bus (required for AT-SPI) + mutter --headless
# as compositor. Designed for Arch Linux / non-GDM systems.
#
# Prerequisites:
#   - at-spi2-core, mutter, python-gobject installed
#   - Accessibility enabled: gsettings set org.gnome.desktop.interface toolkit-accessibility true
#   - venv: python3 -m venv --system-site-packages tests/ui/.venv
#           tests/ui/.venv/bin/pip install dogtail pytest pytest-xdist
#
# Usage:
#   ./tests/ui/run_headless.sh                     # run all UI tests
#   ./tests/ui/run_headless.sh -k "socket"         # run matching tests
#   CMUX_SKIP_BUILD=1 ./tests/ui/run_headless.sh   # skip zig build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV_PYTHON="$SCRIPT_DIR/.venv/bin/python"

if [ ! -f "$VENV_PYTHON" ]; then
    echo "Error: venv not found. Create it:"
    echo "  python3 -m venv --system-site-packages $SCRIPT_DIR/.venv"
    echo "  $SCRIPT_DIR/.venv/bin/pip install dogtail pytest pytest-xdist"
    exit 1
fi

# Build cmux (skip with CMUX_SKIP_BUILD=1)
cd "$PROJECT_DIR"
if [ "${CMUX_SKIP_BUILD:-}" != "1" ]; then
    echo "Building cmux..."
    zig build -Dcmux=true -Dversion-string="0.1.0-dev"
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export GTK_A11Y=atspi

# Ensure accessibility is enabled
gsettings set org.gnome.desktop.interface toolkit-accessibility true 2>/dev/null || true

# --- Clean up stale mutter from previous runs ---
pkill -9 -f 'mutter.*headless' 2>/dev/null || true
sleep 0.5
rm -f "$XDG_RUNTIME_DIR"/wayland-*.lock 2>/dev/null || true

# --- Ensure AT-SPI services are running on the session bus ---
# at-spi-bus-launcher manages the AT-SPI bus. If it's not running
# (e.g. killed by a previous test run), restart it.
if ! pgrep -f at-spi-bus-launcher >/dev/null 2>&1; then
    echo "Starting AT-SPI bus launcher..."
    /usr/lib/at-spi-bus-launcher &>/dev/null &
    sleep 1
fi
if ! pgrep -f at-spi2-registryd >/dev/null 2>&1; then
    echo "Starting AT-SPI registry..."
    /usr/lib/at-spi2-registryd &>/dev/null &
    sleep 1
fi

# --- Start headless Wayland compositor ---
mutter --wayland --no-x11 --headless &>/dev/null &
MUTTER_PID=$!

# Wait for wayland socket
WAYLAND_DISPLAY=""
for i in $(seq 1 20); do
    SOCK=$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | head -1 || true)
    if [ -n "$SOCK" ]; then
        export WAYLAND_DISPLAY=$(basename "$SOCK")
        break
    fi
    sleep 0.25
done

if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "Error: mutter did not create a wayland socket within 5s"
    kill $MUTTER_PID 2>/dev/null || true
    exit 1
fi

echo "Headless session ready: WAYLAND_DISPLAY=$WAYLAND_DISPLAY (mutter=$MUTTER_PID)"

# --- Cleanup on exit (only kill mutter, leave AT-SPI alone) ---
cleanup() {
    kill $MUTTER_PID 2>/dev/null || true
    wait $MUTTER_PID 2>/dev/null || true
}
trap cleanup EXIT

# --- Run tests ---
# --dist loadfile keeps tests from the same file on one worker so they share
# the session-scoped cmux_app fixture. Use -n0 to disable parallelism.
PARALLEL_FLAG=""
if "$VENV_PYTHON" -c "import xdist" 2>/dev/null; then
    PARALLEL_FLAG="-n auto --dist loadfile"
fi
"$VENV_PYTHON" -m pytest tests/ui/ -v --tb=short $PARALLEL_FLAG "$@"
