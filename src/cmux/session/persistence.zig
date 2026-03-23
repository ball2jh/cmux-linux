// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
//
// Session persistence for cmux.
// Saves workspace layout, metadata, and terminal working directories
// to disk so they can be restored on the next launch.
//
// Save path: ~/.local/share/cmux/session.json
// Autosave: every 8 seconds via GLib timeout
// Restore: on application startup before creating the first window
//
// Schema version 3 — adds workspace metadata, sidebar state, window geometry.
// Compatible with the macOS cmux session snapshot format.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gtk = @import("gtk");
const gobject = @import("gobject");

const workspace_mgr = @import("../workspace/manager.zig");
const WorkspaceStatus = @import("../workspace/status.zig").WorkspaceStatus;
const Window = @import("../../apprt/gtk/class/window.zig").Window;
const Tab = @import("../../apprt/gtk/class/tab.zig").Tab;
const GtkSurface = @import("../../apprt/gtk/class/surface.zig").Surface;

const log = std.log.scoped(.cmux_session);

/// Session persistence limits (matching macOS).
const max_workspaces = 128;
const max_tabs_per_workspace = 512;

/// Global session state.
var autosave_timer: c_uint = 0;
var session_app: ?*gtk.Application = null;
var session_alloc: ?Allocator = null;

/// Pending restore data — stored after restore(), consumed by restoreTabs().
var pending_restore: ?PendingRestore = null;

const PendingRestore = struct {
    alloc: Allocator,
    tab_data: std.ArrayListUnmanaged(PendingTab),
    window_width: i32,
    window_height: i32,

    fn deinit(self: *PendingRestore) void {
        for (self.tab_data.items) |*td| {
            self.alloc.free(td.pwd);
        }
        self.tab_data.deinit(self.alloc);
    }
};

const PendingTab = struct {
    pwd: []const u8,
    workspace_id: u64,
};

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
        \\{{"version":3,"active_workspace_id":{d},"window_width":{d},"window_height":{d},"workspaces":[
    , .{ mgr.activeId(), win_width, win_height }) catch return;

    mgr.mutex.lock();
    defer mgr.mutex.unlock();

    const ws_count = @min(mgr.workspaces.items.len, max_workspaces);
    for (mgr.workspaces.items[0..ws_count], 0..) |ws, i| {
        if (i > 0) writer.writeAll(",") catch return;

        // Workspace header with metadata
        writer.writeAll("{\"id\":") catch return;
        writer.print("{d}", .{ws.id}) catch return;
        writer.writeAll(",\"name\":\"") catch return;
        writeJsonEscaped(writer, ws.name);
        writer.writeAll("\"") catch return;

        // Workspace metadata
        if (ws.custom_color) |color| {
            writer.writeAll(",\"customColor\":\"") catch return;
            writeJsonEscaped(writer, color);
            writer.writeAll("\"") catch return;
        }
        if (ws.is_pinned) {
            writer.writeAll(",\"isPinned\":true") catch return;
        }
        if (ws.git_branch) |branch| {
            writer.writeAll(",\"gitBranch\":\"") catch return;
            writeJsonEscaped(writer, branch);
            writer.writeAll("\"") catch return;
            if (ws.is_dirty) {
                writer.writeAll(",\"isDirty\":true") catch return;
            }
        }

        // Status entries
        writeStatusJson(writer, &ws.status, alloc);

        // Tabs
        writer.writeAll(",\"tabs\":[") catch return;
        saveTabs(app, writer);
        writer.writeAll("]") catch return;

        writer.writeAll("}") catch return;
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

/// Write status/log/progress entries for a workspace into JSON.
fn writeStatusJson(writer: anytype, status: *const WorkspaceStatus, alloc: Allocator) void {
    _ = alloc;

    // Status entries
    if (status.statuses.items.len > 0) {
        writer.writeAll(",\"statusEntries\":[") catch return;
        for (status.statuses.items, 0..) |s, si| {
            if (si > 0) writer.writeAll(",") catch return;
            writer.writeAll("{\"key\":\"") catch return;
            writeJsonEscaped(writer, s.key);
            writer.writeAll("\",\"value\":\"") catch return;
            writeJsonEscaped(writer, s.value);
            writer.writeAll("\"") catch return;
            if (s.icon) |icon| {
                writer.writeAll(",\"icon\":\"") catch return;
                writeJsonEscaped(writer, icon);
                writer.writeAll("\"") catch return;
            }
            if (s.color) |color| {
                writer.writeAll(",\"color\":\"") catch return;
                writeJsonEscaped(writer, color);
                writer.writeAll("\"") catch return;
            }
            writer.print(",\"priority\":{d}", .{s.priority}) catch return;
            writer.print(",\"timestamp\":{d}", .{s.timestamp}) catch return;
            writer.writeAll("}") catch return;
        }
        writer.writeAll("]") catch return;
    }

    // Log entries
    if (status.logs.items.len > 0) {
        writer.writeAll(",\"logEntries\":[") catch return;
        for (status.logs.items, 0..) |l, li| {
            if (li > 0) writer.writeAll(",") catch return;
            writer.writeAll("{\"message\":\"") catch return;
            writeJsonEscaped(writer, l.message);
            writer.print("\",\"timestamp\":{d}}}", .{l.timestamp}) catch return;
        }
        writer.writeAll("]") catch return;
    }

    // Progress
    if (status.progress.items.len > 0) {
        writer.writeAll(",\"progress\":[") catch return;
        for (status.progress.items, 0..) |p, pi| {
            if (pi > 0) writer.writeAll(",") catch return;
            writer.writeAll("{\"key\":\"") catch return;
            writeJsonEscaped(writer, p.key);
            writer.print("\",\"value\":{d:.4}}}", .{p.value}) catch return;
        }
        writer.writeAll("]") catch return;
    }
}

/// Save tabs from the active window into JSON.
fn saveTabs(app: *gtk.Application, writer: anytype) void {
    const gtk_win = app.getActiveWindow() orelse return;
    const window = gobject.ext.cast(Window, gtk_win) orelse return;
    const tab_view = window.getTabView();
    const n: usize = @intCast(@max(0, tab_view.getNPages()));
    const tab_count = @min(n, max_tabs_per_workspace);

    var t: usize = 0;
    while (t < tab_count) : (t += 1) {
        const page = tab_view.getNthPage(@intCast(t));
        const child = page.getChild();
        if (gobject.ext.cast(Tab, child)) |tab| {
            if (t > 0) writer.writeAll(",") catch return;
            writer.writeAll("{") catch return;

            // Get title from the page
            writer.writeAll("\"title\":\"") catch return;
            writeJsonEscaped(writer, std.mem.sliceTo(page.getTitle(), 0));
            writer.writeAll("\"") catch return;

            // Get pwd from the active surface
            if (tab.getActiveSurface()) |surface| {
                if (surface.getPwd()) |pwd| {
                    writer.writeAll(",\"pwd\":\"") catch return;
                    writeJsonEscaped(writer, pwd);
                    writer.writeAll("\"") catch return;
                }
            }

            writer.writeAll("}") catch return;
        }
    }
}

/// Restore session state from disk. Call before creating the first window.
/// Returns true if a session was restored.
pub fn restore(alloc: Allocator) bool {
    // Check CMUX_DISABLE_SESSION_RESTORE
    if (std.posix.getenv("CMUX_DISABLE_SESSION_RESTORE")) |val| {
        if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true")) {
            log.info("session restore disabled via CMUX_DISABLE_SESSION_RESTORE", .{});
            return false;
        }
    }

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

    // Prepare pending tab restore data
    var pending = PendingRestore{
        .alloc = alloc,
        .tab_data = .empty,
        .window_width = getJsonIntDefault(root.object, "window_width", 800),
        .window_height = getJsonIntDefault(root.object, "window_height", 600),
    };

    if (root.object.get("workspaces")) |workspaces_val| {
        if (workspaces_val == .array) {
            const ws_count = @min(workspaces_val.array.items.len, max_workspaces);
            for (workspaces_val.array.items[0..ws_count]) |ws_val| {
                if (ws_val != .object) continue;
                const name = getJsonStr(ws_val.object, "name") orelse "workspace";

                // Don't recreate the default workspace
                if (std.mem.eql(u8, name, "default")) {
                    // But restore metadata on the default workspace
                    restoreWorkspaceMetadata(mgr, 1, ws_val.object);
                    continue;
                }

                const cwd = getJsonStr(ws_val.object, "cwd");
                const ws_id = mgr.create(name, cwd) catch continue;

                // Restore workspace metadata
                restoreWorkspaceMetadata(mgr, ws_id, ws_val.object);

                // Collect tab pwds for later restore
                if (ws_val.object.get("tabs")) |tabs_val| {
                    if (tabs_val == .array) {
                        const tab_count = @min(tabs_val.array.items.len, max_tabs_per_workspace);
                        for (tabs_val.array.items[0..tab_count]) |tab_val| {
                            if (tab_val != .object) continue;
                            const pwd = getJsonStr(tab_val.object, "pwd") orelse continue;
                            pending.tab_data.append(alloc, .{
                                .pwd = alloc.dupe(u8, pwd) catch continue,
                                .workspace_id = ws_id,
                            }) catch continue;
                        }
                    }
                }
            }
        }
    }

    // Restore active workspace
    if (root.object.get("active_workspace_id")) |id_val| {
        if (id_val == .integer) {
            _ = mgr.select(@intCast(@max(0, id_val.integer)));
        }
    }

    // Store pending data for restoreTabs()
    if (pending.tab_data.items.len > 0 or pending.window_width != 800 or pending.window_height != 600) {
        pending_restore = pending;
    } else {
        pending.deinit();
    }

    log.info("session restored from {s}", .{path});
    return true;
}

/// Restore workspace metadata (color, pinned, git branch, log entries).
fn restoreWorkspaceMetadata(mgr: *workspace_mgr.Manager, ws_id: u64, obj: std.json.ObjectMap) void {
    // Color
    if (getJsonStr(obj, "customColor")) |color| {
        mgr.setColor(ws_id, color) catch {};
    }

    // Pinned
    if (obj.get("isPinned")) |pinned_val| {
        if (pinned_val == .bool) {
            mgr.setPinned(ws_id, pinned_val.bool);
        }
    }

    // Git branch
    if (getJsonStr(obj, "gitBranch")) |branch| {
        const is_dirty = if (obj.get("isDirty")) |d| d == .bool and d.bool else false;
        mgr.setGitBranch(ws_id, branch, is_dirty) catch {};
    }

    // Log entries
    if (obj.get("logEntries")) |logs_val| {
        if (logs_val == .array) {
            mgr.mutex.lock();
            defer mgr.mutex.unlock();
            if (mgr.getStatus(ws_id)) |status| {
                for (logs_val.array.items) |log_val| {
                    if (log_val != .object) continue;
                    const msg = getJsonStr(log_val.object, "message") orelse continue;
                    status.addLog(msg) catch continue;
                }
            }
        }
    }
}

/// Restore tabs in the window after it's been created.
pub const RestoreDims = struct { width: i32, height: i32 };

/// Call this from application.zig after the first window is shown.
/// Returns the saved window dimensions if available.
pub fn restoreTabs(window: *Window) RestoreDims {
    var result = RestoreDims{ .width = 800, .height = 600 };

    var pr = pending_restore orelse return result;
    defer {
        pr.deinit();
        pending_restore = null;
    }

    result.width = pr.window_width;
    result.height = pr.window_height;

    // Create additional tabs with the saved working directories
    for (pr.tab_data.items) |td| {
        // Create a new tab (no parent — fresh terminal)
        window.newTab(null);

        // Set the pwd on the newly created tab's surface before it's realized.
        // setPwd expects a null-terminated slice, so we use glib.ext.dupeZ
        // to convert and then pass the sentinel-terminated copy.
        const tab_view = window.getTabView();
        const n_pages = tab_view.getNPages();
        if (n_pages > 0) {
            const page = tab_view.getNthPage(n_pages - 1);
            const child = page.getChild();
            if (gobject.ext.cast(Tab, child)) |tab| {
                if (tab.getActiveSurface()) |surface| {
                    const pwd_z: [:0]const u8 = glib.ext.dupeZ(u8, td.pwd);
                    defer glib.free(@ptrCast(@constCast(pwd_z.ptr)));
                    surface.setPwd(pwd_z);
                }
            }
        }
    }

    log.info("restored {d} tabs from session", .{pr.tab_data.items.len});
    return result;
}

/// Check if there's pending restore data.
pub fn hasPendingRestore() bool {
    return pending_restore != null;
}

// --- JSON helpers ---

fn getJsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getJsonIntDefault(obj: std.json.ObjectMap, key: []const u8, default: i32) i32 {
    const val = obj.get(key) orelse return default;
    return switch (val) {
        .integer => |i| @intCast(@max(std.math.minInt(i32), @min(std.math.maxInt(i32), i))),
        else => default,
    };
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
