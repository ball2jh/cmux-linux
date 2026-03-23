// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2025 cmux-linux contributors
//
// WebKitGTK integration for cmux browser panel.
// Uses C interop to create and manage WebKitWebView widgets.

const std = @import("std");
const gtk = @import("gtk");
const gobject = @import("gobject");

const log = std.log.scoped(.cmux_webkit);

// C bindings for WebKitGTK via pkg-config (linked in SharedDeps.zig)
const c = @cImport({
    @cInclude("webkit/webkit.h");
});

/// Create a new WebKitWebView as a GTK widget.
/// Returns the widget pointer that can be added to a GTK container.
pub fn createWebView() ?*gtk.Widget {
    const web_view = c.webkit_web_view_new();
    if (web_view == null) {
        log.err("failed to create WebKitWebView", .{});
        return null;
    }
    log.info("WebKitWebView created", .{});
    return @ptrCast(@alignCast(web_view));
}

/// Load a URL in a WebKitWebView.
pub fn loadUri(widget: *gtk.Widget, url: [*:0]const u8) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    c.webkit_web_view_load_uri(web_view, url);
    log.info("navigating to {s}", .{std.mem.span(url)});
}

/// Get the current URI from a WebKitWebView.
pub fn getUri(widget: *gtk.Widget) ?[*:0]const u8 {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    const uri = c.webkit_web_view_get_uri(web_view);
    if (uri == null) return null;
    return uri;
}

/// Get the page title from a WebKitWebView.
pub fn getTitle(widget: *gtk.Widget) ?[*:0]const u8 {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    const title = c.webkit_web_view_get_title(web_view);
    if (title == null) return null;
    return title;
}

/// Navigate back.
pub fn goBack(widget: *gtk.Widget) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    c.webkit_web_view_go_back(web_view);
}

/// Navigate forward.
pub fn goForward(widget: *gtk.Widget) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    c.webkit_web_view_go_forward(web_view);
}

/// Reload the page.
pub fn reload(widget: *gtk.Widget) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    c.webkit_web_view_reload(web_view);
}
