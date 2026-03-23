// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
//
// Workspace manager for cmux.
// A workspace is a named group of terminal tabs. Agents can create,
// switch, rename, and close workspaces via the socket API.
//
// This is a logical overlay on top of Ghostty's single TabView.
// Each workspace tracks its member tabs and metadata (name, cwd, git branch).

const std = @import("std");
const Allocator = std.mem.Allocator;

const WorkspaceStatus = @import("status.zig").WorkspaceStatus;

const log = std.log.scoped(.cmux_workspace);

/// A single workspace.
pub const Workspace = struct {
    id: u64,
    name: []const u8,
    cwd: ?[]const u8 = null,
    custom_color: ?[]const u8 = null, // hex color e.g. "#C0392B"
    is_pinned: bool = false,
    focused_panel_id: ?u64 = null,
    git_branch: ?[]const u8 = null, // current branch name
    is_dirty: bool = false, // uncommitted changes
    port_ordinal: u32 = 0,
    created_at: i64,
    status: WorkspaceStatus,
};

/// Port allocation config (matching macOS defaults).
pub const port_base: u32 = 9100;
pub const port_range: u32 = 10;

/// Workspace manager.
pub const Manager = struct {
    alloc: Allocator,
    workspaces: std.ArrayListUnmanaged(Workspace) = .empty,
    active_id: u64 = 0,
    next_id: u64 = 1,
    next_port_ordinal: u32 = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: Allocator) Manager {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Manager) void {
        for (self.workspaces.items) |*ws| {
            self.alloc.free(ws.name);
            if (ws.cwd) |cwd| self.alloc.free(cwd);
            if (ws.custom_color) |c| self.alloc.free(c);
            if (ws.git_branch) |b| self.alloc.free(b);
            ws.status.deinit();
        }
        self.workspaces.deinit(self.alloc);
    }

    /// Create a new workspace with the given name. Returns the workspace ID.
    pub fn create(self: *Manager, name: []const u8, cwd: ?[]const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const name_copy = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(name_copy);

        const cwd_copy = if (cwd) |c| try self.alloc.dupe(u8, c) else null;
        errdefer if (cwd_copy) |c| self.alloc.free(c);

        const id = self.next_id;
        self.next_id += 1;

        const ordinal = self.next_port_ordinal;
        self.next_port_ordinal += 1;

        try self.workspaces.append(self.alloc, .{
            .id = id,
            .name = name_copy,
            .cwd = cwd_copy,
            .port_ordinal = ordinal,
            .created_at = std.time.timestamp(),
            .status = WorkspaceStatus.init(self.alloc),
        });

        // If this is the first workspace, make it active
        if (self.active_id == 0) {
            self.active_id = id;
        }

        log.info("created workspace id={} name=\"{s}\"", .{ id, name });
        return id;
    }

    /// Select (switch to) a workspace by ID.
    pub fn select(self: *Manager, id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.workspaces.items) |ws| {
            if (ws.id == id) {
                self.active_id = id;
                log.debug("switched to workspace id={} name=\"{s}\"", .{ id, ws.name });
                return true;
            }
        }
        return false;
    }

    /// Get the active workspace ID.
    pub fn activeId(self: *Manager) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.active_id;
    }

    /// Rename a workspace.
    pub fn rename(self: *Manager, id: u64, new_name: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.workspaces.items) |*ws| {
            if (ws.id == id) {
                const name_copy = try self.alloc.dupe(u8, new_name);
                self.alloc.free(ws.name);
                ws.name = name_copy;
                return true;
            }
        }
        return false;
    }

    /// Close (remove) a workspace by ID.
    pub fn close(self: *Manager, id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.workspaces.items, 0..) |*ws, i| {
            if (ws.id == id) {
                self.alloc.free(ws.name);
                if (ws.cwd) |cwd| self.alloc.free(cwd);
                if (ws.custom_color) |c| self.alloc.free(c);
                if (ws.git_branch) |b| self.alloc.free(b);
                ws.status.deinit();
                _ = self.workspaces.orderedRemove(i);

                // If we closed the active workspace, switch to the first one
                if (self.active_id == id) {
                    self.active_id = if (self.workspaces.items.len > 0)
                        self.workspaces.items[0].id
                    else
                        0;
                }
                return true;
            }
        }
        return false;
    }

    /// Reorder a workspace to a new index position.
    pub fn reorder(self: *Manager, id: u64, new_index: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find current index
        var old_index: ?usize = null;
        for (self.workspaces.items, 0..) |ws, i| {
            if (ws.id == id) {
                old_index = i;
                break;
            }
        }
        const from = old_index orelse return false;
        const to = @min(new_index, if (self.workspaces.items.len > 0) self.workspaces.items.len - 1 else 0);
        if (from == to) return true;

        // Remove from old position and insert at new
        const item = self.workspaces.orderedRemove(from);
        self.workspaces.insertSlice(self.alloc, to, &[_]Workspace{item}) catch {
            // Re-insert at original position on failure
            self.workspaces.insertSlice(self.alloc, from, &[_]Workspace{item}) catch {};
            return false;
        };
        return true;
    }

    /// Set the custom color for a workspace.
    pub fn setColor(self: *Manager, id: u64, color: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.workspaces.items) |*ws| {
            if (ws.id == id) {
                if (ws.custom_color) |old| self.alloc.free(old);
                ws.custom_color = if (color) |c| try self.alloc.dupe(u8, c) else null;
                return;
            }
        }
    }

    /// Set the pinned state for a workspace.
    pub fn setPinned(self: *Manager, id: u64, pinned: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.workspaces.items) |*ws| {
            if (ws.id == id) {
                ws.is_pinned = pinned;
                return;
            }
        }
    }

    /// Set the git branch info for a workspace.
    pub fn setGitBranch(self: *Manager, id: u64, branch: ?[]const u8, is_dirty: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.workspaces.items) |*ws| {
            if (ws.id == id) {
                if (ws.git_branch) |old| self.alloc.free(old);
                ws.git_branch = if (branch) |b| try self.alloc.dupe(u8, b) else null;
                ws.is_dirty = is_dirty;
                return;
            }
        }
    }

    /// Get the status store for a workspace (must hold mutex or call with lock).
    pub fn getStatus(self: *Manager, id: u64) ?*WorkspaceStatus {
        for (self.workspaces.items) |*ws| {
            if (ws.id == id) return &ws.status;
        }
        return null;
    }

    /// Get the active workspace's status.
    pub fn getActiveStatus(self: *Manager) ?*WorkspaceStatus {
        return self.getStatus(self.active_id);
    }

    /// Get the port range for the active workspace.
    pub fn getActivePortRange(self: *Manager) struct { port: u32, port_end: u32, range: u32 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.workspaces.items) |ws| {
            if (ws.id == self.active_id) {
                const start = port_base + (ws.port_ordinal * port_range);
                return .{ .port = start, .port_end = start + port_range - 1, .range = port_range };
            }
        }
        return .{ .port = port_base, .port_end = port_base + port_range - 1, .range = port_range };
    }

    /// Format workspace list as JSON for the socket API.
    pub fn formatJson(self: *Manager, alloc: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);
        var writer = buf.writer(alloc);

        try writer.writeAll("[");
        for (self.workspaces.items, 0..) |ws, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print(
                \\{{"id":{d},"name":"{s}","active":{s},"pinned":{s}
            , .{
                ws.id,
                ws.name,
                if (ws.id == self.active_id) "true" else "false",
                if (ws.is_pinned) "true" else "false",
            });
            if (ws.custom_color) |color| {
                try writer.print(",\"color\":\"{s}\"", .{color});
            }
            if (ws.git_branch) |branch| {
                try writer.print(",\"gitBranch\":\"{s}\",\"isDirty\":{s}", .{
                    branch,
                    if (ws.is_dirty) "true" else "false",
                });
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        return try buf.toOwnedSlice(alloc);
    }

    /// Format as V1 text (one workspace per line).
    pub fn formatText(self: *Manager, alloc: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);
        var writer = buf.writer(alloc);

        for (self.workspaces.items) |ws| {
            try writer.print("{d}\t{s}\t{s}\n", .{
                ws.id,
                ws.name,
                if (ws.id == self.active_id) "active" else "",
            });
        }

        return try buf.toOwnedSlice(alloc);
    }
};

// --- Global singleton ---

var global_manager: ?*Manager = null;

pub fn initGlobal(alloc: Allocator) !void {
    const mgr = try alloc.create(Manager);
    mgr.* = Manager.init(alloc);

    // Create a default workspace
    _ = mgr.create("default", null) catch {};

    global_manager = mgr;
}

pub fn deinitGlobal(alloc: Allocator) void {
    if (global_manager) |mgr| {
        mgr.deinit();
        alloc.destroy(mgr);
        global_manager = null;
    }
}

pub fn getGlobal() ?*Manager {
    return global_manager;
}
