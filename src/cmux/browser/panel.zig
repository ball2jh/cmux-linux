// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2025 cmux-linux contributors
//
// Browser panel stub for cmux.
// This module will embed a WebKitGTK web view as a split panel.
// Currently provides URL tracking and socket API commands.
// Full WebKitGTK integration requires build system changes to link
// -lwebkitgtk-6.0.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.cmux_browser);

/// Browser panel state.
pub const Panel = struct {
    url: []const u8,
    alloc: Allocator,

    pub fn init(alloc: Allocator, url: []const u8) !Panel {
        return .{
            .alloc = alloc,
            .url = try alloc.dupe(u8, url),
        };
    }

    pub fn deinit(self: *Panel) void {
        self.alloc.free(self.url);
    }

    pub fn navigate(self: *Panel, url: []const u8) !void {
        self.alloc.free(self.url);
        self.url = try self.alloc.dupe(u8, url);
        log.info("browser navigate: {s}", .{url});
        // TODO: When WebKitGTK is linked, call webkit_web_view_load_uri()
    }
};

/// Global browser panel instances.
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

/// Open a browser panel with the given URL.
pub fn open(url: []const u8) !usize {
    const alloc = global_alloc orelse return error.NotInitialized;
    var panel = try Panel.init(alloc, url);
    errdefer panel.deinit();
    try panels.append(alloc, panel);
    log.info("browser panel opened: {s} (id={})", .{ url, panels.items.len - 1 });
    return panels.items.len - 1;
}

/// Get the current URL of a browser panel.
pub fn getUrl(id: usize) ?[]const u8 {
    if (id >= panels.items.len) return null;
    return panels.items[id].url;
}

/// Navigate an existing panel to a new URL.
pub fn navigateTo(id: usize, url: []const u8) !void {
    if (id >= panels.items.len) return error.NotFound;
    try panels.items[id].navigate(url);
}

/// List all browser panels as JSON.
pub fn formatJson(alloc: Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    try writer.writeAll("[");
    for (panels.items, 0..) |panel, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{\"id\":");
        try writer.print("{d}", .{i});
        try writer.writeAll(",\"url\":\"");
        for (panel.url) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeAll("\"}");
    }
    try writer.writeAll("]");

    return try buf.toOwnedSlice(alloc);
}
