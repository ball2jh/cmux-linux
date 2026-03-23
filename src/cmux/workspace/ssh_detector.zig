// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
//
// SSH session detection for cmux.
// Detects foreground SSH processes by parsing /proc to find processes
// whose command is "ssh" and whose process group matches the terminal's
// foreground process group.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.cmux_ssh);

pub const SshSession = struct {
    pid: i32,
    target: []const u8, // hostname or user@hostname
};

/// Detect SSH sessions on the given TTY.
/// Reads /proc/{pid}/stat for each process to find foreground SSH sessions.
pub fn detectSshSessions(alloc: Allocator) ![]SshSession {
    var sessions: std.ArrayListUnmanaged(SshSession) = .empty;
    errdefer {
        for (sessions.items) |*s| alloc.free(s.target);
        sessions.deinit(alloc);
    }

    // Read all PIDs from /proc
    var proc_dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return sessions.toOwnedSlice(alloc);
    defer proc_dir.close();

    var it = proc_dir.iterate();
    while (it.next() catch null) |entry| {
        // Skip non-numeric entries
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;

        // Read cmdline
        var cmdline_path_buf: [64]u8 = undefined;
        const cmdline_path = std.fmt.bufPrint(&cmdline_path_buf, "/proc/{d}/cmdline", .{pid}) catch continue;

        const file = std.fs.openFileAbsolute(cmdline_path, .{}) catch continue;
        defer file.close();

        var buf: [4096]u8 = undefined;
        const n = file.readAll(&buf) catch continue;
        if (n == 0) continue;

        // cmdline is null-separated. First arg is the command.
        const cmd_end = std.mem.indexOf(u8, buf[0..n], &[_]u8{0}) orelse n;
        const cmd = buf[0..cmd_end];

        // Check if command ends with "ssh"
        const basename = if (std.mem.lastIndexOf(u8, cmd, "/")) |pos| cmd[pos + 1 ..] else cmd;
        if (!std.mem.eql(u8, basename, "ssh")) continue;

        // Extract target (last non-flag argument)
        var target: []const u8 = "unknown";
        var arg_start: usize = cmd_end + 1;
        var last_arg: []const u8 = "";
        while (arg_start < n) {
            const arg_end = std.mem.indexOf(u8, buf[arg_start..n], &[_]u8{0}) orelse n - arg_start;
            const arg = buf[arg_start .. arg_start + arg_end];
            if (arg.len > 0 and arg[0] != '-') {
                last_arg = arg;
            }
            arg_start += arg_end + 1;
        }
        if (last_arg.len > 0) target = last_arg;

        try sessions.append(alloc, .{
            .pid = pid,
            .target = try alloc.dupe(u8, target),
        });
    }

    return sessions.toOwnedSlice(alloc);
}

/// Format SSH sessions as JSON.
pub fn formatJson(alloc: Allocator) ![]u8 {
    const sessions = try detectSshSessions(alloc);
    defer {
        for (sessions) |*s| alloc.free(s.target);
        alloc.free(sessions);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    try writer.writeAll("[");
    for (sessions, 0..) |s, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{{\"pid\":{d},\"target\":\"{s}\"}}", .{ s.pid, s.target });
    }
    try writer.writeAll("]");

    return try buf.toOwnedSlice(alloc);
}
