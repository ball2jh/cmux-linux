/// Menu model for the com.canonical.dbusmenu protocol.
///
/// Manages a menu item tree that is serialized via the `GetLayout` D-Bus method.
/// Menu items have fixed IDs so the tray host can track them across rebuilds.
///
/// Ports the macOS `NotificationMenuSnapshotBuilder` and `MenuBarExtraController.buildMenu()`.
const std = @import("std");
const notification = @import("../notification/main.zig");
const badge = @import("../notification/badge.zig");
const workspace = @import("../workspace/main.zig");

const log = std.log.scoped(.cmux_menu_model);

// ── Fixed menu item IDs ──────────────────────────────────────

pub const id_root: i32 = 0;
pub const id_state_hint: i32 = 1;
pub const id_sep_after_notifications: i32 = 50;
pub const id_notification_base: i32 = 10; // 10..15 for up to 6 notifications
pub const id_sep_before_actions: i32 = 51;
pub const id_show_notifications: i32 = 20;
pub const id_jump_to_unread: i32 = 21;
pub const id_mark_all_read: i32 = 22;
pub const id_clear_all: i32 = 23;
pub const id_sep_before_prefs: i32 = 52;
pub const id_preferences: i32 = 31;
pub const id_sep_before_quit: i32 = 53;
pub const id_quit: i32 = 33;

pub const max_inline_notifications: usize = 6;

/// Max bytes for a formatted notification label.
/// Format: "● Title  HH:MM\nBody\nTab Title" — 3 lines max.
pub const max_label_len: usize = 384;

/// Callbacks for menu item activation.
pub const Callbacks = struct {
    on_show_notifications: ?*const fn () void = null,
    on_open_notification: ?*const fn (usize) void = null, // index into store
    on_jump_to_unread: ?*const fn () void = null,
    on_mark_all_read: ?*const fn () void = null,
    on_clear_all: ?*const fn () void = null,
    on_open_preferences: ?*const fn () void = null,
    on_quit: ?*const fn () void = null,
};

pub const MenuModel = struct {
    revision: u32 = 0,
    unread_count: u32 = 0,
    total_count: u32 = 0,
    inline_count: u32 = 0,
    callbacks: Callbacks = .{},

    /// Formatted notification labels for inline items.
    /// Each label matches the macOS format: "● Title  HH:MM\nBody\nTab Title"
    inline_labels: [max_inline_notifications][max_label_len]u8 = undefined,
    inline_label_lens: [max_inline_notifications]u16 = .{0} ** max_inline_notifications,

    pub fn init(callbacks: Callbacks) MenuModel {
        return .{ .callbacks = callbacks };
    }

    /// Rebuild menu state from the notification store.
    /// `manager` is optional — when provided, tab titles are resolved from workspace names.
    pub fn rebuild(self: *MenuModel, store: *const notification.Store, manager: ?*const workspace.Manager) void {
        self.unread_count = store.getUnreadCount();
        const notifications = store.getNotifications();
        self.total_count = @intCast(notifications.len);
        self.inline_count = @intCast(@min(notifications.len, max_inline_notifications));

        // Format notification labels matching macOS MenuBarNotificationLineFormatter.plainTitle.
        for (0..self.inline_count) |i| {
            const n = &notifications[i];
            // Resolve tab title from workspace manager (matches Mac's tabTitle(for:) lookup).
            const tab_title: ?[]const u8 = if (manager) |mgr|
                if (mgr.workspaceById(n.tab_id)) |ws| ws.displayTitle() else null
            else
                null;
            self.inline_label_lens[i] = @intCast(formatNotificationLabel(
                &self.inline_labels[i],
                n,
                tab_title,
            ));
        }

        self.revision +%= 1;
    }

    /// Get the inline label for notification at index `i`.
    pub fn inlineLabel(self: *const MenuModel, i: usize) []const u8 {
        return self.inline_labels[i][0..self.inline_label_lens[i]];
    }

    /// Handle a menu item click event.
    pub fn handleEvent(self: *const MenuModel, item_id: i32) void {
        // Notification items.
        if (item_id >= id_notification_base and item_id < id_notification_base + @as(i32, @intCast(max_inline_notifications))) {
            const idx: usize = @intCast(item_id - id_notification_base);
            if (idx < self.inline_count) {
                if (self.callbacks.on_open_notification) |cb| cb(idx);
            }
            return;
        }

        switch (item_id) {
            id_show_notifications => if (self.callbacks.on_show_notifications) |cb| cb(),
            id_jump_to_unread => if (self.callbacks.on_jump_to_unread) |cb| cb(),
            id_mark_all_read => if (self.callbacks.on_mark_all_read) |cb| cb(),
            id_clear_all => if (self.callbacks.on_clear_all) |cb| cb(),
            id_preferences => if (self.callbacks.on_open_preferences) |cb| cb(),
            id_quit => if (self.callbacks.on_quit) |cb| cb(),
            else => log.debug("unknown menu item id: {}", .{item_id}),
        }
    }

    /// Get the state hint text for the current unread count.
    pub fn stateHintText(self: *const MenuModel, buf: []u8) []const u8 {
        return badge.stateHintTitle(buf, self.unread_count);
    }
};

// ── Notification label formatting ────────────────────────────

/// Format a notification label matching macOS MenuBarNotificationLineFormatter.plainTitle:
///   "● Title  HH:MM\nBody or Subtitle\nTab Title"
///
/// - Unread: `●` bullet prefix. Read: two spaces.
/// - Time: hours:minutes from created_at (millis since epoch).
/// - Detail: body if non-empty, else subtitle. Omitted if both empty.
/// - Tab title: omitted for now (not stored in Notification struct).
///
/// Returns the number of bytes written.
fn formatNotificationLabel(
    buf: *[max_label_len]u8,
    n: *const notification.Notification,
    tab_title: ?[]const u8,
) usize {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    // Read indicator.
    if (n.is_read) {
        w.writeAll("  ") catch return fbs.pos;
    } else {
        // UTF-8 bullet: ● = E2 97 8F, then a space.
        w.writeAll("\xe2\x97\x8f ") catch return fbs.pos;
    }

    // Title (truncate to keep room for time).
    const title_max = 80;
    const title = if (n.title.len > title_max) n.title[0..title_max] else n.title;
    w.writeAll(title) catch return fbs.pos;

    // Time suffix: "  HH:MM"
    {
        w.writeAll("  ") catch return fbs.pos;
        formatTime(w, n.created_at) catch {};
    }

    // Detail line (body or subtitle).
    const detail = if (n.body.len > 0) n.body else n.subtitle;
    if (detail.len > 0) {
        w.writeAll("\n") catch return fbs.pos;
        const detail_max = 120;
        const d = if (detail.len > detail_max) detail[0..detail_max] else detail;
        w.writeAll(d) catch return fbs.pos;
    }

    // Tab title line (matches Mac's last line).
    if (tab_title) |tt| {
        if (tt.len > 0) {
            w.writeAll("\n") catch return fbs.pos;
            const tt_max = 80;
            const t = if (tt.len > tt_max) tt[0..tt_max] else tt;
            w.writeAll(t) catch return fbs.pos;
        }
    }

    return fbs.pos;
}

/// Write "HH:MM" from milliseconds-since-epoch into writer, using local time.
fn formatTime(w: anytype, millis: i64) !void {
    const c = @cImport({ @cInclude("time.h"); });
    const secs: c.time_t = @intCast(@divTrunc(millis, 1000));
    const tm: *const c.struct_tm = c.localtime(&secs) orelse return;
    try w.print("{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
    });
}

// ══════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════

const testing = std.testing;

test "MenuModel init has zero state" {
    const model = MenuModel.init(.{});
    try testing.expectEqual(@as(u32, 0), model.revision);
    try testing.expectEqual(@as(u32, 0), model.unread_count);
    try testing.expectEqual(@as(u32, 0), model.total_count);
    try testing.expectEqual(@as(u32, 0), model.inline_count);
}

test "MenuModel rebuild increments revision" {
    var model = MenuModel.init(.{});
    var store = notification.Store.init(testing.allocator);
    defer store.deinit();

    model.rebuild(&store, null);
    try testing.expectEqual(@as(u32, 1), model.revision);

    model.rebuild(&store, null);
    try testing.expectEqual(@as(u32, 2), model.revision);
}

test "MenuModel rebuild captures notification state" {
    var model = MenuModel.init(.{});
    var store = notification.Store.init(testing.allocator);
    defer store.deinit();

    const Uuid = @import("../uuid.zig").Uuid;
    const tab = Uuid.generate();
    const surface = Uuid.generate();
    try store.addNotification(tab, surface, "Hello", "", "");

    model.rebuild(&store, null);
    try testing.expectEqual(@as(u32, 1), model.unread_count);
    try testing.expectEqual(@as(u32, 1), model.total_count);
    try testing.expectEqual(@as(u32, 1), model.inline_count);

    // Label should start with bullet (unread).
    const label = model.inlineLabel(0);
    try testing.expect(std.mem.startsWith(u8, label, "\xe2\x97\x8f "));
    try testing.expect(std.mem.indexOf(u8, label, "Hello") != null);
}

test "MenuModel rebuild caps inline notifications" {
    var model = MenuModel.init(.{});
    var store = notification.Store.init(testing.allocator);
    defer store.deinit();

    const Uuid = @import("../uuid.zig").Uuid;
    const tab = Uuid.generate();

    // Add 8 notifications (more than max_inline_notifications).
    for (0..8) |i| {
        const surface = Uuid.generate();
        var title_buf: [16]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Notif {}", .{i}) catch unreachable;
        try store.addNotification(tab, surface, title, "", "");
    }

    model.rebuild(&store, null);
    try testing.expectEqual(@as(u32, 8), model.total_count);
    try testing.expectEqual(@as(u32, max_inline_notifications), @as(usize, model.inline_count));
}

test "MenuModel handleEvent dispatches callbacks" {
    const S = struct {
        var show_called = false;
        var quit_called = false;
        var notif_idx: ?usize = null;

        fn onShow() void {
            show_called = true;
        }
        fn onQuit() void {
            quit_called = true;
        }
        fn onNotif(idx: usize) void {
            notif_idx = idx;
        }
    };

    S.show_called = false;
    S.quit_called = false;
    S.notif_idx = null;

    var model = MenuModel.init(.{
        .on_show_notifications = &S.onShow,
        .on_quit = &S.onQuit,
        .on_open_notification = &S.onNotif,
    });
    model.inline_count = 3;

    model.handleEvent(id_show_notifications);
    try testing.expect(S.show_called);

    model.handleEvent(id_quit);
    try testing.expect(S.quit_called);

    model.handleEvent(id_notification_base + 2);
    try testing.expectEqual(@as(?usize, 2), S.notif_idx);
}

test "MenuModel stateHintText" {
    var model = MenuModel.init(.{});
    var buf: [128]u8 = undefined;

    model.unread_count = 0;
    try testing.expectEqualStrings("No unread notifications", model.stateHintText(&buf));

    model.unread_count = 1;
    try testing.expectEqualStrings("1 unread notification", model.stateHintText(&buf));

    model.unread_count = 5;
    try testing.expectEqualStrings("5 unread notifications", model.stateHintText(&buf));
}

test "formatNotificationLabel unread with body" {
    const n = notification.Notification{
        .id = @import("../uuid.zig").Uuid.generate(),
        .tab_id = @import("../uuid.zig").Uuid.generate(),
        .surface_id = null,
        .title = "Build started",
        .subtitle = "",
        .body = "Release build for v0.2.0",
        .created_at = 1711324800000, // Some timestamp
        .is_read = false,
    };
    var buf: [max_label_len]u8 = undefined;
    const len = formatNotificationLabel(&buf, &n, null);
    const label = buf[0..len];

    // Should start with bullet.
    try testing.expect(std.mem.startsWith(u8, label, "\xe2\x97\x8f "));
    // Should contain the title.
    try testing.expect(std.mem.indexOf(u8, label, "Build started") != null);
    // Should contain the body on a second line.
    try testing.expect(std.mem.indexOf(u8, label, "\nRelease build for v0.2.0") != null);
    // Should contain time.
    try testing.expect(std.mem.indexOf(u8, label, ":") != null);
}

test "formatNotificationLabel read no body" {
    const n = notification.Notification{
        .id = @import("../uuid.zig").Uuid.generate(),
        .tab_id = @import("../uuid.zig").Uuid.generate(),
        .surface_id = null,
        .title = "Done",
        .subtitle = "Subtitled",
        .body = "",
        .created_at = 0,
        .is_read = true,
    };
    var buf: [max_label_len]u8 = undefined;
    const len = formatNotificationLabel(&buf, &n, null);
    const label = buf[0..len];

    // Should start with spaces (read).
    try testing.expect(std.mem.startsWith(u8, label, "  "));
    // Should NOT start with bullet.
    try testing.expect(!std.mem.startsWith(u8, label, "\xe2\x97\x8f"));
    // Should contain subtitle since body is empty.
    try testing.expect(std.mem.indexOf(u8, label, "Subtitled") != null);
}

// ── Additional menu model edge cases ─────────────────────────────────

test "formatNotificationLabel with tab title" {
    const n = notification.Notification{
        .id = @import("../uuid.zig").Uuid.generate(),
        .tab_id = @import("../uuid.zig").Uuid.generate(),
        .surface_id = null,
        .title = "Build",
        .subtitle = "",
        .body = "Completed",
        .created_at = 1711324800000,
        .is_read = false,
    };
    var buf: [max_label_len]u8 = undefined;
    const len = formatNotificationLabel(&buf, &n, "Workspace Alpha");
    const label = buf[0..len];

    // Should contain tab title on a separate line.
    try testing.expect(std.mem.indexOf(u8, label, "\nWorkspace Alpha") != null);
}

test "formatNotificationLabel no body or subtitle" {
    const n = notification.Notification{
        .id = @import("../uuid.zig").Uuid.generate(),
        .tab_id = @import("../uuid.zig").Uuid.generate(),
        .surface_id = null,
        .title = "Alert",
        .subtitle = "",
        .body = "",
        .created_at = 0,
        .is_read = false,
    };
    var buf: [max_label_len]u8 = undefined;
    const len = formatNotificationLabel(&buf, &n, null);
    const label = buf[0..len];

    // Should contain the title.
    try testing.expect(std.mem.indexOf(u8, label, "Alert") != null);
    // Should NOT have a second newline (no detail line).
    var newline_count: usize = 0;
    for (label) |c| {
        if (c == '\n') newline_count += 1;
    }
    try testing.expectEqual(@as(usize, 0), newline_count);
}

test "MenuModel handleEvent ignores out of range notification index" {
    const S = struct {
        var notif_idx: ?usize = null;
        fn onNotif(idx: usize) void {
            notif_idx = idx;
        }
    };
    S.notif_idx = null;

    var model = MenuModel.init(.{
        .on_open_notification = &S.onNotif,
    });
    model.inline_count = 2;

    // Index 5 is out of range (only 2 inline items).
    model.handleEvent(id_notification_base + 5);
    try testing.expect(S.notif_idx == null);
}

test "MenuModel handleEvent dispatches mark_all_read and clear_all" {
    const S = struct {
        var mark_read_called = false;
        var clear_called = false;
        fn onMarkRead() void {
            mark_read_called = true;
        }
        fn onClear() void {
            clear_called = true;
        }
    };
    S.mark_read_called = false;
    S.clear_called = false;

    const model = MenuModel.init(.{
        .on_mark_all_read = &S.onMarkRead,
        .on_clear_all = &S.onClear,
    });

    model.handleEvent(id_mark_all_read);
    try testing.expect(S.mark_read_called);

    model.handleEvent(id_clear_all);
    try testing.expect(S.clear_called);
}
