/// URL / drag target resolution.
///
/// Pure URL parsing logic to determine how to handle dragged or pasted URLs.
/// Ports the macOS `TerminalImageTransferPlanner.escapeForShell` and URL
/// scheme detection logic.
const std = @import("std");

// ── URL scheme classification ───────────────────────────────────────

pub const UrlTarget = enum {
    /// Open in the built-in browser panel.
    browser_panel,
    /// Open as a local file.
    local_file,
    /// Pass through to the terminal (ssh://, etc.).
    terminal_passthrough,
    /// Unknown scheme — treat as browser panel with https:// prefix.
    bare_domain,
};

/// Classify a URL string into a handling target.
pub fn classify(url: []const u8) UrlTarget {
    if (url.len == 0) return .bare_domain;

    // Check for explicit schemes.
    if (startsWithScheme(url, "https://") or startsWithScheme(url, "http://")) {
        return .browser_panel;
    }
    if (startsWithScheme(url, "file://")) {
        return .local_file;
    }
    if (startsWithScheme(url, "ssh://") or
        startsWithScheme(url, "telnet://") or
        startsWithScheme(url, "ftp://"))
    {
        return .terminal_passthrough;
    }

    // Check for bare domain patterns (contains a dot, no spaces, no scheme).
    if (looksLikeBareDomain(url)) {
        return .bare_domain;
    }

    return .bare_domain;
}

fn startsWithScheme(url: []const u8, scheme: []const u8) bool {
    if (url.len < scheme.len) return false;
    return std.ascii.eqlIgnoreCase(url[0..scheme.len], scheme);
}

fn looksLikeBareDomain(s: []const u8) bool {
    var has_dot = false;
    for (s) |c| {
        if (c == '.') has_dot = true;
        if (c == ' ' or c == '\t') return false;
    }
    return has_dot;
}

// ── Shell escaping ──────────────────────────────────────────────────

/// Escape a path for safe pasting into a shell.
/// Matches macOS `GhosttyPasteboardHelper.escapeForShell`.
///
/// Rules:
/// - If the path contains newlines (\n or \r), wrap in single quotes
///   (with embedded single quotes escaped as '\'' ).
/// - Otherwise, backslash-escape all shell metacharacters.
///
/// Characters escaped (matching macOS shellEscapeCharacters):
///   \ ()[]{}<>"'`!#$&;|*?\t
pub fn escapeForShell(buf: []u8, path: []const u8) ?[]const u8 {
    // Check for newlines.
    const has_newlines = std.mem.indexOfAny(u8, path, "\n\r") != null;

    if (has_newlines) {
        return shellSingleQuoted(buf, path);
    }

    // Backslash-escape shell metacharacters.
    var pos: usize = 0;
    for (path) |c| {
        if (isShellMetachar(c)) {
            if (pos + 2 > buf.len) return null;
            buf[pos] = '\\';
            buf[pos + 1] = c;
            pos += 2;
        } else {
            if (pos + 1 > buf.len) return null;
            buf[pos] = c;
            pos += 1;
        }
    }
    return buf[0..pos];
}

/// Matches macOS shellEscapeCharacters: "\\ ()[]{}<>\"'`!#$&;|*?\t"
fn isShellMetachar(c: u8) bool {
    return switch (c) {
        '\\', ' ', '(', ')', '[', ']', '{', '}', '<', '>', '"', '\'', '`', '!', '#', '$', '&', ';', '|', '*', '?', '\t' => true,
        else => false,
    };
}

/// Wrap value in single quotes, escaping embedded single quotes as '\''.
/// Matches macOS shellSingleQuoted.
fn shellSingleQuoted(buf: []u8, value: []const u8) ?[]const u8 {
    var pos: usize = 0;

    if (pos >= buf.len) return null;
    buf[pos] = '\'';
    pos += 1;

    for (value) |c| {
        if (c == '\'') {
            // Close quote, escaped quote, open quote: '\''
            if (pos + 4 > buf.len) return null;
            buf[pos] = '\'';
            buf[pos + 1] = '\\';
            buf[pos + 2] = '\'';
            buf[pos + 3] = '\'';
            pos += 4;
        } else {
            if (pos + 1 > buf.len) return null;
            buf[pos] = c;
            pos += 1;
        }
    }

    if (pos >= buf.len) return null;
    buf[pos] = '\'';
    pos += 1;

    return buf[0..pos];
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "https url classifies as browser panel" {
    try testing.expectEqual(UrlTarget.browser_panel, classify("https://example.com"));
    try testing.expectEqual(UrlTarget.browser_panel, classify("http://example.com"));
    try testing.expectEqual(UrlTarget.browser_panel, classify("HTTPS://EXAMPLE.COM"));
}

test "bare domain classifies as bare domain" {
    try testing.expectEqual(UrlTarget.bare_domain, classify("example.com"));
    try testing.expectEqual(UrlTarget.bare_domain, classify("docs.google.com"));
}

test "file scheme classifies as local file" {
    try testing.expectEqual(UrlTarget.local_file, classify("file:///tmp/test.txt"));
}

test "ssh scheme classifies as terminal passthrough" {
    try testing.expectEqual(UrlTarget.terminal_passthrough, classify("ssh://host.example.com"));
}

test "escape for shell escapes spaces" {
    var buf: [256]u8 = undefined;
    const result = escapeForShell(&buf, "/tmp/Screen Shot.png");
    try testing.expect(result != null);
    try testing.expectEqualStrings("/tmp/Screen\\ Shot.png", result.?);
}

test "escape for shell single quotes embedded newlines" {
    var buf: [256]u8 = undefined;
    const result = escapeForShell(&buf, "/tmp/Screen\nShot\r.png");
    try testing.expect(result != null);
    try testing.expectEqualStrings("'/tmp/Screen\nShot\r.png'", result.?);
}

// ── Additional URL resolution cases ─────────────────────────────────

test "telnet scheme classifies as terminal passthrough" {
    try testing.expectEqual(UrlTarget.terminal_passthrough, classify("telnet://host.example.com"));
}

test "ftp scheme classifies as terminal passthrough" {
    try testing.expectEqual(UrlTarget.terminal_passthrough, classify("ftp://files.example.com"));
}

test "empty string classifies as bare domain" {
    try testing.expectEqual(UrlTarget.bare_domain, classify(""));
}

test "text with spaces does not classify as bare domain" {
    // "hello world" has a space, so looksLikeBareDomain returns false.
    try testing.expectEqual(UrlTarget.bare_domain, classify("hello world"));
}

test "text without dot classifies as bare domain" {
    try testing.expectEqual(UrlTarget.bare_domain, classify("localhost"));
}

test "path-like string without scheme" {
    try testing.expectEqual(UrlTarget.bare_domain, classify("/tmp/test.txt"));
}

test "escape for shell no special characters" {
    var buf: [256]u8 = undefined;
    const result = escapeForShell(&buf, "/tmp/simple.png");
    try testing.expect(result != null);
    try testing.expectEqualStrings("/tmp/simple.png", result.?);
}

test "escape for shell empty path" {
    var buf: [256]u8 = undefined;
    const result = escapeForShell(&buf, "");
    try testing.expect(result != null);
    try testing.expectEqualStrings("", result.?);
}

test "escape for shell multiple spaces" {
    var buf: [256]u8 = undefined;
    const result = escapeForShell(&buf, "/my dir/my file.txt");
    try testing.expect(result != null);
    try testing.expectEqualStrings("/my\\ dir/my\\ file.txt", result.?);
}

test "escape for shell buffer too small returns null" {
    var buf: [5]u8 = undefined;
    const result = escapeForShell(&buf, "/tmp/Screen Shot.png");
    try testing.expect(result == null);
}

test "escape for shell metacharacters" {
    var buf: [256]u8 = undefined;
    // Parentheses.
    try testing.expectEqualStrings("/tmp/file\\(1\\).txt", escapeForShell(&buf, "/tmp/file(1).txt").?);
    // Dollar sign.
    try testing.expectEqualStrings("/tmp/\\$HOME/file", escapeForShell(&buf, "/tmp/$HOME/file").?);
    // Backtick.
    try testing.expectEqualStrings("/tmp/file\\`name", escapeForShell(&buf, "/tmp/file`name").?);
    // Ampersand.
    try testing.expectEqualStrings("/tmp/a\\&b", escapeForShell(&buf, "/tmp/a&b").?);
    // Semicolon.
    try testing.expectEqualStrings("/tmp/a\\;b", escapeForShell(&buf, "/tmp/a;b").?);
}

test "escape for shell single quote in newline path" {
    var buf: [256]u8 = undefined;
    // A path with both a newline and a single quote.
    const result = escapeForShell(&buf, "/tmp/it's\nhere");
    try testing.expect(result != null);
    try testing.expectEqualStrings("'/tmp/it'\\''s\nhere'", result.?);
}
