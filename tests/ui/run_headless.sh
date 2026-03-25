#!/bin/bash
# Run cmux UI tests in a headless Wayland session.
#
# Uses mutter --headless as compositor + at-spi2-registryd for accessibility.
# Designed for Arch Linux / non-GDM systems (Hyprland, sway, etc).
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
    echo "  $SCRIPT_DIR/.venv/bin/pip install dogtail pytest"
    exit 1
fi

# Build cmux (skip with CMUX_SKIP_BUILD=1)
cd "$PROJECT_DIR"
if [ "${CMUX_SKIP_BUILD:-}" != "1" ]; then
    echo "Building cmux..."
    zig build -Dcmux=true -Dversion-string="0.1.0-dev"
fi

# Ensure accessibility is enabled
gsettings set org.gnome.desktop.interface toolkit-accessibility true 2>/dev/null || true

# --- Clean up stale processes from previous test runs ---
# Only kill our mutter instances, NOT the system's at-spi-bus-launcher.
pkill -9 -f 'mutter.*headless' 2>/dev/null || true
sleep 1
rm -f /run/user/$(id -u)/wayland-*.lock 2>/dev/null || true

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export GTK_A11Y=atspi

# --- Start headless Wayland compositor ---
# AT-SPI uses the system's at-spi-bus-launcher + registryd (do NOT start our own).
mutter --wayland --no-x11 --headless &>/dev/null &
MUTTER_PID=$!

# Wait for wayland socket to appear
for i in $(seq 1 20); do
    SOCK=$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | head -1)
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

# --- Cleanup on exit ---
cleanup() {
    kill $MUTTER_PID 2>/dev/null || true
    wait $MUTTER_PID 2>/dev/null || true
}
trap cleanup EXIT

# --- Run tests ---
# Use pytest-xdist for parallel execution when available.
# -n auto = one worker per CPU core. Each test launches its own cmux instance
# so they don't conflict. Use -n0 or --forked to disable parallelism.
# Use pytest-xdist for parallel execution when available.
# --dist loadfile keeps tests from the same file on one worker so they share
# the session-scoped cmux_app fixture (one cmux instance per file, not per worker).
# Use -n0 to disable parallelism for debugging.
PARALLEL_FLAG=""
if "$VENV_PYTHON" -c "import xdist" 2>/dev/null; then
    PARALLEL_FLAG="-n auto --dist loadfile"
fi
"$VENV_PYTHON" -m pytest tests/ui/ -v --tb=short $PARALLEL_FLAG "$@"
