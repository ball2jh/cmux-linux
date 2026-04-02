//! Lightweight V1 protocol client for connecting to the cmux Unix domain socket.
//!
//! Used by the claude-hook CLI action to send commands to the running cmux
//! server from a separate process. Matches the macOS SocketClient (cmux.swift
//! line 842) adapted for Zig/Linux.

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const socket_path = @import("socket_path.zig");

const log = std.log.scoped(.cmux_socket_client);

pub const SocketClient = struct {
    fd: posix.socket_t,

    /// Connect to the cmux Unix domain socket at the given path.
    pub fn connect(path: []const u8) !SocketClient {
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };
        if (path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;
        // Zero-fill remaining bytes
        @memset(addr.path[path.len + 1 ..], 0);

        try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        // Set a receive timeout so we don't hang forever.
        const timeout = posix.timeval{
            .sec = 10,
            .usec = 0,
        };
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

        return .{ .fd = fd };
    }

    /// Send a V1 command and read the response line.
    /// The response is allocated with the provided allocator.
    pub fn sendCommand(self: *SocketClient, alloc: Allocator, command: []const u8) ![]const u8 {
        // Write command + newline
        var iov = [_]posix.iovec_const{
            .{ .base = command.ptr, .len = command.len },
            .{ .base = "\n", .len = 1 },
        };
        _ = try posix.writev(self.fd, &iov);

        // Read response into a fixed buffer (V1 responses are small)
        var buf: [8192]u8 = undefined;
        var total: usize = 0;

        while (total < buf.len) {
            const n = posix.read(self.fd, buf[total..]) catch |err| switch (err) {
                error.WouldBlock => break, // timeout
                else => return err,
            };
            if (n == 0) break; // EOF
            total += n;

            // Check if we have a complete line
            if (std.mem.indexOfScalar(u8, buf[0..total], '\n') != null) break;
        }

        // Trim trailing newline
        var len = total;
        if (len > 0 and buf[len - 1] == '\n') len -= 1;

        return try alloc.dupe(u8, buf[0..len]);
    }

    pub fn close(self: *SocketClient) void {
        posix.close(self.fd);
    }
};

/// Resolve the socket path, checking env vars and standard locations.
/// Returns a slice of `buf`.
pub fn resolveSocketPath(buf: *[posix.PATH_MAX]u8) ![]const u8 {
    // Try standard resolution (env vars, XDG, etc.)
    if (socket_path.defaultPath(buf)) |path| {
        return path;
    } else |_| {}

    // Fall back to reading /tmp/cmux-last-socket-path
    const file = std.fs.openFileAbsolute(socket_path.tmp_last_path, .{}) catch return error.SocketNotFound;
    defer file.close();
    const n = file.read(buf) catch return error.SocketNotFound;
    if (n == 0) return error.SocketNotFound;
    // Trim trailing newline
    const len = if (n > 0 and buf[n - 1] == '\n') n - 1 else n;
    if (len == 0) return error.SocketNotFound;
    return buf[0..len];
}

/// Connect, send one command, read response, disconnect.
/// Caller owns the returned response string.
pub fn sendOneShot(alloc: Allocator, sock_path: []const u8, command: []const u8) ![]const u8 {
    var client = try SocketClient.connect(sock_path);
    defer client.close();
    return client.sendCommand(alloc, command);
}

// --- Tests ---

test "resolveSocketPath from env" {
    // This test just verifies the function doesn't crash.
    // In CI, the socket likely won't exist.
    var buf: [posix.PATH_MAX]u8 = undefined;
    _ = resolveSocketPath(&buf) catch {};
}
