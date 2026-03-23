// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
//
// SSH session detection for cmux.
// Detects foreground SSH processes by parsing /proc to find processes
// whose command is "ssh" and whose process group matches the terminal's
// foreground process group. Parses SSH options for rich sidebar display.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.cmux_ssh);

pub const SshSession = struct {
    pid: i32,
    target: []const u8, // hostname (resolved from user@host or positional arg)
    user: ?[]const u8, // resolved user (from -l or user@host)
    port: ?u16, // resolved port (from -p, default null = 22)
    jump_host: ?[]const u8, // -J proxy/jump host
};

/// Detect SSH sessions by scanning /proc.
/// Filters to foreground processes (pgrp == tpgid in /proc/{pid}/stat).
pub fn detectSshSessions(alloc: Allocator) ![]SshSession {
    var sessions: std.ArrayListUnmanaged(SshSession) = .empty;
    errdefer {
        for (sessions.items) |*s| freeSession(alloc, s);
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

        // Check if this is a foreground process (filter out background tunnels)
        if (!isForegroundProcess(pid)) continue;

        // Parse SSH arguments
        const session = parseSshArgs(alloc, pid, buf[0..n]) catch continue;
        try sessions.append(alloc, session);
    }

    return sessions.toOwnedSlice(alloc);
}

/// Check if a process is in the foreground of its terminal.
/// Reads /proc/{pid}/stat and checks if pgrp (field 5) == tpgid (field 8).
fn isForegroundProcess(pid: i32) bool {
    var stat_path_buf: [64]u8 = undefined;
    const stat_path = std.fmt.bufPrint(&stat_path_buf, "/proc/{d}/stat", .{pid}) catch return true;

    const file = std.fs.openFileAbsolute(stat_path, .{}) catch return true;
    defer file.close();

    var buf: [1024]u8 = undefined;
    const n = file.readAll(&buf) catch return true;
    if (n == 0) return true;

    const content = buf[0..n];

    // /proc/{pid}/stat format: pid (comm) state ppid pgrp session tty_nr tpgid ...
    // We need to skip past the (comm) field which may contain spaces/parens
    const comm_end = std.mem.lastIndexOf(u8, content, ")") orelse return true;
    if (comm_end + 2 >= content.len) return true;

    // Fields after (comm): state ppid pgrp session tty_nr tpgid
    var fields = std.mem.tokenizeScalar(u8, content[comm_end + 2 ..], ' ');
    _ = fields.next() orelse return true; // state
    _ = fields.next() orelse return true; // ppid
    const pgrp_str = fields.next() orelse return true; // pgrp (field 5)
    _ = fields.next() orelse return true; // session
    _ = fields.next() orelse return true; // tty_nr
    const tpgid_str = fields.next() orelse return true; // tpgid (field 8)

    const pgrp = std.fmt.parseInt(i32, pgrp_str, 10) catch return true;
    const tpgid = std.fmt.parseInt(i32, tpgid_str, 10) catch return true;

    // tpgid == -1 means no controlling terminal (background daemon)
    if (tpgid == -1) return false;

    return pgrp == tpgid;
}

/// Parse SSH command-line arguments to extract target, user, port, jump host.
fn parseSshArgs(alloc: Allocator, pid: i32, cmdline: []const u8) !SshSession {
    // Split cmdline on null bytes to get individual arguments
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(alloc);

    var start: usize = 0;
    for (cmdline, 0..) |c, i| {
        if (c == 0) {
            if (i > start) {
                try args_list.append(alloc, cmdline[start..i]);
            }
            start = i + 1;
        }
    }
    if (start < cmdline.len) {
        try args_list.append(alloc, cmdline[start..]);
    }

    const args = args_list.items;
    if (args.len == 0) return error.NoArgs;

    var user: ?[]const u8 = null;
    var port: ?u16 = null;
    var jump_host: ?[]const u8 = null;
    var target: ?[]const u8 = null;

    // Skip args[0] (the ssh command itself)
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len == 0) continue;

        if (arg[0] == '-' and arg.len >= 2) {
            const flag = arg[1];

            // Flags that take a value as the next argument
            switch (flag) {
                'p' => {
                    // -p port (may be -pNNN or -p NNN)
                    if (arg.len > 2) {
                        port = std.fmt.parseInt(u16, arg[2..], 10) catch null;
                    } else if (i + 1 < args.len) {
                        i += 1;
                        port = std.fmt.parseInt(u16, args[i], 10) catch null;
                    }
                },
                'l' => {
                    // -l user
                    if (arg.len > 2) {
                        user = arg[2..];
                    } else if (i + 1 < args.len) {
                        i += 1;
                        user = args[i];
                    }
                },
                'J' => {
                    // -J jump_host
                    if (arg.len > 2) {
                        jump_host = arg[2..];
                    } else if (i + 1 < args.len) {
                        i += 1;
                        jump_host = args[i];
                    }
                },
                'o' => {
                    // -o option=value — skip the value
                    if (arg.len <= 2 and i + 1 < args.len) {
                        i += 1;
                    }
                },
                // Other flags that take a value argument — skip them
                'i', 'F', 'S', 'b', 'c', 'D', 'e', 'I', 'L', 'R', 'W', 'w', 'E', 'Q' => {
                    if (arg.len <= 2 and i + 1 < args.len) {
                        i += 1;
                    }
                },
                else => {
                    // Other flags without values (e.g. -N, -f, -v, -4, -6)
                    // or combined flags like -fNv — just skip
                },
            }
        } else {
            // Positional argument — this is the destination
            target = arg;
        }
    }

    // Parse user@host from target
    var resolved_host: []const u8 = target orelse "unknown";
    if (target) |t| {
        if (std.mem.indexOf(u8, t, "@")) |at_pos| {
            if (user == null) {
                user = t[0..at_pos];
            }
            resolved_host = t[at_pos + 1 ..];
        }
    }

    return SshSession{
        .pid = pid,
        .target = try alloc.dupe(u8, resolved_host),
        .user = if (user) |u| try alloc.dupe(u8, u) else null,
        .port = port,
        .jump_host = if (jump_host) |j| try alloc.dupe(u8, j) else null,
    };
}

fn writeJsonEscaped(writer: anytype, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => writer.writeAll("\\\"") catch return,
            '\\' => writer.writeAll("\\\\") catch return,
            '\n' => writer.writeAll("\\n") catch return,
            '\r' => writer.writeAll("\\r") catch return,
            '\t' => writer.writeAll("\\t") catch return,
            else => writer.writeByte(c) catch return,
        }
    }
}

fn freeSession(alloc: Allocator, session: *SshSession) void {
    alloc.free(session.target);
    if (session.user) |u| alloc.free(u);
    if (session.jump_host) |j| alloc.free(j);
}

/// Format SSH sessions as JSON.
pub fn formatJson(alloc: Allocator) ![]u8 {
    const sessions = try detectSshSessions(alloc);
    defer {
        for (sessions) |*s| freeSession(alloc, @constCast(s));
        alloc.free(sessions);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    try writer.writeAll("[");
    for (sessions, 0..) |s, idx| {
        if (idx > 0) try writer.writeAll(",");
        try writer.print("{{\"pid\":{d},\"target\":\"", .{s.pid});
        writeJsonEscaped(writer, s.target);
        try writer.writeAll("\"");
        if (s.user) |u| {
            try writer.writeAll(",\"user\":\"");
            writeJsonEscaped(writer, u);
            try writer.writeAll("\"");
        }
        if (s.port) |p| {
            try writer.print(",\"port\":{d}", .{p});
        }
        if (s.jump_host) |j| {
            try writer.writeAll(",\"jumpHost\":\"");
            writeJsonEscaped(writer, j);
            try writer.writeAll("\"");
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    return try buf.toOwnedSlice(alloc);
}
