// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2025 cmux-linux contributors
//
// Workspace sidebar metadata: status entries, progress bars, and log entries.
// These are displayed in the workspace sidebar and controlled via socket API.
// Matches the macOS cmux SidebarStatusEntry / SidebarMetadataBlock model.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.cmux_status);

/// Maximum entries per workspace.
const max_status_entries = 64;
const max_log_entries = 256;
const max_progress_entries = 16;

/// A status entry displayed in the sidebar.
pub const StatusEntry = struct {
    key: []const u8,
    value: []const u8,
    icon: ?[]const u8 = null,
    color: ?[]const u8 = null, // hex color e.g. "#3a944a"
    priority: i32 = 0,
    timestamp: i64,
};

/// A progress indicator displayed in the sidebar.
pub const ProgressEntry = struct {
    key: []const u8,
    value: f64, // 0.0 to 1.0
    label: ?[]const u8 = null,
};

/// A log entry in the workspace log.
pub const LogEntry = struct {
    message: []const u8,
    level: Level = .info,
    timestamp: i64,

    pub const Level = enum { debug, info, warn, err };
};

/// Per-workspace metadata store.
pub const WorkspaceStatus = struct {
    alloc: Allocator,
    statuses: std.ArrayListUnmanaged(StatusEntry) = .empty,
    progress: std.ArrayListUnmanaged(ProgressEntry) = .empty,
    logs: std.ArrayListUnmanaged(LogEntry) = .empty,

    pub fn init(alloc: Allocator) WorkspaceStatus {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *WorkspaceStatus) void {
        for (self.statuses.items) |*s| self.freeStatus(s);
        self.statuses.deinit(self.alloc);
        for (self.progress.items) |*p| self.freeProgress(p);
        self.progress.deinit(self.alloc);
        for (self.logs.items) |*l| self.alloc.free(l.message);
        self.logs.deinit(self.alloc);
    }

    // --- Status ---

    pub fn setStatus(self: *WorkspaceStatus, key: []const u8, value: []const u8) !void {
        // Update existing or insert
        for (self.statuses.items) |*s| {
            if (std.mem.eql(u8, s.key, key)) {
                self.alloc.free(s.value);
                s.value = try self.alloc.dupe(u8, value);
                s.timestamp = std.time.timestamp();
                return;
            }
        }
        if (self.statuses.items.len >= max_status_entries) return error.TooManyEntries;
        try self.statuses.append(self.alloc, .{
            .key = try self.alloc.dupe(u8, key),
            .value = try self.alloc.dupe(u8, value),
            .timestamp = std.time.timestamp(),
        });
    }

    pub fn clearStatus(self: *WorkspaceStatus, key: []const u8) void {
        for (self.statuses.items, 0..) |*s, i| {
            if (std.mem.eql(u8, s.key, key)) {
                self.freeStatus(s);
                _ = self.statuses.orderedRemove(i);
                return;
            }
        }
    }

    pub fn clearAllStatuses(self: *WorkspaceStatus) void {
        for (self.statuses.items) |*s| self.freeStatus(s);
        self.statuses.clearRetainingCapacity();
    }

    fn freeStatus(self: *WorkspaceStatus, s: *StatusEntry) void {
        self.alloc.free(s.key);
        self.alloc.free(s.value);
        if (s.icon) |ic| self.alloc.free(ic);
        if (s.color) |c| self.alloc.free(c);
    }

    // --- Progress ---

    pub fn setProgress(self: *WorkspaceStatus, key: []const u8, value: f64) !void {
        const clamped = @max(0.0, @min(1.0, value));
        for (self.progress.items) |*p| {
            if (std.mem.eql(u8, p.key, key)) {
                p.value = clamped;
                return;
            }
        }
        if (self.progress.items.len >= max_progress_entries) return error.TooManyEntries;
        try self.progress.append(self.alloc, .{
            .key = try self.alloc.dupe(u8, key),
            .value = clamped,
        });
    }

    pub fn clearProgress(self: *WorkspaceStatus, key: []const u8) void {
        for (self.progress.items, 0..) |*p, i| {
            if (std.mem.eql(u8, p.key, key)) {
                self.freeProgress(p);
                _ = self.progress.orderedRemove(i);
                return;
            }
        }
    }

    fn freeProgress(self: *WorkspaceStatus, p: *ProgressEntry) void {
        self.alloc.free(p.key);
        if (p.label) |l| self.alloc.free(l);
    }

    // --- Logs ---

    pub fn addLog(self: *WorkspaceStatus, message: []const u8) !void {
        if (self.logs.items.len >= max_log_entries) {
            const oldest = self.logs.orderedRemove(0);
            self.alloc.free(oldest.message);
        }
        try self.logs.append(self.alloc, .{
            .message = try self.alloc.dupe(u8, message),
            .timestamp = std.time.timestamp(),
        });
    }

    pub fn clearLogs(self: *WorkspaceStatus) void {
        for (self.logs.items) |*l| self.alloc.free(l.message);
        self.logs.clearRetainingCapacity();
    }

    // --- JSON formatting ---

    pub fn formatStatusJson(self: *WorkspaceStatus, alloc: Allocator) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);
        var writer = buf.writer(alloc);

        try writer.writeAll("[");
        for (self.statuses.items, 0..) |s, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"key\":\"{s}\",\"value\":\"{s}\",\"timestamp\":{d}}}", .{
                s.key, s.value, s.timestamp,
            });
        }
        try writer.writeAll("]");
        return try buf.toOwnedSlice(alloc);
    }

    pub fn formatProgressJson(self: *WorkspaceStatus, alloc: Allocator) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);
        var writer = buf.writer(alloc);

        try writer.writeAll("[");
        for (self.progress.items, 0..) |p, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"key\":\"{s}\",\"value\":{d:.2}}}", .{ p.key, p.value });
        }
        try writer.writeAll("]");
        return try buf.toOwnedSlice(alloc);
    }

    pub fn formatLogJson(self: *WorkspaceStatus, alloc: Allocator) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);
        var writer = buf.writer(alloc);

        try writer.writeAll("[");
        for (self.logs.items, 0..) |l, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"message\":\"");
            for (l.message) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    else => try writer.writeByte(c),
                }
            }
            try writer.print("\",\"timestamp\":{d}}}", .{l.timestamp});
        }
        try writer.writeAll("]");
        return try buf.toOwnedSlice(alloc);
    }

    /// Format as V1 text (for list-status command).
    pub fn formatStatusText(self: *WorkspaceStatus, alloc: Allocator) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);
        var writer = buf.writer(alloc);

        for (self.statuses.items) |s| {
            try writer.print("{s}\t{s}\n", .{ s.key, s.value });
        }
        return try buf.toOwnedSlice(alloc);
    }

    pub fn formatLogText(self: *WorkspaceStatus, alloc: Allocator) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);
        var writer = buf.writer(alloc);

        for (self.logs.items) |l| {
            try writer.print("{d}\t{s}\n", .{ l.timestamp, l.message });
        }
        return try buf.toOwnedSlice(alloc);
    }
};
