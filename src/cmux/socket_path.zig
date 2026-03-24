//! Socket path resolution and management.
//!
//! Determines where the cmux Unix domain socket lives on disk, matching the
//! macOS reference implementation's path strategy adapted for XDG on Linux:
//!   1. $CMUX_SOCKET_PATH or $CMUX_SOCKET (explicit override)
//!   2. $XDG_CONFIG_HOME/cmux/cmux.sock (standard)
//!   3. $HOME/.config/cmux/cmux.sock (fallback)
//!
//! Also records the last-used path so the CLI can discover the socket.

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const log = std.log.scoped(.cmux_socket_path);

pub const env_socket_path = "CMUX_SOCKET_PATH";
pub const env_socket = "CMUX_SOCKET";
pub const default_dir = "cmux";
pub const default_name = "cmux.sock";
pub const last_path_name = "last-socket-path";
pub const tmp_last_path = "/tmp/cmux-last-socket-path";

/// Maximum length for a Unix socket path (sun_path field minus null terminator).
pub const max_socket_path_len = 107;

/// Resolve the default socket path into the provided buffer.
/// Returns a slice of `buf` containing the path.
///
/// Resolution order:
///   1. $CMUX_SOCKET_PATH environment variable
///   2. $CMUX_SOCKET environment variable
///   3. Stable default path ($XDG_CONFIG_HOME/cmux/cmux.sock), if missing
///      or owned by the current user
///   4. User-scoped fallback: cmux-{UID}.sock (when the stable path exists
///      but is owned by a different user — matches macOS
///      resolvedStableDefaultSocketPath logic)
pub fn defaultPath(buf: *[posix.PATH_MAX]u8) error{PathTooLong}![]const u8 {
    // Check env overrides first.
    if (posix.getenv(env_socket_path) orelse posix.getenv(env_socket)) |env| {
        if (env.len > 0 and env.len <= max_socket_path_len) {
            return bufCopy(buf, env);
        }
    }

    // Try the stable default path, with multi-user fallback.
    return resolvedStableDefaultPath(buf);
}

/// Matches macOS resolvedStableDefaultSocketPath: use the stable path if it
/// is missing or owned by the current user; otherwise fall back to a
/// user-scoped path (cmux-{UID}.sock) to avoid conflicts.
fn resolvedStableDefaultPath(buf: *[posix.PATH_MAX]u8) error{PathTooLong}![]const u8 {
    var stable_buf: [posix.PATH_MAX]u8 = undefined;
    const stable = stableDefaultPath(&stable_buf) catch return userScopedPath(buf);

    switch (inspectSocketPath(stable)) {
        .missing => return bufCopy(buf, stable),
        .owned_by_us => return bufCopy(buf, stable),
        .owned_by_other, .inaccessible => return userScopedPath(buf),
    }
}

/// The canonical socket path: $XDG_CONFIG_HOME/cmux/cmux.sock or
/// $HOME/.config/cmux/cmux.sock.
fn stableDefaultPath(buf: *[posix.PATH_MAX]u8) error{PathTooLong}![]const u8 {
    const config_base = posix.getenv("XDG_CONFIG_HOME");
    if (config_base) |base| {
        if (base.len > 0) {
            return joinPath(buf, &.{ base, default_dir, default_name });
        }
    }
    const home = posix.getenv("HOME") orelse return error.PathTooLong;
    return joinPath(buf, &.{ home, ".config", default_dir, default_name });
}

/// User-scoped fallback: cmux-{UID}.sock. Used when the stable default
/// path exists but belongs to a different user.
fn userScopedPath(buf: *[posix.PATH_MAX]u8) error{PathTooLong}![]const u8 {
    var name_buf: [64]u8 = undefined;
    const uid = std.os.linux.getuid();
    const name = std.fmt.bufPrint(&name_buf, "cmux-{d}.sock", .{uid}) catch return error.PathTooLong;

    // Try XDG config dir first, fall back to /tmp.
    const config_base = posix.getenv("XDG_CONFIG_HOME");
    if (config_base) |base| {
        if (base.len > 0) {
            return joinPath(buf, &.{ base, default_dir, name });
        }
    }
    if (posix.getenv("HOME")) |home| {
        return joinPath(buf, &.{ home, ".config", default_dir, name });
    }
    return joinPath(buf, &.{ "/tmp", name });
}

const PathInspection = enum { missing, owned_by_us, owned_by_other, inaccessible };

/// lstat the path and check ownership. Matches macOS inspectStableDefaultSocketPathEntry.
fn inspectSocketPath(path: []const u8) PathInspection {
    const path_z = posix.toPosixPath(path) catch return .inaccessible;
    var st: std.os.linux.Stat = undefined;
    const rc = std.os.linux.fstatat(std.os.linux.AT.FDCWD, &path_z, &st, std.os.linux.AT.SYMLINK_NOFOLLOW);
    if (rc != 0) {
        return .inaccessible;
    }
    if (st.uid == std.os.linux.getuid()) return .owned_by_us;
    return .owned_by_other;
}

/// Ensure the parent directory of the given socket path exists.
/// Creates it with mode 0o700 if missing.
pub fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    std.fs.makeDirAbsolute(parent) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            log.err("failed to create socket parent directory '{s}': {}", .{ parent, e });
            return e;
        },
    };
    // Ensure restrictive permissions on the directory.
    // Use fchmodat via the linux syscall directly to set restrictive perms.
    const parent_z = std.posix.toPosixPath(parent) catch return;
    _ = std.os.linux.fchmodat(std.posix.AT.FDCWD, &parent_z, 0o700, 0);
}

/// Record the socket path for CLI discovery.
/// Writes to both the XDG config location and /tmp for legacy compat.
pub fn recordLastPath(path: []const u8) void {
    writePathFile(path, configLastPath()) catch |e| {
        log.warn("failed to record last socket path to config dir: {}", .{e});
    };
    writePathFile(path, tmp_last_path) catch |e| {
        log.warn("failed to record last socket path to /tmp: {}", .{e});
    };
}

fn writePathFile(path: []const u8, dest: ?[]const u8) !void {
    const d = dest orelse return error.PathNotAvailable;
    const file = try std.fs.createFileAbsolute(d, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(path);
    try file.writeAll("\n");
}

fn configLastPath() ?[]const u8 {
    // Build $XDG_CONFIG_HOME/cmux/last-socket-path.
    // We use a static buffer since this is only called from recordLastPath.
    const S = struct {
        var buf: [posix.PATH_MAX]u8 = undefined;
        var len: usize = 0;
    };

    const config_base = posix.getenv("XDG_CONFIG_HOME");
    const result: ?[]const u8 = if (config_base) |base|
        if (base.len > 0) (joinPath(&S.buf, &.{ base, default_dir, last_path_name }) catch null) else null
    else blk: {
        const home = posix.getenv("HOME") orelse break :blk null;
        break :blk joinPath(&S.buf, &.{ home, ".config", default_dir, last_path_name }) catch null;
    };

    if (result) |path| {
        S.len = path.len;
        return S.buf[0..S.len];
    }
    return null;
}

// --- helpers ---

fn bufCopy(buf: *[posix.PATH_MAX]u8, src: []const u8) error{PathTooLong}![]const u8 {
    if (src.len > buf.len) return error.PathTooLong;
    @memcpy(buf[0..src.len], src);
    return buf[0..src.len];
}

fn joinPath(buf: *[posix.PATH_MAX]u8, components: []const []const u8) error{PathTooLong}![]const u8 {
    var pos: usize = 0;
    for (components, 0..) |comp, i| {
        if (i > 0) {
            if (pos >= buf.len) return error.PathTooLong;
            buf[pos] = '/';
            pos += 1;
        }
        if (pos + comp.len > buf.len) return error.PathTooLong;
        @memcpy(buf[pos..][0..comp.len], comp);
        pos += comp.len;
    }
    if (pos > max_socket_path_len) return error.PathTooLong;
    return buf[0..pos];
}

// --- Tests ---

test "stableDefaultPath joins correctly" {
    var buf: [posix.PATH_MAX]u8 = undefined;
    const result = joinPath(&buf, &.{ "/home/test", ".config", default_dir, default_name });
    try std.testing.expectEqualStrings("/home/test/.config/cmux/cmux.sock", result catch unreachable);
}

test "userScopedPath includes UID" {
    var buf: [posix.PATH_MAX]u8 = undefined;
    const uid = std.os.linux.getuid();
    var name_buf: [64]u8 = undefined;
    const expected_name = try std.fmt.bufPrint(&name_buf, "cmux-{d}.sock", .{uid});
    const path = userScopedPath(&buf) catch unreachable;
    // Path should end with cmux-{UID}.sock
    try std.testing.expect(std.mem.endsWith(u8, path, expected_name));
}

test "joinPath overflow returns error" {
    var buf: [posix.PATH_MAX]u8 = undefined;
    const long = "a" ** (max_socket_path_len + 1);
    try std.testing.expectError(error.PathTooLong, joinPath(&buf, &.{long}));
}

test "bufCopy" {
    var buf: [posix.PATH_MAX]u8 = undefined;
    const result = try bufCopy(&buf, "/tmp/test.sock");
    try std.testing.expectEqualStrings("/tmp/test.sock", result);
}
