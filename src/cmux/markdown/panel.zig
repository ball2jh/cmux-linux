// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
//
// Markdown panel for cmux.
// Renders markdown files alongside terminal panes. On macOS this uses
// MarkdownUI; on Linux we render to HTML via a simple converter and
// display in a WebKitGTK view or as plain text in a scrollable label.
//
// File watching: uses GFileMonitor to detect changes and reload.
// Handles atomic saves (delete+rename) with retry logic via GLib timeout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gio = @import("gio");
const glib = @import("glib");

const log = std.log.scoped(.cmux_markdown);

/// Maximum reattach attempts after file delete/rename (atomic save recovery).
const max_reattach_attempts: u32 = 6;
/// Delay between reattach attempts in milliseconds.
const reattach_delay_ms: c_uint = 500;

pub const Panel = struct {
    path: []const u8,
    content: []const u8,
    alloc: Allocator,
    monitor: ?*gio.FileMonitor = null,
    reattach_timer: c_uint = 0,
    reattach_count: u32 = 0,
    closed: bool = false,

    pub fn init(alloc: Allocator, path: []const u8) !Panel {
        var panel = Panel{
            .alloc = alloc,
            .path = try alloc.dupe(u8, path),
            .content = try readFileContent(alloc, path),
        };
        panel.startWatching();
        return panel;
    }

    pub fn deinit(self: *Panel) void {
        self.closed = true;
        self.stopWatching();
        self.alloc.free(self.path);
        self.alloc.free(self.content);
    }

    /// Reload content from disk.
    pub fn reload(self: *Panel) void {
        const new_content = readFileContent(self.alloc, self.path) catch return;
        self.alloc.free(self.content);
        self.content = new_content;
        log.debug("markdown panel reloaded: {s}", .{self.path});
    }

    fn startWatching(self: *Panel) void {
        const gfile = gio.File.newForPath(@ptrCast(self.path.ptr));
        var err: ?*glib.Error = null;
        self.monitor = gio.File.monitor(gfile, .{}, null, &err);
        if (self.monitor == null) {
            log.warn("failed to create file monitor for {s}", .{self.path});
            if (err) |e| glib.Error.free(e);
            return;
        }
        // Connect the "changed" signal on the monitor
        _ = gio.FileMonitor.signals.changed.connect(
            self.monitor.?,
            *Panel,
            &onFileChanged,
            self,
            .{},
        );
    }

    fn stopWatching(self: *Panel) void {
        if (self.reattach_timer != 0) {
            _ = glib.Source.remove(self.reattach_timer);
            self.reattach_timer = 0;
        }
        if (self.monitor) |mon| {
            _ = mon.cancel();
            self.monitor = null;
        }
    }

    fn onFileChanged(
        _: *gio.FileMonitor,
        _: *gio.File,
        _: ?*gio.File,
        event_type: gio.FileMonitorEvent,
        self_ptr: *Panel,
    ) callconv(.c) void {
        if (self_ptr.closed) return;

        switch (event_type) {
            .changed, .created, .attribute_changed => {
                self_ptr.reload();
            },
            .deleted, .moved_out => {
                // File deleted or renamed — likely atomic save
                self_ptr.stopWatching();
                self_ptr.reload();
                // Schedule reattach attempts
                self_ptr.reattach_count = 0;
                self_ptr.scheduleReattach();
            },
            else => {},
        }
    }

    fn scheduleReattach(self: *Panel) void {
        if (self.closed) return;
        if (self.reattach_count >= max_reattach_attempts) return;

        self.reattach_timer = glib.timeoutAdd(reattach_delay_ms, &reattachCallback, self);
    }

    fn reattachCallback(user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *Panel = @ptrCast(@alignCast(user_data orelse return 0));
        self.reattach_timer = 0;
        if (self.closed) return 0;

        // Check if the file exists now
        std.fs.accessAbsolute(self.path, .{}) catch {
            // File still gone, retry
            self.reattach_count += 1;
            self.scheduleReattach();
            return 0; // Don't repeat this timer
        };

        // File is back — reload and reattach watcher
        self.reload();
        self.startWatching();
        log.debug("markdown panel reattached to {s} after {d} attempts", .{
            self.path, self.reattach_count + 1,
        });
        return 0;
    }
};

fn readFileContent(alloc: Allocator, path: []const u8) ![]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch {
        return try alloc.dupe(u8, "(file not found)");
    };
    defer file.close();
    return file.readToEndAlloc(alloc, 1024 * 1024) catch {
        return try alloc.dupe(u8, "(read error)");
    };
}

var panels: std.ArrayListUnmanaged(Panel) = .empty;
var global_alloc: ?Allocator = null;

pub fn initGlobal(alloc: Allocator) void {
    global_alloc = alloc;
}

pub fn deinitGlobal() void {
    const alloc = global_alloc orelse return;
    for (panels.items) |*p| p.deinit();
    panels.deinit(alloc);
    global_alloc = null;
}

pub fn open(path: []const u8) !usize {
    const alloc = global_alloc orelse return error.NotInitialized;
    var panel = try Panel.init(alloc, path);
    errdefer panel.deinit();
    try panels.append(alloc, panel);
    log.info("markdown panel opened: {s} (id={})", .{ path, panels.items.len - 1 });
    return panels.items.len - 1;
}

pub fn getContent(id: usize) ?[]const u8 {
    if (id >= panels.items.len) return null;
    return panels.items[id].content;
}

pub fn getPath(id: usize) ?[]const u8 {
    if (id >= panels.items.len) return null;
    return panels.items[id].path;
}

pub fn formatJson(alloc: Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    try writer.writeAll("[");
    for (panels.items, 0..) |panel, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{\"id\":");
        try writer.print("{d}", .{i});
        try writer.writeAll(",\"path\":\"");
        for (panel.path) |ch| {
            switch (ch) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(ch),
            }
        }
        try writer.writeAll("\"}");
    }
    try writer.writeAll("]");
    return try buf.toOwnedSlice(alloc);
}
