// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2025 cmux-linux contributors
//
// Socket authentication for cmux.
// Supports multiple modes matching the macOS cmux protocol:
//   off       - Socket disabled
//   cmuxOnly  - Only processes started inside cmux terminals (default)
//   automation - Any local process from the same user
//   password  - HMAC-SHA256 challenge-response
//   allowAll  - No restrictions (unsafe)

const std = @import("std");
const posix = std.posix;

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

/// Current authentication mode.
var current_mode: Mode = .cmux_only;

/// The PID of the cmux process itself.
var cmux_pid: posix.pid_t = 0;

/// Initialize authentication with the cmux PID.
pub fn init(mode: Mode) void {
    current_mode = mode;
    cmux_pid = @intCast(std.os.linux.getpid());
    log.info("socket auth mode: {s}", .{@tagName(mode)});
}

/// Check if a client connection is authorized.
/// Returns true if the client should be allowed.
/// client_fd is the accepted socket fd — we use SO_PEERCRED to get the peer PID.
pub fn checkClient(client_fd: posix.fd_t) bool {
    return switch (current_mode) {
        .off => false, // Socket should be disabled entirely
        .allow_all => true,
        .automation => checkSameUser(client_fd),
        .cmux_only => checkAncestry(client_fd),
        .password => true, // TODO: implement challenge-response
    };
}

/// Check that the connecting process belongs to the same user.
fn checkSameUser(client_fd: posix.fd_t) bool {
    const cred = getPeerCred(client_fd) orelse return false;
    const our_uid = std.os.linux.getuid();
    return cred.uid == our_uid;
}

/// Check that the connecting process is a descendant of cmux.
/// Walks the /proc/{pid}/status PPid chain up to PID 1.
fn checkAncestry(client_fd: posix.fd_t) bool {
    const cred = getPeerCred(client_fd) orelse {
        log.debug("auth: failed to get peer credentials", .{});
        return false;
    };

    // Check same user first
    const our_uid = std.os.linux.getuid();
    if (cred.uid != our_uid) {
        log.debug("auth: rejected (different user uid={} vs {})", .{ cred.uid, our_uid });
        return false;
    }

    // Walk the process tree
    var pid: posix.pid_t = @intCast(cred.pid);
    var depth: u32 = 0;
    const max_depth: u32 = 64;

    while (pid > 1 and depth < max_depth) : (depth += 1) {
        if (pid == cmux_pid) {
            log.debug("auth: accepted (ancestor match at depth {})", .{depth});
            return true;
        }

        pid = getParentPid(pid) orelse {
            log.debug("auth: could not read ppid for {}", .{pid});
            return false;
        };
    }

    log.debug("auth: rejected (pid {} not a descendant of cmux pid {})", .{ cred.pid, cmux_pid });
    return false;
}

/// Get the peer credentials from a Unix socket via SO_PEERCRED.
fn getPeerCred(fd: posix.fd_t) ?ucred {
    var cred: ucred = undefined;
    var len: u32 = @sizeOf(ucred);

    const rc = std.os.linux.getsockopt(
        fd,
        std.os.linux.SOL.SOCKET,
        std.os.linux.SO.PEERCRED,
        @ptrCast(&cred),
        &len,
    );

    if (rc != 0) return null;
    return cred;
}

/// Read the parent PID from /proc/{pid}/status.
fn getParentPid(pid: posix.pid_t) ?posix.pid_t {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const content = buf[0..n];

    // Find "PPid:\t<number>"
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "PPid:")) {
            const val = std.mem.trim(u8, line["PPid:".len..], &[_]u8{ '\t', ' ' });
            return std.fmt.parseInt(posix.pid_t, val, 10) catch null;
        }
    }

    return null;
}
