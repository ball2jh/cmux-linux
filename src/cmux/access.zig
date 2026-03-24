//! Socket access control.
//!
//! Defines access modes for the cmux socket and provides Linux-specific
//! peer credential checks. Matches the macOS reference SocketControlSettings
//! and TerminalController.isDescendant() logic.
//!
//! Access modes:
//!   off        — Socket disabled.
//!   cmux_only  — Only processes descended from cmux may connect (0600).
//!   automation — Same UID as cmux, no ancestry check (0600).
//!   password   — Password required before any command (0600).
//!   allow_all  — No checks, world-accessible (0666). Dev only.

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.cmux_access);

pub const Mode = enum {
    off,
    cmux_only,
    automation,
    password,
    allow_all,

    /// File permissions to apply to the socket after bind.
    pub fn socketPermissions(self: Mode) posix.mode_t {
        return switch (self) {
            .allow_all => 0o666,
            else => 0o600,
        };
    }

    /// Whether this mode requires password authentication before commands.
    pub fn requiresAuth(self: Mode) bool {
        return self == .password;
    }
};

/// Linux ucred structure obtained via SO_PEERCRED.
pub const Ucred = extern struct {
    pid: posix.pid_t, // i32
    uid: posix.uid_t, // u32
    gid: posix.gid_t, // u32
};

/// Get peer credentials from a connected Unix domain socket.
/// Returns null if the getsockopt call fails.
pub fn getPeerCred(fd: posix.socket_t) ?Ucred {
    var cred: Ucred = undefined;
    var len: posix.socklen_t = @sizeOf(Ucred);

    // SO_PEERCRED = 17 on Linux.
    const SO_PEERCRED = 17;
    const rc = std.os.linux.syscall5(
        .getsockopt,
        @as(usize, @bitCast(@as(isize, fd))),
        posix.SOL.SOCKET,
        SO_PEERCRED,
        @intFromPtr(&cred),
        @intFromPtr(&len),
    );
    if (@as(isize, @bitCast(rc)) < 0) return null;
    return cred;
}

/// Check whether `target_pid` is a descendant of `ancestor_pid`.
/// Walks the process tree via /proc/<pid>/stat up to `max_depth` levels.
/// Matches macOS TerminalController.isDescendant (128 level limit).
pub fn isDescendant(target_pid: posix.pid_t, ancestor_pid: posix.pid_t) bool {
    const max_depth = 128;
    var current = target_pid;

    for (0..max_depth) |_| {
        if (current == ancestor_pid) return true;
        if (current <= 1) return false;
        current = getParentPid(current) orelse return false;
    }
    return false;
}

/// Read the parent PID of a process from /proc/<pid>/stat.
/// The stat file format is: pid (comm) state ppid ...
/// We need field 4 (ppid), but comm can contain spaces and parens,
/// so we find the last ')' to safely skip it.
fn getParentPid(pid: posix.pid_t) ?posix.pid_t {
    var path_buf: [48]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var stat_buf: [512]u8 = undefined;
    const n = file.read(&stat_buf) catch return null;
    const data = stat_buf[0..n];

    // Find last ')' — end of comm field.
    const close_paren = std.mem.lastIndexOfScalar(u8, data, ')') orelse return null;

    // After ')' comes: " state ppid ..."
    const rest = data[close_paren + 1 ..];

    // Skip whitespace, then the state char, then whitespace to reach ppid.
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    _ = it.next() orelse return null; // state
    const ppid_str = it.next() orelse return null;

    return std.fmt.parseInt(posix.pid_t, ppid_str, 10) catch return null;
}

/// Verify that the peer has the same UID as the current process.
pub fn isSameUser(peer_uid: posix.uid_t) bool {
    return peer_uid == std.os.linux.getuid();
}

// --- Tests ---

test "Mode permissions" {
    try std.testing.expectEqual(@as(posix.mode_t, 0o600), Mode.cmux_only.socketPermissions());
    try std.testing.expectEqual(@as(posix.mode_t, 0o600), Mode.password.socketPermissions());
    try std.testing.expectEqual(@as(posix.mode_t, 0o666), Mode.allow_all.socketPermissions());
}

test "Mode requiresAuth" {
    try std.testing.expect(Mode.password.requiresAuth());
    try std.testing.expect(!Mode.cmux_only.requiresAuth());
    try std.testing.expect(!Mode.allow_all.requiresAuth());
}

test "getParentPid returns valid ppid for init" {
    // PID 1 (init/systemd) should have ppid 0.
    if (getParentPid(1)) |ppid| {
        try std.testing.expectEqual(@as(posix.pid_t, 0), ppid);
    }
    // If /proc/1/stat isn't readable (container), that's fine — test passes.
}

test "isDescendant self is always true" {
    const my_pid = std.os.linux.getpid();
    try std.testing.expect(isDescendant(my_pid, my_pid));
}

test "isDescendant with pid 0 returns false" {
    try std.testing.expect(!isDescendant(0, 12345));
}
