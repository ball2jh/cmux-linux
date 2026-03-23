// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
//
// cmux CLI: connects to the cmux socket and sends commands.
// Usage: cmux +ctl <command> [args...]
//
// Examples:
//   cmux +ctl ping
//   cmux +ctl list-windows
//   cmux +ctl new-window
//   cmux +ctl version

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.cmux_cli);

pub const Options = struct {
    /// Enable arg parsing diagnostics.
    _diagnostics: @import("diagnostics.zig").DiagnosticList = .{},
};

/// Run the cmux ctl CLI action.
pub fn run(alloc: Allocator) !u8 {
    // Collect all remaining args after "+ctl" as the command
    var iter = try std.process.argsWithAllocator(alloc);
    defer iter.deinit();

    // Skip argv[0] and "+ctl"
    _ = iter.next(); // binary name
    var found_ctl = false;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "+ctl")) {
            found_ctl = true;
            break;
        }
    }
    if (!found_ctl) {
        printUsage();
        return 1;
    }

    // Get the command
    const command = iter.next() orelse {
        printUsage();
        return 1;
    };

    // Collect remaining args
    var args_buf: [4096]u8 = undefined;
    var args_len: usize = 0;
    while (iter.next()) |arg| {
        if (args_len > 0) {
            if (args_len < args_buf.len) {
                args_buf[args_len] = ' ';
                args_len += 1;
            }
        }
        const copy_len = @min(arg.len, args_buf.len - args_len);
        @memcpy(args_buf[args_len..][0..copy_len], arg[0..copy_len]);
        args_len += copy_len;
    }

    const args_str = if (args_len > 0) args_buf[0..args_len] else "";

    // Build the full command line
    var line_buf: [8192]u8 = undefined;
    const line = if (args_str.len > 0)
        std.fmt.bufPrint(&line_buf, "{s} {s}\n", .{ command, args_str }) catch {
            std.debug.print("error: command too long\n", .{});
            return 1;
        }
    else
        std.fmt.bufPrint(&line_buf, "{s}\n", .{command}) catch {
            std.debug.print("error: command too long\n", .{});
            return 1;
        };

    // Determine socket path (env override or default)
    const socket_path = if (std.posix.getenv("CMUX_SOCKET_PATH") orelse std.posix.getenv("CMUX_SOCKET")) |env_path|
        try alloc.dupe(u8, env_path)
    else blk: {
        const uid = std.os.linux.getuid();
        break :blk try std.fmt.allocPrint(alloc, "/tmp/cmux-{d}.sock", .{uid});
    };
    defer alloc.free(socket_path);

    // Connect to socket
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
        std.debug.print("error: failed to create socket: {}\n", .{err});
        return 1;
    };
    defer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    if (socket_path.len >= addr.path.len) {
        std.debug.print("error: socket path too long\n", .{});
        return 1;
    }
    @memcpy(addr.path[0..socket_path.len], socket_path);

    posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
        std.debug.print("error: failed to connect to {s}: {}\n", .{ socket_path, err });
        std.debug.print("Is cmux running?\n", .{});
        return 1;
    };

    // Send command
    _ = posix.write(fd, line) catch |err| {
        std.debug.print("error: failed to send command: {}\n", .{err});
        return 1;
    };

    // Read response (with timeout via poll)
    var poll_fds: [1]posix.pollfd = .{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
    };
    const poll_result = posix.poll(&poll_fds, 5000) catch 0; // 5 second timeout
    if (poll_result == 0) {
        std.debug.print("error: timeout waiting for response\n", .{});
        return 1;
    }

    var response_buf: [65536]u8 = undefined;
    const n = posix.read(fd, &response_buf) catch |err| {
        std.debug.print("error: failed to read response: {}\n", .{err});
        return 1;
    };

    if (n > 0) {
        const response = std.mem.trim(u8, response_buf[0..n], &[_]u8{ '\n', '\r' });
        var buffer: [65536]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&buffer);
        const stdout = &stdout_writer.interface;
        stdout.writeAll(response) catch {};
        stdout.writeAll("\n") catch {};
        stdout.flush() catch {};
    }

    return 0;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: cmux +ctl <command> [args...]
        \\
        \\Send a command to a running cmux instance via the control socket.
        \\
        \\Commands:
        \\  ping           Check if cmux is running
        \\  version        Get cmux version
        \\  new-window     Open a new window
        \\  list-windows   List open window IDs
        \\  close-window   Close the active window
        \\  send <text>    Send text to the active terminal
        \\  quit           Quit cmux
        \\
    , .{});
}
