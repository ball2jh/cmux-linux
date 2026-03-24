//! Session persistence policy constants and sanitization functions.
//!
//! Matches macOS SessionPersistencePolicy — limits on snapshot size,
//! sidebar width clamping, and ANSI-safe scrollback truncation.

const std = @import("std");

// --- Constants ---

pub const autosave_interval_ms: u32 = 8000;
pub const max_windows_per_snapshot: usize = 12;
pub const max_workspaces_per_window: usize = 128;
pub const max_panels_per_workspace: usize = 512;
pub const max_scrollback_lines: usize = 4000;
pub const max_scrollback_chars: usize = 400_000;

pub const default_sidebar_width: f64 = 200;
pub const minimum_sidebar_width: f64 = 180;
pub const maximum_sidebar_width: f64 = 600;

pub const minimum_window_width: f64 = 300;
pub const minimum_window_height: f64 = 200;

/// Maximum interval (in ms) for which an unchanged fingerprint can skip save.
pub const max_autosave_skip_interval_ms: i64 = 60_000;

// --- Sanitization ---

/// Clamp sidebar width to [minimum, maximum], falling back to default.
pub fn sanitizedSidebarWidth(candidate: ?f64) f64 {
    const w = candidate orelse return default_sidebar_width;
    if (!std.math.isFinite(w)) return default_sidebar_width;
    return @min(@max(w, minimum_sidebar_width), maximum_sidebar_width);
}

/// Truncate scrollback to the last `max_scrollback_chars` characters,
/// ensuring the cut point does not fall inside an ANSI CSI escape sequence.
/// Returns null for null/empty input. Caller owns the returned slice.
pub fn truncatedScrollback(allocator: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    const t = text orelse return null;
    if (t.len == 0) return null;

    if (t.len <= max_scrollback_chars) {
        return try allocator.dupe(u8, t);
    }

    const initial_start = t.len - max_scrollback_chars;
    const safe_start = ansiSafeTruncationStart(t, initial_start);
    return try allocator.dupe(u8, t[safe_start..]);
}

/// If the initial truncation start falls inside an ANSI CSI escape sequence,
/// advance past the end of that sequence to avoid replaying malformed bytes.
fn ansiSafeTruncationStart(text: []const u8, initial_start: usize) usize {
    if (initial_start == 0) return initial_start;

    // Find the last ESC before the initial start.
    const search_region = text[0..initial_start];
    const last_esc = std.mem.lastIndexOfScalar(u8, search_region, '\x1B') orelse return initial_start;

    // Check for CSI: ESC followed by '['.
    const csi_marker = last_esc + 1;
    if (csi_marker >= text.len or text[csi_marker] != '[') return initial_start;

    // If a CSI final byte exists between csi_marker and initial_start,
    // the sequence is complete and we are NOT inside it.
    if (csiFinalByteIndex(text, csi_marker, initial_start) != null) return initial_start;

    // We are inside a partial CSI sequence. Skip to the first character
    // after the sequence terminator.
    const final_idx = csiFinalByteIndex(text, csi_marker, text.len) orelse return initial_start;
    const next = final_idx + 1;
    return if (next < text.len) next else text.len;
}

/// Find the index of the first CSI final byte (0x40–0x7E) in [from+1 .. upper_bound).
fn csiFinalByteIndex(text: []const u8, from: usize, upper_bound: usize) ?usize {
    var idx = from + 1;
    while (idx < upper_bound) : (idx += 1) {
        const ch = text[idx];
        if (ch >= 0x40 and ch <= 0x7E) return idx;
    }
    return null;
}

// --- Tests ---

test "sanitizedSidebarWidth: null returns default" {
    try std.testing.expectEqual(default_sidebar_width, sanitizedSidebarWidth(null));
}

test "sanitizedSidebarWidth: NaN returns default" {
    try std.testing.expectEqual(default_sidebar_width, sanitizedSidebarWidth(std.math.nan(f64)));
}

test "sanitizedSidebarWidth: inf returns default" {
    try std.testing.expectEqual(default_sidebar_width, sanitizedSidebarWidth(std.math.inf(f64)));
}

test "sanitizedSidebarWidth: clamps below minimum" {
    try std.testing.expectEqual(minimum_sidebar_width, sanitizedSidebarWidth(50));
}

test "sanitizedSidebarWidth: clamps above maximum" {
    try std.testing.expectEqual(maximum_sidebar_width, sanitizedSidebarWidth(1000));
}

test "sanitizedSidebarWidth: preserves valid value" {
    try std.testing.expectEqual(@as(f64, 250), sanitizedSidebarWidth(250));
}

test "truncatedScrollback: null returns null" {
    try std.testing.expect(try truncatedScrollback(std.testing.allocator, null) == null);
}

test "truncatedScrollback: empty returns null" {
    try std.testing.expect(try truncatedScrollback(std.testing.allocator, "") == null);
}

test "truncatedScrollback: short text returned as-is" {
    const alloc = std.testing.allocator;
    const result = (try truncatedScrollback(alloc, "hello world")).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "truncatedScrollback: long text truncated to tail" {
    const alloc = std.testing.allocator;

    // Build a string longer than max_scrollback_chars.
    const long = try alloc.alloc(u8, max_scrollback_chars + 100);
    defer alloc.free(long);
    @memset(long[0..100], 'A');
    @memset(long[100..], 'B');

    const result = (try truncatedScrollback(alloc, long)).?;
    defer alloc.free(result);

    try std.testing.expectEqual(max_scrollback_chars, result.len);
    // The result should be the tail: all 'B's.
    try std.testing.expect(result[0] == 'B');
}

test "truncatedScrollback: avoids splitting CSI sequence" {
    const alloc = std.testing.allocator;

    // Construct text where the naive cut point falls inside a CSI sequence.
    // CSI sequence: ESC [ 3 1 m  (red color)
    const prefix_len = 5; // ESC [ 3 1 m
    const content_len = max_scrollback_chars;

    const total = prefix_len + content_len;
    const text = try alloc.alloc(u8, total);
    defer alloc.free(text);

    // Place the CSI right before where the naive cut would be.
    // Naive cut: total - max_scrollback_chars = prefix_len = 5
    // So the ESC is at index 0, '[' at 1, '3' at 2, '1' at 3, 'm' at 4.
    text[0] = '\x1B';
    text[1] = '[';
    text[2] = '3';
    text[3] = '1';
    text[4] = 'm';
    @memset(text[5..], 'X');

    const result = (try truncatedScrollback(alloc, text)).?;
    defer alloc.free(result);

    // The cut should land after the 'm' (index 5), so we get the full text
    // minus the CSI sequence.
    try std.testing.expectEqual(content_len, result.len);
    try std.testing.expect(result[0] == 'X');
}

test "truncatedScrollback: complete CSI before cut point is fine" {
    const alloc = std.testing.allocator;

    // CSI sequence that completes before the cut point — no adjustment needed.
    const total = max_scrollback_chars + 20;
    const text = try alloc.alloc(u8, total);
    defer alloc.free(text);

    // Place a complete CSI at index 0-4, then fill rest.
    text[0] = '\x1B';
    text[1] = '[';
    text[2] = '3';
    text[3] = '1';
    text[4] = 'm'; // Final byte
    @memset(text[5..], 'Y');

    const result = (try truncatedScrollback(alloc, text)).?;
    defer alloc.free(result);

    // Naive cut at index 20. The CSI at 0-4 is complete before 20, so no adjustment.
    try std.testing.expectEqual(max_scrollback_chars, result.len);
}

test "csiFinalByteIndex: finds final byte" {
    const text = "\x1B[31m";
    // csi_marker is at index 1 ('['), so search from 2.
    const idx = csiFinalByteIndex(text, 1, text.len);
    try std.testing.expectEqual(@as(?usize, 4), idx);
}

test "csiFinalByteIndex: no final byte" {
    const text = "\x1B[31";
    const idx = csiFinalByteIndex(text, 1, text.len);
    try std.testing.expect(idx == null);
}
