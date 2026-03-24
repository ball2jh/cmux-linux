//! Scrollback replay store — writes scrollback text to temp files
//! for terminal restoration.
//!
//! Matches macOS SessionScrollbackReplayStore: normalize scrollback,
//! ANSI-safe wrap, write to temp file, return env key + path.

const std = @import("std");
const policy = @import("policy.zig");
const Uuid = @import("../uuid.zig").Uuid;

/// Environment variable key passed to Ghostty for scrollback replay.
pub const environment_key = "CMUX_RESTORE_SCROLLBACK_FILE";

const directory_name = "cmux-session-scrollback";
const ansi_escape = "\x1B";
const ansi_reset = "\x1B[0m";

/// Result of preparing scrollback replay.
pub const ReplayEnv = struct {
    key: []const u8,
    path: []const u8,
};

/// Prepare scrollback for replay: normalize, write to temp file, return
/// env key + path. Returns null if scrollback is null, empty, or
/// whitespace-only.
pub fn replayEnvironment(
    allocator: std.mem.Allocator,
    scrollback: ?[]const u8,
    temp_dir: ?[]const u8,
) !?ReplayEnv {
    const replay_text = try normalizedScrollback(allocator, scrollback) orelse return null;
    defer allocator.free(replay_text);

    const dir = temp_dir orelse defaultTempDir();
    const file_path = try writeReplayFile(allocator, replay_text, dir) orelse return null;

    return .{
        .key = environment_key,
        .path = file_path,
    };
}

/// Normalize scrollback: skip whitespace-only, truncate, ANSI-safe wrap.
fn normalizedScrollback(allocator: std.mem.Allocator, scrollback: ?[]const u8) !?[]const u8 {
    const text = scrollback orelse return null;
    if (text.len == 0) return null;

    // Check for non-whitespace content
    var has_content = false;
    for (text) |ch| {
        if (!std.ascii.isWhitespace(ch)) {
            has_content = true;
            break;
        }
    }
    if (!has_content) return null;

    // Truncate via policy
    const truncated = try policy.truncatedScrollback(allocator, text) orelse return null;
    defer allocator.free(truncated);

    // ANSI-safe wrap
    return try ansiSafeReplayText(allocator, truncated);
}

/// Wrap text in ANSI reset sequences to ensure clean color state.
fn ansiSafeReplayText(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, ansi_escape) == null) {
        return try allocator.dupe(u8, text);
    }

    // Prepend/append ANSI reset if not already present
    const prefix = if (!std.mem.startsWith(u8, text, ansi_reset)) ansi_reset else "";
    const suffix = if (!std.mem.endsWith(u8, text, ansi_reset)) ansi_reset else "";

    const result = try allocator.alloc(u8, prefix.len + text.len + suffix.len);
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len..][0..text.len], text);
    @memcpy(result[prefix.len + text.len ..], suffix);
    return result;
}

fn defaultTempDir() []const u8 {
    return std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
}

fn writeReplayFile(allocator: std.mem.Allocator, contents: []const u8, temp_dir: []const u8) !?[]const u8 {
    // Build directory path: {temp_dir}/{directory_name}/
    var dir_buf: [std.posix.PATH_MAX]u8 = undefined;
    var dir_fbs = std.io.fixedBufferStream(&dir_buf);
    dir_fbs.writer().print("{s}/{s}", .{ temp_dir, directory_name }) catch return null;
    const dir_path = dir_fbs.getWritten();

    std.fs.cwd().makePath(dir_path) catch return null;

    // Generate unique filename
    const uuid = Uuid.generate();
    const uuid_str = uuid.format();

    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    var path_fbs = std.io.fixedBufferStream(&path_buf);
    path_fbs.writer().print("{s}/{s}.txt", .{ dir_path, uuid_str }) catch return null;
    const file_path = path_fbs.getWritten();

    // Write file
    const file = std.fs.cwd().createFile(file_path, .{}) catch return null;
    defer file.close();
    file.writeAll(contents) catch return null;

    return try allocator.dupe(u8, file_path);
}

// --- Tests ---

test "replayEnvironment: null scrollback" {
    try std.testing.expect(try replayEnvironment(std.testing.allocator, null, "/tmp") == null);
}

test "replayEnvironment: empty scrollback" {
    try std.testing.expect(try replayEnvironment(std.testing.allocator, "", "/tmp") == null);
}

test "replayEnvironment: whitespace-only scrollback" {
    try std.testing.expect(try replayEnvironment(std.testing.allocator, "   \n\t  ", "/tmp") == null);
}

test "replayEnvironment: writes replay file" {
    const alloc = std.testing.allocator;
    const result = try replayEnvironment(alloc, "$ echo hello\nhello\n", "/tmp") orelse return error.ReplayFailed;
    defer alloc.free(result.path);

    try std.testing.expectEqualStrings(environment_key, result.key);
    try std.testing.expect(std.mem.startsWith(u8, result.path, "/tmp/cmux-session-scrollback/"));

    // Verify file exists and has content
    const file = try std.fs.cwd().openFile(result.path, .{});
    defer file.close();
    const stat = try file.stat();
    try std.testing.expect(stat.size > 0);

    // Clean up
    std.fs.cwd().deleteFile(result.path) catch {};
}

test "replayEnvironment: ANSI content gets reset wrapper" {
    const alloc = std.testing.allocator;
    const result = try replayEnvironment(alloc, "\x1B[31mred text\x1B[0m", "/tmp") orelse return error.ReplayFailed;
    defer alloc.free(result.path);

    // Read the file
    const data = try std.fs.cwd().readFileAlloc(alloc, result.path, 1024 * 1024);
    defer alloc.free(data);

    // Should start with ANSI reset
    try std.testing.expect(std.mem.startsWith(u8, data, ansi_reset));

    // Clean up
    std.fs.cwd().deleteFile(result.path) catch {};
}

test "ansiSafeReplayText: no ANSI — returned as-is" {
    const alloc = std.testing.allocator;
    const result = try ansiSafeReplayText(alloc, "plain text");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("plain text", result);
}

test "ansiSafeReplayText: wraps with reset" {
    const alloc = std.testing.allocator;
    const result = try ansiSafeReplayText(alloc, "\x1B[31mred");
    defer alloc.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, ansi_reset));
    try std.testing.expect(std.mem.endsWith(u8, result, ansi_reset));
}

test "ansiSafeReplayText: already wrapped — no double wrap" {
    const alloc = std.testing.allocator;
    const input = "\x1B[0mtext\x1B[0m";
    const result = try ansiSafeReplayText(alloc, input);
    defer alloc.free(result);
    try std.testing.expectEqualStrings(input, result);
}
