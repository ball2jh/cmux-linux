//! V1 socket protocol: line-oriented, space-delimited commands.
//!
//! Request format:  command [args]\n
//! Response format: PONG\n / OK: result\n / ERROR: message\n
//!
//! Command names are lowercased and use underscores (not hyphens).
//! Only the first space splits command from args — the rest is preserved as-is.
//! Matches macOS TerminalController.processCommand parsing (line 1633).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Command = struct {
    /// Lowercased command name.
    name: []const u8,
    /// Everything after the first space, untrimmed. Empty string if no args.
    args: []const u8,
};

/// Parse a V1 command line into name and args.
/// The `arena` is used to allocate the lowercased command name.
pub fn parse(arena: Allocator, line: []const u8) Allocator.Error!Command {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{ .name = "", .args = "" };

    const space_idx = std.mem.indexOfScalar(u8, trimmed, ' ');
    const raw_name = if (space_idx) |idx| trimmed[0..idx] else trimmed;
    const args = if (space_idx) |idx| trimmed[idx + 1 ..] else "";

    // Lowercase the command name.
    const lower = try arena.alloc(u8, raw_name.len);
    for (raw_name, 0..) |ch, i| {
        lower[i] = std.ascii.toLower(ch);
    }

    return .{ .name = lower, .args = args };
}

/// Write an "OK: {msg}" response.
pub fn ok(writer: anytype, msg: []const u8) !void {
    try writer.writeAll("OK: ");
    try writer.writeAll(msg);
    try writer.writeByte('\n');
}

/// Write an "ERROR: {msg}" response.
pub fn err(writer: anytype, msg: []const u8) !void {
    try writer.writeAll("ERROR: ");
    try writer.writeAll(msg);
    try writer.writeByte('\n');
}

/// Write a raw response line (no prefix).
pub fn raw(writer: anytype, msg: []const u8) !void {
    try writer.writeAll(msg);
    try writer.writeByte('\n');
}

// --- Tests ---

test "parse simple command" {
    const cmd = try parse(std.testing.allocator, "ping");
    defer std.testing.allocator.free(cmd.name);
    try std.testing.expectEqualStrings("ping", cmd.name);
    try std.testing.expectEqualStrings("", cmd.args);
}

test "parse command with args" {
    const cmd = try parse(std.testing.allocator, "send_key ctrl+c");
    defer std.testing.allocator.free(cmd.name);
    try std.testing.expectEqualStrings("send_key", cmd.name);
    try std.testing.expectEqualStrings("ctrl+c", cmd.args);
}

test "parse preserves args after first space" {
    const cmd = try parse(std.testing.allocator, "send hello world");
    defer std.testing.allocator.free(cmd.name);
    try std.testing.expectEqualStrings("send", cmd.name);
    try std.testing.expectEqualStrings("hello world", cmd.args);
}

test "parse lowercases command name" {
    const cmd = try parse(std.testing.allocator, "PING");
    defer std.testing.allocator.free(cmd.name);
    try std.testing.expectEqualStrings("ping", cmd.name);
}

test "parse trims whitespace" {
    const cmd = try parse(std.testing.allocator, "  ping  ");
    defer std.testing.allocator.free(cmd.name);
    try std.testing.expectEqualStrings("ping", cmd.name);
}

test "parse empty line" {
    const cmd = try parse(std.testing.allocator, "");
    try std.testing.expectEqualStrings("", cmd.name);
    try std.testing.expectEqualStrings("", cmd.args);
}

test "ok response format" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try ok(fbs.writer(), "Authenticated");
    try std.testing.expectEqualStrings("OK: Authenticated\n", fbs.getWritten());
}

test "err response format" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try err(fbs.writer(), "Unknown command");
    try std.testing.expectEqualStrings("ERROR: Unknown command\n", fbs.getWritten());
}

test "raw response format" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try raw(fbs.writer(), "PONG");
    try std.testing.expectEqualStrings("PONG\n", fbs.getWritten());
}
