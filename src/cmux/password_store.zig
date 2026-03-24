/// File-based socket control password store.
///
/// Ports the macOS `SocketControlPasswordStore` — save/load/clear/verify
/// operations for a socket password stored as a plain text file on disk.
///
/// On Linux there is no Keychain equivalent, so the lazy keychain fallback
/// and migration logic from macOS is omitted. The environment variable
/// override (`CMUX_SOCKET_PASSWORD`) and file-based storage are fully ported.
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// Environment variable key for the socket password override.
pub const socket_password_env_key = "CMUX_SOCKET_PASSWORD";

/// Default relative path within the app support directory.
pub const default_relative_path = "cmux/socket-control-password";

/// Save a password to the given file path.
/// Creates intermediate directories if needed.
pub fn savePassword(
    allocator: Allocator,
    password: []const u8,
    file_path: []const u8,
) !void {
    // Ensure parent directory exists.
    if (mem.lastIndexOfScalar(u8, file_path, '/')) |sep| {
        const dir_path = file_path[0..sep];
        try fs.cwd().makePath(dir_path);
    }

    const file = try fs.cwd().createFile(file_path, .{ .truncate = true });
    defer file.close();
    _ = allocator;

    try file.writeAll(password);

    // Set restrictive permissions (owner-only read/write).
    const fd = file.handle;
    const rc = std.os.linux.fchmod(fd, 0o600);
    if (@as(isize, @bitCast(rc)) < 0) {
        // Best-effort — not fatal if permissions can't be set.
    }
}

/// Load a password from the given file path.
/// Returns null if the file does not exist.
pub fn loadPassword(
    allocator: Allocator,
    file_path: []const u8,
) !?[]const u8 {
    const file = fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.size == 0) return null;

    const content = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(content);

    const bytes_read = try file.readAll(content);
    if (bytes_read == 0) {
        allocator.free(content);
        return null;
    }

    // Trim trailing whitespace/newlines.
    const trimmed = mem.trimRight(u8, content[0..bytes_read], &[_]u8{ '\n', '\r', ' ', '\t' });
    if (trimmed.len == 0) {
        allocator.free(content);
        return null;
    }

    if (trimmed.len < content.len) {
        // Return just the trimmed portion; we still own the full allocation.
        // Caller must free the full buffer, so we realloc to trimmed size.
        const result = try allocator.dupe(u8, trimmed);
        allocator.free(content);
        return result;
    }

    return content;
}

/// Clear (delete) the password file.
pub fn clearPassword(file_path: []const u8) !void {
    fs.cwd().deleteFile(file_path) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
}

/// Check whether a password is configured via environment variable or file.
pub fn hasConfiguredPassword(
    env_value: ?[]const u8,
    allocator: Allocator,
    file_path: ?[]const u8,
) bool {
    // Environment variable takes precedence.
    if (env_value) |v| {
        if (v.len > 0) return true;
    }

    // Check file.
    if (file_path) |path| {
        const loaded = loadPassword(allocator, path) catch return false;
        if (loaded) |pw| {
            allocator.free(pw);
            return true;
        }
    }

    return false;
}

/// Get the configured password, preferring environment variable over file.
pub fn configuredPassword(
    env_value: ?[]const u8,
    allocator: Allocator,
    file_path: ?[]const u8,
) !?[]const u8 {
    // Environment variable takes precedence.
    if (env_value) |v| {
        if (v.len > 0) return try allocator.dupe(u8, v);
    }

    // File-based storage.
    if (file_path) |path| {
        return try loadPassword(allocator, path);
    }

    return null;
}

/// Verify that a candidate password matches the configured password.
pub fn verify(
    candidate: []const u8,
    env_value: ?[]const u8,
    allocator: Allocator,
    file_path: ?[]const u8,
) bool {
    const configured = configuredPassword(env_value, allocator, file_path) catch return false;
    const pw = configured orelse return false;
    defer allocator.free(pw);
    return mem.eql(u8, candidate, pw);
}

/// Resolve the default password file path given an app support directory.
///
/// Returns allocator-owned string: "<app_support>/cmux/socket-control-password".
pub fn defaultPasswordFilePath(
    allocator: Allocator,
    app_support_directory: []const u8,
) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{
        app_support_directory,
        default_relative_path,
    });
}

// ══════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════

const testing = std.testing;

fn testTempDir(allocator: Allocator) ![]const u8 {
    // Use /tmp for test directories.
    var buf: [128]u8 = undefined;
    const pid = std.os.linux.getpid();
    const ts = std.time.milliTimestamp();
    const path = try std.fmt.bufPrint(&buf, "/tmp/cmux-pw-test-{d}-{d}", .{ pid, ts });
    const owned = try allocator.dupe(u8, path);
    try fs.cwd().makePath(owned);
    return owned;
}

fn testCleanup(allocator: Allocator, path: []const u8) void {
    fs.cwd().deleteTree(path) catch {};
    allocator.free(path);
}

test "PasswordStore: save load and clear round trip" {
    const alloc = testing.allocator;
    const tmp = try testTempDir(alloc);
    defer testCleanup(alloc, tmp);

    const file_path = try std.fmt.allocPrint(alloc, "{s}/socket-password.txt", .{tmp});
    defer alloc.free(file_path);

    // Initially no password.
    try testing.expect(!hasConfiguredPassword(null, alloc, file_path));

    // Save.
    try savePassword(alloc, "hunter2", file_path);

    // Load.
    const loaded = (try loadPassword(alloc, file_path)).?;
    defer alloc.free(loaded);
    try testing.expectEqualStrings("hunter2", loaded);

    // Has configured.
    try testing.expect(hasConfiguredPassword(null, alloc, file_path));

    // Clear.
    try clearPassword(file_path);

    // No longer configured.
    const after_clear = try loadPassword(alloc, file_path);
    try testing.expect(after_clear == null);
    try testing.expect(!hasConfiguredPassword(null, alloc, file_path));
}

test "PasswordStore: configured password prefers environment over stored file" {
    const alloc = testing.allocator;
    const tmp = try testTempDir(alloc);
    defer testCleanup(alloc, tmp);

    const file_path = try std.fmt.allocPrint(alloc, "{s}/socket-password.txt", .{tmp});
    defer alloc.free(file_path);

    try savePassword(alloc, "stored-secret", file_path);

    const configured = (try configuredPassword("env-secret", alloc, file_path)).?;
    defer alloc.free(configured);
    try testing.expectEqualStrings("env-secret", configured);
}

test "PasswordStore: verify matches configured password" {
    const alloc = testing.allocator;
    const tmp = try testTempDir(alloc);
    defer testCleanup(alloc, tmp);

    const file_path = try std.fmt.allocPrint(alloc, "{s}/socket-password.txt", .{tmp});
    defer alloc.free(file_path);

    try savePassword(alloc, "correct-horse", file_path);

    try testing.expect(verify("correct-horse", null, alloc, file_path));
    try testing.expect(!verify("wrong-password", null, alloc, file_path));
}

test "PasswordStore: verify prefers env over file" {
    const alloc = testing.allocator;
    const tmp = try testTempDir(alloc);
    defer testCleanup(alloc, tmp);

    const file_path = try std.fmt.allocPrint(alloc, "{s}/socket-password.txt", .{tmp});
    defer alloc.free(file_path);

    try savePassword(alloc, "stored-secret", file_path);

    // Verify against env secret, not stored one.
    try testing.expect(verify("env-secret", "env-secret", alloc, file_path));
    try testing.expect(!verify("stored-secret", "env-secret", alloc, file_path));
}

test "PasswordStore: has configured password with env only" {
    const alloc = testing.allocator;
    try testing.expect(hasConfiguredPassword("some-secret", alloc, null));
    try testing.expect(!hasConfiguredPassword("", alloc, null));
    try testing.expect(!hasConfiguredPassword(null, alloc, null));
}

test "PasswordStore: default password file path format" {
    const alloc = testing.allocator;
    const path = try defaultPasswordFilePath(alloc, "/home/user/.local/share");
    defer alloc.free(path);
    try testing.expectEqualStrings("/home/user/.local/share/cmux/socket-control-password", path);
}

test "PasswordStore: stored file prefers over no env" {
    const alloc = testing.allocator;
    const tmp = try testTempDir(alloc);
    defer testCleanup(alloc, tmp);

    const file_path = try std.fmt.allocPrint(alloc, "{s}/socket-password.txt", .{tmp});
    defer alloc.free(file_path);

    try savePassword(alloc, "stored-secret", file_path);

    const configured = (try configuredPassword(null, alloc, file_path)).?;
    defer alloc.free(configured);
    try testing.expectEqualStrings("stored-secret", configured);
}

test "PasswordStore: load returns null for nonexistent file" {
    const alloc = testing.allocator;
    const result = try loadPassword(alloc, "/tmp/cmux-nonexistent-password-file-12345.txt");
    try testing.expect(result == null);
}

test "PasswordStore: clear nonexistent file is no-op" {
    try clearPassword("/tmp/cmux-nonexistent-password-file-12345.txt");
}
