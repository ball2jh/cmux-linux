/// Notification badge label formatting.
///
/// Ports the macOS `TerminalNotificationStore.dockBadgeLabel` and
/// `MenuBarBadgeLabelFormatter.badgeText` logic for composing badge
/// display strings from unread counts and optional run tags.
const std = @import("std");

// ── Dock badge label ────────────────────────────────────────────────────

/// Compose a dock/taskbar badge label from an unread count, enabled flag,
/// and optional run tag.
///
/// Returns `null` when no badge should be displayed.
///
/// Matches macOS `TerminalNotificationStore.dockBadgeLabel(unreadCount:isEnabled:runTag:)`.
pub fn dockBadgeLabel(
    buf: []u8,
    unread_count: u32,
    is_enabled: bool,
    run_tag: ?[]const u8,
) ?[]const u8 {
    const has_run_tag = run_tag != null and run_tag.?.len > 0;
    const has_unread = is_enabled and unread_count > 0;

    if (!has_run_tag and !has_unread) return null;

    // Format the unread portion.
    const unread_str: ?[]const u8 = if (has_unread) blk: {
        if (unread_count >= 100) {
            break :blk "99+";
        } else {
            // Format into the user buffer, but we need scratch space.
            // We'll format directly.
            break :blk null; // will handle below
        }
    } else null;

    // We need to build the string: [run_tag:][unread]
    var pos: usize = 0;

    if (has_run_tag) {
        const tag = run_tag.?;
        if (pos + tag.len > buf.len) return null;
        @memcpy(buf[pos..][0..tag.len], tag);
        pos += tag.len;

        if (has_unread) {
            if (pos + 1 > buf.len) return null;
            buf[pos] = ':';
            pos += 1;
        }
    }

    if (has_unread) {
        if (unread_str) |s| {
            if (pos + s.len > buf.len) return null;
            @memcpy(buf[pos..][0..s.len], s);
            pos += s.len;
        } else {
            // Format the number.
            const n = std.fmt.bufPrint(buf[pos..], "{d}", .{unread_count}) catch return null;
            pos += n.len;
        }
    }

    return buf[0..pos];
}

// ── Menu bar badge label ────────────────────────────────────────────────

/// Compose a menu bar badge text from an unread count.
///
/// Returns `null` when unread_count is 0. Returns "9+" for 10 or more.
///
/// Matches macOS `MenuBarBadgeLabelFormatter.badgeText(for:)`.
pub fn menuBarBadgeText(buf: []u8, unread_count: u32) ?[]const u8 {
    if (unread_count == 0) return null;
    if (unread_count >= 10) {
        if (buf.len < 2) return null;
        buf[0] = '9';
        buf[1] = '+';
        return buf[0..2];
    }
    const n = std.fmt.bufPrint(buf, "{d}", .{unread_count}) catch return null;
    return n;
}

// ── Notification state hint title ───────────────────────────────────────

/// Compose a notification menu state hint ("No unread notifications",
/// "1 unread notification", "N unread notifications").
///
/// Matches macOS `NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount:)`.
pub fn stateHintTitle(buf: []u8, unread_count: u32) []const u8 {
    if (unread_count == 0) {
        const msg = "No unread notifications";
        if (buf.len < msg.len) return "";
        @memcpy(buf[0..msg.len], msg);
        return buf[0..msg.len];
    } else if (unread_count == 1) {
        const msg = "1 unread notification";
        if (buf.len < msg.len) return "";
        @memcpy(buf[0..msg.len], msg);
        return buf[0..msg.len];
    } else {
        const n = std.fmt.bufPrint(buf, "{d} unread notifications", .{unread_count}) catch return "";
        return n;
    }
}

// ══════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "Store.badge: dockBadgeLabel enabled and counted" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1", dockBadgeLabel(&buf, 1, true, null).?);
    try testing.expectEqualStrings("42", dockBadgeLabel(&buf, 42, true, null).?);
    try testing.expectEqualStrings("99+", dockBadgeLabel(&buf, 100, true, null).?);
}

test "Store.badge: dockBadgeLabel hidden when disabled or zero" {
    var buf: [64]u8 = undefined;
    try testing.expect(dockBadgeLabel(&buf, 0, true, null) == null);
    try testing.expect(dockBadgeLabel(&buf, 5, false, null) == null);
}

test "Store.badge: dockBadgeLabel shows run tag even without unread" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("verify-tag", dockBadgeLabel(&buf, 0, true, "verify-tag").?);
}

test "Store.badge: dockBadgeLabel combines run tag and unread count" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("verify:7", dockBadgeLabel(&buf, 7, true, "verify").?);
    try testing.expectEqualStrings("verify:99+", dockBadgeLabel(&buf, 120, true, "verify").?);
}

test "Store.badge: menuBarBadgeText formatting" {
    var buf: [16]u8 = undefined;
    try testing.expect(menuBarBadgeText(&buf, 0) == null);
    try testing.expectEqualStrings("1", menuBarBadgeText(&buf, 1).?);
    try testing.expectEqualStrings("9", menuBarBadgeText(&buf, 9).?);
    try testing.expectEqualStrings("9+", menuBarBadgeText(&buf, 10).?);
    try testing.expectEqualStrings("9+", menuBarBadgeText(&buf, 47).?);
}

test "Store.badge: stateHintTitle singular plural and zero" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("No unread notifications", stateHintTitle(&buf, 0));
    try testing.expectEqualStrings("1 unread notification", stateHintTitle(&buf, 1));
    try testing.expectEqualStrings("2 unread notifications", stateHintTitle(&buf, 2));
}
