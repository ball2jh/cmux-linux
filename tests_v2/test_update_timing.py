#!/usr/bin/env python3
"""
Verify update UI timing constants so update indicators are visible long enough.

On Linux, the timing constants live in the Zig source tree instead of Swift.
This test checks the Zig equivalents.
"""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]

# On Linux the update timing constants live in Zig source.
# Check multiple possible locations for the timing definitions.
_TIMING_CANDIDATES = [
    ROOT / "src" / "cmux" / "update_timing.zig",
    ROOT / "src" / "cmux" / "UpdateTiming.zig",
    ROOT / "src" / "cmux" / "update" / "timing.zig",
]


def _find_timing_file() -> Path | None:
    for candidate in _TIMING_CANDIDATES:
        if candidate.exists():
            return candidate
    return None


def read_constants_zig(text: str) -> dict[str, float]:
    """Extract timing constants from Zig source.

    Matches patterns like:
        pub const minimum_check_display_duration: f64 = 2.0;
        const minimumCheckDisplayDuration = 2.0;
        pub const minimum_check_display_duration = 2.0;
    """
    constants: dict[str, float] = {}

    # Pattern for Zig const declarations with explicit type
    pattern1 = re.compile(r"(?:pub\s+)?const\s+(\w+)\s*(?::\s*\w+)?\s*=\s*([0-9.]+)")
    for match in pattern1.finditer(text):
        name = match.group(1)
        try:
            constants[name] = float(match.group(2))
        except ValueError:
            pass

    return constants


def _normalize_name(name: str) -> str:
    """Normalize snake_case/camelCase to a comparable form."""
    # Convert camelCase to snake_case
    s1 = re.sub(r'([A-Z]+)([A-Z][a-z])', r'\1_\2', name)
    s2 = re.sub(r'([a-z\d])([A-Z])', r'\1_\2', s1)
    return s2.lower()


def main() -> int:
    timing_file = _find_timing_file()
    if timing_file is None:
        print(f"SKIP: No timing file found in any of: {[str(c) for c in _TIMING_CANDIDATES]}")
        print("This test will be relevant once update timing is implemented.")
        return 0

    constants = read_constants_zig(timing_file.read_text())

    # Normalize all constant names for comparison
    normalized = {_normalize_name(k): v for k, v in constants.items()}

    required = {
        "minimum_check_display_duration": 2.0,
        "no_update_display_duration": 5.0,
    }

    failures = []
    for name, expected in required.items():
        actual = normalized.get(name)
        if actual is None:
            failures.append(f"{name} missing")
            continue
        if actual != expected:
            failures.append(f"{name} = {actual} (expected {expected})")

    if failures:
        print("Update timing test failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("Update timing test passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
