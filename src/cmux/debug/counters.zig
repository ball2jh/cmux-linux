//! Debug diagnostic counters.
//!
//! Thread-safe counters for flash events, empty panels, and bonsplit
//! underflows. These are incremented by the GTK/workspace layer and
//! queried/reset via debug.* socket commands.
//!
//! Matches macOS flash_count / empty_panel_count / bonsplit_underflow_count
//! diagnostic state (TerminalController lines 10677-10699, 10711-10724).

const std = @import("std");
const Uuid = @import("../uuid.zig").Uuid;

pub const Counters = struct {
    // --- Flash counts (per surface) ---
    flash_counts: std.AutoArrayHashMapUnmanaged(Uuid, u32) = .{},
    flash_mutex: std.Thread.Mutex = .{},

    // --- Global counters (atomic, no mutex needed) ---
    empty_panel_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    bonsplit_underflow_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Allocator for the flash_counts map.
    alloc: std.mem.Allocator = undefined,

    // --- Flash ---

    pub fn incrementFlash(self: *Counters, surface_id: Uuid) void {
        self.flash_mutex.lock();
        defer self.flash_mutex.unlock();
        const entry = self.flash_counts.getOrPut(self.alloc, surface_id) catch return;
        if (!entry.found_existing) {
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
    }

    pub fn getFlashCount(self: *Counters, surface_id: Uuid) u32 {
        self.flash_mutex.lock();
        defer self.flash_mutex.unlock();
        return self.flash_counts.get(surface_id) orelse 0;
    }

    pub fn resetFlashCounts(self: *Counters) void {
        self.flash_mutex.lock();
        defer self.flash_mutex.unlock();
        self.flash_counts.clearRetainingCapacity();
    }

    // --- Empty panel ---

    pub fn incrementEmptyPanel(self: *Counters) void {
        _ = self.empty_panel_count.fetchAdd(1, .monotonic);
    }

    pub fn getEmptyPanelCount(self: *const Counters) u32 {
        return self.empty_panel_count.load(.monotonic);
    }

    pub fn resetEmptyPanelCount(self: *Counters) void {
        self.empty_panel_count.store(0, .monotonic);
    }

    // --- Bonsplit underflow ---

    pub fn incrementBonsplitUnderflow(self: *Counters) void {
        _ = self.bonsplit_underflow_count.fetchAdd(1, .monotonic);
    }

    pub fn getBonsplitUnderflowCount(self: *const Counters) u32 {
        return self.bonsplit_underflow_count.load(.monotonic);
    }

    pub fn resetBonsplitUnderflowCount(self: *Counters) void {
        self.bonsplit_underflow_count.store(0, .monotonic);
    }

    pub fn deinit(self: *Counters) void {
        self.flash_counts.deinit(self.alloc);
    }
};

// --- Tests ---

test "flash counter increment and query" {
    var c = Counters{};
    c.alloc = std.testing.allocator;
    defer c.deinit();

    const id = @import("../uuid.zig").Uuid.generate();
    try std.testing.expectEqual(@as(u32, 0), c.getFlashCount(id));
    c.incrementFlash(id);
    c.incrementFlash(id);
    try std.testing.expectEqual(@as(u32, 2), c.getFlashCount(id));
    c.resetFlashCounts();
    try std.testing.expectEqual(@as(u32, 0), c.getFlashCount(id));
}

test "empty panel counter" {
    var c = Counters{};
    try std.testing.expectEqual(@as(u32, 0), c.getEmptyPanelCount());
    c.incrementEmptyPanel();
    c.incrementEmptyPanel();
    c.incrementEmptyPanel();
    try std.testing.expectEqual(@as(u32, 3), c.getEmptyPanelCount());
    c.resetEmptyPanelCount();
    try std.testing.expectEqual(@as(u32, 0), c.getEmptyPanelCount());
}

test "bonsplit underflow counter" {
    var c = Counters{};
    try std.testing.expectEqual(@as(u32, 0), c.getBonsplitUnderflowCount());
    c.incrementBonsplitUnderflow();
    try std.testing.expectEqual(@as(u32, 1), c.getBonsplitUnderflowCount());
    c.resetBonsplitUnderflowCount();
    try std.testing.expectEqual(@as(u32, 0), c.getBonsplitUnderflowCount());
}
