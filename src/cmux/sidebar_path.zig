/// Sidebar path formatting utilities.
///
/// Ports the macOS `SidebarPathFormatter.shortenedPath` function that
/// replaces the home directory prefix with `~` for display in the sidebar.
const std = @import("std");

/// Replace the home directory prefix with `~` for display.
///
/// Returns the shortened path in the provided buffer, or the original
/// path unchanged if it does not start with the home directory.
///
/// Matches macOS `SidebarPathFormatter.shortenedPath(_:homeDirectoryPath:)`.
pub fn shortenedPath(
    buf: []u8,
    path: []const u8,
    home_directory_path: []const u8,
) []const u8 {
    if (home_directory_path.len == 0) return path;

    // Exact match: path == home
    if (std.mem.eql(u8, path, home_directory_path)) {
        if (buf.len < 1) return path;
        buf[0] = '~';
        return buf[0..1];
    }

    // Prefix match: path starts with home + "/"
    if (std.mem.startsWith(u8, path, home_directory_path)) {
        const rest = path[home_directory_path.len..];
        if (rest.len > 0 and rest[0] == '/') {
            // Build "~" + rest
            const needed = 1 + rest.len;
            if (needed > buf.len) return path;
            buf[0] = '~';
            @memcpy(buf[1..][0..rest.len], rest);
            return buf[0..needed];
        }
    }

    // No match — return original path.
    return path;
}

// ══════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "SidebarPathFormatter: shortened path replaces exact home directory" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "~",
        shortenedPath(&buf, "/Users/example", "/Users/example"),
    );
}

test "SidebarPathFormatter: shortened path replaces home directory prefix" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "~/projects/cmux",
        shortenedPath(&buf, "/Users/example/projects/cmux", "/Users/example"),
    );
}

test "SidebarPathFormatter: shortened path leaves external path unchanged" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "/tmp/cmux",
        shortenedPath(&buf, "/tmp/cmux", "/Users/example"),
    );
}

test "SidebarPathFormatter: shortened path with Linux-style home" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "~/dev/project",
        shortenedPath(&buf, "/home/jacka/dev/project", "/home/jacka"),
    );
}

test "SidebarPathFormatter: empty home directory returns path unchanged" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "/some/path",
        shortenedPath(&buf, "/some/path", ""),
    );
}

test "SidebarPathFormatter: home prefix without slash separator not replaced" {
    var buf: [256]u8 = undefined;
    // "/Users/exampleXtra" starts with "/Users/example" but next char is not "/"
    try testing.expectEqualStrings(
        "/Users/exampleXtra",
        shortenedPath(&buf, "/Users/exampleXtra", "/Users/example"),
    );
}
