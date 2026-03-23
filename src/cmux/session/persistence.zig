// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
//
// Session persistence for cmux.
// Saves workspace layout, split tree structure, terminal working directories,
// and browser/markdown panel state to disk for restore on next launch.
//
// Save path: ~/.local/share/cmux/session.json
// Autosave: every 8 seconds via GLib timeout
// Restore: on application startup before creating the first window
//
// Schema version 4 — adds recursive split/panel tree layout matching macOS cmux.
// Backward-compatible with version 3 (flat tab list).

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gtk = @import("gtk");
const gobject = @import("gobject");

const workspace_mgr = @import("../workspace/manager.zig");
const WorkspaceStatus = @import("../workspace/status.zig").WorkspaceStatus;
const browser_panel = @import("../browser/panel.zig");
const Window = @import("../../apprt/gtk/class/window.zig").Window;
const Tab = @import("../../apprt/gtk/class/tab.zig").Tab;
const GtkSurface = @import("../../apprt/gtk/class/surface.zig").Surface;
const SplitTree = @import("../../apprt/gtk/class/split_tree.zig").SplitTree;

const log = std.log.scoped(.cmux_session);

/// Session persistence limits (matching macOS).
const max_workspaces = 128;
const max_panels_per_workspace = 512;

/// Global session state.
var autosave_timer: c_uint = 0;
var session_app: ?*gtk.Application = null;
var session_alloc: ?Allocator = null;

/// Pending restore data — stored after restore(), consumed by restoreTabs().
var pending_restore: ?PendingRestore = null;

const PendingRestore = struct {
    alloc: Allocator,
    workspaces: std.ArrayListUnmanaged(PendingWorkspace),
    window_width: i32,
    window_height: i32,

    fn deinit(self: *PendingRestore) void {
        for (self.workspaces.items) |*ws| {
            ws.deinit(self.alloc);
        }
        self.workspaces.deinit(self.alloc);
    }
};

const PendingWorkspace = struct {
    workspace_id: u64,
    layout: ?PendingLayout,
    panels: std.ArrayListUnmanaged(PendingPanel),

    fn deinit(self: *PendingWorkspace, alloc: Allocator) void {
        if (self.layout) |*l| l.deinit(alloc);
        for (self.panels.items) |*p| p.deinit(alloc);
        self.panels.deinit(alloc);
    }
};

const PendingLayout = union(enum) {
    pane: PendingPane,
    split: *PendingSplit,

    fn deinit(self: *PendingLayout, alloc: Allocator) void {
        switch (self.*) {
            .pane => {},
            .split => |s| {
                s.first.deinit(alloc);
                s.second.deinit(alloc);
                alloc.destroy(s);
            },
        }
    }
};

const PendingPane = struct {
    panel_id: u64,
};

const Orientation = enum { horizontal, vertical };

const PendingSplit = struct {
    orientation: Orientation,
    divider_position: f64,
    first: PendingLayout,
    second: PendingLayout,
};

const PendingPanel = struct {
    id: u64,
    panel_type: enum { terminal, browser, markdown },
    pwd: ?[]const u8,
    browser_url: ?[]const u8,
    markdown_path: ?[]const u8,

    fn deinit(self: *PendingPanel, alloc: Allocator) void {
        if (self.pwd) |p| alloc.free(p);
        if (self.browser_url) |u| alloc.free(u);
        if (self.markdown_path) |m| alloc.free(m);
    }
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
    const gtk_win = app.getActiveWindow();
    if (gtk_win) |win| {
        win.getDefaultSize(&win_width, &win_height);
    }

    // Version 4 format with windows array
    writer.writeAll("{\"version\":4,\"createdAt\":") catch return;
    writer.print("{d}", .{std.time.timestamp()}) catch return;
    writer.writeAll(",\"windows\":[{") catch return;

    // Window frame
    writer.print("\"frame\":{{\"x\":0,\"y\":0,\"width\":{d},\"height\":{d}}}", .{ win_width, win_height }) catch return;

    // Sidebar state
    writer.writeAll(",\"sidebar\":{\"isVisible\":true,\"selection\":\"tabs\",\"width\":200}") catch return;

    // Tab manager with workspaces
    writer.writeAll(",\"tabManager\":{") catch return;

    // Snapshot workspace data under the lock, then write without it.
    // This avoids deadlocks from catch-return leaking the mutex.
    const WsSnapshot = struct {
        name: []const u8,
        cwd: ?[]const u8,
        custom_color: ?[]const u8,
        is_pinned: bool,
        git_branch: ?[]const u8,
        is_dirty: bool,
    };
    var ws_snapshots: [max_workspaces]WsSnapshot = undefined;
    var ws_count: usize = 0;
    var selected_idx: usize = 0;

    {
        mgr.mutex.lock();
        defer mgr.mutex.unlock();

        const active_id = mgr.active_id;
        ws_count = @min(mgr.workspaces.items.len, max_workspaces);
        for (mgr.workspaces.items[0..ws_count], 0..) |ws, idx| {
            if (ws.id == active_id) selected_idx = idx;
            ws_snapshots[idx] = .{
                .name = ws.name,
                .cwd = ws.cwd,
                .custom_color = ws.custom_color,
                .is_pinned = ws.is_pinned,
                .git_branch = ws.git_branch,
                .is_dirty = ws.is_dirty,
            };
        }
    }

    writer.print("\"selectedWorkspaceIndex\":{d}", .{selected_idx}) catch return;
    writer.writeAll(",\"workspaces\":[") catch return;

    for (ws_snapshots[0..ws_count], 0..) |ws, i| {
        if (i > 0) writer.writeAll(",") catch return;
        writer.writeAll("{") catch return;

        // processTitle (workspace name)
        writer.writeAll("\"processTitle\":\"") catch return;
        writeJsonEscaped(writer, ws.name);
        writer.writeAll("\"") catch return;

        // currentDirectory
        if (ws.cwd) |cwd| {
            writer.writeAll(",\"currentDirectory\":\"") catch return;
            writeJsonEscaped(writer, cwd);
            writer.writeAll("\"") catch return;
        }

        // customColor
        if (ws.custom_color) |color| {
            writer.writeAll(",\"customColor\":\"") catch return;
            writeJsonEscaped(writer, color);
            writer.writeAll("\"") catch return;
        }

        // isPinned
        writer.print(",\"isPinned\":{s}", .{if (ws.is_pinned) "true" else "false"}) catch return;

        // gitBranch
        if (ws.git_branch) |branch| {
            writer.writeAll(",\"gitBranch\":{\"branch\":\"") catch return;
            writeJsonEscaped(writer, branch);
            writer.print("\",\"isDirty\":{s}}}", .{if (ws.is_dirty) "true" else "false"}) catch return;
        }

        // Status entries (read under lock)
        {
            mgr.mutex.lock();
            defer mgr.mutex.unlock();
            if (i < mgr.workspaces.items.len) {
                writeStatusJson(writer, &mgr.workspaces.items[i].status);
            }
        }

        // Layout and panels — no lock needed, accessing GTK widgets on main thread
        saveWorkspaceLayout(app, writer, i);

        writer.writeAll("}") catch return;
    }

    writer.writeAll("]}") catch return; // close tabManager
    writer.writeAll("}]}\n") catch return; // close window, windows array, root

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

/// Save the layout and panels for a single workspace (tab at index ws_index).
fn saveWorkspaceLayout(app: *gtk.Application, writer: anytype, ws_index: usize) void {
    const gtk_win = app.getActiveWindow() orelse return;
    const window = gobject.ext.cast(Window, gtk_win) orelse return;
    const tab_view = window.getTabView();
    const n_pages: usize = @intCast(@max(0, tab_view.getNPages()));

    if (ws_index >= n_pages) return;

    const page = tab_view.getNthPage(@intCast(ws_index));
    const child = page.getChild();
    const tab = gobject.ext.cast(Tab, child) orelse return;

    const tree = tab.getSurfaceTree() orelse {
        // No split tree — single surface fallback
        writer.writeAll(",\"layout\":{\"type\":\"pane\",\"pane\":{\"panelIds\":[1]}}") catch return;
        writer.writeAll(",\"panels\":[") catch return;
        if (tab.getActiveSurface()) |surface| {
            writer.writeAll("{\"id\":1,\"type\":\"terminal\"") catch return;
            if (surface.getPwd()) |pwd| {
                writer.writeAll(",\"terminal\":{\"workingDirectory\":\"") catch return;
                writeJsonEscaped(writer, pwd);
                writer.writeAll("\"}") catch return;
            }
            writer.writeAll("}") catch return;
        }
        writer.writeAll("]") catch return;
        return;
    };

    // Collect panels (surfaces) with auto-assigned IDs
    var panel_id: u64 = 1;
    var panels_buf: [max_panels_per_workspace]PanelInfo = undefined;
    var panel_count: usize = 0;

    var it = tree.iterator();
    while (it.next()) |entry| {
        if (panel_count >= max_panels_per_workspace) break;
        const surface: *GtkSurface = entry.view;
        panels_buf[panel_count] = .{
            .id = panel_id,
            .handle_idx = entry.handle.idx(),
            .pwd = surface.getPwd(),
        };
        panel_id += 1;
        panel_count += 1;
    }
    const panels = panels_buf[0..panel_count];

    // Write layout (recursive tree structure)
    writer.writeAll(",\"layout\":") catch return;
    writeLayoutNode(writer, tree.nodes, .root, panels);

    // Write panels array
    writer.writeAll(",\"panels\":[") catch return;
    for (panels, 0..) |p, pi| {
        if (pi > 0) writer.writeAll(",") catch return;
        writer.print("{{\"id\":{d},\"type\":\"terminal\"", .{p.id}) catch return;
        if (p.pwd) |pwd| {
            writer.writeAll(",\"terminal\":{\"workingDirectory\":\"") catch return;
            writeJsonEscaped(writer, pwd);
            writer.writeAll("\"}") catch return;
        }
        writer.writeAll("}") catch return;
    }
    writer.writeAll("]") catch return;
}

const PanelInfo = struct {
    id: u64,
    handle_idx: usize,
    pwd: ?[:0]const u8,
};

/// Recursively write a layout node as JSON.
fn writeLayoutNode(
    writer: anytype,
    nodes: []const GtkSurface.Tree.Node,
    handle: GtkSurface.Tree.Node.Handle,
    panels: []const PanelInfo,
) void {
    if (handle.idx() >= nodes.len) return;
    const node = nodes[handle.idx()];

    switch (node) {
        .leaf => {
            // Find the panel ID for this leaf's handle index
            var panel_id: u64 = 1;
            for (panels) |p| {
                if (p.handle_idx == handle.idx()) {
                    panel_id = p.id;
                    break;
                }
            }
            writer.print("{{\"type\":\"pane\",\"pane\":{{\"panelIds\":[{d}]}}}}", .{panel_id}) catch return;
        },
        .split => |split| {
            const orientation: []const u8 = switch (split.layout) {
                .horizontal => "horizontal",
                .vertical => "vertical",
            };
            const ratio: f64 = @floatCast(split.ratio);
            writer.writeAll("{\"type\":\"split\",\"split\":{\"orientation\":\"") catch return;
            writer.writeAll(orientation) catch return;
            writer.print("\",\"dividerPosition\":{d:.4}", .{ratio}) catch return;
            writer.writeAll(",\"first\":") catch return;
            writeLayoutNode(writer, nodes, split.left, panels);
            writer.writeAll(",\"second\":") catch return;
            writeLayoutNode(writer, nodes, split.right, panels);
            writer.writeAll("}}") catch return;
        },
    }
}

/// Write status/log/progress entries for a workspace into JSON.
fn writeStatusJson(writer: anytype, status: *const WorkspaceStatus) void {
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

    const version = getJsonIntDefault(root.object, "version", 0);
    if (version == 3) {
        return restoreV3(alloc, root.object);
    } else if (version == 4) {
        return restoreV4(alloc, root.object);
    }

    log.warn("unsupported session version: {d}", .{version});
    return false;
}

/// Restore from version 3 format (backward compatibility).
fn restoreV3(alloc: Allocator, root: std.json.ObjectMap) bool {
    const mgr = workspace_mgr.getGlobal() orelse return false;

    var pending = PendingRestore{
        .alloc = alloc,
        .workspaces = .empty,
        .window_width = getJsonIntDefault(root, "window_width", 800),
        .window_height = getJsonIntDefault(root, "window_height", 600),
    };

    if (root.get("workspaces")) |workspaces_val| {
        if (workspaces_val == .array) {
            const ws_count = @min(workspaces_val.array.items.len, max_workspaces);
            for (workspaces_val.array.items[0..ws_count]) |ws_val| {
                if (ws_val != .object) continue;
                const name = getJsonStr(ws_val.object, "name") orelse "workspace";

                // Don't recreate the default workspace
                const ws_id = if (std.mem.eql(u8, name, "default")) blk: {
                    restoreWorkspaceMetadata(mgr, 1, ws_val.object);
                    break :blk @as(u64, 1);
                } else blk: {
                    const cwd = getJsonStr(ws_val.object, "cwd");
                    const id = mgr.create(name, cwd) catch continue;
                    restoreWorkspaceMetadata(mgr, id, ws_val.object);
                    break :blk id;
                };

                // Convert v3 tabs to v4 panel format
                if (ws_val.object.get("tabs")) |tabs_val| {
                    if (tabs_val == .array) {
                        var pws = PendingWorkspace{
                            .workspace_id = ws_id,
                            .layout = null,
                            .panels = .empty,
                        };
                        const tab_count = @min(tabs_val.array.items.len, max_panels_per_workspace);
                        for (tabs_val.array.items[0..tab_count]) |tab_val| {
                            if (tab_val != .object) continue;
                            const pwd = getJsonStr(tab_val.object, "pwd") orelse continue;
                            pws.panels.append(alloc, .{
                                .id = pws.panels.items.len + 1,
                                .panel_type = .terminal,
                                .pwd = alloc.dupe(u8, pwd) catch continue,
                                .browser_url = null,
                                .markdown_path = null,
                            }) catch continue;
                        }
                        if (pws.panels.items.len > 0) {
                            pending.workspaces.append(alloc, pws) catch continue;
                        }
                    }
                }
            }
        }
    }

    // Restore active workspace
    if (root.get("active_workspace_id")) |id_val| {
        if (id_val == .integer) {
            _ = mgr.select(@intCast(@max(0, id_val.integer)));
        }
    }

    if (pending.workspaces.items.len > 0 or pending.window_width != 800 or pending.window_height != 600) {
        pending_restore = pending;
    } else {
        pending.deinit();
    }

    log.info("session restored (v3 format)", .{});
    return true;
}

/// Restore from version 4 format (full Mac parity).
fn restoreV4(alloc: Allocator, root: std.json.ObjectMap) bool {
    const mgr = workspace_mgr.getGlobal() orelse return false;

    // Get first window (we only support single window for now)
    const windows_val = root.get("windows") orelse return false;
    if (windows_val != .array or windows_val.array.items.len == 0) return false;
    const win_obj = windows_val.array.items[0];
    if (win_obj != .object) return false;

    // Parse window frame
    var win_width: i32 = 800;
    var win_height: i32 = 600;
    if (win_obj.object.get("frame")) |frame_val| {
        if (frame_val == .object) {
            win_width = getJsonIntDefault(frame_val.object, "width", 800);
            win_height = getJsonIntDefault(frame_val.object, "height", 600);
        }
    }

    var pending = PendingRestore{
        .alloc = alloc,
        .workspaces = .empty,
        .window_width = win_width,
        .window_height = win_height,
    };

    // Parse tab manager
    const tm = getJsonObj(win_obj.object, "tabManager") orelse return false;
    const selected_idx = getJsonIntDefault(tm, "selectedWorkspaceIndex", 0);

    const workspaces_val = tm.get("workspaces") orelse return false;
    if (workspaces_val != .array) return false;

    const ws_count = @min(workspaces_val.array.items.len, max_workspaces);
    for (workspaces_val.array.items[0..ws_count], 0..) |ws_val, ws_idx| {
        if (ws_val != .object) continue;
        const name = getJsonStr(ws_val.object, "processTitle") orelse "workspace";

        // Create or reuse default workspace
        const ws_id = if (ws_idx == 0) blk: {
            // First workspace — reuse default, just rename
            _ = mgr.rename(1, name) catch false;
            restoreWorkspaceMetadataV4(mgr, 1, ws_val.object);
            break :blk @as(u64, 1);
        } else blk: {
            const cwd = getJsonStr(ws_val.object, "currentDirectory");
            const id = mgr.create(name, cwd) catch continue;
            restoreWorkspaceMetadataV4(mgr, id, ws_val.object);
            break :blk id;
        };

        var pws = PendingWorkspace{
            .workspace_id = ws_id,
            .layout = null,
            .panels = .empty,
        };

        // Parse panels
        if (ws_val.object.get("panels")) |panels_val| {
            if (panels_val == .array) {
                for (panels_val.array.items) |panel_val| {
                    if (panel_val != .object) continue;
                    const panel_id: u64 = @intCast(@max(0, getJsonIntDefault(panel_val.object, "id", 0)));
                    const type_str = getJsonStr(panel_val.object, "type") orelse "terminal";

                    var panel = PendingPanel{
                        .id = panel_id,
                        .panel_type = .terminal,
                        .pwd = null,
                        .browser_url = null,
                        .markdown_path = null,
                    };

                    if (std.mem.eql(u8, type_str, "browser")) {
                        panel.panel_type = .browser;
                        if (getJsonObj(panel_val.object, "browser")) |browser_obj| {
                            if (getJsonStr(browser_obj, "urlString")) |url| {
                                panel.browser_url = alloc.dupe(u8, url) catch null;
                            }
                        }
                    } else if (std.mem.eql(u8, type_str, "markdown")) {
                        panel.panel_type = .markdown;
                        if (getJsonObj(panel_val.object, "markdown")) |md_obj| {
                            if (getJsonStr(md_obj, "filePath")) |fp| {
                                panel.markdown_path = alloc.dupe(u8, fp) catch null;
                            }
                        }
                    } else {
                        // terminal
                        if (getJsonObj(panel_val.object, "terminal")) |term_obj| {
                            if (getJsonStr(term_obj, "workingDirectory")) |pwd| {
                                panel.pwd = alloc.dupe(u8, pwd) catch null;
                            }
                        }
                    }

                    pws.panels.append(alloc, panel) catch continue;
                }
            }
        }

        // Parse layout
        if (ws_val.object.get("layout")) |layout_val| {
            if (layout_val == .object) {
                pws.layout = parseLayout(alloc, layout_val.object);
            }
        }

        pending.workspaces.append(alloc, pws) catch continue;
    }

    // Select the saved active workspace
    if (selected_idx > 0 and @as(usize, @intCast(selected_idx)) < ws_count) {
        // Map index to workspace ID
        if (@as(usize, @intCast(selected_idx)) < pending.workspaces.items.len) {
            _ = mgr.select(pending.workspaces.items[@intCast(selected_idx)].workspace_id);
        }
    }

    if (pending.workspaces.items.len > 0 or pending.window_width != 800 or pending.window_height != 600) {
        pending_restore = pending;
    } else {
        pending.deinit();
    }

    log.info("session restored (v4 format, {d} workspaces)", .{ws_count});
    return true;
}

/// Parse a layout node from JSON (recursive).
fn parseLayout(alloc: Allocator, obj: std.json.ObjectMap) ?PendingLayout {
    const type_str = getJsonStr(obj, "type") orelse return null;

    if (std.mem.eql(u8, type_str, "pane")) {
        if (getJsonObj(obj, "pane")) |pane_obj| {
            // Get first panel ID from panelIds array
            if (pane_obj.get("panelIds")) |ids_val| {
                if (ids_val == .array and ids_val.array.items.len > 0) {
                    const first_id = ids_val.array.items[0];
                    if (first_id == .integer) {
                        return .{ .pane = .{ .panel_id = @intCast(@max(0, first_id.integer)) } };
                    }
                }
            }
        }
        return .{ .pane = .{ .panel_id = 1 } };
    } else if (std.mem.eql(u8, type_str, "split")) {
        if (getJsonObj(obj, "split")) |split_obj| {
            const orient_str = getJsonStr(split_obj, "orientation") orelse "horizontal";
            const orientation: Orientation =
                if (std.mem.eql(u8, orient_str, "vertical")) .vertical else .horizontal;

            var divider: f64 = 0.5;
            if (split_obj.get("dividerPosition")) |dv| {
                divider = switch (dv) {
                    .float => |f| f,
                    .integer => |i| @floatFromInt(i),
                    else => 0.5,
                };
            }

            const first_obj = getJsonObj(split_obj, "first") orelse return null;
            const second_obj = getJsonObj(split_obj, "second") orelse return null;

            const first = parseLayout(alloc, first_obj) orelse return null;
            var second = parseLayout(alloc, second_obj) orelse {
                var first_copy = first;
                first_copy.deinit(alloc);
                return null;
            };
            _ = &second;

            const split = alloc.create(PendingSplit) catch return null;
            split.* = .{
                .orientation = orientation,
                .divider_position = divider,
                .first = first,
                .second = second,
            };
            return .{ .split = split };
        }
    }

    return null;
}

/// Restore workspace metadata from v4 format.
fn restoreWorkspaceMetadataV4(mgr: *workspace_mgr.Manager, ws_id: u64, obj: std.json.ObjectMap) void {
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

    // Git branch (v4 nests under gitBranch object)
    if (obj.get("gitBranch")) |gb_val| {
        if (gb_val == .object) {
            if (getJsonStr(gb_val.object, "branch")) |branch| {
                var is_dirty = false;
                if (gb_val.object.get("isDirty")) |d| {
                    is_dirty = d == .bool and d.bool;
                }
                mgr.setGitBranch(ws_id, branch, is_dirty) catch {};
            }
        }
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

/// Restore workspace metadata from v3 format.
fn restoreWorkspaceMetadata(mgr: *workspace_mgr.Manager, ws_id: u64, obj: std.json.ObjectMap) void {
    if (getJsonStr(obj, "customColor")) |color| {
        mgr.setColor(ws_id, color) catch {};
    }
    if (obj.get("isPinned")) |pinned_val| {
        if (pinned_val == .bool) {
            mgr.setPinned(ws_id, pinned_val.bool);
        }
    }
    if (getJsonStr(obj, "gitBranch")) |branch| {
        const is_dirty = if (obj.get("isDirty")) |d| d == .bool and d.bool else false;
        mgr.setGitBranch(ws_id, branch, is_dirty) catch {};
    }
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

    // Skip the first workspace — it was already created with the window's default tab
    for (pr.workspaces.items, 0..) |*pws, ws_idx| {
        if (ws_idx > 0) {
            // Create a new tab for additional workspaces
            window.newTab(null);
        }

        // Restore panels: for now, handle the simple case of terminal panels
        // by setting the working directory on each surface
        if (pws.layout) |layout| {
            restoreLayout(window, layout, pws.panels.items);
        } else if (pws.panels.items.len > 0) {
            // V3 fallback: just set pwd on the current surface
            const tab_view = window.getTabView();
            const n_pages = tab_view.getNPages();
            if (n_pages > 0) {
                const page = tab_view.getNthPage(n_pages - 1);
                const child = page.getChild();
                if (gobject.ext.cast(Tab, child)) |tab| {
                    if (tab.getActiveSurface()) |surface| {
                        if (pws.panels.items[0].pwd) |pwd| {
                            const pwd_z: [:0]const u8 = glib.ext.dupeZ(u8, pwd);
                            defer glib.free(@ptrCast(@constCast(pwd_z.ptr)));
                            surface.setPwd(pwd_z);
                        }
                    }
                }
            }
        }
    }

    log.info("restored {d} workspaces from session", .{pr.workspaces.items.len});
    return result;
}

/// Restore a layout tree by creating splits and setting working directories.
fn restoreLayout(window: *Window, layout: PendingLayout, panels: []const PendingPanel) void {
    switch (layout) {
        .pane => |pane| {
            // Set working directory on the current surface
            const panel = findPanel(panels, pane.panel_id) orelse return;
            setCurrentSurfacePwd(window, panel);
        },
        .split => |split| {
            // First restore the left/first subtree on the current surface
            restoreLayout(window, split.first, panels);

            // Create a split in the appropriate direction
            const direction: GtkSurface.Tree.Split.Direction = switch (split.orientation) {
                .horizontal => .right,
                .vertical => .down,
            };

            // Get the current tab's split tree and create the split
            const tab_view = window.getTabView();
            const n_pages = tab_view.getNPages();
            if (n_pages > 0) {
                const page = tab_view.getSelectedPage() orelse tab_view.getNthPage(n_pages - 1);
                const child = page.getChild();
                if (gobject.ext.cast(Tab, child)) |tab| {
                    const split_tree = tab.getSplitTree();
                    const parent = split_tree.getActiveSurface();
                    split_tree.newSplit(direction, parent) catch |err| {
                        log.warn("failed to restore split: {}", .{err});
                        return;
                    };
                }
            }

            // Now restore the right/second subtree on the new surface
            restoreLayout(window, split.second, panels);
        },
    }
}

/// Find a panel by ID in the panels array.
fn findPanel(panels: []const PendingPanel, id: u64) ?*const PendingPanel {
    for (panels) |*p| {
        if (p.id == id) return p;
    }
    // Fallback: return first panel if ID not found
    if (panels.len > 0) return &panels[0];
    return null;
}

/// Set the pwd on the currently active surface in the window.
fn setCurrentSurfacePwd(window: *Window, panel: *const PendingPanel) void {
    if (panel.pwd) |pwd| {
        const tab_view = window.getTabView();
        const page = tab_view.getSelectedPage() orelse return;
        const child = page.getChild();
        if (gobject.ext.cast(Tab, child)) |tab| {
            if (tab.getActiveSurface()) |surface| {
                const pwd_z: [:0]const u8 = glib.ext.dupeZ(u8, pwd);
                defer glib.free(@ptrCast(@constCast(pwd_z.ptr)));
                surface.setPwd(pwd_z);
            }
        }
    }
}

/// Check if there's pending restore data.
pub fn hasPendingRestore() bool {
    return pending_restore != null;
}

// --- JSON helpers ---

fn getJsonStr(obj: std.json.ObjectMap, key_name: []const u8) ?[]const u8 {
    const val = obj.get(key_name) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getJsonObj(obj: std.json.ObjectMap, key_name: []const u8) ?std.json.ObjectMap {
    const val = obj.get(key_name) orelse return null;
    return switch (val) {
        .object => |o| o,
        else => null,
    };
}

fn getJsonIntDefault(obj: std.json.ObjectMap, key_name: []const u8, default: i32) i32 {
    const val = obj.get(key_name) orelse return default;
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
