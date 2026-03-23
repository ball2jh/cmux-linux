// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
//
// Markdown panel for cmux.
// Renders markdown files alongside terminal panes. On macOS this uses
// MarkdownUI; on Linux we render to HTML via a simple converter and
// display in a WebKitGTK view or as plain text in a scrollable label.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.cmux_markdown);

pub const Panel = struct {
    path: []const u8,
    content: []const u8,
    alloc: Allocator,

    pub fn init(alloc: Allocator, path: []const u8) !Panel {
        const content = blk: {
            const file = std.fs.openFileAbsolute(path, .{}) catch {
                break :blk try alloc.dupe(u8, "(file not found)");
            };
            defer file.close();
            break :blk file.readToEndAlloc(alloc, 1024 * 1024) catch {
                break :blk try alloc.dupe(u8, "(read error)");
            };
        };

        return .{
            .alloc = alloc,
            .path = try alloc.dupe(u8, path),
            .content = content,
        };
    }

    pub fn deinit(self: *Panel) void {
        self.alloc.free(self.path);
        self.alloc.free(self.content);
    }
};

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
        try writer.print("{{\"id\":{d},\"path\":\"{s}\"}}", .{ i, panel.path });
    }
    try writer.writeAll("]");
    return try buf.toOwnedSlice(alloc);
}
