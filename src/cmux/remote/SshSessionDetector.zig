//! Detect SSH processes on a TTY via /proc and parse SSH command-line args.
//!
//! Linux replacement for Mac's sysctl(KERN_PROCARGS2) approach.
//! Scans /proc/<pid>/stat for SSH processes in the foreground process group
//! of the target TTY, then reads /proc/<pid>/cmdline for argument parsing.
//!
//! Matches macOS TerminalSSHSessionDetector (TerminalSSHSessionDetector.swift).

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const log = std.log.scoped(.cmux_ssh_detector);

pub const DetectedSession = struct {
    destination: []const u8,
    port: ?u16 = null,
    identity_file: ?[]const u8 = null,
    config_file: ?[]const u8 = null,
    jump_host: ?[]const u8 = null,
    control_path: ?[]const u8 = null,
    use_ipv4: bool = false,
    use_ipv6: bool = false,
    forward_agent: bool = false,
    compression_enabled: bool = false,
    ssh_options: []const []const u8 = &.{},
};

/// Detect an active SSH session on the given TTY.
///
/// Scans /proc for SSH processes whose foreground process group matches
/// the TTY. Returns the first detected session, or null if none found.
pub fn detect(alloc: Allocator, tty_name: []const u8) ?DetectedSession {
    const tty_dev = ttyDeviceNumber(tty_name) orelse return null;

    var proc_dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return null;
    defer proc_dir.close();

    var iter = proc_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        // Only numeric directory names (PIDs).
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;

        // Read /proc/<pid>/stat to check comm, TTY, PGID, TPGID.
        if (checkProcess(alloc, pid, tty_dev)) |session| {
            return session;
        }
    }

    return null;
}

/// Parse SSH command-line arguments into a DetectedSession.
/// Matches macOS parseSSHCommandLine (TerminalSSHSessionDetector.swift lines 582-717).
pub fn parseCommandLine(alloc: Allocator, args: []const []const u8) ?DetectedSession {
    if (args.len == 0) return null;

    // Skip argv[0] (ssh binary path).
    var i: usize = if (std.mem.endsWith(u8, args[0], "ssh")) @as(usize, 1) else @as(usize, 0);

    var session = DetectedSession{ .destination = "" };
    var options = std.ArrayListUnmanaged([]const u8){};
    var past_separator = false;
    var login_name: ?[]const u8 = null;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (past_separator or arg.len == 0 or arg[0] != '-') {
            // Bare argument — this is the destination.
            if (session.destination.len == 0) {
                session.destination = arg;
            }
            break;
        }

        if (std.mem.eql(u8, arg, "--")) {
            past_separator = true;
            continue;
        }

        // Process flag characters.
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            const c = arg[j];

            if (isNoArgumentFlag(c)) {
                // Flags that take no argument.
                switch (c) {
                    '4' => session.use_ipv4 = true,
                    '6' => session.use_ipv6 = true,
                    'A' => session.forward_agent = true,
                    'C' => session.compression_enabled = true,
                    else => {},
                }
            } else if (isValueArgumentFlag(c)) {
                // Flags that take a value (possibly concatenated or next arg).
                const value = if (j + 1 < arg.len)
                    arg[j + 1 ..] // Concatenated: -p2222
                else blk: {
                    i += 1;
                    break :blk if (i < args.len) args[i] else null;
                };

                if (value) |val| {
                    switch (c) {
                        'p' => session.port = std.fmt.parseInt(u16, val, 10) catch null,
                        'i' => session.identity_file = val,
                        'F' => session.config_file = val,
                        'J' => session.jump_host = val,
                        'S' => session.control_path = val,
                        'l' => login_name = val,
                        'o' => consumeSSHOption(&session, alloc, &options, val),
                        else => {},
                    }
                }
                break; // Value consumed the rest of this arg.
            }
        }
    }

    if (session.destination.len == 0) return null;

    // If -l was used and destination doesn't already include a user, prepend it.
    if (login_name) |ln| {
        if (std.mem.indexOfScalar(u8, session.destination, '@') == null) {
            session.destination = std.fmt.allocPrint(alloc, "{s}@{s}", .{ ln, session.destination }) catch session.destination;
        }
    }

    session.ssh_options = options.toOwnedSlice(alloc) catch &.{};
    return session;
}

fn consumeSSHOption(session: *DetectedSession, alloc: Allocator, options: *std.ArrayListUnmanaged([]const u8), opt: []const u8) void {
    const key = extractOptionKey(opt);
    const value = extractOptionValue(opt);

    if (std.ascii.eqlIgnoreCase(key, "port")) {
        if (value) |v| session.port = std.fmt.parseInt(u16, v, 10) catch null;
    } else if (std.ascii.eqlIgnoreCase(key, "identityfile")) {
        if (value) |v| session.identity_file = v;
    } else if (std.ascii.eqlIgnoreCase(key, "controlpath")) {
        if (value) |v| session.control_path = v;
    } else if (std.ascii.eqlIgnoreCase(key, "proxyjump")) {
        if (value) |v| session.jump_host = v;
    } else if (isFilteredOption(opt) or isDangerousOption(key)) {
        // Drop filtered and dangerous options.
    } else {
        options.append(alloc, opt) catch {};
    }
}

fn extractOptionValue(opt: []const u8) ?[]const u8 {
    for (opt, 0..) |c, i| {
        if (c == '=' or c == ' ' or c == '\t') {
            const rest = opt[i + 1 ..];
            if (rest.len == 0) return null;
            return rest;
        }
    }
    return null;
}

fn isDangerousOption(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "forkafterauthentication") or
        std.ascii.eqlIgnoreCase(key, "localcommand") or
        std.ascii.eqlIgnoreCase(key, "permitlocalcommand") or
        std.ascii.eqlIgnoreCase(key, "remotecommand") or
        std.ascii.eqlIgnoreCase(key, "requesttty") or
        std.ascii.eqlIgnoreCase(key, "sendenv") or
        std.ascii.eqlIgnoreCase(key, "sessiontype") or
        std.ascii.eqlIgnoreCase(key, "setenv") or
        std.ascii.eqlIgnoreCase(key, "stdioforward");
}

/// Build SCP arguments from a detected session for file upload.
pub fn buildScpArgs(
    alloc: Allocator,
    session: *const DetectedSession,
    local_path: []const u8,
    remote_path: []const u8,
) ![]const []const u8 {
    var args = std.ArrayListUnmanaged([]const u8){};

    try args.append(alloc, "scp");
    try args.append(alloc, "-q");

    if (session.use_ipv4) try args.append(alloc, "-4");
    if (session.use_ipv6) try args.append(alloc, "-6");

    if (session.config_file) |cf| {
        try args.appendSlice(alloc, &.{ "-F", cf });
    }

    if (session.identity_file) |id| {
        try args.appendSlice(alloc, &.{ "-i", id });
    }

    if (session.jump_host) |jh| {
        try args.appendSlice(alloc, &.{ "-J", jh });
    }

    if (session.port) |port| {
        var buf: [6]u8 = undefined;
        const port_str = std.fmt.bufPrint(&buf, "{d}", .{port}) catch unreachable;
        try args.appendSlice(alloc, &.{ "-P", try alloc.dupe(u8, port_str) });
    }

    if (session.compression_enabled) {
        try args.append(alloc, "-C");
    }

    for (session.ssh_options) |opt| {
        try args.appendSlice(alloc, &.{ "-o", opt });
    }

    try args.appendSlice(alloc, &.{ "-o", "ConnectTimeout=6" });
    try args.appendSlice(alloc, &.{ "-o", "ServerAliveInterval=20" });
    try args.appendSlice(alloc, &.{ "-o", "BatchMode=yes" });
    try args.appendSlice(alloc, &.{ "-o", "ControlMaster=no" });

    try args.append(alloc, local_path);

    // Build remote destination: dest:path.
    const remote_dest = try std.fmt.allocPrint(alloc, "{s}:{s}", .{
        session.destination,
        remote_path,
    });
    try args.append(alloc, remote_dest);

    return args.toOwnedSlice(alloc);
}

// -----------------------------------------------------------------------
// /proc helpers
// -----------------------------------------------------------------------

fn checkProcess(alloc: Allocator, pid: u32, target_tty_dev: u32) ?DetectedSession {
    // Read /proc/<pid>/stat.
    var stat_path_buf: [64]u8 = undefined;
    const stat_path = std.fmt.bufPrint(&stat_path_buf, "/proc/{d}/stat", .{pid}) catch return null;

    var stat_buf: [1024]u8 = undefined;
    const stat_len = readProcFile(stat_path, &stat_buf) orelse return null;
    const stat_str = stat_buf[0..stat_len];

    // Parse fields. Format: pid (comm) state ppid pgrp session tty_nr tpgid ...
    // Find the closing paren of comm to skip embedded spaces.
    const comm_end = std.mem.lastIndexOfScalar(u8, stat_str, ')') orelse return null;
    const after_comm = std.mem.trim(u8, stat_str[comm_end + 1 ..], " ");

    // Extract comm (between parentheses).
    const comm_start = std.mem.indexOfScalar(u8, stat_str, '(') orelse return null;
    const comm = stat_str[comm_start + 1 .. comm_end];

    // Only interested in ssh processes.
    if (!std.mem.eql(u8, comm, "ssh")) return null;

    // Parse remaining fields.
    var fields = std.mem.splitScalar(u8, after_comm, ' ');
    _ = fields.next(); // state
    _ = fields.next(); // ppid
    const pgrp_str = fields.next() orelse return null;
    _ = fields.next(); // session
    const tty_str = fields.next() orelse return null;
    const tpgid_str = fields.next() orelse return null;

    const tty_nr = std.fmt.parseInt(u32, tty_str, 10) catch return null;
    const pgrp = std.fmt.parseInt(u32, pgrp_str, 10) catch return null;
    const tpgid = std.fmt.parseInt(u32, tpgid_str, 10) catch return null;

    // Check: correct TTY and foreground process group.
    if (tty_nr != target_tty_dev) return null;
    if (pgrp != tpgid) return null;

    // Read /proc/<pid>/cmdline (null-separated argv).
    var cmdline_path_buf: [64]u8 = undefined;
    const cmdline_path = std.fmt.bufPrint(&cmdline_path_buf, "/proc/{d}/cmdline", .{pid}) catch return null;

    var cmdline_buf: [8192]u8 = undefined;
    const cmdline_len = readProcFile(cmdline_path, &cmdline_buf) orelse return null;

    // Split by null bytes.
    var args_list = std.ArrayListUnmanaged([]const u8){};
    var start: usize = 0;
    for (cmdline_buf[0..cmdline_len], 0..) |byte, idx| {
        if (byte == 0) {
            if (idx > start) {
                args_list.append(alloc, cmdline_buf[start..idx]) catch continue;
            }
            start = idx + 1;
        }
    }

    if (args_list.items.len == 0) return null;

    return parseCommandLine(alloc, args_list.items);
}

fn ttyDeviceNumber(tty_name: []const u8) ?u32 {
    // tty_name is like "pts/0". Resolve via /dev/<tty_name> stat.
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/dev/{s}", .{tty_name}) catch return null;

    const stat = std.fs.cwd().statFile(path) catch return null;
    _ = stat;

    // Use the rdev from stat. We need the raw stat syscall.
    var stat_buf: posix.Stat = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "/dev/{s}", .{tty_name}) catch return null;
    if (std.os.linux.stat(path_z, &stat_buf) != 0) return null;
    return @truncate(stat_buf.rdev);
}

fn readProcFile(path: []const u8, buf: []u8) ?usize {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const n = file.read(buf) catch return null;
    return n;
}

// -----------------------------------------------------------------------
// SSH flag classification
// -----------------------------------------------------------------------

/// Flags that take no argument.
/// Matches Mac: "46AaCfGgKkMNnqsTtVvXxYy"
fn isNoArgumentFlag(c: u8) bool {
    return switch (c) {
        '4', '6', 'A', 'a', 'C', 'f', 'G', 'g', 'K', 'k', 'M', 'N', 'n', 'q', 's', 'T', 't', 'V', 'v', 'X', 'x', 'Y', 'y' => true,
        else => false,
    };
}

/// Flags that take a value argument.
/// Matches Mac: "BbcDEeFIiJLlmOopQRSWw"
fn isValueArgumentFlag(c: u8) bool {
    return switch (c) {
        'B', 'b', 'c', 'D', 'E', 'e', 'F', 'I', 'i', 'J', 'L', 'l', 'm', 'O', 'o', 'p', 'Q', 'R', 'S', 'W', 'w' => true,
        else => false,
    };
}

/// SSH options that should be filtered from detected sessions.
fn isFilteredOption(opt: []const u8) bool {
    const key = extractOptionKey(opt);
    return std.ascii.eqlIgnoreCase(key, "batchmode") or
        std.ascii.eqlIgnoreCase(key, "controlmaster") or
        std.ascii.eqlIgnoreCase(key, "controlpath") or
        std.ascii.eqlIgnoreCase(key, "controlpersist");
}

fn extractOptionKey(opt: []const u8) []const u8 {
    for (opt, 0..) |c, i| {
        if (c == '=' or c == ' ' or c == '\t') return opt[0..i];
    }
    return opt;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "parseCommandLine basic" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{ "ssh", "-p", "2222", "-i", "/home/user/.ssh/id_rsa", "user@example.com" };
    const session = parseCommandLine(alloc, &args).?;
    defer if (session.ssh_options.len > 0) alloc.free(session.ssh_options);

    try std.testing.expectEqualStrings("user@example.com", session.destination);
    try std.testing.expectEqual(@as(?u16, 2222), session.port);
    try std.testing.expectEqualStrings("/home/user/.ssh/id_rsa", session.identity_file.?);
}

test "parseCommandLine flags" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{ "ssh", "-4", "-A", "-C", "-J", "bastion", "host" };
    const session = parseCommandLine(alloc, &args).?;
    defer if (session.ssh_options.len > 0) alloc.free(session.ssh_options);

    try std.testing.expect(session.use_ipv4);
    try std.testing.expect(session.forward_agent);
    try std.testing.expect(session.compression_enabled);
    try std.testing.expectEqualStrings("bastion", session.jump_host.?);
    try std.testing.expectEqualStrings("host", session.destination);
}

test "parseCommandLine concatenated port" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{ "ssh", "-p2222", "host" };
    const session = parseCommandLine(alloc, &args).?;
    defer if (session.ssh_options.len > 0) alloc.free(session.ssh_options);

    try std.testing.expectEqual(@as(?u16, 2222), session.port);
}

test "isNoArgumentFlag" {
    try std.testing.expect(isNoArgumentFlag('4'));
    try std.testing.expect(isNoArgumentFlag('A'));
    try std.testing.expect(isNoArgumentFlag('C'));
    try std.testing.expect(!isNoArgumentFlag('p'));
    try std.testing.expect(!isNoArgumentFlag('i'));
}
