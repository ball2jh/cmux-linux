//! Session restore policy — conditions for restoring on startup.
//!
//! Matches macOS SessionRestorePolicy: skip restore when disabled via
//! environment, running under tests, or launched with explicit arguments.

const std = @import("std");

/// Check whether session restore should be attempted at startup.
pub fn shouldAttemptRestore() bool {
    // std.os.argv is [][*:0]u8, coerce element type for the test-friendly signature
    const argv_ptr: [*]const [*:0]const u8 = @ptrCast(std.os.argv.ptr);
    return shouldAttemptRestoreWith(argv_ptr[0..std.os.argv.len]);
}

/// Testable variant that accepts explicit arguments.
pub fn shouldAttemptRestoreWith(argv: []const [*:0]const u8) bool {
    // Env var opt-out
    if (envEql("CMUX_DISABLE_SESSION_RESTORE", "1")) return false;

    // Running under automated tests
    if (isRunningUnderAutomatedTests()) return false;

    // Explicit launch arguments (beyond the binary name itself)
    if (argv.len > 1) return false;

    return true;
}

/// Check whether we appear to be running under a test harness.
pub fn isRunningUnderAutomatedTests() bool {
    if (envEql("CMUX_UI_TEST_MODE", "1")) return true;

    // Check for any CMUX_UI_TEST_* env var
    const env = std.os.environ;
    for (env) |entry| {
        const kv = std.mem.span(entry);
        if (std.mem.startsWith(u8, kv, "CMUX_UI_TEST_")) return true;
    }

    return false;
}

fn envEql(key: []const u8, expected: []const u8) bool {
    const val = std.posix.getenv(key) orelse return false;
    return std.mem.eql(u8, val, expected);
}

// --- Tests ---

test "shouldAttemptRestoreWith: no args returns true" {
    const argv = [_][*:0]const u8{"cmux"};
    try std.testing.expect(shouldAttemptRestoreWith(&argv));
}

test "shouldAttemptRestoreWith: explicit args returns false" {
    const argv = [_][*:0]const u8{ "cmux", "--some-flag" };
    try std.testing.expect(!shouldAttemptRestoreWith(&argv));
}
