//! Thin Zig wrapper around WebKitGTK 6.0.
//!
//! Mirrors Mac's CmuxWebView.swift — provides only the subset of WebKitGTK
//! needed for browser panel basics: navigation, state queries, JS eval,
//! and GObject signal connection.
//!
//! NOTE: WebKitGTK is not yet linked in the build system (it causes a
//! libxml2 symbol collision with the static fontconfig copy). All methods
//! are stubs that log warnings. They will be wired up when WebKitGTK
//! linking is resolved.

const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const log = std.log.scoped(.webkit);

/// Opaque handle to a WebKitWebView (stub — not yet linked).
pub const WebView = opaque {
    pub fn new() *gtk.Widget {
        log.warn("webkit stub: WebView.new() called but WebKitGTK is not linked", .{});
        // Return a placeholder label widget so callers don't crash.
        const label = gtk.Label.new("Browser panel requires WebKitGTK");
        return label.as(gtk.Widget);
    }

    pub fn loadUri(_: *WebView, _: [*:0]const u8) void {}
    pub fn goBack(_: *WebView) void {}
    pub fn goForward(_: *WebView) void {}
    pub fn reload(_: *WebView) void {}
    pub fn stopLoading(_: *WebView) void {}
    pub fn canGoBack(_: *WebView) bool { return false; }
    pub fn canGoForward(_: *WebView) bool { return false; }
    pub fn getUri(_: *WebView) ?[*:0]const u8 { return null; }
    pub fn getTitle(_: *WebView) ?[*:0]const u8 { return null; }
    pub fn isLoading(_: *WebView) bool { return false; }
    pub fn getEstimatedLoadProgress(_: *WebView) f64 { return 0.0; }
    pub fn getFavicon(_: *WebView) ?*anyopaque { return null; }

    pub fn evaluateJavascript(
        _: *WebView,
        _: [*:0]const u8,
        _: isize,
        _: ?*anyopaque,
        _: ?*const anyopaque,
        _: ?*anyopaque,
    ) void {}

    pub fn evaluateJavascriptFinish(_: *WebView, _: *anyopaque) ?*anyopaque {
        return null;
    }

    pub fn asGObject(self: *WebView) *gobject.Object {
        return @ptrCast(@alignCast(self));
    }

    pub fn loadHtml(_: *WebView, _: [*:0]const u8, _: ?[*:0]const u8) void {}
    pub fn setVexpand(_: *WebView, _: c_int) void {}
    pub fn setHexpand(_: *WebView, _: c_int) void {}

    pub fn asWidget(self: *WebView) *gtk.Widget {
        return @ptrCast(@alignCast(self));
    }
};

pub fn fromWidget(widget: *gtk.Widget) *WebView {
    return @ptrCast(@alignCast(widget));
}

// --- JSC Value helpers (stubs) ---

pub fn jscValueToString(_: *anyopaque) ?[*:0]u8 { return null; }
pub fn gFree(_: ?*anyopaque) void {}

pub const NotifyCallback = *const fn (
    instance: *anyopaque,
    pspec: *anyopaque,
    user_data: ?*anyopaque,
) callconv(.c) void;

pub fn connectNotify(
    _: *anyopaque,
    _: [*:0]const u8,
    _: NotifyCallback,
    _: ?*anyopaque,
) void {}

pub const AsyncReadyCallback = ?*const anyopaque;

pub fn jscValueIsString(_: *anyopaque) bool { return false; }
pub fn jscValueIsNumber(_: *anyopaque) bool { return false; }
pub fn jscValueIsBoolean(_: *anyopaque) bool { return false; }
pub fn jscValueIsNull(_: *anyopaque) bool { return true; }
pub fn jscValueIsUndefined(_: *anyopaque) bool { return true; }
pub fn jscValueToJson(_: *anyopaque, _: c_uint) ?[*:0]u8 { return null; }

pub const GMainLoop = opaque {
    pub fn new() *GMainLoop { unreachable; }
    pub fn run(_: *GMainLoop) void {}
    pub fn quit(_: *GMainLoop) void {}
    pub fn unref(_: *GMainLoop) void {}
};

pub fn timeoutAdd(_: c_uint, _: *const fn (?*anyopaque) callconv(.c) c_int, _: ?*anyopaque) c_uint {
    return 0;
}
