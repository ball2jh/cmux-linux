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

pub const BrowserSplitResult = struct {
    workspace_id: Uuid,
    surface_id: Uuid,
};

pub const MarkdownSplitResult = struct {
    workspace_id: Uuid,
    panel_id: Uuid,
};

pub const BrowserEvalResult = struct {
    json_value: ?[*:0]const u8 = null,
    error_message: ?[]const u8 = null,
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

    // Browser operations (optional — null if browser panels not supported)
    browserOpenSplitFn: ?*const fn (ctx: *anyopaque, workspace_id: Uuid, url: ?[*:0]const u8, direction: Direction) ?BrowserSplitResult = null,
    browserNavigateFn: ?*const fn (ctx: *anyopaque, surface_id: Uuid, url: [*:0]const u8) bool = null,
    browserBackFn: ?*const fn (ctx: *anyopaque, surface_id: Uuid) bool = null,
    browserForwardFn: ?*const fn (ctx: *anyopaque, surface_id: Uuid) bool = null,
    browserReloadFn: ?*const fn (ctx: *anyopaque, surface_id: Uuid) bool = null,
    browserGetUrlFn: ?*const fn (ctx: *anyopaque, surface_id: Uuid) ?[*:0]const u8 = null,
    browserEvalFn: ?*const fn (ctx: *anyopaque, surface_id: Uuid, script: [*:0]const u8, timeout_ms: u32) BrowserEvalResult = null,

    // Markdown operations (optional)
    markdownOpenSplitFn: ?*const fn (ctx: *anyopaque, workspace_id: Uuid, path: [*:0]const u8, direction: Direction) ?MarkdownSplitResult = null,

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

    // --- Browser operations ---

    pub fn browserOpenSplit(self: WindowOps, workspace_id: Uuid, url: ?[*:0]const u8, direction: Direction) ?BrowserSplitResult {
        if (self.browserOpenSplitFn) |f| return f(self.ctx, workspace_id, url, direction);
        return null;
    }

    pub fn browserNavigate(self: WindowOps, surface_id: Uuid, url: [*:0]const u8) bool {
        if (self.browserNavigateFn) |f| return f(self.ctx, surface_id, url);
        return false;
    }

    pub fn browserBack(self: WindowOps, surface_id: Uuid) bool {
        if (self.browserBackFn) |f| return f(self.ctx, surface_id);
        return false;
    }

    pub fn browserForward(self: WindowOps, surface_id: Uuid) bool {
        if (self.browserForwardFn) |f| return f(self.ctx, surface_id);
        return false;
    }

    pub fn browserReload(self: WindowOps, surface_id: Uuid) bool {
        if (self.browserReloadFn) |f| return f(self.ctx, surface_id);
        return false;
    }

    pub fn browserGetUrl(self: WindowOps, surface_id: Uuid) ?[*:0]const u8 {
        if (self.browserGetUrlFn) |f| return f(self.ctx, surface_id);
        return null;
    }

    pub fn browserEval(self: WindowOps, surface_id: Uuid, script: [*:0]const u8, timeout_ms: u32) BrowserEvalResult {
        if (self.browserEvalFn) |f| return f(self.ctx, surface_id, script, timeout_ms);
        return .{ .error_message = "Browser eval not supported" };
    }

    // --- Markdown operations ---

    pub fn markdownOpenSplit(self: WindowOps, workspace_id: Uuid, path: [*:0]const u8, direction: Direction) ?MarkdownSplitResult {
        if (self.markdownOpenSplitFn) |f| return f(self.ctx, workspace_id, path, direction);
        return null;
    }
};
