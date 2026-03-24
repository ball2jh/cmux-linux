//! Callback interface for window/surface operations.
//!
//! The socket Server needs to trigger GTK-layer operations (splits, surface
//! close, focus) but must not depend on GTK types. This module defines the
//! callback vtable that the GTK window layer implements and registers on
//! the Server.
//!
//! Note: Direction is intentionally separate from Surface.Tree.Split.Direction
//! to keep the cmux protocol layer decoupled from Ghostty data structures.

const std = @import("std");
const Uuid = @import("uuid.zig").Uuid;

pub const Direction = enum {
    left,
    right,
    up,
    down,

    pub fn parse(s: []const u8) ?Direction {
        if (std.mem.eql(u8, s, "left")) return .left;
        if (std.mem.eql(u8, s, "right")) return .right;
        if (std.mem.eql(u8, s, "up")) return .up;
        if (std.mem.eql(u8, s, "down")) return .down;
        return null;
    }
};

pub const SurfaceInfo = struct {
    id: Uuid,
    title: []const u8 = "",
    pwd: []const u8 = "",
    focused: bool = false,
    panel_type: []const u8 = "terminal",
};

pub const SplitResult = struct {
    surface_id: Uuid,
};

pub const SurfaceInfoList = std.ArrayListUnmanaged(SurfaceInfo);

pub const WindowOps = struct {
    ctx: *anyopaque,

    /// Return surfaces for workspace. Caller provides unmanaged ArrayList + allocator.
    listSurfacesFn: *const fn (ctx: *anyopaque, workspace_id: Uuid, alloc: std.mem.Allocator, out: *SurfaceInfoList) void,
    currentSurfaceFn: *const fn (ctx: *anyopaque, workspace_id: Uuid) ?SurfaceInfo,
    splitFn: *const fn (ctx: *anyopaque, workspace_id: Uuid, direction: Direction) ?SplitResult,
    /// Close a surface. If surface_id is null, close the focused surface.
    closeSurfaceFn: *const fn (ctx: *anyopaque, workspace_id: Uuid, surface_id: ?Uuid) ?Uuid,
    focusSurfaceFn: *const fn (ctx: *anyopaque, workspace_id: Uuid, surface_id: Uuid) bool,
    readScrollbackFn: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, surface_id: Uuid) ?[]const u8 = null,

    pub fn listSurfaces(self: WindowOps, workspace_id: Uuid, alloc: std.mem.Allocator, out: *SurfaceInfoList) void {
        self.listSurfacesFn(self.ctx, workspace_id, alloc, out);
    }

    pub fn currentSurface(self: WindowOps, workspace_id: Uuid) ?SurfaceInfo {
        return self.currentSurfaceFn(self.ctx, workspace_id);
    }

    pub fn split(self: WindowOps, workspace_id: Uuid, direction: Direction) ?SplitResult {
        return self.splitFn(self.ctx, workspace_id, direction);
    }

    /// Returns the UUID of the closed surface, or null on failure.
    pub fn closeSurface(self: WindowOps, workspace_id: Uuid, surface_id: ?Uuid) ?Uuid {
        return self.closeSurfaceFn(self.ctx, workspace_id, surface_id);
    }

    pub fn focusSurface(self: WindowOps, workspace_id: Uuid, surface_id: Uuid) bool {
        return self.focusSurfaceFn(self.ctx, workspace_id, surface_id);
    }

    /// Read the full scrollback text for a terminal surface.
    /// Returns owned slice (caller frees) or null if unavailable.
    pub fn readScrollback(self: WindowOps, alloc: std.mem.Allocator, surface_id: Uuid) ?[]const u8 {
        if (self.readScrollbackFn) |f| return f(self.ctx, alloc, surface_id);
        return null;
    }
};
