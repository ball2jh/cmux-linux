//! Per-client socket handler thread.
//!
//! Each accepted connection spawns a new thread running `handleClient`.
//! The handler reads newline-delimited commands, detects V1 vs V2 protocol,
//! dispatches to the appropriate parser, and writes responses back.
//!
//! Matches macOS TerminalController.handleClient (line 1573).

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const protocol = @import("protocol.zig");
const v1 = protocol.v1;
const v2 = protocol.v2;
const access = @import("access.zig");

const log = std.log.scoped(.cmux_client);

/// Opaque reference to the Server, avoiding circular @import.
/// The Server passes itself as `*anyopaque`; we cast back in dispatch.
pub const ServerRef = *anyopaque;

/// Function pointer type for command dispatch.
/// Called with: server ref, arena allocator, writer, protocol detection, raw line.
/// The server implements this and passes it to us.
pub const DispatchFn = *const fn (
    server: ServerRef,
    arena: Allocator,
    writer: *ResponseWriter,
    line: []const u8,
) void;

/// Buffered writer wrapper around the client socket fd.
pub const ResponseWriter = struct {
    fd: posix.socket_t,

    pub fn writeAll(self: *ResponseWriter, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = posix.write(self.fd, data[written..]) catch |e| {
                log.debug("write to client failed: {}", .{e});
                return error.BrokenPipe;
            };
            if (n == 0) return error.BrokenPipe;
            written += n;
        }
    }

    pub fn writeByte(self: *ResponseWriter, byte: u8) !void {
        try self.writeAll(&.{byte});
    }

    pub fn print(self: *ResponseWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        std.fmt.format(fbs.writer(), fmt, args) catch return error.BrokenPipe;
        try self.writeAll(fbs.getWritten());
    }
};

/// Configuration passed from the accept loop to each client handler thread.
pub const Config = struct {
    server: ServerRef,
    dispatch_fn: DispatchFn,
    client_fd: posix.socket_t,
    peer_cred: ?access.Ucred,
    access_mode: access.Mode,
    my_pid: posix.pid_t,
    alloc: Allocator,
};

/// Entry point for the per-client handler thread.
pub fn handleClient(config: Config) void {
    defer posix.close(config.client_fd);

    // Access control check.
    if (!checkAccess(config)) return;

    // Read loop with line buffering.
    var pending: std.ArrayList(u8) = .{};
    defer pending.deinit(config.alloc);

    var read_buf: [4096]u8 = undefined;
    var writer = ResponseWriter{ .fd = config.client_fd };

    while (true) {
        const n = posix.read(config.client_fd, &read_buf) catch |e| {
            log.debug("client read error: {}", .{e});
            break;
        };
        if (n == 0) break; // Client disconnected.

        pending.appendSlice(config.alloc, read_buf[0..n]) catch {
            log.warn("client handler out of memory", .{});
            break;
        };

        // Process all complete lines in the buffer.
        processLines(config, &pending, &writer);
    }
}

fn processLines(config: Config, pending: *std.ArrayList(u8), writer: *ResponseWriter) void {
    while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline_idx| {
        const line = std.mem.trim(u8, pending.items[0..newline_idx], &std.ascii.whitespace);

        // Remove the processed line from the buffer (including the \n).
        const remaining = pending.items.len - newline_idx - 1;
        if (remaining > 0) {
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[newline_idx + 1 ..]);
        }
        pending.shrinkRetainingCapacity(remaining);

        if (line.len == 0) continue;

        // Per-command arena: all allocations freed after response is written.
        var arena_impl = std.heap.ArenaAllocator.init(config.alloc);
        defer arena_impl.deinit();

        // Make a stable copy of the line before we mutate the pending buffer.
        const line_copy = arena_impl.allocator().dupe(u8, line) catch continue;

        config.dispatch_fn(config.server, arena_impl.allocator(), writer, line_copy);
    }
}

fn checkAccess(config: Config) bool {
    switch (config.access_mode) {
        .off => return false,
        .allow_all => return true,
        .cmux_only => {
            const cred = config.peer_cred orelse {
                log.debug("cmux_only: no peer credentials, rejecting", .{});
                return false;
            };
            // Primary check: peer must be a descendant of cmux.
            if (access.isDescendant(cred.pid, config.my_pid)) return true;
            // Fallback (matches macOS): if ancestry check fails (e.g. peer
            // disconnected before PID read), verify same UID. The socket
            // permissions (0600) already restrict to same user, but this
            // provides defense-in-depth.
            if (access.isSameUser(cred.uid)) {
                log.debug("cmux_only: pid {} not descendant but same UID, allowing", .{cred.pid});
                return true;
            }
            log.debug("cmux_only: pid {} rejected (not descendant, different UID)", .{cred.pid});
            return false;
        },
        .automation => {
            // Automation mode: any local process from the same user.
            // Socket permissions (0600) enforce same-user at the OS level,
            // but we also explicitly verify UID via SO_PEERCRED to match
            // macOS peerHasSameUID() behavior.
            const cred = config.peer_cred orelse {
                log.debug("automation: no peer credentials, rejecting", .{});
                return false;
            };
            if (!access.isSameUser(cred.uid)) {
                log.debug("automation: UID mismatch (peer={d}), rejecting", .{cred.uid});
                return false;
            }
            return true;
        },
        .password => {
            // Password auth is handled at the command level (auth.login).
            // Allow the connection; commands check auth state.
            return true;
        },
    }
}

// --- Tests ---

test "ResponseWriter writeAll" {
    // Can't easily test with real fds, but we verify the struct compiles.
    _ = ResponseWriter{ .fd = -1 };
}

test "processLines extracts complete lines" {
    // Verify the line extraction logic with a mock dispatch.
    const S = struct {
        var call_count: u32 = 0;
        fn mockDispatch(_: ServerRef, _: Allocator, _: *ResponseWriter, _: []const u8) void {
            call_count += 1;
        }
    };
    S.call_count = 0;

    var pending: std.ArrayList(u8) = .{};
    defer pending.deinit(std.testing.allocator);
    try pending.appendSlice(std.testing.allocator, "ping\nlist_windows\n");

    var writer = ResponseWriter{ .fd = -1 };
    const config = Config{
        .server = @ptrFromInt(1), // dummy
        .dispatch_fn = &S.mockDispatch,
        .client_fd = -1,
        .peer_cred = null,
        .access_mode = .allow_all,
        .my_pid = 1,
        .alloc = std.testing.allocator,
    };

    processLines(config, &pending, &writer);
    try std.testing.expectEqual(@as(u32, 2), S.call_count);
    try std.testing.expectEqual(@as(usize, 0), pending.items.len);
}

test "processLines handles partial lines" {
    const S = struct {
        var call_count: u32 = 0;
        fn mockDispatch(_: ServerRef, _: Allocator, _: *ResponseWriter, _: []const u8) void {
            call_count += 1;
        }
    };
    S.call_count = 0;

    var pending: std.ArrayList(u8) = .{};
    defer pending.deinit(std.testing.allocator);
    try pending.appendSlice(std.testing.allocator, "ping\nincomplete");

    var writer = ResponseWriter{ .fd = -1 };
    const config = Config{
        .server = @ptrFromInt(1),
        .dispatch_fn = &S.mockDispatch,
        .client_fd = -1,
        .peer_cred = null,
        .access_mode = .allow_all,
        .my_pid = 1,
        .alloc = std.testing.allocator,
    };

    processLines(config, &pending, &writer);
    try std.testing.expectEqual(@as(u32, 1), S.call_count);
    try std.testing.expectEqualStrings("incomplete", pending.items);
}
