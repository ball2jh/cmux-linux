// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2025 cmux-linux contributors
//
// Session persistence for cmux.
// Saves workspace layout and working directories to disk so they
// can be restored on the next launch.
//
// Save path: ~/.local/share/cmux/session.json
// Autosave: every 8 seconds via GLib timeout
// Restore: on application startup before creating the first window

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gtk = @import("gtk");
const gobject = @import("gobject");

const workspace_mgr = @import("../workspace/manager.zig");

const log = std.log.scoped(.cmux_session);

/// Session snapshot data.
const SessionSnapshot = struct {
    version: u32 = 1,
    workspaces: []const WorkspaceSnapshot,
    active_workspace_id: u64,
    window_width: i32,
    window_height: i32,
};

const WorkspaceSnapshot = struct {
    id: u64,
    name: []const u8,
    tabs: []const TabSnapshot,
};

const TabSnapshot = struct {
    pwd: []const u8,
    title: []const u8,
};

/// Global session state.
var autosave_timer: c_uint = 0;
var session_app: ?*gtk.Application = null;
var session_alloc: ?Allocator = null;

/// Get the session file path.
fn sessionPath(alloc: Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return try std.fmt.allocPrint(alloc, "{s}/.local/share/cmux/session.json", .{home});
}

/// Ensure the session directory exists.
fn ensureDir(alloc: Allocator) !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.local/share/cmux", .{home});
    defer alloc.free(dir_path);
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Start the autosave timer and set the app reference for saving.
pub fn startAutosave(alloc: Allocator, app: *gtk.Application) void {
    session_alloc = alloc;
    session_app = app;

    // Start the GLib timeout for autosave (8 seconds)
    autosave_timer = glib.timeoutAdd(8000, &autosaveCallback, null);
    log.info("session autosave started (8s interval)", .{});
}

/// Stop the autosave timer.
pub fn stopAutosave() void {
    if (autosave_timer != 0) {
        _ = glib.Source.remove(autosave_timer);
        autosave_timer = 0;
    }
    // Do a final save on shutdown
    save();
    session_app = null;
    session_alloc = null;
}

/// GLib timeout callback for autosave.
fn autosaveCallback(_: ?*anyopaque) callconv(.c) c_int {
    save();
    return 1; // Keep timer active
}

/// Save the current session state to disk.
pub fn save() void {
    const alloc = session_alloc orelse return;
    const app = session_app orelse return;

    // Get workspace data
    const mgr = workspace_mgr.getGlobal() orelse return;

    ensureDir(alloc) catch |err| {
        log.warn("failed to create session dir: {}", .{err});
        return;
    };

    const path = sessionPath(alloc) catch return;
    defer alloc.free(path);

    // Build JSON manually
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    // Get window geometry
    var win_width: c_int = 800;
    var win_height: c_int = 600;
    if (app.getActiveWindow()) |win| {
        win.getDefaultSize(&win_width, &win_height);
    }

    writer.print(
        \\{{"version":1,"active_workspace_id":{d},"window_width":{d},"window_height":{d},"workspaces":[
    , .{ mgr.activeId(), win_width, win_height }) catch return;

    mgr.mutex.lock();
    defer mgr.mutex.unlock();

    for (mgr.workspaces.items, 0..) |ws, i| {
        if (i > 0) writer.writeAll(",") catch return;
        writer.writeAll("{\"id\":") catch return;
        writer.print("{d}", .{ws.id}) catch return;
        writer.writeAll(",\"name\":\"") catch return;
        writeJsonEscaped(writer, ws.name);
        writer.writeAll("\",\"tabs\":[]}") catch return;
    }

    writer.writeAll("]}\n") catch return;

    // Write atomically: write to tmp, then rename
    const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{path}) catch return;
    defer alloc.free(tmp_path);

    const file = std.fs.createFileAbsolute(tmp_path, .{}) catch |err| {
        log.warn("failed to create session tmp file: {}", .{err});
        return;
    };
    file.writeAll(buf.items) catch |err| {
        log.warn("failed to write session data: {}", .{err});
        file.close();
        return;
    };
    file.close();

    std.fs.renameAbsolute(tmp_path, path) catch |err| {
        log.warn("failed to rename session file: {}", .{err});
        return;
    };

    log.debug("session saved ({d} bytes)", .{buf.items.len});
}

/// Restore session state from disk. Call before creating the first window.
/// Returns true if a session was restored.
pub fn restore(alloc: Allocator) bool {
    const path = sessionPath(alloc) catch return false;
    defer alloc.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    const data = file.readToEndAlloc(alloc, 1024 * 1024) catch return false;
    defer alloc.free(data);

    // Parse the JSON
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{
        .allocate = .alloc_always,
    }) catch |err| {
        log.warn("failed to parse session file: {}", .{err});
        return false;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return false;

    // Restore workspaces
    const mgr = workspace_mgr.getGlobal() orelse return false;

    if (root.object.get("workspaces")) |workspaces_val| {
        if (workspaces_val == .array) {
            for (workspaces_val.array.items) |ws_val| {
                if (ws_val != .object) continue;
                const name = blk: {
                    const n = ws_val.object.get("name") orelse break :blk "workspace";
                    break :blk switch (n) {
                        .string => |s| s,
                        else => "workspace",
                    };
                };

                // Don't recreate the default workspace
                if (std.mem.eql(u8, name, "default")) continue;
                _ = mgr.create(name, null) catch continue;
            }
        }
    }

    // Restore active workspace
    if (root.object.get("active_workspace_id")) |id_val| {
        if (id_val == .integer) {
            _ = mgr.select(@intCast(@max(0, id_val.integer)));
        }
    }

    log.info("session restored from {s}", .{path});
    return true;
}

fn writeJsonEscaped(writer: anytype, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => writer.writeAll("\\\"") catch return,
            '\\' => writer.writeAll("\\\\") catch return,
            '\n' => writer.writeAll("\\n") catch return,
            '\r' => writer.writeAll("\\r") catch return,
            '\t' => writer.writeAll("\\t") catch return,
            else => writer.writeByte(c) catch return,
        }
    }
}
