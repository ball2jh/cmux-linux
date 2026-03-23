// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
//
// Socket authentication for cmux.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.cmux_auth);

/// Linux ucred structure for SO_PEERCRED.
const ucred = extern struct {
    pid: i32,
    uid: u32,
    gid: u32,
};

pub const Mode = enum {
    off,
    cmux_only,
    automation,
    password,
    allow_all,
};

var current_mode: Mode = .cmux_only;
var cmux_pid: posix.pid_t = 0;
var password_hash: ?[32]u8 = null; // SHA-256 of password

pub fn init(mode: Mode) void {
    current_mode = mode;
    cmux_pid = @intCast(std.os.linux.getpid());

    // Load password if password mode
    if (mode == .password) {
        loadPassword();
    }

    log.info("socket auth mode: {s}", .{@tagName(mode)});
}

/// Load password from ~/.config/cmux/socket-control-password or CMUX_SOCKET_PASSWORD env
fn loadPassword() void {
    // Check env var first
    if (std.posix.getenv("CMUX_SOCKET_PASSWORD")) |pw| {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(pw);
        password_hash = hasher.finalResult();
        log.info("password loaded from CMUX_SOCKET_PASSWORD env", .{});
        return;
    }

    // Try file
    const home = std.posix.getenv("HOME") orelse return;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/cmux/socket-control-password", .{home}) catch return;

    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var pw_buf: [256]u8 = undefined;
    const n = file.readAll(&pw_buf) catch return;
    const pw = std.mem.trim(u8, pw_buf[0..n], &[_]u8{ '\n', '\r', ' ', '\t' });
    if (pw.len == 0) return;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(pw);
    password_hash = hasher.finalResult();
    log.info("password loaded from {s}", .{path});
}

/// Check if a client connection is authorized.
pub fn checkClient(client_fd: posix.fd_t) bool {
    return switch (current_mode) {
        .off => false,
        .allow_all => true,
        .automation => checkSameUser(client_fd),
        .cmux_only => checkAncestry(client_fd),
        .password => checkSameUser(client_fd), // Password check happens at protocol level
    };
}

/// Verify a password attempt (for protocol-level auth).
pub fn verifyPassword(attempt: []const u8) bool {
    const expected = password_hash orelse return false;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(attempt);
    const actual = hasher.finalResult();
    return std.mem.eql(u8, &expected, &actual);
}

fn checkSameUser(client_fd: posix.fd_t) bool {
    const cred = getPeerCred(client_fd) orelse return false;
    const our_uid = std.os.linux.getuid();
    return cred.uid == our_uid;
}

fn checkAncestry(client_fd: posix.fd_t) bool {
    const cred = getPeerCred(client_fd) orelse {
        log.debug("auth: failed to get peer credentials", .{});
        return false;
    };

    const our_uid = std.os.linux.getuid();
    if (cred.uid != our_uid) {
        log.debug("auth: rejected (different user uid={} vs {})", .{ cred.uid, our_uid });
        return false;
    }

    var pid: posix.pid_t = @intCast(cred.pid);
    var depth: u32 = 0;
    const max_depth: u32 = 64;

    while (pid > 1 and depth < max_depth) : (depth += 1) {
        if (pid == cmux_pid) {
            log.debug("auth: accepted (ancestor match at depth {})", .{depth});
            return true;
        }
        pid = getParentPid(pid) orelse return false;
    }

    log.debug("auth: rejected (pid {} not descendant of cmux pid {})", .{ cred.pid, cmux_pid });
    return false;
}

fn getPeerCred(fd: posix.fd_t) ?ucred {
    var cred: ucred = undefined;
    var len: u32 = @sizeOf(ucred);
    const rc = std.os.linux.getsockopt(fd, std.os.linux.SOL.SOCKET, std.os.linux.SO.PEERCRED, @ptrCast(&cred), &len);
    if (rc != 0) return null;
    return cred;
}

fn getParentPid(pid: posix.pid_t) ?posix.pid_t {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return null;
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "PPid:")) {
            const val = std.mem.trim(u8, line["PPid:".len..], &[_]u8{ '\t', ' ' });
            return std.fmt.parseInt(posix.pid_t, val, 10) catch null;
        }
    }
    return null;
}
