/// In-memory notification store, porting the macOS `TerminalNotificationStore`.
///
/// Manages a list of notifications with performance indexes rebuilt on every
/// mutation. One notification per tab+surface pair — adding a new notification
/// for the same pair replaces the existing one.
///
/// All operations are intended to be called from the main thread only
/// (matching the macOS `@MainActor` constraint).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Uuid = @import("../uuid.zig").Uuid;
const Notification = @import("Notification.zig").Notification;

fn UuidValueMap(comptime V: type) type {
    return std.HashMapUnmanaged(Uuid, V, Uuid.HashContext, std.hash_map.default_max_load_percentage);
}

/// Composite key for tab + optional surface lookups.
pub const TabSurfaceKey = struct {
    tab_id: Uuid,
    surface_id: ?Uuid,

    pub const HashContext = struct {
        pub fn hash(_: HashContext, key: TabSurfaceKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(&key.tab_id.bytes);
            if (key.surface_id) |sid| {
                h.update(&[_]u8{1}); // discriminator
                h.update(&sid.bytes);
            } else {
                h.update(&[_]u8{0});
            }
            return h.final();
        }

        pub fn eql(_: HashContext, a: TabSurfaceKey, b: TabSurfaceKey) bool {
            if (!Uuid.eql(a.tab_id, b.tab_id)) return false;
            const a_sid = a.surface_id orelse {
                return b.surface_id == null;
            };
            const b_sid = b.surface_id orelse return false;
            return Uuid.eql(a_sid, b_sid);
        }
    };
};

const TabSurfaceSet = std.HashMapUnmanaged(TabSurfaceKey, void, TabSurfaceKey.HashContext, std.hash_map.default_max_load_percentage);

/// Callback interface for app focus state queries.
/// Default stubs return null/false (never suppress, always deliver).
pub const FocusState = struct {
    /// Returns the currently selected tab/workspace ID.
    selected_tab_id: *const fn () ?Uuid = &defaultNoTab,
    /// Returns the focused surface ID for a given tab.
    focused_surface_id: *const fn (Uuid) ?Uuid = &defaultNoSurface,
    /// Returns true if the app window is currently focused.
    is_app_focused: *const fn () bool = &defaultNotFocused,

    fn defaultNoTab() ?Uuid {
        return null;
    }
    fn defaultNoSurface(_: Uuid) ?Uuid {
        return null;
    }
    fn defaultNotFocused() bool {
        return false;
    }
};

pub const Store = struct {
    allocator: Allocator,
    notifications: std.ArrayListUnmanaged(Notification) = .{},

    // --- Indexes (rebuilt from scratch on every mutation) ---
    unread_count: u32 = 0,
    unread_count_by_tab: UuidValueMap(u32) = .{},
    unread_by_tab_surface: TabSurfaceSet = .{},
    /// Indexes into `notifications` list.
    latest_unread_by_tab: UuidValueMap(usize) = .{},
    latest_by_tab: UuidValueMap(usize) = .{},

    // --- Focused read indicator (tabId → surfaceId) ---
    focused_read_indicator_by_tab: UuidValueMap(Uuid) = .{},

    // --- Delivery callbacks (set by GTK layer) ---
    on_deliver: ?*const fn (*const Notification) void = null,
    on_withdraw: ?*const fn (Uuid) void = null,
    on_suppressed: ?*const fn (*const Notification) void = null,

    // --- Focus state for suppression logic ---
    focus_state: FocusState = .{},

    pub fn init(allocator: Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.notifications.items) |*n| {
            self.freeNotificationStrings(n);
        }
        self.notifications.deinit(self.allocator);
        self.unread_count_by_tab.deinit(self.allocator);
        self.unread_by_tab_surface.deinit(self.allocator);
        self.latest_unread_by_tab.deinit(self.allocator);
        self.latest_by_tab.deinit(self.allocator);
        self.focused_read_indicator_by_tab.deinit(self.allocator);
    }

    // ── Core operations ──────────────────────────────────────

    /// Add a notification. Replaces any existing notification for the same
    /// tab+surface pair (matching Mac behavior: one notification per pair).
    pub fn addNotification(
        self: *Store,
        tab_id: Uuid,
        surface_id: ?Uuid,
        title: []const u8,
        subtitle: []const u8,
        body: []const u8,
    ) Allocator.Error!void {
        // Remove existing notification for this tab+surface pair.
        self.removeByTabSurface(tab_id, surface_id);

        // Clear focused read indicator if it's for a different surface on this tab.
        if (self.focused_read_indicator_by_tab.get(tab_id)) |existing_sid| {
            if (surface_id == null or !Uuid.eql(existing_sid, surface_id.?)) {
                _ = self.focused_read_indicator_by_tab.remove(tab_id);
            }
        }

        const notification = Notification{
            .id = Uuid.generate(),
            .tab_id = tab_id,
            .surface_id = surface_id,
            .title = if (title.len > 0) try self.allocator.dupe(u8, title) else "",
            .subtitle = if (subtitle.len > 0) try self.allocator.dupe(u8, subtitle) else "",
            .body = if (body.len > 0) try self.allocator.dupe(u8, body) else "",
            .created_at = std.time.milliTimestamp(),
            .is_read = false,
        };

        // Insert at front (newest first) — shift everything right.
        try self.notifications.insert(self.allocator, 0, notification);
        self.rebuildIndexes();

        // Delivery: check suppression, then deliver or suppress.
        const n_ptr = &self.notifications.items[0];
        const is_active_tab = if (self.focus_state.selected_tab_id()) |sel|
            Uuid.eql(sel, tab_id)
        else
            false;
        const is_focused_surface = if (is_active_tab)
            if (surface_id) |sid|
                if (self.focus_state.focused_surface_id(tab_id)) |fid|
                    Uuid.eql(fid, sid)
                else
                    true // null surface_id matches when no specific focus
            else
                true
        else
            false;
        const should_suppress = is_active_tab and is_focused_surface and self.focus_state.is_app_focused();

        if (should_suppress) {
            self.setFocusedReadIndicator(tab_id, surface_id);
            if (self.on_suppressed) |cb| cb(n_ptr);
        } else {
            if (self.on_deliver) |cb| cb(n_ptr);
        }
    }

    /// Mark a single notification as read by its ID.
    pub fn markRead(self: *Store, id: Uuid) void {
        for (self.notifications.items) |*n| {
            if (Uuid.eql(n.id, id) and !n.is_read) {
                n.is_read = true;
                self.rebuildIndexes();
                self.withdrawDelivered(id);
                return;
            }
        }
    }

    /// Mark all notifications for a tab as read.
    pub fn markReadForTab(self: *Store, tab_id: Uuid) void {
        var changed = false;
        for (self.notifications.items) |*n| {
            if (Uuid.eql(n.tab_id, tab_id) and !n.is_read) {
                n.is_read = true;
                self.withdrawDelivered(n.id);
                changed = true;
            }
        }
        if (changed) self.rebuildIndexes();
    }

    /// Mark all notifications for a specific tab+surface as read.
    pub fn markReadForTabSurface(self: *Store, tab_id: Uuid, surface_id: ?Uuid) void {
        var changed = false;
        for (self.notifications.items) |*n| {
            if (Uuid.eql(n.tab_id, tab_id) and optionalUuidEql(n.surface_id, surface_id) and !n.is_read) {
                n.is_read = true;
                self.withdrawDelivered(n.id);
                changed = true;
            }
        }
        if (changed) self.rebuildIndexes();
    }

    /// Mark all notifications for a tab as unread.
    pub fn markUnreadForTab(self: *Store, tab_id: Uuid) void {
        var changed = false;
        for (self.notifications.items) |*n| {
            if (Uuid.eql(n.tab_id, tab_id) and n.is_read) {
                n.is_read = false;
                changed = true;
            }
        }
        if (changed) self.rebuildIndexes();
    }

    /// Mark all notifications as read.
    pub fn markAllRead(self: *Store) void {
        var changed = false;
        for (self.notifications.items) |*n| {
            if (!n.is_read) {
                n.is_read = true;
                self.withdrawDelivered(n.id);
                changed = true;
            }
        }
        if (changed) self.rebuildIndexes();
    }

    /// Remove a single notification by ID.
    pub fn remove(self: *Store, id: Uuid) void {
        for (self.notifications.items, 0..) |*n, i| {
            if (Uuid.eql(n.id, id)) {
                self.clearFocusedReadIndicator(n.tab_id, n.surface_id);
                self.freeNotificationStrings(n);
                _ = self.notifications.orderedRemove(i);
                self.rebuildIndexes();
                return;
            }
        }
    }

    /// Remove all notifications.
    pub fn clearAll(self: *Store) void {
        if (self.notifications.items.len == 0 and self.focused_read_indicator_by_tab.count() == 0) return;
        for (self.notifications.items) |*n| {
            self.freeNotificationStrings(n);
        }
        self.notifications.clearRetainingCapacity();
        self.focused_read_indicator_by_tab.clearRetainingCapacity();
        self.rebuildIndexes();
    }

    /// Remove all notifications for a specific tab.
    pub fn clearNotificationsForTab(self: *Store, tab_id: Uuid) void {
        var i: usize = 0;
        var removed = false;
        while (i < self.notifications.items.len) {
            if (Uuid.eql(self.notifications.items[i].tab_id, tab_id)) {
                self.freeNotificationStrings(&self.notifications.items[i]);
                _ = self.notifications.orderedRemove(i);
                removed = true;
            } else {
                i += 1;
            }
        }
        if (removed) {
            self.clearFocusedReadIndicator(tab_id, null);
            self.rebuildIndexes();
        }
    }

    /// Remove all notifications for a specific tab+surface pair.
    pub fn clearNotificationsForTabSurface(self: *Store, tab_id: Uuid, surface_id: ?Uuid) void {
        var i: usize = 0;
        var removed = false;
        while (i < self.notifications.items.len) {
            const n = &self.notifications.items[i];
            if (Uuid.eql(n.tab_id, tab_id) and optionalUuidEql(n.surface_id, surface_id)) {
                self.freeNotificationStrings(n);
                _ = self.notifications.orderedRemove(i);
                removed = true;
            } else {
                i += 1;
            }
        }
        if (removed) {
            self.clearFocusedReadIndicator(tab_id, surface_id);
            self.rebuildIndexes();
        }
    }

    // ── Queries ──────────────────────────────────────────────

    pub fn getUnreadCount(self: *const Store) u32 {
        return self.unread_count;
    }

    pub fn getUnreadCountForTab(self: *const Store, tab_id: Uuid) u32 {
        return self.unread_count_by_tab.get(tab_id) orelse 0;
    }

    pub fn hasUnreadNotification(self: *const Store, tab_id: Uuid, surface_id: ?Uuid) bool {
        return self.unread_by_tab_surface.get(.{ .tab_id = tab_id, .surface_id = surface_id }) != null;
    }

    /// Returns the latest notification for a tab (prefers unread, falls back to any).
    pub fn latestNotification(self: *const Store, tab_id: Uuid) ?*const Notification {
        const idx = self.latest_unread_by_tab.get(tab_id) orelse
            self.latest_by_tab.get(tab_id) orelse
            return null;
        return &self.notifications.items[idx];
    }

    /// Returns true if there's an unread notification or a focused read indicator
    /// for this tab+surface.
    pub fn hasVisibleNotificationIndicator(self: *const Store, tab_id: Uuid, surface_id: ?Uuid) bool {
        if (self.hasUnreadNotification(tab_id, surface_id)) return true;
        if (surface_id) |sid| {
            if (self.focused_read_indicator_by_tab.get(tab_id)) |indicator_sid| {
                return Uuid.eql(indicator_sid, sid);
            }
        }
        return false;
    }

    /// Returns the full notification list (newest first).
    pub fn getNotifications(self: *const Store) []const Notification {
        return self.notifications.items;
    }

    // ── Focused read indicator ───────────────────────────────

    pub fn setFocusedReadIndicator(self: *Store, tab_id: Uuid, surface_id: ?Uuid) void {
        const sid = surface_id orelse return;
        if (self.focused_read_indicator_by_tab.get(tab_id)) |existing| {
            if (Uuid.eql(existing, sid)) return;
        }
        self.focused_read_indicator_by_tab.put(self.allocator, tab_id, sid) catch {};
    }

    pub fn clearFocusedReadIndicator(self: *Store, tab_id: Uuid, surface_id: ?Uuid) void {
        const existing = self.focused_read_indicator_by_tab.get(tab_id) orelse return;
        if (surface_id) |sid| {
            if (!Uuid.eql(existing, sid)) return;
        }
        _ = self.focused_read_indicator_by_tab.remove(tab_id);
    }

    pub fn clearFocusedReadIndicatorIfSurfaceChanged(self: *Store, tab_id: Uuid, surface_id: ?Uuid) void {
        const existing = self.focused_read_indicator_by_tab.get(tab_id) orelse return;
        if (surface_id) |sid| {
            if (Uuid.eql(existing, sid)) return; // same surface, don't clear
        }
        _ = self.focused_read_indicator_by_tab.remove(tab_id);
    }

    pub fn getFocusedReadIndicatorSurfaceId(self: *const Store, tab_id: Uuid) ?Uuid {
        return self.focused_read_indicator_by_tab.get(tab_id);
    }

    // ── Internals ────────────────────────────────────────────

    fn rebuildIndexes(self: *Store) void {
        self.unread_count = 0;
        self.unread_count_by_tab.clearRetainingCapacity();
        self.unread_by_tab_surface.clearRetainingCapacity();
        self.latest_unread_by_tab.clearRetainingCapacity();
        self.latest_by_tab.clearRetainingCapacity();

        for (self.notifications.items, 0..) |n, i| {
            // Latest by tab: first occurrence wins (list is newest-first).
            if (self.latest_by_tab.get(n.tab_id) == null) {
                self.latest_by_tab.put(self.allocator, n.tab_id, i) catch {};
            }

            if (!n.is_read) {
                self.unread_count += 1;
                const entry = self.unread_count_by_tab.getOrPutValue(self.allocator, n.tab_id, 0) catch continue;
                entry.value_ptr.* += 1;
                self.unread_by_tab_surface.put(self.allocator, .{
                    .tab_id = n.tab_id,
                    .surface_id = n.surface_id,
                }, {}) catch {};
                if (self.latest_unread_by_tab.get(n.tab_id) == null) {
                    self.latest_unread_by_tab.put(self.allocator, n.tab_id, i) catch {};
                }
            }
        }
    }

    fn removeByTabSurface(self: *Store, tab_id: Uuid, surface_id: ?Uuid) void {
        var i: usize = 0;
        while (i < self.notifications.items.len) {
            const n = &self.notifications.items[i];
            if (Uuid.eql(n.tab_id, tab_id) and optionalUuidEql(n.surface_id, surface_id)) {
                self.freeNotificationStrings(n);
                _ = self.notifications.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        // Don't rebuild indexes — caller will do it after inserting the replacement.
    }

    fn freeNotificationStrings(self: *Store, n: *Notification) void {
        if (n.title.len > 0) self.allocator.free(n.title);
        if (n.subtitle.len > 0) self.allocator.free(n.subtitle);
        if (n.body.len > 0) self.allocator.free(n.body);
    }

    fn withdrawDelivered(self: *Store, id: Uuid) void {
        if (self.on_withdraw) |cb| cb(id);
    }

    fn optionalUuidEql(a: ?Uuid, b: ?Uuid) bool {
        const a_val = a orelse return b == null;
        const b_val = b orelse return false;
        return Uuid.eql(a_val, b_val);
    }
};

// ══════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════

const testing = std.testing;

fn testStore() Store {
    return Store.init(testing.allocator);
}

const test_tab1 = Uuid.parse("11111111-1111-1111-1111-111111111111") catch unreachable;
const test_tab2 = Uuid.parse("22222222-2222-2222-2222-222222222222") catch unreachable;
const test_surface1 = Uuid.parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") catch unreachable;
const test_surface2 = Uuid.parse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb") catch unreachable;

test "empty store" {
    var store = testStore();
    defer store.deinit();

    try testing.expectEqual(@as(u32, 0), store.getUnreadCount());
    try testing.expectEqual(@as(u32, 0), store.getUnreadCountForTab(test_tab1));
    try testing.expect(!store.hasUnreadNotification(test_tab1, null));
    try testing.expect(store.latestNotification(test_tab1) == null);
    try testing.expectEqual(@as(usize, 0), store.getNotifications().len);
}

test "add notification" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "Title", "Sub", "Body");

    try testing.expectEqual(@as(usize, 1), store.getNotifications().len);
    try testing.expectEqual(@as(u32, 1), store.getUnreadCount());
    try testing.expectEqual(@as(u32, 1), store.getUnreadCountForTab(test_tab1));
    try testing.expect(store.hasUnreadNotification(test_tab1, test_surface1));
    try testing.expect(!store.hasUnreadNotification(test_tab1, test_surface2));

    const latest = store.latestNotification(test_tab1).?;
    try testing.expectEqualStrings("Title", latest.title);
    try testing.expectEqualStrings("Sub", latest.subtitle);
    try testing.expectEqualStrings("Body", latest.body);
    try testing.expect(!latest.is_read);
}

test "add replaces same tab+surface" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "Old", "", "");
    try store.addNotification(test_tab1, test_surface1, "New", "", "");

    try testing.expectEqual(@as(usize, 1), store.getNotifications().len);
    try testing.expectEqualStrings("New", store.getNotifications()[0].title);
}

test "add does not replace different surface" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "First", "", "");
    try store.addNotification(test_tab1, test_surface2, "Second", "", "");

    try testing.expectEqual(@as(usize, 2), store.getNotifications().len);
    try testing.expectEqual(@as(u32, 2), store.getUnreadCount());
}

test "add workspace-level notification (null surface)" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, null, "Workspace", "", "");

    try testing.expectEqual(@as(usize, 1), store.getNotifications().len);
    try testing.expect(store.hasUnreadNotification(test_tab1, null));
    try testing.expect(!store.hasUnreadNotification(test_tab1, test_surface1));
}

test "newest first ordering" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "First", "", "");
    try store.addNotification(test_tab2, test_surface2, "Second", "", "");

    try testing.expectEqualStrings("Second", store.getNotifications()[0].title);
    try testing.expectEqualStrings("First", store.getNotifications()[1].title);
}

test "markRead by id" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "A", "", "");
    const id = store.getNotifications()[0].id;

    store.markRead(id);

    try testing.expectEqual(@as(u32, 0), store.getUnreadCount());
    try testing.expect(store.getNotifications()[0].is_read);
}

test "markRead no-op for already read" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "A", "", "");
    const id = store.getNotifications()[0].id;

    store.markRead(id);
    store.markRead(id); // should not panic or error

    try testing.expectEqual(@as(u32, 0), store.getUnreadCount());
}

test "markRead no-op for nonexistent id" {
    var store = testStore();
    defer store.deinit();

    store.markRead(Uuid.generate()); // should not panic
}

test "markReadForTab" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "A", "", "");
    try store.addNotification(test_tab1, test_surface2, "B", "", "");
    try store.addNotification(test_tab2, test_surface1, "C", "", "");

    store.markReadForTab(test_tab1);

    try testing.expectEqual(@as(u32, 1), store.getUnreadCount());
    try testing.expectEqual(@as(u32, 0), store.getUnreadCountForTab(test_tab1));
    try testing.expectEqual(@as(u32, 1), store.getUnreadCountForTab(test_tab2));
}

test "markReadForTabSurface" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "A", "", "");
    try store.addNotification(test_tab1, test_surface2, "B", "", "");

    store.markReadForTabSurface(test_tab1, test_surface1);

    try testing.expectEqual(@as(u32, 1), store.getUnreadCount());
    try testing.expect(!store.hasUnreadNotification(test_tab1, test_surface1));
    try testing.expect(store.hasUnreadNotification(test_tab1, test_surface2));
}

test "markUnreadForTab" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "A", "", "");
    store.markAllRead();
    try testing.expectEqual(@as(u32, 0), store.getUnreadCount());

    store.markUnreadForTab(test_tab1);
    try testing.expectEqual(@as(u32, 1), store.getUnreadCount());
}

test "markAllRead" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "A", "", "");
    try store.addNotification(test_tab2, test_surface2, "B", "", "");

    store.markAllRead();

    try testing.expectEqual(@as(u32, 0), store.getUnreadCount());
    try testing.expectEqual(@as(usize, 2), store.getNotifications().len);
}

test "remove by id" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "A", "", "");
    try store.addNotification(test_tab2, test_surface2, "B", "", "");
    const id = store.getNotifications()[1].id; // "A" is at index 1

    store.remove(id);

    try testing.expectEqual(@as(usize, 1), store.getNotifications().len);
    try testing.expectEqualStrings("B", store.getNotifications()[0].title);
}

test "remove nonexistent id is no-op" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "A", "", "");
    store.remove(Uuid.generate());

    try testing.expectEqual(@as(usize, 1), store.getNotifications().len);
}

test "clearAll" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "A", "", "");
    try store.addNotification(test_tab2, test_surface2, "B", "", "");

    store.clearAll();

    try testing.expectEqual(@as(usize, 0), store.getNotifications().len);
    try testing.expectEqual(@as(u32, 0), store.getUnreadCount());
}

test "clearAll on empty store is no-op" {
    var store = testStore();
    defer store.deinit();
    store.clearAll(); // should not panic
}

test "clearNotificationsForTab" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "A", "", "");
    try store.addNotification(test_tab1, test_surface2, "B", "", "");
    try store.addNotification(test_tab2, test_surface1, "C", "", "");

    store.clearNotificationsForTab(test_tab1);

    try testing.expectEqual(@as(usize, 1), store.getNotifications().len);
    try testing.expectEqualStrings("C", store.getNotifications()[0].title);
}

test "clearNotificationsForTabSurface" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "A", "", "");
    try store.addNotification(test_tab1, test_surface2, "B", "", "");

    store.clearNotificationsForTabSurface(test_tab1, test_surface1);

    try testing.expectEqual(@as(usize, 1), store.getNotifications().len);
    try testing.expectEqualStrings("B", store.getNotifications()[0].title);
}

test "latestNotification prefers unread" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "Older", "", "");
    try store.addNotification(test_tab1, test_surface2, "Newer", "", "");

    // Both unread — latest (index 0) should be returned.
    const latest = store.latestNotification(test_tab1).?;
    try testing.expectEqualStrings("Newer", latest.title);

    // Mark the newer one as read — older unread should be returned.
    store.markRead(store.getNotifications()[0].id);
    const latest2 = store.latestNotification(test_tab1).?;
    try testing.expectEqualStrings("Older", latest2.title);

    // Mark both read — falls back to latest by tab (newest).
    store.markAllRead();
    const latest3 = store.latestNotification(test_tab1).?;
    try testing.expectEqualStrings("Newer", latest3.title);
}

test "focused read indicator set and clear" {
    var store = testStore();
    defer store.deinit();

    store.setFocusedReadIndicator(test_tab1, test_surface1);
    try testing.expect(Uuid.eql(store.getFocusedReadIndicatorSurfaceId(test_tab1).?, test_surface1));

    store.clearFocusedReadIndicator(test_tab1, test_surface1);
    try testing.expect(store.getFocusedReadIndicatorSurfaceId(test_tab1) == null);
}

test "clearFocusedReadIndicator ignores wrong surface" {
    var store = testStore();
    defer store.deinit();

    store.setFocusedReadIndicator(test_tab1, test_surface1);
    store.clearFocusedReadIndicator(test_tab1, test_surface2); // wrong surface

    try testing.expect(store.getFocusedReadIndicatorSurfaceId(test_tab1) != null);
}

test "clearFocusedReadIndicator with null clears any" {
    var store = testStore();
    defer store.deinit();

    store.setFocusedReadIndicator(test_tab1, test_surface1);
    store.clearFocusedReadIndicator(test_tab1, null);

    try testing.expect(store.getFocusedReadIndicatorSurfaceId(test_tab1) == null);
}

test "clearFocusedReadIndicatorIfSurfaceChanged" {
    var store = testStore();
    defer store.deinit();

    store.setFocusedReadIndicator(test_tab1, test_surface1);

    // Same surface — should NOT clear.
    store.clearFocusedReadIndicatorIfSurfaceChanged(test_tab1, test_surface1);
    try testing.expect(store.getFocusedReadIndicatorSurfaceId(test_tab1) != null);

    // Different surface — should clear.
    store.clearFocusedReadIndicatorIfSurfaceChanged(test_tab1, test_surface2);
    try testing.expect(store.getFocusedReadIndicatorSurfaceId(test_tab1) == null);
}

test "hasVisibleNotificationIndicator" {
    var store = testStore();
    defer store.deinit();

    // Unread notification makes it visible.
    try store.addNotification(test_tab1, test_surface1, "A", "", "");
    try testing.expect(store.hasVisibleNotificationIndicator(test_tab1, test_surface1));

    // Mark read — no longer visible via unread.
    store.markAllRead();
    try testing.expect(!store.hasVisibleNotificationIndicator(test_tab1, test_surface1));

    // Focused read indicator makes it visible.
    store.setFocusedReadIndicator(test_tab1, test_surface1);
    try testing.expect(store.hasVisibleNotificationIndicator(test_tab1, test_surface1));
    try testing.expect(!store.hasVisibleNotificationIndicator(test_tab1, test_surface2));
}

test "add notification with empty strings" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "", "", "");

    try testing.expectEqual(@as(usize, 1), store.getNotifications().len);
    try testing.expectEqualStrings("", store.getNotifications()[0].title);
}

test "indexes after mixed operations" {
    var store = testStore();
    defer store.deinit();

    try store.addNotification(test_tab1, test_surface1, "A", "", "");
    try store.addNotification(test_tab1, test_surface2, "B", "", "");
    try store.addNotification(test_tab2, test_surface1, "C", "", "");

    // 3 unread across 2 tabs
    try testing.expectEqual(@as(u32, 3), store.getUnreadCount());
    try testing.expectEqual(@as(u32, 2), store.getUnreadCountForTab(test_tab1));
    try testing.expectEqual(@as(u32, 1), store.getUnreadCountForTab(test_tab2));

    // Mark tab1 read
    store.markReadForTab(test_tab1);
    try testing.expectEqual(@as(u32, 1), store.getUnreadCount());
    try testing.expectEqual(@as(u32, 0), store.getUnreadCountForTab(test_tab1));

    // Remove the remaining unread
    store.clearNotificationsForTab(test_tab2);
    try testing.expectEqual(@as(u32, 0), store.getUnreadCount());
    try testing.expectEqual(@as(usize, 2), store.getNotifications().len);
}
