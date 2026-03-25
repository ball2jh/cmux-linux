/// Sidebar drop planner — pure logic for workspace reorder drag & drop.
///
/// Faithful port of macOS `SidebarDropPlanner`. Calculates where a drop
/// indicator should appear and what target index a workspace should move
/// to when dropped.
const std = @import("std");
const Uuid = @import("uuid.zig").Uuid;

pub const DropEdge = enum {
    top,
    bottom,
};

pub const DropIndicator = struct {
    /// The workspace to show the indicator relative to.
    /// null means "after the last workspace" (append).
    tab_id: ?Uuid,
    edge: DropEdge,
};

/// Calculate the drop indicator to show during a drag.
///
/// Returns null if no indicator should be shown (e.g. the drop position
/// equals the current position, or there aren't enough tabs to reorder).
pub fn indicator(
    dragged_tab_id: ?Uuid,
    target_tab_id: ?Uuid,
    tab_ids: []const Uuid,
    pinned_tab_ids: []const Uuid,
    pointer_y: ?f64,
    target_height: ?f64,
) ?DropIndicator {
    if (tab_ids.len <= 1) return null;
    const dragged = dragged_tab_id orelse return null;
    const from_index = indexOf(tab_ids, dragged) orelse return null;

    const insertion_position: usize = blk: {
        if (target_tab_id) |target| {
            const target_index = indexOf(tab_ids, target) orelse return null;
            const edge: DropEdge = if (pointer_y != null and target_height != null)
                edgeForPointer(pointer_y.?, target_height.?)
            else
                preferredEdge(from_index, target_index);
            break :blk if (edge == .bottom) target_index + 1 else target_index;
        } else {
            break :blk tab_ids.len;
        }
    };

    const legal = legalInsertionPosition(dragged, insertion_position, tab_ids, pinned_tab_ids);
    const target_idx = resolvedTargetIndex(from_index, legal, tab_ids.len);
    if (target_idx == from_index) return null;
    return indicatorForInsertionPosition(legal, tab_ids);
}

/// Calculate the target index for the final drop.
pub fn targetIndex(
    dragged_tab_id: Uuid,
    target_tab_id: ?Uuid,
    ind: ?DropIndicator,
    tab_ids: []const Uuid,
    pinned_tab_ids: []const Uuid,
) ?usize {
    const from_index = indexOf(tab_ids, dragged_tab_id) orelse return null;

    const insertion_position: usize = blk: {
        if (ind) |the_indicator| {
            if (insertionPositionForIndicator(the_indicator, tab_ids)) |pos| {
                break :blk pos;
            }
        }
        if (target_tab_id) |target| {
            const target_idx = indexOf(tab_ids, target) orelse return null;
            const edge: DropEdge = if (ind) |the_indicator| e: {
                if (the_indicator.tab_id) |ind_tab| {
                    if (ind_tab.eql(target)) {
                        break :e the_indicator.edge;
                    }
                }
                break :e preferredEdge(from_index, target_idx);
            } else preferredEdge(from_index, target_idx);
            break :blk if (edge == .bottom) target_idx + 1 else target_idx;
        } else {
            break :blk tab_ids.len;
        }
    };

    const legal = legalInsertionPosition(dragged_tab_id, insertion_position, tab_ids, pinned_tab_ids);
    return resolvedTargetIndex(from_index, legal, tab_ids.len);
}

/// Determine whether the pointer is in the top or bottom half of a row.
pub fn edgeForPointer(location_y: f64, target_height: f64) DropEdge {
    if (target_height <= 0) return .top;
    const clamped = @min(@max(location_y, 0), target_height);
    return if (clamped < target_height / 2) .top else .bottom;
}

// -----------------------------------------------------------------------
// Internal helpers
// -----------------------------------------------------------------------

fn preferredEdge(from_index: usize, target_index: usize) DropEdge {
    return if (from_index < target_index) .bottom else .top;
}

fn indicatorForInsertionPosition(insertion_position: usize, tab_ids: []const Uuid) DropIndicator {
    const clamped = @min(insertion_position, tab_ids.len);
    if (clamped >= tab_ids.len) {
        return .{ .tab_id = null, .edge = .bottom };
    }
    return .{ .tab_id = tab_ids[clamped], .edge = .top };
}

fn insertionPositionForIndicator(ind: DropIndicator, tab_ids: []const Uuid) ?usize {
    if (ind.tab_id) |tab_id| {
        const idx = indexOf(tab_ids, tab_id) orelse return null;
        return if (ind.edge == .bottom) idx + 1 else idx;
    }
    return tab_ids.len;
}

fn legalInsertionPosition(
    dragged_tab_id: Uuid,
    proposed: usize,
    tab_ids: []const Uuid,
    pinned_tab_ids: []const Uuid,
) usize {
    const clamped = @min(proposed, tab_ids.len);
    if (pinned_tab_ids.len == 0) return clamped;

    var pinned_count: usize = 0;
    for (tab_ids) |id| {
        if (containsUuid(pinned_tab_ids, id)) pinned_count += 1;
    }
    if (pinned_count == 0) return clamped;

    if (containsUuid(pinned_tab_ids, dragged_tab_id)) {
        // Pinned tab must stay in pinned zone
        return @min(clamped, pinned_count);
    }
    // Unpinned tab must stay after pinned zone
    return @max(clamped, pinned_count);
}

fn resolvedTargetIndex(source_index: usize, insertion_position: usize, total_count: usize) usize {
    const clamped = @min(insertion_position, total_count);
    const adjusted = if (clamped > source_index) clamped - 1 else clamped;
    return @min(adjusted, if (total_count > 0) total_count - 1 else 0);
}

fn indexOf(tab_ids: []const Uuid, id: Uuid) ?usize {
    for (tab_ids, 0..) |tab_id, i| {
        if (tab_id.eql(id)) return i;
    }
    return null;
}

fn containsUuid(list: []const Uuid, id: Uuid) bool {
    for (list) |item| {
        if (item.eql(id)) return true;
    }
    return false;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const testing = std.testing;

fn makeUuids(comptime n: usize) [n]Uuid {
    var uuids: [n]Uuid = undefined;
    for (&uuids, 0..) |*u, i| {
        var bytes: [16]u8 = .{0} ** 16;
        bytes[0] = @intCast(i);
        u.* = .{ .bytes = bytes };
    }
    return uuids;
}

test "no indicator for single tab" {
    const ids = makeUuids(1);
    const result = indicator(ids[0], ids[0], &ids, &.{}, null, null);
    try testing.expect(result == null);
}

test "no indicator when dragged to same position" {
    const ids = makeUuids(3);
    // Drag tab 0 to target tab 0 — no move needed
    const result = indicator(ids[0], ids[0], &ids, &.{}, null, null);
    try testing.expect(result == null);
}

test "drag first tab down to second" {
    const ids = makeUuids(3);
    // Drag tab 0 onto tab 1 — preferred edge is bottom (dragging down)
    const result = indicator(ids[0], ids[1], &ids, &.{}, null, null);
    try testing.expect(result != null);
    const ind = result.?;
    // Insertion at index 2 → indicator shows above tab[2]
    try testing.expect(ind.tab_id.?.eql(ids[2]));
    try testing.expectEqual(DropEdge.top, ind.edge);
}

test "drag last tab up to first" {
    const ids = makeUuids(3);
    // Drag tab 2 onto tab 0 — preferred edge is top (dragging up)
    const result = indicator(ids[2], ids[0], &ids, &.{}, null, null);
    try testing.expect(result != null);
    const ind = result.?;
    try testing.expect(ind.tab_id.?.eql(ids[0]));
    try testing.expectEqual(DropEdge.top, ind.edge);
}

test "drag to end (nil target)" {
    const ids = makeUuids(3);
    const result = indicator(ids[0], null, &ids, &.{}, null, null);
    try testing.expect(result != null);
    const ind = result.?;
    try testing.expect(ind.tab_id == null);
    try testing.expectEqual(DropEdge.bottom, ind.edge);
}

test "target index basic reorder" {
    const ids = makeUuids(3);
    // Move tab 0 to after tab 2 (end)
    const ind = DropIndicator{ .tab_id = null, .edge = .bottom };
    const result = targetIndex(ids[0], null, ind, &ids, &.{});
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 2), result.?);
}

test "pinned boundary enforced: unpinned cannot enter pinned zone" {
    const ids = makeUuids(4);
    const pinned = [_]Uuid{ ids[0], ids[1] };
    // Try to drag tab 2 (unpinned) before tab 0 (pinned)
    const result = indicator(ids[2], ids[0], &ids, &pinned, 5.0, 40.0);
    // Should be clamped to after pinned zone
    if (result) |ind| {
        const ti = targetIndex(ids[2], ids[0], ind, &ids, &pinned);
        try testing.expect(ti != null);
        try testing.expect(ti.? >= pinned.len);
    }
}

test "pinned boundary enforced: pinned cannot leave pinned zone" {
    const ids = makeUuids(4);
    const pinned = [_]Uuid{ ids[0], ids[1] };
    // Try to drag tab 0 (pinned) after tab 3 (unpinned)
    const result = indicator(ids[0], ids[3], &ids, &pinned, 35.0, 40.0);
    if (result) |ind| {
        const ti = targetIndex(ids[0], ids[3], ind, &ids, &pinned);
        try testing.expect(ti != null);
        try testing.expect(ti.? < pinned.len);
    }
}

test "edge for pointer top half" {
    try testing.expectEqual(DropEdge.top, edgeForPointer(10.0, 40.0));
}

test "edge for pointer bottom half" {
    try testing.expectEqual(DropEdge.bottom, edgeForPointer(30.0, 40.0));
}

test "edge for pointer zero height" {
    try testing.expectEqual(DropEdge.top, edgeForPointer(10.0, 0.0));
}

test "edge for pointer exactly midpoint" {
    // At exactly half, should be bottom (>= midpoint)
    try testing.expectEqual(DropEdge.bottom, edgeForPointer(20.0, 40.0));
}

test "resolved target index adjusts for removal" {
    // Moving index 1 to insertion position 3 in a 5-element list:
    // After removing index 1, position 3 becomes position 2
    try testing.expectEqual(@as(usize, 2), resolvedTargetIndex(1, 3, 5));
}

test "resolved target index no adjustment when moving up" {
    // Moving index 3 to insertion position 1: no adjustment needed
    try testing.expectEqual(@as(usize, 1), resolvedTargetIndex(3, 1, 5));
}
