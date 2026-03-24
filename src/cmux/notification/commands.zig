/// Socket command handlers for notification operations.
///
/// These are pure functions that operate on a Store and return response
/// strings. They are decoupled from the socket transport layer.
///
/// Protocol matches the macOS reference: pipe-delimited payloads,
/// underscore command names.
const std = @import("std");
const Uuid = @import("../uuid.zig").Uuid;
const Store = @import("Store.zig").Store;
const Notification = @import("Notification.zig").Notification;

/// Result of parsing a notification payload ("title|subtitle|body").
pub const NotificationPayload = struct {
    title: []const u8,
    subtitle: []const u8,
    body: []const u8,
};

/// Parse the "title|subtitle|body" pipe-delimited payload.
///
/// - If empty: title defaults to "Notification".
/// - If one part: title only.
/// - If two parts: title and body (no subtitle).
/// - If three parts: title, subtitle, body.
/// - Title trimmed; empty title defaults to "Notification".
///
/// Matches macOS `parseNotificationPayload`.
pub fn parseNotificationPayload(raw: []const u8) NotificationPayload {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .{ .title = "Notification", .subtitle = "", .body = "" };

    // Split on '|', max 3 parts.
    var parts: [3][]const u8 = .{ "", "", "" };
    var count: usize = 0;
    var start: usize = 0;
    for (trimmed, 0..) |ch, i| {
        if (ch == '|' and count < 2) {
            parts[count] = trimmed[start..i];
            count += 1;
            start = i + 1;
        }
    }
    parts[count] = trimmed[start..];
    count += 1;

    const title_raw = std.mem.trim(u8, parts[0], " \t\r\n");
    const title = if (title_raw.len == 0) "Notification" else title_raw;

    if (count == 3) {
        return .{
            .title = title,
            .subtitle = std.mem.trim(u8, parts[1], " \t\r\n"),
            .body = std.mem.trim(u8, parts[2], " \t\r\n"),
        };
    } else if (count == 2) {
        // Two parts: title and body (no subtitle), matching Mac behavior.
        return .{
            .title = title,
            .subtitle = "",
            .body = std.mem.trim(u8, parts[1], " \t\r\n"),
        };
    } else {
        return .{
            .title = title,
            .subtitle = "",
            .body = "",
        };
    }
}

/// Handle `notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>`.
///
/// Writes the response to `buf` and returns the used slice.
/// Note: This simplified version doesn't validate that the tab/surface exist
/// in a tab manager — that will be wired in when the full socket layer is built.
pub fn handleNotifyTarget(store: *Store, args: []const u8, buf: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        return writeStr(buf, "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>");
    }

    // Split: workspace_id surface_id payload
    const first_space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse {
        return writeStr(buf, "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>");
    };
    const tab_str = trimmed[0..first_space];
    const rest = std.mem.trimLeft(u8, trimmed[first_space + 1 ..], " ");

    const second_space = std.mem.indexOfScalar(u8, rest, ' ');
    const surface_str = if (second_space) |sp| rest[0..sp] else rest;
    const payload = if (second_space) |sp| rest[sp + 1 ..] else "";

    const tab_id = Uuid.parse(tab_str) catch {
        return writeStr(buf, "ERROR: Invalid workspace ID");
    };
    const surface_id = Uuid.parse(surface_str) catch {
        return writeStr(buf, "ERROR: Invalid surface ID");
    };

    const parsed = parseNotificationPayload(payload);

    store.addNotification(
        tab_id,
        surface_id,
        parsed.title,
        parsed.subtitle,
        parsed.body,
    ) catch {
        return writeStr(buf, "ERROR: Out of memory");
    };

    return writeStr(buf, "OK");
}

/// Handle `list_notifications`.
///
/// Response format (one per line):
///   <index>:<id>|<tabId>|<surfaceId>|<readStatus>|<title>|<subtitle>|<body>
///
/// Returns "No notifications" if empty.
pub fn handleListNotifications(store: *const Store, buf: []u8) []const u8 {
    const notifications = store.getNotifications();
    if (notifications.len == 0) {
        return writeStr(buf, "No notifications");
    }

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    for (notifications, 0..) |n, i| {
        if (i > 0) writer.writeByte('\n') catch return stream.getWritten();

        // index:id|tabId|surfaceId|readStatus|title|subtitle|body
        var id_buf: [36]u8 = undefined;
        var tab_buf: [36]u8 = undefined;
        _ = n.id.formatBuf(&id_buf);
        _ = n.tab_id.formatBuf(&tab_buf);

        writer.print("{d}:", .{i}) catch return stream.getWritten();
        writer.writeAll(&id_buf) catch return stream.getWritten();
        writer.writeByte('|') catch return stream.getWritten();
        writer.writeAll(&tab_buf) catch return stream.getWritten();
        writer.writeByte('|') catch return stream.getWritten();

        if (n.surface_id) |sid| {
            var sid_buf: [36]u8 = undefined;
            _ = sid.formatBuf(&sid_buf);
            writer.writeAll(&sid_buf) catch return stream.getWritten();
        } else {
            writer.writeAll("none") catch return stream.getWritten();
        }

        writer.writeByte('|') catch return stream.getWritten();
        writer.writeAll(if (n.is_read) "read" else "unread") catch return stream.getWritten();
        writer.writeByte('|') catch return stream.getWritten();
        writer.writeAll(n.title) catch return stream.getWritten();
        writer.writeByte('|') catch return stream.getWritten();
        writer.writeAll(n.subtitle) catch return stream.getWritten();
        writer.writeByte('|') catch return stream.getWritten();
        writer.writeAll(n.body) catch return stream.getWritten();
    }

    return stream.getWritten();
}

/// Handle `clear_notifications [--tab=<uuid>]`.
pub fn handleClearNotifications(store: *Store, args: []const u8, buf: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        store.clearAll();
        return writeStr(buf, "OK");
    }

    // Parse --tab=<uuid>
    const prefix = "--tab=";
    if (std.mem.startsWith(u8, trimmed, prefix)) {
        const tab_str = trimmed[prefix.len..];
        const tab_id = Uuid.parse(tab_str) catch {
            return writeStr(buf, "ERROR: Invalid tab ID");
        };
        store.clearNotificationsForTab(tab_id);
        return writeStr(buf, "OK");
    }

    return writeStr(buf, "ERROR: Usage: clear_notifications [--tab=<uuid>]");
}

fn writeStr(buf: []u8, s: []const u8) []const u8 {
    const len = @min(s.len, buf.len);
    @memcpy(buf[0..len], s[0..len]);
    return buf[0..len];
}

// ══════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════

const testing = std.testing;

test "parseNotificationPayload empty" {
    const p = parseNotificationPayload("");
    try testing.expectEqualStrings("Notification", p.title);
    try testing.expectEqualStrings("", p.subtitle);
    try testing.expectEqualStrings("", p.body);
}

test "parseNotificationPayload title only" {
    const p = parseNotificationPayload("Build complete");
    try testing.expectEqualStrings("Build complete", p.title);
    try testing.expectEqualStrings("", p.subtitle);
    try testing.expectEqualStrings("", p.body);
}

test "parseNotificationPayload title and body" {
    const p = parseNotificationPayload("Build|All tests passed");
    try testing.expectEqualStrings("Build", p.title);
    try testing.expectEqualStrings("", p.subtitle);
    try testing.expectEqualStrings("All tests passed", p.body);
}

test "parseNotificationPayload all three" {
    const p = parseNotificationPayload("Build|Step 3|All tests passed");
    try testing.expectEqualStrings("Build", p.title);
    try testing.expectEqualStrings("Step 3", p.subtitle);
    try testing.expectEqualStrings("All tests passed", p.body);
}

test "parseNotificationPayload empty title defaults" {
    const p = parseNotificationPayload("|Sub|Body");
    try testing.expectEqualStrings("Notification", p.title);
    try testing.expectEqualStrings("Sub", p.subtitle);
    try testing.expectEqualStrings("Body", p.body);
}

test "parseNotificationPayload trims whitespace" {
    const p = parseNotificationPayload("  Title  |  Sub  |  Body  ");
    try testing.expectEqualStrings("Title", p.title);
    try testing.expectEqualStrings("Sub", p.subtitle);
    try testing.expectEqualStrings("Body", p.body);
}

test "parseNotificationPayload pipe in body" {
    const p = parseNotificationPayload("Title|Sub|Body with | pipes");
    try testing.expectEqualStrings("Title", p.title);
    try testing.expectEqualStrings("Sub", p.subtitle);
    try testing.expectEqualStrings("Body with | pipes", p.body);
}

test "handleNotifyTarget" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    const resp = handleNotifyTarget(
        &store,
        "11111111-1111-1111-1111-111111111111 aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa Build|Step 1|Done",
        &buf,
    );
    try testing.expectEqualStrings("OK", resp);
    try testing.expectEqual(@as(usize, 1), store.getNotifications().len);
    try testing.expectEqualStrings("Build", store.getNotifications()[0].title);
    try testing.expectEqualStrings("Step 1", store.getNotifications()[0].subtitle);
    try testing.expectEqualStrings("Done", store.getNotifications()[0].body);
}

test "handleNotifyTarget empty args" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    const resp = handleNotifyTarget(&store, "", &buf);
    try testing.expect(std.mem.startsWith(u8, resp, "ERROR:"));
}

test "handleNotifyTarget invalid uuid" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    const resp = handleNotifyTarget(&store, "not-a-uuid also-bad Title|Body", &buf);
    try testing.expect(std.mem.startsWith(u8, resp, "ERROR:"));
}

test "handleListNotifications empty" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    const resp = handleListNotifications(&store, &buf);
    try testing.expectEqualStrings("No notifications", resp);
}

test "handleListNotifications with entries" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addNotification(
        Uuid.parse("11111111-1111-1111-1111-111111111111") catch unreachable,
        Uuid.parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") catch unreachable,
        "Build",
        "Step 1",
        "Done",
    );

    var buf: [4096]u8 = undefined;
    const resp = handleListNotifications(&store, &buf);

    // Should start with "0:" and contain pipe-delimited fields.
    try testing.expect(std.mem.startsWith(u8, resp, "0:"));
    try testing.expect(std.mem.indexOf(u8, resp, "|unread|") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "|Build|") != null);
}

test "handleListNotifications null surface shows none" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addNotification(
        Uuid.parse("11111111-1111-1111-1111-111111111111") catch unreachable,
        null,
        "Title",
        "",
        "",
    );

    var buf: [4096]u8 = undefined;
    const resp = handleListNotifications(&store, &buf);
    try testing.expect(std.mem.indexOf(u8, resp, "|none|") != null);
}

test "handleClearNotifications all" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.addNotification(
        Uuid.parse("11111111-1111-1111-1111-111111111111") catch unreachable,
        null,
        "A",
        "",
        "",
    );

    var buf: [4096]u8 = undefined;
    const resp = handleClearNotifications(&store, "", &buf);
    try testing.expectEqualStrings("OK", resp);
    try testing.expectEqual(@as(usize, 0), store.getNotifications().len);
}

test "handleClearNotifications by tab" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const tab1 = Uuid.parse("11111111-1111-1111-1111-111111111111") catch unreachable;
    const tab2 = Uuid.parse("22222222-2222-2222-2222-222222222222") catch unreachable;

    try store.addNotification(tab1, null, "A", "", "");
    try store.addNotification(tab2, null, "B", "", "");

    var buf: [4096]u8 = undefined;
    const resp = handleClearNotifications(&store, "--tab=11111111-1111-1111-1111-111111111111", &buf);
    try testing.expectEqualStrings("OK", resp);
    try testing.expectEqual(@as(usize, 1), store.getNotifications().len);
    try testing.expectEqualStrings("B", store.getNotifications()[0].title);
}

test "handleClearNotifications invalid args" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var buf: [4096]u8 = undefined;
    const resp = handleClearNotifications(&store, "invalid", &buf);
    try testing.expect(std.mem.startsWith(u8, resp, "ERROR:"));
}
