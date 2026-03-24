//! Blocking process runner for SSH/SCP commands.
//!
//! Spawns a child process, captures stdout/stderr, and enforces a timeout.
//! Used for platform probing, SCP uploads, and one-shot SSH commands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const log = std.log.scoped(.cmux_process);

pub const ProcessResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    timed_out: bool,
};

/// Run a command and capture its output. Blocks until the command completes
/// or the timeout expires.
///
/// On timeout, sends SIGKILL to the child and returns with timed_out=true.
/// Caller owns the returned stdout/stderr slices and must free them.
pub fn run(
    alloc: Allocator,
    argv: []const []const u8,
    timeout_ms: u32,
) !ProcessResult {
    if (argv.len == 0) return error.InvalidArgument;

    var child = std.process.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    // Capture output with timeout via a thread.
    var capture = CaptureState{
        .alloc = alloc,
        .child = &child,
    };

    const reader_thread = try std.Thread.spawn(.{}, captureOutputThread, .{&capture});

    // Wait with timeout.
    const timed_out = timedWait(reader_thread, timeout_ms);

    if (timed_out) {
        // Kill the child process.
        _ = child.kill() catch {};
        reader_thread.join(); // Thread will finish after child dies.
    } else {
        reader_thread.join();
    }

    // Get exit code.
    const term = child.wait() catch |err| {
        log.warn("failed to wait for child: {}", .{err});
        return .{
            .stdout = capture.stdout orelse "",
            .stderr = capture.stderr orelse "",
            .exit_code = 255,
            .timed_out = timed_out,
        };
    };

    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        .signal => 128,
        .stopped => 127,
        .unknown => 255,
    };

    return .{
        .stdout = capture.stdout orelse "",
        .stderr = capture.stderr orelse "",
        .exit_code = exit_code,
        .timed_out = timed_out,
    };
}

/// Free stdout and stderr from a ProcessResult.
pub fn freeResult(alloc: Allocator, result: *ProcessResult) void {
    if (result.stdout.len > 0) alloc.free(result.stdout);
    if (result.stderr.len > 0) alloc.free(result.stderr);
    result.stdout = "";
    result.stderr = "";
}

// -----------------------------------------------------------------------
// Internals
// -----------------------------------------------------------------------

const CaptureState = struct {
    alloc: Allocator,
    child: *std.process.Child,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
};

fn captureOutputThread(state: *CaptureState) void {
    const max_output: usize = 256 * 1024; // 256 KiB max capture per stream.

    if (state.child.stdout) |stdout| {
        state.stdout = stdout.reader().readAllAlloc(state.alloc, max_output) catch "";
    }
    if (state.child.stderr) |stderr| {
        state.stderr = stderr.reader().readAllAlloc(state.alloc, max_output) catch "";
    }
}

/// Wait for a thread to complete with a timeout. Returns true if timed out.
fn timedWait(thread: std.Thread, timeout_ms: u32) bool {
    // Use a ResetEvent as a signaling mechanism.
    var done = std.Thread.ResetEvent{};
    const waiter = std.Thread.spawn(.{}, struct {
        fn run(t: std.Thread, event: *std.Thread.ResetEvent) void {
            t.join();
            event.set();
        }
    }.run, .{ thread, &done }) catch return false;
    _ = waiter;

    const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;
    done.timedWait(timeout_ns) catch return true;
    return false;
}
