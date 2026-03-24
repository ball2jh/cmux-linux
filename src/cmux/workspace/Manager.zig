const std = @import("std");
const Allocator = std.mem.Allocator;
const Uuid = @import("../uuid.zig").Uuid;
const Workspace = @import("Workspace.zig");

const Manager = @This();

/// Ordered list of workspaces (order = sidebar/tab order).
workspaces: std.ArrayListUnmanaged(*Workspace),

/// Fast lookup by UUID.
workspace_map: std.ArrayHashMapUnmanaged(Uuid, *Workspace, Uuid.ArrayHashContext, true),

/// Currently selected workspace ID.
selected_id: ?Uuid,

/// Previously selected workspace ID (for select_last).
last_selected_id: ?Uuid,

/// Monotonically increasing port ordinal counter.
next_port_ordinal: u32,

/// Allocator for the manager and its owned workspaces.
allocator: Allocator,

/// Optional change notification callback.
on_change: ?*const fn (ChangeEvent, ?*anyopaque) void,
on_change_ctx: ?*anyopaque,

// -----------------------------------------------------------------------
// Change events
// -----------------------------------------------------------------------

pub const ChangeEvent = union(enum) {
    workspace_added: Uuid,
    workspace_removed: Uuid,
    workspace_selected: Uuid,
    workspace_reordered,
    workspace_updated: Uuid,
    workspace_remote_state_changed: Uuid,
    panel_added: struct { workspace_id: Uuid, panel_id: Uuid },
    panel_removed: struct { workspace_id: Uuid, panel_id: Uuid },
};

// -----------------------------------------------------------------------
// Initialization
// -----------------------------------------------------------------------

pub fn init(allocator: Allocator) Manager {
    return .{
        .workspaces = .{},
        .workspace_map = .{},
        .selected_id = null,
        .last_selected_id = null,
        .next_port_ordinal = 0,
        .allocator = allocator,
        .on_change = null,
        .on_change_ctx = null,
    };
}

pub fn deinit(self: *Manager) void {
    // Destroy all workspaces
    for (self.workspaces.items) |ws| {
        ws.deinit();
        self.allocator.destroy(ws);
    }
    self.workspaces.deinit(self.allocator);
    self.workspace_map.deinit(self.allocator);
}

// -----------------------------------------------------------------------
// Change notification
// -----------------------------------------------------------------------

pub fn setOnChange(
    self: *Manager,
    cb: ?*const fn (ChangeEvent, ?*anyopaque) void,
    ctx: ?*anyopaque,
) void {
    self.on_change = cb;
    self.on_change_ctx = ctx;
}

pub fn notify(self: *Manager, event: ChangeEvent) void {
    if (self.on_change) |cb| cb(event, self.on_change_ctx);
}

// -----------------------------------------------------------------------
// Workspace lifecycle
// -----------------------------------------------------------------------

pub const CreateOptions = struct {
    title: []const u8 = "Terminal",
    working_directory: []const u8 = "",
    id: ?Uuid = null,
    select: bool = true,
    position: Position = .after_current,

    pub const Position = enum {
        start,
        after_current,
        end,
    };
};

pub fn createWorkspace(self: *Manager, opts: CreateOptions) !*Workspace {
    const ws = try self.allocator.create(Workspace);
    errdefer self.allocator.destroy(ws);

    ws.* = try Workspace.init(self.allocator, .{
        .title = opts.title,
        .working_directory = opts.working_directory,
        .port_ordinal = self.next_port_ordinal,
        .id = opts.id,
    });
    errdefer ws.deinit();

    self.next_port_ordinal += 1;

    // Insert at the requested position
    const insert_idx = switch (opts.position) {
        .start => @as(usize, 0),
        .end => self.workspaces.items.len,
        .after_current => if (self.selectedIndex()) |idx|
            idx + 1
        else
            self.workspaces.items.len,
    };

    try self.workspaces.insert(self.allocator, insert_idx, ws);
    errdefer _ = self.workspaces.orderedRemove(insert_idx);

    try self.workspace_map.put(self.allocator, ws.id, ws);

    self.notify(.{ .workspace_added = ws.id });

    if (opts.select) {
        self.selectWorkspaceInternal(ws.id);
    }

    return ws;
}

pub const CloseError = error{
    WorkspaceNotFound,
    WorkspacePinned,
    LastWorkspace,
};

pub fn closeWorkspace(self: *Manager, id: Uuid) CloseError!void {
    const ws = self.workspaceById(id) orelse return error.WorkspaceNotFound;

    if (ws.is_pinned) return error.WorkspacePinned;
    if (self.workspaces.items.len <= 1) return error.LastWorkspace;

    // If this was selected, select an adjacent workspace
    if (self.selected_id) |sel| {
        if (sel.eql(id)) {
            if (self.selectedIndex()) |idx| {
                // Prefer the next workspace, or the previous if at end
                const new_idx = if (idx + 1 < self.workspaces.items.len) idx + 1 else idx -| 1;
                if (new_idx < self.workspaces.items.len) {
                    self.selectWorkspaceInternal(self.workspaces.items[new_idx].id);
                }
            }
        }
    }

    // Remove from ordered list
    const idx = self.indexOfWorkspace(id) orelse return error.WorkspaceNotFound;
    _ = self.workspaces.orderedRemove(idx);
    _ = self.workspace_map.swapRemove(id);

    // Clear last_selected if it was this workspace
    if (self.last_selected_id) |last| {
        if (last.eql(id)) self.last_selected_id = null;
    }

    self.notify(.{ .workspace_removed = id });

    // Destroy the workspace
    ws.deinit();
    self.allocator.destroy(ws);
}

pub fn closeOtherWorkspaces(self: *Manager, keep_id: Uuid) void {
    // Collect IDs to close (can't modify while iterating)
    var to_close = std.ArrayListUnmanaged(Uuid){};
    defer to_close.deinit(self.allocator);

    for (self.workspaces.items) |ws| {
        if (!ws.id.eql(keep_id) and !ws.is_pinned) {
            to_close.append(self.allocator, ws.id) catch continue;
        }
    }

    for (to_close.items) |id| {
        self.closeWorkspace(id) catch continue;
    }
}

// -----------------------------------------------------------------------
// Selection
// -----------------------------------------------------------------------

pub fn selectWorkspace(self: *Manager, id: Uuid) void {
    if (self.workspaceById(id) == null) return;
    self.selectWorkspaceInternal(id);
}

pub fn selectWorkspaceByIndex(self: *Manager, index: usize) void {
    if (index >= self.workspaces.items.len) return;
    self.selectWorkspaceInternal(self.workspaces.items[index].id);
}

pub fn selectNextWorkspace(self: *Manager) void {
    if (self.workspaces.items.len == 0) return;
    const idx = self.selectedIndex() orelse return;
    const next = (idx + 1) % self.workspaces.items.len;
    self.selectWorkspaceInternal(self.workspaces.items[next].id);
}

pub fn selectPreviousWorkspace(self: *Manager) void {
    if (self.workspaces.items.len == 0) return;
    const idx = self.selectedIndex() orelse return;
    const prev = if (idx == 0) self.workspaces.items.len - 1 else idx - 1;
    self.selectWorkspaceInternal(self.workspaces.items[prev].id);
}

pub fn selectLastWorkspace(self: *Manager) void {
    if (self.last_selected_id) |last| {
        if (self.workspaceById(last) != null) {
            self.selectWorkspaceInternal(last);
        }
    }
}

fn selectWorkspaceInternal(self: *Manager, id: Uuid) void {
    if (self.selected_id) |current| {
        if (current.eql(id)) return;
        self.last_selected_id = current;
    }
    self.selected_id = id;
    self.notify(.{ .workspace_selected = id });
}

// -----------------------------------------------------------------------
// Ordering
// -----------------------------------------------------------------------

pub fn moveWorkspaceUp(self: *Manager, id: Uuid) void {
    const idx = self.indexOfWorkspace(id) orelse return;
    if (idx == 0) return;
    self.swapWorkspaces(idx, idx - 1);
    self.notify(.workspace_reordered);
}

pub fn moveWorkspaceDown(self: *Manager, id: Uuid) void {
    const idx = self.indexOfWorkspace(id) orelse return;
    if (idx + 1 >= self.workspaces.items.len) return;
    self.swapWorkspaces(idx, idx + 1);
    self.notify(.workspace_reordered);
}

pub fn moveWorkspaceToTop(self: *Manager, id: Uuid) void {
    const idx = self.indexOfWorkspace(id) orelse return;
    if (idx == 0) return;
    const ws = self.workspaces.orderedRemove(idx);
    self.workspaces.insert(self.allocator, 0, ws) catch return;
    self.notify(.workspace_reordered);
}

pub fn moveWorkspaceToIndex(self: *Manager, id: Uuid, new_index: usize) void {
    const idx = self.indexOfWorkspace(id) orelse return;
    if (idx == new_index) return;
    const target = @min(new_index, self.workspaces.items.len -| 1);
    const ws = self.workspaces.orderedRemove(idx);
    self.workspaces.insert(self.allocator, target, ws) catch return;
    self.notify(.workspace_reordered);
}

pub fn renameWorkspace(self: *Manager, id: Uuid, title: []const u8) error{ WorkspaceNotFound, OutOfMemory }!void {
    const ws = self.workspaceById(id) orelse return error.WorkspaceNotFound;
    try ws.setCustomTitle(if (title.len > 0) title else null);
    self.notify(.{ .workspace_updated = id });
}

fn swapWorkspaces(self: *Manager, a: usize, b: usize) void {
    const items = self.workspaces.items;
    const tmp = items[a];
    items[a] = items[b];
    items[b] = tmp;
}

// -----------------------------------------------------------------------
// Queries
// -----------------------------------------------------------------------

pub fn workspaceCount(self: *const Manager) usize {
    return self.workspaces.items.len;
}

pub fn workspaceByIndex(self: *const Manager, index: usize) ?*Workspace {
    if (index >= self.workspaces.items.len) return null;
    return self.workspaces.items[index];
}

pub fn workspaceById(self: *const Manager, id: Uuid) ?*Workspace {
    return self.workspace_map.get(id);
}

pub fn selectedWorkspace(self: *const Manager) ?*Workspace {
    const id = self.selected_id orelse return null;
    return self.workspaceById(id);
}

pub fn selectedIndex(self: *const Manager) ?usize {
    const id = self.selected_id orelse return null;
    return self.indexOfWorkspace(id);
}

// -----------------------------------------------------------------------
// Private helpers
// -----------------------------------------------------------------------

pub fn indexOfWorkspace(self: *const Manager, id: Uuid) ?usize {
    for (self.workspaces.items, 0..) |ws, i| {
        if (ws.id.eql(id)) return i;
    }
    return null;
}

// -----------------------------------------------------------------------
// Session persistence — snapshot building
// -----------------------------------------------------------------------

const snap = @import("snapshot.zig");
const policy = @import("../persistence/policy.zig");

/// Build a serializable snapshot of the tab manager (all workspaces).
pub fn sessionSnapshot(self: *const Manager, alloc: std.mem.Allocator, include_scrollback: bool, scrollback_reader: Workspace.ScrollbackReader) !snap.TabManagerSnapshot {
    const count = @min(self.workspaces.items.len, policy.max_workspaces_per_window);
    const ws_snapshots = try alloc.alloc(snap.WorkspaceSnapshot, count);
    errdefer alloc.free(ws_snapshots);

    for (self.workspaces.items[0..count], 0..) |ws, i| {
        ws_snapshots[i] = try ws.sessionSnapshot(alloc, include_scrollback, scrollback_reader);
    }

    const selected_idx: ?usize = if (self.selected_id) |sel|
        self.indexOfWorkspace(sel)
    else
        null;

    return .{
        .selected_workspace_index = selected_idx,
        .workspaces = ws_snapshots,
    };
}

/// Compute a fingerprint of the current state for autosave dedup.
/// Returns a hash that changes when meaningful state changes.
pub fn sessionAutosaveFingerprint(self: *const Manager) u64 {
    var hasher = std.hash.Wyhash.init(0);

    hasher.update(std.mem.asBytes(&self.workspaces.items.len));
    if (self.selected_id) |sel| hasher.update(&sel.bytes) else hasher.update(&[_]u8{0} ** 16);

    for (self.workspaces.items) |ws| {
        hasher.update(&ws.id.bytes);
        hasher.update(ws.process_title);
        hasher.update(ws.custom_title orelse "");
        hasher.update(ws.custom_color orelse "");
        hasher.update(ws.current_directory);
        hasher.update(if (ws.is_pinned) "1" else "0");
        hasher.update(std.mem.asBytes(&ws.panels.count()));
        hasher.update(std.mem.asBytes(&ws.status_entries.count()));
        hasher.update(std.mem.asBytes(&ws.log_entries.items.len));

        if (ws.focused_panel_id) |fid| hasher.update(&fid.bytes) else hasher.update(&[_]u8{0} ** 16);

        if (ws.progress) |p| {
            const quantized: i32 = @intFromFloat(p.value * 1000);
            hasher.update(std.mem.asBytes(&quantized));
            hasher.update(p.label orelse "");
        } else {
            hasher.update(&[_]u8{0xFF});
        }

        if (ws.git_branch) |g| {
            hasher.update(g.branch);
            hasher.update(if (g.is_dirty) "1" else "0");
        } else {
            hasher.update("");
            hasher.update("0");
        }
    }

    return hasher.final();
}

/// Restore the workspace manager state from a tab manager snapshot.
/// Clears all existing workspaces and recreates from the snapshot.
pub fn restoreSessionSnapshot(self: *Manager, tm_snap: snap.TabManagerSnapshot) !void {
    // Clear existing workspaces
    while (self.workspaces.items.len > 0) {
        const ws = self.workspaces.items[self.workspaces.items.len - 1];
        const id = ws.id;
        _ = self.workspaces.pop();
        _ = self.workspace_map.swapRemove(id);
        ws.deinit();
        self.allocator.destroy(ws);
    }
    self.selected_id = null;
    self.last_selected_id = null;

    // Create workspaces from snapshot
    for (tm_snap.workspaces) |ws_snap| {
        const ws = try self.allocator.create(Workspace);
        errdefer self.allocator.destroy(ws);

        ws.* = try Workspace.init(self.allocator, .{
            .title = ws_snap.process_title,
            .working_directory = ws_snap.current_directory,
            .port_ordinal = self.next_port_ordinal,
        });
        errdefer ws.deinit();
        self.next_port_ordinal += 1;

        // Restore workspace state from snapshot
        try ws.restoreFromSnapshot(ws_snap);

        try self.workspaces.append(self.allocator, ws);
        try self.workspace_map.put(self.allocator, ws.id, ws);
        self.notify(.{ .workspace_added = ws.id });
    }

    // Select the workspace from the snapshot
    if (tm_snap.selected_workspace_index) |idx| {
        if (idx < self.workspaces.items.len) {
            self.selectWorkspaceInternal(self.workspaces.items[idx].id);
        }
    } else if (self.workspaces.items.len > 0) {
        self.selectWorkspaceInternal(self.workspaces.items[0].id);
    }
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "create and query workspace" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws = try mgr.createWorkspace(.{ .title = "test" });
    try std.testing.expectEqual(@as(usize, 1), mgr.workspaceCount());
    try std.testing.expectEqualStrings("test", ws.displayTitle());
    try std.testing.expect(mgr.selectedWorkspace() != null);
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws.id));
}

test "create multiple and select" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "first" });
    const ws2 = try mgr.createWorkspace(.{ .title = "second" });
    const ws3 = try mgr.createWorkspace(.{ .title = "third" });

    // Last created should be selected
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws3.id));
    try std.testing.expectEqual(@as(usize, 3), mgr.workspaceCount());

    // Select by ID
    mgr.selectWorkspace(ws1.id);
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws1.id));

    // Select by index
    mgr.selectWorkspaceByIndex(1);
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws2.id));
}

test "select next and previous wraps around" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "a" });
    _ = try mgr.createWorkspace(.{ .title = "b" });
    const ws3 = try mgr.createWorkspace(.{ .title = "c" });

    // ws3 is selected (last created). Next should wrap to ws1.
    mgr.selectNextWorkspace();
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws1.id));

    // Previous from ws1 should wrap to ws3.
    mgr.selectPreviousWorkspace();
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws3.id));
}

test "select last returns to previous" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "a" });
    const ws2 = try mgr.createWorkspace(.{ .title = "b" });

    // ws2 is selected. Select ws1.
    mgr.selectWorkspace(ws1.id);
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws1.id));

    // selectLast should go back to ws2
    mgr.selectLastWorkspace();
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws2.id));
}

test "close workspace selects adjacent" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    _ = try mgr.createWorkspace(.{ .title = "a" });
    const ws2 = try mgr.createWorkspace(.{ .title = "b" });
    const ws3 = try mgr.createWorkspace(.{ .title = "c" });

    // ws3 selected. Close it — should select ws2.
    try mgr.closeWorkspace(ws3.id);
    try std.testing.expectEqual(@as(usize, 2), mgr.workspaceCount());
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws2.id));
}

test "cannot close last workspace" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws = try mgr.createWorkspace(.{});
    try std.testing.expectError(CloseError.LastWorkspace, mgr.closeWorkspace(ws.id));
}

test "cannot close pinned workspace" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws = try mgr.createWorkspace(.{});
    _ = try mgr.createWorkspace(.{}); // need at least 2
    ws.setPinned(true);
    try std.testing.expectError(CloseError.WorkspacePinned, mgr.closeWorkspace(ws.id));
}

test "move workspace ordering" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "a" });
    const ws2 = try mgr.createWorkspace(.{ .title = "b" });
    const ws3 = try mgr.createWorkspace(.{ .title = "c" });

    // Move ws3 to top
    mgr.moveWorkspaceToTop(ws3.id);
    try std.testing.expect(mgr.workspaceByIndex(0).?.id.eql(ws3.id));
    try std.testing.expect(mgr.workspaceByIndex(1).?.id.eql(ws1.id));
    try std.testing.expect(mgr.workspaceByIndex(2).?.id.eql(ws2.id));

    // Move ws3 down one
    mgr.moveWorkspaceDown(ws3.id);
    try std.testing.expect(mgr.workspaceByIndex(0).?.id.eql(ws1.id));
    try std.testing.expect(mgr.workspaceByIndex(1).?.id.eql(ws3.id));
}

test "port ordinal increments" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{});
    const ws2 = try mgr.createWorkspace(.{});
    const ws3 = try mgr.createWorkspace(.{});

    try std.testing.expectEqual(@as(u32, 0), ws1.port_ordinal);
    try std.testing.expectEqual(@as(u32, 1), ws2.port_ordinal);
    try std.testing.expectEqual(@as(u32, 2), ws3.port_ordinal);
}

test "change events fire" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const State = struct {
        var added_count: usize = 0;
        var selected_count: usize = 0;
        var removed_count: usize = 0;

        fn handler(event: ChangeEvent, _: ?*anyopaque) void {
            switch (event) {
                .workspace_added => added_count += 1,
                .workspace_selected => selected_count += 1,
                .workspace_removed => removed_count += 1,
                else => {},
            }
        }
    };

    State.added_count = 0;
    State.selected_count = 0;
    State.removed_count = 0;

    mgr.setOnChange(&State.handler, null);

    _ = try mgr.createWorkspace(.{}); // fires added + selected
    const ws2 = try mgr.createWorkspace(.{}); // fires added + selected

    try std.testing.expectEqual(@as(usize, 2), State.added_count);
    try std.testing.expectEqual(@as(usize, 2), State.selected_count);

    try mgr.closeWorkspace(ws2.id); // fires selected (new selection) + removed
    try std.testing.expectEqual(@as(usize, 1), State.removed_count);
}

test "after_current position inserts correctly" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "a" });
    _ = try mgr.createWorkspace(.{ .title = "c", .position = .end });

    // Select ws1, then create at after_current
    mgr.selectWorkspace(ws1.id);
    const ws_mid = try mgr.createWorkspace(.{ .title = "b", .position = .after_current });

    // Should be at index 1 (after ws1)
    try std.testing.expect(mgr.workspaceByIndex(0).?.id.eql(ws1.id));
    try std.testing.expect(mgr.workspaceByIndex(1).?.id.eql(ws_mid.id));
}

// -----------------------------------------------------------------------
// Tests ported from macOS TabManagerUnitTests.swift
// -----------------------------------------------------------------------

test "Manager: close workspace returns error for unknown UUID" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    _ = try mgr.createWorkspace(.{});
    _ = try mgr.createWorkspace(.{});

    const initial_count = mgr.workspaceCount();
    const bogus_id = Uuid.generate();

    try std.testing.expectError(CloseError.WorkspaceNotFound, mgr.closeWorkspace(bogus_id));
    try std.testing.expectEqual(initial_count, mgr.workspaceCount());
}

test "Manager: close middle workspace keeps selection at same index" {
    // Ported from testChildExitOnLastPanelClosesSelectedWorkspaceAndKeepsIndexStable
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const first = try mgr.createWorkspace(.{ .title = "first" });
    const second = try mgr.createWorkspace(.{ .title = "second" });
    const third = try mgr.createWorkspace(.{ .title = "third" });

    mgr.selectWorkspace(second.id);
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(second.id));

    // Close the selected middle workspace — selection should advance to
    // the workspace now at the same index (third).
    try mgr.closeWorkspace(second.id);

    try std.testing.expectEqual(@as(usize, 2), mgr.workspaceCount());
    try std.testing.expect(mgr.workspaceByIndex(0).?.id.eql(first.id));
    try std.testing.expect(mgr.workspaceByIndex(1).?.id.eql(third.id));
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(third.id));
}

test "Manager: close last-index workspace selects previous" {
    // Ported from testChildExitOnLastPanelInLastWorkspaceSelectsPreviousWorkspace
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const first = try mgr.createWorkspace(.{ .title = "first" });
    const second = try mgr.createWorkspace(.{ .title = "second" });

    mgr.selectWorkspace(second.id);
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(second.id));

    try mgr.closeWorkspace(second.id);

    try std.testing.expectEqual(@as(usize, 1), mgr.workspaceCount());
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(first.id));
}

test "Manager: close other workspaces keeps target" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    _ = try mgr.createWorkspace(.{ .title = "a" });
    const ws2 = try mgr.createWorkspace(.{ .title = "b" });
    _ = try mgr.createWorkspace(.{ .title = "c" });

    mgr.closeOtherWorkspaces(ws2.id);

    try std.testing.expectEqual(@as(usize, 1), mgr.workspaceCount());
    try std.testing.expect(mgr.workspaceByIndex(0).?.id.eql(ws2.id));
}

test "Manager: close other workspaces preserves pinned" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "pinned" });
    ws1.setPinned(true);
    const ws2 = try mgr.createWorkspace(.{ .title = "keep" });
    _ = try mgr.createWorkspace(.{ .title = "remove" });

    mgr.closeOtherWorkspaces(ws2.id);

    // ws1 (pinned) and ws2 (kept) should remain; ws3 should be removed
    try std.testing.expectEqual(@as(usize, 2), mgr.workspaceCount());
    try std.testing.expect(mgr.workspaceById(ws1.id) != null);
    try std.testing.expect(mgr.workspaceById(ws2.id) != null);
}

test "Manager: move workspace up at top is noop" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "a" });
    const ws2 = try mgr.createWorkspace(.{ .title = "b" });

    mgr.moveWorkspaceUp(ws1.id);

    try std.testing.expect(mgr.workspaceByIndex(0).?.id.eql(ws1.id));
    try std.testing.expect(mgr.workspaceByIndex(1).?.id.eql(ws2.id));
}

test "Manager: move workspace down at bottom is noop" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "a" });
    const ws2 = try mgr.createWorkspace(.{ .title = "b" });

    mgr.moveWorkspaceDown(ws2.id);

    try std.testing.expect(mgr.workspaceByIndex(0).?.id.eql(ws1.id));
    try std.testing.expect(mgr.workspaceByIndex(1).?.id.eql(ws2.id));
}

test "Manager: move workspace to specific index" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "a" });
    const ws2 = try mgr.createWorkspace(.{ .title = "b" });
    const ws3 = try mgr.createWorkspace(.{ .title = "c" });

    // Move ws1 (index 0) to index 2 (end)
    mgr.moveWorkspaceToIndex(ws1.id, 2);
    try std.testing.expect(mgr.workspaceByIndex(0).?.id.eql(ws2.id));
    try std.testing.expect(mgr.workspaceByIndex(1).?.id.eql(ws3.id));
    try std.testing.expect(mgr.workspaceByIndex(2).?.id.eql(ws1.id));
}

test "Manager: move workspace to index clamps to bounds" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "a" });
    const ws2 = try mgr.createWorkspace(.{ .title = "b" });
    const ws3 = try mgr.createWorkspace(.{ .title = "c" });

    // Move ws1 to index 999 — should clamp to end
    mgr.moveWorkspaceToIndex(ws1.id, 999);
    try std.testing.expect(mgr.workspaceByIndex(0).?.id.eql(ws2.id));
    try std.testing.expect(mgr.workspaceByIndex(1).?.id.eql(ws3.id));
    try std.testing.expect(mgr.workspaceByIndex(2).?.id.eql(ws1.id));
}

test "Manager: select by invalid index is noop" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws = try mgr.createWorkspace(.{});
    mgr.selectWorkspaceByIndex(999);

    // Selection should remain unchanged
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws.id));
}

test "Manager: select next on empty manager is noop" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    mgr.selectNextWorkspace();
    try std.testing.expect(mgr.selectedWorkspace() == null);
}

test "Manager: select previous on empty manager is noop" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    mgr.selectPreviousWorkspace();
    try std.testing.expect(mgr.selectedWorkspace() == null);
}

test "Manager: select last with no history is noop" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws = try mgr.createWorkspace(.{});
    // Only one workspace ever — last_selected_id is null
    mgr.selectLastWorkspace();
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws.id));
}

test "Manager: create workspace with explicit id" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const explicit_id = Uuid.generate();
    const ws = try mgr.createWorkspace(.{ .id = explicit_id });

    try std.testing.expect(ws.id.eql(explicit_id));
    try std.testing.expect(mgr.workspaceById(explicit_id) != null);
}

test "Manager: create workspace without auto-select" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "first" });
    _ = try mgr.createWorkspace(.{ .title = "second", .select = false });

    // ws1 should still be selected because ws2 was created with select=false
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws1.id));
    try std.testing.expectEqual(@as(usize, 2), mgr.workspaceCount());
}

test "Manager: workspace lookup by id returns null for unknown" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    _ = try mgr.createWorkspace(.{});

    const bogus = Uuid.generate();
    try std.testing.expect(mgr.workspaceById(bogus) == null);
}

test "Manager: start position inserts at beginning" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "first" });
    const ws2 = try mgr.createWorkspace(.{ .title = "second", .position = .end });
    const ws_front = try mgr.createWorkspace(.{ .title = "front", .position = .start });

    try std.testing.expect(mgr.workspaceByIndex(0).?.id.eql(ws_front.id));
    try std.testing.expect(mgr.workspaceByIndex(1).?.id.eql(ws1.id));
    try std.testing.expect(mgr.workspaceByIndex(2).?.id.eql(ws2.id));
}

test "Manager: last_selected_id cleared when that workspace is closed" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "a" });
    const ws2 = try mgr.createWorkspace(.{ .title = "b" });
    _ = try mgr.createWorkspace(.{ .title = "c" });

    // ws3 is selected. Select ws1 — last_selected becomes ws3.
    mgr.selectWorkspace(ws1.id);
    // Select ws2 — last_selected becomes ws1.
    mgr.selectWorkspace(ws2.id);
    // Now close ws1 (the last_selected). last_selected should be cleared.
    try mgr.closeWorkspace(ws1.id);

    // selectLast should be a noop since last_selected was cleared
    mgr.selectLastWorkspace();
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws2.id));
}

test "Manager: select workspace by id with unknown id is noop" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws = try mgr.createWorkspace(.{});
    mgr.selectWorkspace(Uuid.generate());

    // Selection unchanged
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws.id));
}

test "Manager: selecting already-selected workspace is noop" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "a" });
    const ws2 = try mgr.createWorkspace(.{ .title = "b" });

    // Select ws1, then select ws1 again — last_selected should still be ws2
    mgr.selectWorkspace(ws1.id);
    mgr.selectWorkspace(ws1.id); // noop

    mgr.selectLastWorkspace();
    try std.testing.expect(mgr.selectedWorkspace().?.id.eql(ws2.id));
}

test "Manager: move workspace up swaps with predecessor" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "a" });
    const ws2 = try mgr.createWorkspace(.{ .title = "b" });
    const ws3 = try mgr.createWorkspace(.{ .title = "c" });

    mgr.moveWorkspaceUp(ws2.id);

    try std.testing.expect(mgr.workspaceByIndex(0).?.id.eql(ws2.id));
    try std.testing.expect(mgr.workspaceByIndex(1).?.id.eql(ws1.id));
    try std.testing.expect(mgr.workspaceByIndex(2).?.id.eql(ws3.id));
}

test "Manager: selectedIndex returns correct index" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    _ = try mgr.createWorkspace(.{ .title = "a" });
    const ws2 = try mgr.createWorkspace(.{ .title = "b" });
    _ = try mgr.createWorkspace(.{ .title = "c" });

    mgr.selectWorkspace(ws2.id);
    try std.testing.expectEqual(@as(?usize, 1), mgr.selectedIndex());
}

test "Manager: selectedIndex returns null when nothing selected" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    try std.testing.expect(mgr.selectedIndex() == null);
}

test "Manager: workspaceByIndex returns null for out-of-bounds" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    _ = try mgr.createWorkspace(.{});
    try std.testing.expect(mgr.workspaceByIndex(5) == null);
}

test "Manager: reorder event fires on move" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const State = struct {
        var reorder_count: usize = 0;

        fn handler(event: ChangeEvent, _: ?*anyopaque) void {
            switch (event) {
                .workspace_reordered => reorder_count += 1,
                else => {},
            }
        }
    };

    State.reorder_count = 0;
    mgr.setOnChange(&State.handler, null);

    _ = try mgr.createWorkspace(.{ .title = "a" });
    const ws2 = try mgr.createWorkspace(.{ .title = "b" });

    mgr.moveWorkspaceUp(ws2.id);
    try std.testing.expectEqual(@as(usize, 1), State.reorder_count);

    mgr.moveWorkspaceDown(ws2.id);
    try std.testing.expectEqual(@as(usize, 2), State.reorder_count);

    mgr.moveWorkspaceToTop(ws2.id);
    try std.testing.expectEqual(@as(usize, 3), State.reorder_count);
}

test "Manager: move workspace to same index is noop" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const State = struct {
        var reorder_count: usize = 0;

        fn handler(event: ChangeEvent, _: ?*anyopaque) void {
            switch (event) {
                .workspace_reordered => reorder_count += 1,
                else => {},
            }
        }
    };

    State.reorder_count = 0;
    mgr.setOnChange(&State.handler, null);

    const ws1 = try mgr.createWorkspace(.{ .title = "a" });
    _ = try mgr.createWorkspace(.{ .title = "b" });

    mgr.moveWorkspaceToIndex(ws1.id, 0);
    try std.testing.expectEqual(@as(usize, 0), State.reorder_count);
}

test "Manager: move workspace to top when already at top is noop" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const State = struct {
        var reorder_count: usize = 0;

        fn handler(event: ChangeEvent, _: ?*anyopaque) void {
            switch (event) {
                .workspace_reordered => reorder_count += 1,
                else => {},
            }
        }
    };

    State.reorder_count = 0;
    mgr.setOnChange(&State.handler, null);

    const ws1 = try mgr.createWorkspace(.{ .title = "a" });
    _ = try mgr.createWorkspace(.{ .title = "b" });

    mgr.moveWorkspaceToTop(ws1.id);
    try std.testing.expectEqual(@as(usize, 0), State.reorder_count);
}

// -----------------------------------------------------------------------
// Stubs for Swift tests that require APIs not yet in the Zig Manager.
// Each block documents which Swift test class/method it corresponds to.
// -----------------------------------------------------------------------

// TODO: Port TabManagerChildExitCloseTests
// These tests require closePanelAfterChildExited() and panel/surface APIs:
//   - testChildExitOnLastPanelClosesSelectedWorkspaceAndKeepsIndexStable
//     (core workspace-close logic already tested above)
//   - testChildExitOnNonLastPanelClosesOnlyPanel
//     (needs newTerminalSplit, panels map)

// TODO: Port TabManagerPullRequestProbeTests
// These test static helper methods not yet in the Zig Manager:
//   - testGitHubRepositorySlugsPrioritizeUpstreamThenOriginAndDeduplicate
//     (needs githubRepositorySlugs)
//   - testPreferredPullRequestPrefersOpenOverMergedAndClosed
//     (needs GitHubPullRequestProbeItem, preferredPullRequest)
//   - testPreferredPullRequestPrefersMostRecentlyUpdatedWithinSameStatus
//   - testPreferredPullRequestIgnoresMalformedCandidates

// TODO: Port TabManagerCloseWorkspacesWithConfirmationTests
// These require confirmCloseHandler, setSidebarSelectedWorkspaceIds,
// setCustomTitle, and closeWorkspacesWithConfirmation:
//   - testCloseWorkspacesWithConfirmationPromptsOnceAndClosesAcceptedWorkspaces
//   - testCloseWorkspacesWithConfirmationKeepsWorkspacesWhenCancelled
//   - testCloseCurrentWorkspaceWithConfirmationUsesSidebarMultiSelection

// TODO: Port TabManagerCloseCurrentPanelTests
// These require panel close with confirmation, shell activity state,
// surface management, and pinned-workspace close confirmation:
//   - testRuntimeCloseSkipsConfirmationWhenShellReportsPromptIdle
//   - testRuntimeClosePromptsWhenShellReportsRunningCommand
//   - testCloseCurrentPanelClosesWorkspaceWhenItOwnsTheLastSurface
//   - testCloseCurrentPanelPromptsBeforeClosingPinnedWorkspaceLastSurface
//   - testCloseCurrentPanelClosesPinnedWorkspaceAfterConfirmation
//   - testCloseCurrentPanelKeepsWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled
//   - testClosePanelButtonClosesWorkspaceWhenItOwnsTheLastSurface
//   - testClosePanelButtonStillClosesWorkspaceWhenKeepWorkspaceOpenPreferenceIsEnabled
//   - testGenericClosePanelKeepsWorkspaceOpenWithoutExplicitCloseMarker
//   - testCloseCurrentPanelIgnoresStaleSurfaceId
//   - testCloseCurrentPanelClearsNotificationsForClosedSurface

// TODO: Port TabManagerNotificationFocusTests
// These require split zoom, notification store, and focusTabFromNotification:
//   - testFocusTabFromNotificationClearsSplitZoomBeforeFocusingTargetPanel
//   - testFocusTabFromNotificationReturnsFalseForMissingPanel
//   - testFocusTabFromNotificationDismissesUnreadWithDismissFlash

// TODO: Port TabManagerPendingUnfocusPolicyTests
// These require shouldUnfocusPendingWorkspace static method:
//   - testDoesNotUnfocusWhenPendingTabIsCurrentlySelected
//   - testUnfocusesWhenPendingTabIsNotSelected

// TODO: Port TabManagerSurfaceCreationTests
// These require newSurface, openBrowser, and bonsplit pane APIs:
//   - testNewSurfaceFocusesCreatedSurface
//   - testOpenBrowserInsertAtEndPlacesNewBrowserAtPaneEnd
//   - testOpenBrowserInWorkspaceSplitRightSelectsTargetWorkspaceAndCreatesSplit
//   - testOpenBrowserInWorkspaceSplitRightReusesTopRightPaneWhenAlreadySplit

// TODO: Port TabManagerEqualizeSplitsTests
// These require bonsplit tree operations:
//   - testEqualizeSplitsSetsEverySplitDividerToHalf

// TODO: Port TabManagerWorkspaceConfigInheritanceSourceTests
// These require terminalPanelForWorkspaceConfigInheritanceSource and browser panels:
//   - testUsesFocusedTerminalWhenTerminalIsFocused
//   - testFallsBackToTerminalWhenBrowserIsFocused
//   - testPrefersLastFocusedTerminalAcrossPanesWhenBrowserIsFocused

// -----------------------------------------------------------------------
// Session persistence tests
// -----------------------------------------------------------------------

test "Manager: sessionSnapshot captures workspace state" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    const ws1 = try mgr.createWorkspace(.{ .title = "Terminal" });
    try ws1.setCwd("/home/user");
    const ws2 = try mgr.createWorkspace(.{ .title = "Server" });
    try ws2.setCustomTitle("Backend");

    const tm_snap = try mgr.sessionSnapshot(alloc, false, .{});
    defer {
        for (tm_snap.workspaces) |*ws_s| {
            snap.freeWorkspaceSnapshot(alloc, @constCast(ws_s));
        }
        alloc.free(tm_snap.workspaces);
    }

    try std.testing.expectEqual(@as(usize, 2), tm_snap.workspaces.len);
    try std.testing.expectEqualStrings("Terminal", tm_snap.workspaces[0].process_title);
    try std.testing.expectEqualStrings("/home/user", tm_snap.workspaces[0].current_directory);
    try std.testing.expectEqualStrings("Server", tm_snap.workspaces[1].process_title);
    try std.testing.expectEqualStrings("Backend", tm_snap.workspaces[1].custom_title.?);

    // ws2 was last created with auto-select, so it should be selected
    try std.testing.expectEqual(@as(?usize, 1), tm_snap.selected_workspace_index);
}

test "Manager: sessionAutosaveFingerprint changes on state change" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    _ = try mgr.createWorkspace(.{ .title = "Terminal" });
    const fp1 = mgr.sessionAutosaveFingerprint();

    // Create another workspace — fingerprint should change
    _ = try mgr.createWorkspace(.{ .title = "Server" });
    const fp2 = mgr.sessionAutosaveFingerprint();
    try std.testing.expect(fp1 != fp2);
}

test "Manager: sessionAutosaveFingerprint stable when unchanged" {
    const alloc = std.testing.allocator;
    var mgr = Manager.init(alloc);
    defer mgr.deinit();

    _ = try mgr.createWorkspace(.{ .title = "Terminal" });
    const fp1 = mgr.sessionAutosaveFingerprint();
    const fp2 = mgr.sessionAutosaveFingerprint();
    try std.testing.expectEqual(fp1, fp2);
}

// TODO: Port TabManagerFocusedNotificationIndicatorTests
// These require notification store and focus-based notification dismissal:
//   - testFocusPanelDismissesUnreadNotificationWithDismissFlash
//   - testDismissNotificationOnDirectInteractionClearsFocusedNotificationIndicator
//   - testDismissNotificationOnDirectInteractionTriggersDismissFlashForFocusedIndicatorOnly

// TODO: Port TabManagerReopenClosedBrowserFocusTests
// These require browser panel reopen and workspace switching:
//   - testReopenFromDifferentWorkspaceFocusesReopenedBrowser
//   - testReopenFallsBackToCurrentWorkspaceAndFocusesBrowserWhenOriginalWorkspaceDeleted
//   - testReopenCollapsedSplitFromDifferentWorkspaceFocusesBrowser
//   - testReopenFromDifferentWorkspaceWinsAgainstSingleDeferredStaleFocus
//   - testReopenInSameWorkspaceWinsAgainstSingleDeferredStaleFocus
