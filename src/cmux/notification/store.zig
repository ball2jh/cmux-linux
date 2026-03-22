// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2025 cmux-linux contributors
//
// In-memory notification store for cmux.
// Captures OSC 9/99/777 notifications from terminal surfaces and makes
// them available via the socket API.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.cmux_notification);

/// Maximum number of stored notifications (LRU eviction).
const max_notifications = 256;

/// A single notification entry.
pub const Notification = struct {
    id: u64,
    title: []const u8,
    body: []const u8,
    surface_id: usize, // pointer address of the core surface
    timestamp: i64, // unix timestamp in seconds
    read: bool,
};

/// Global notification store. Thread-safe via mutex.
pub const Store = struct {
    alloc: Allocator,
    entries: std.ArrayListUnmanaged(Notification) = .empty,
    next_id: u64 = 1,
    mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: Allocator) Store {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |*entry| {
            self.alloc.free(entry.title);
            self.alloc.free(entry.body);
        }
        self.entries.deinit(self.alloc);
    }

    /// Add a notification. Evicts oldest if at capacity.
    pub fn add(
        self: *Store,
        title: []const u8,
        body: []const u8,
        surface_id: usize,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Evict oldest if at capacity
        if (self.entries.items.len >= max_notifications) {
            const oldest = self.entries.orderedRemove(0);
            self.alloc.free(oldest.title);
            self.alloc.free(oldest.body);
        }

        const title_copy = self.alloc.dupe(u8, title) catch return;
        const body_copy = self.alloc.dupe(u8, body) catch {
            self.alloc.free(title_copy);
            return;
        };

        const now = std.time.timestamp();

        self.entries.append(self.alloc, .{
            .id = self.next_id,
            .title = title_copy,
            .body = body_copy,
            .surface_id = surface_id,
            .timestamp = now,
            .read = false,
        }) catch {
            self.alloc.free(title_copy);
            self.alloc.free(body_copy);
            return;
        };
        self.next_id += 1;

        log.debug("notification stored: id={} title=\"{s}\"", .{ self.next_id - 1, title });
    }

    /// Get unread count.
    pub fn unreadCount(self: *Store) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (!entry.read) count += 1;
        }
        return count;
    }

    /// Format all notifications as newline-separated text for the socket API.
    pub fn formatList(self: *Store, alloc: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);

        var writer = buf.writer(alloc);
        for (self.entries.items) |entry| {
            try writer.print("{d}\t{s}\t{s}\t{d}\t{s}\n", .{
                entry.id,
                entry.title,
                entry.body,
                entry.timestamp,
                if (entry.read) "read" else "unread",
            });
        }

        return buf.toOwnedSlice(alloc);
    }

    /// Clear all notifications (or for a specific surface).
    pub fn clear(self: *Store, surface_id: ?usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (surface_id) |sid| {
            // Remove only matching surface notifications
            var i: usize = 0;
            while (i < self.entries.items.len) {
                if (self.entries.items[i].surface_id == sid) {
                    const removed = self.entries.orderedRemove(i);
                    self.alloc.free(removed.title);
                    self.alloc.free(removed.body);
                } else {
                    i += 1;
                }
            }
        } else {
            // Clear all
            for (self.entries.items) |*entry| {
                self.alloc.free(entry.title);
                self.alloc.free(entry.body);
            }
            self.entries.clearRetainingCapacity();
        }
    }

    /// Mark all notifications as read.
    pub fn markAllRead(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.entries.items) |*entry| {
            entry.read = true;
        }
    }
};

/// Global notification store singleton.
var global_store: ?*Store = null;

/// Initialize the global notification store.
pub fn initGlobal(alloc: Allocator) !void {
    const store = try alloc.create(Store);
    store.* = Store.init(alloc);
    global_store = store;
}

/// Deinitialize the global notification store.
pub fn deinitGlobal(alloc: Allocator) void {
    if (global_store) |store| {
        store.deinit();
        alloc.destroy(store);
        global_store = null;
    }
}

/// Get the global notification store.
pub fn getGlobal() ?*Store {
    return global_store;
}
