//! Accept loop for the cmux socket server.
//!
//! Runs on a dedicated background thread, blocking on accept() and spawning
//! a new handler thread per client connection. Implements exponential backoff
//! and automatic rearm on persistent failures.
//!
//! Matches macOS TerminalController.acceptLoop (line 1290).

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const access = @import("access.zig");
const client_handler = @import("client_handler.zig");
const dispatch = @import("dispatch.zig");

const log = std.log.scoped(.cmux_accept);

/// Backoff constants matching macOS reference.
pub const base_backoff_ms: u32 = 10;
pub const max_backoff_ms: u32 = 5_000;
pub const rearm_threshold: u32 = 50;
pub const listen_backlog: c_int = 128;

/// Error classification for accept failures.
const ErrorClass = enum {
    /// Transient — retry immediately (EINTR, ECONNABORTED, EAGAIN).
    immediate_retry,
    /// Resource pressure — back off (EMFILE, ENFILE, ENOBUFS, ENOMEM).
    resource_pressure,
    /// Fatal — rearm the listener (EBADF, EINVAL, ENOTSOCK).
    fatal,
    /// Other — retry with exponential backoff.
    backoff,
};

/// Recovery action after a classified error.
const Recovery = union(enum) {
    retry,
    resume_after: u32, // ms
    rearm_after: u32, // ms
};

/// Opaque server reference. The Server passes itself as `*anyopaque` to avoid
/// circular imports. The accept loop calls back through function pointers.
pub const ServerCallbacks = struct {
    /// Check if the accept loop should continue running.
    should_continue: *const fn (ctx: *anyopaque, generation: u64) bool,
    /// Notify server that accept loop has exited.
    on_loop_exit: *const fn (ctx: *anyopaque, generation: u64) void,
    /// Get the dispatch function for client handlers.
    dispatch_fn: client_handler.DispatchFn,
    /// Access mode for client checks.
    access_mode: access.Mode,
    /// Server's own PID.
    my_pid: posix.pid_t,
    /// Allocator for client handler threads.
    alloc: Allocator,
    /// Opaque server pointer.
    ctx: *anyopaque,
};

/// Entry point for the accept loop thread.
pub fn run(callbacks: *const ServerCallbacks, listener_fd: posix.socket_t, generation: u64) void {
    defer callbacks.on_loop_exit(callbacks.ctx, generation);

    log.info("accept loop started (gen={d}, fd={d})", .{ generation, listener_fd });

    var consecutive_failures: u32 = 0;

    while (callbacks.should_continue(callbacks.ctx, generation)) {
        const result = doAccept(listener_fd);

        switch (result) {
            .accepted => |accepted| {
                consecutive_failures = 0;
                spawnClientHandler(callbacks, accepted.fd, accepted.peer_cred);
            },
            .err => |errno| {
                consecutive_failures += 1;
                const class = classifyError(errno);
                const recovery = determineRecovery(class, consecutive_failures);

                switch (recovery) {
                    .retry => continue,
                    .resume_after => |ms| {
                        log.warn("accept backoff: {d}ms (failures={d}, errno={d})", .{ ms, consecutive_failures, errno });
                        std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
                    },
                    .rearm_after => |ms| {
                        log.err("accept rearm scheduled after {d}ms (failures={d})", .{ ms, consecutive_failures });
                        std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
                        // The server's on_loop_exit will handle cleanup.
                        // A rearm would restart the listener via the server.
                        return;
                    },
                }
            },
        }
    }

    log.info("accept loop exiting (gen={d})", .{generation});
}

const AcceptResult = union(enum) {
    accepted: struct {
        fd: posix.socket_t,
        peer_cred: ?access.Ucred,
    },
    err: u16, // errno value
};

fn doAccept(listener_fd: posix.socket_t) AcceptResult {
    var addr: std.posix.sockaddr.un = undefined;
    var addr_len: posix.socklen_t = @sizeOf(@TypeOf(addr));

    const fd = posix.accept(listener_fd, @ptrCast(&addr), &addr_len, posix.SOCK.CLOEXEC) catch |e| {
        return .{ .err = @intFromEnum(errnoFromAcceptError(e)) };
    };

    // Get peer credentials immediately (before client can disconnect).
    // Captures PID, UID, and GID for access control checks.
    const peer_cred: ?access.Ucred = access.getPeerCred(fd);

    return .{ .accepted = .{ .fd = fd, .peer_cred = peer_cred } };
}

fn spawnClientHandler(callbacks: *const ServerCallbacks, client_fd: posix.socket_t, peer_cred: ?access.Ucred) void {
    const config = client_handler.Config{
        .server = callbacks.ctx,
        .dispatch_fn = callbacks.dispatch_fn,
        .client_fd = client_fd,
        .peer_cred = peer_cred,
        .access_mode = callbacks.access_mode,
        .my_pid = callbacks.my_pid,
        .alloc = callbacks.alloc,
    };

    const thread = std.Thread.spawn(.{}, client_handler.handleClient, .{config}) catch |e| {
        log.err("failed to spawn client handler thread: {}", .{e});
        posix.close(client_fd);
        return;
    };
    thread.detach();
}

fn classifyError(errno: u16) ErrorClass {
    return switch (@as(std.os.linux.E, @enumFromInt(errno))) {
        .INTR, .CONNABORTED, .AGAIN => .immediate_retry,
        .MFILE, .NFILE, .NOBUFS, .NOMEM => .resource_pressure,
        .BADF, .INVAL, .NOTSOCK => .fatal,
        else => .backoff,
    };
}

fn determineRecovery(class: ErrorClass, consecutive_failures: u32) Recovery {
    switch (class) {
        .immediate_retry => return .retry,
        .fatal => return .{ .rearm_after = max_backoff_ms },
        .resource_pressure, .backoff => {
            if (consecutive_failures >= rearm_threshold) {
                return .{ .rearm_after = max_backoff_ms };
            }
            // Exponential backoff: base * 2^(log2(failures)), capped.
            const shift: u5 = @intCast(@min(consecutive_failures, 20));
            const delay = @min(base_backoff_ms << shift, max_backoff_ms);
            return .{ .resume_after = delay };
        },
    }
}

fn errnoFromAcceptError(e: posix.AcceptError) std.os.linux.E {
    return switch (e) {
        error.ConnectionAborted => .CONNABORTED,
        error.ProcessFdQuotaExceeded => .MFILE,
        error.SystemFdQuotaExceeded => .NFILE,
        error.SystemResources => .NOMEM,
        error.SocketNotListening => .INVAL,
        else => .INVAL,
    };
}

// --- Tests ---

test "classifyError" {
    try std.testing.expectEqual(ErrorClass.immediate_retry, classifyError(@intFromEnum(std.os.linux.E.INTR)));
    try std.testing.expectEqual(ErrorClass.immediate_retry, classifyError(@intFromEnum(std.os.linux.E.CONNABORTED)));
    try std.testing.expectEqual(ErrorClass.resource_pressure, classifyError(@intFromEnum(std.os.linux.E.MFILE)));
    try std.testing.expectEqual(ErrorClass.fatal, classifyError(@intFromEnum(std.os.linux.E.BADF)));
    try std.testing.expectEqual(ErrorClass.backoff, classifyError(@intFromEnum(std.os.linux.E.PERM)));
}

test "determineRecovery immediate" {
    const r = determineRecovery(.immediate_retry, 5);
    try std.testing.expectEqual(Recovery.retry, r);
}

test "determineRecovery fatal triggers rearm" {
    const r = determineRecovery(.fatal, 1);
    switch (r) {
        .rearm_after => |ms| try std.testing.expectEqual(max_backoff_ms, ms),
        else => return error.TestUnexpectedResult,
    }
}

test "determineRecovery backoff exponential" {
    const r1 = determineRecovery(.resource_pressure, 1);
    switch (r1) {
        .resume_after => |ms| try std.testing.expect(ms >= base_backoff_ms),
        else => return error.TestUnexpectedResult,
    }

    const r2 = determineRecovery(.resource_pressure, 3);
    switch (r2) {
        .resume_after => |ms| try std.testing.expect(ms > base_backoff_ms),
        else => return error.TestUnexpectedResult,
    }
}

test "determineRecovery rearm threshold" {
    const r = determineRecovery(.backoff, rearm_threshold);
    switch (r) {
        .rearm_after => {},
        else => return error.TestUnexpectedResult,
    }
}
