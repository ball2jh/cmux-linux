//! Bridge between the cmux workspace Manager and GTK widgets.
//!
//! The Manager fires change events from any thread (socket handler threads).
//! This module dispatches those events to the GTK main thread via g_idle_add,
//! where the CmuxWindow handles them.

const std = @import("std");
const cmux = @import("../main.zig");
const CmuxWindow = @import("window.zig").CmuxWindow;

const log = std.log.scoped(.cmux_bridge);

/// Stable context passed to Manager.setOnChange.
pub const BridgeContext = struct {
    window: *CmuxWindow,
};

/// Called by Manager on any thread.
/// Dispatches the event to the main GTK thread via idle_add.
pub fn onManagerChange(event: cmux.workspace.Manager.ChangeEvent, ctx_raw: ?*anyopaque) void {
    const ctx: *BridgeContext = @ptrCast(@alignCast(ctx_raw orelse return));

    // Heap-allocate an event box to survive until the idle callback runs.
    const alloc = std.heap.c_allocator;
    const boxed = alloc.create(EventBox) catch {
        log.err("failed to allocate event box for bridge dispatch", .{});
        return;
    };
    boxed.* = .{
        .event = event,
        .window = ctx.window,
    };

    cmux.dispatch.idleAdd(&dispatchOnMainThread, @ptrCast(boxed));
}

const EventBox = struct {
    event: cmux.workspace.Manager.ChangeEvent,
    window: *CmuxWindow,
};

fn dispatchOnMainThread(data: ?*anyopaque) callconv(.c) c_int {
    const boxed: *EventBox = @ptrCast(@alignCast(data orelse return 0));
    defer std.heap.c_allocator.destroy(boxed);

    switch (boxed.event) {
        .workspace_added => |id| boxed.window.handleWorkspaceAdded(id),
        .workspace_removed => |id| boxed.window.handleWorkspaceRemoved(id),
        .workspace_selected => |id| boxed.window.handleWorkspaceSelected(id),
        .workspace_reordered => boxed.window.handleWorkspaceReordered(),
        .workspace_updated => |id| boxed.window.handleWorkspaceUpdated(id),
        .workspace_remote_state_changed => |id| boxed.window.handleWorkspaceUpdated(id),
        .panel_added => {},
        .panel_removed => {},
    }

    return 0; // G_SOURCE_REMOVE
}
