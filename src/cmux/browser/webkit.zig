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

/// Context for async JS evaluation results.
const EvalContext = struct {
    result: ?[]u8 = null,
    done: bool = false,
    alloc: std.mem.Allocator,
    fd: std.posix.fd_t,
};

/// Evaluate JavaScript in the web view. Writes the result to client_fd asynchronously.
pub fn evaluateJavaScript(
    widget: *gtk.Widget,
    script: [*:0]const u8,
    alloc: std.mem.Allocator,
    client_fd: std.posix.fd_t,
) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));

    // Allocate context for the async callback
    const ctx = alloc.create(EvalContext) catch {
        const Server = @import("../socket/server.zig").Server;
        Server.respond(client_fd, "error: alloc failed");
        return;
    };
    ctx.* = .{ .alloc = alloc, .fd = client_fd };

    c.webkit_web_view_evaluate_javascript(
        web_view,
        script,
        -1, // length (-1 = null-terminated)
        null, // world_name
        null, // source_uri
        null, // cancellable
        &evalCallback,
        @ptrCast(ctx),
    );

    log.info("JS evaluation started", .{});
}

/// Async callback for JS evaluation result.
fn evalCallback(
    source_object: ?*c.GObject,
    result: ?*c.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const ctx: *EvalContext = @ptrCast(@alignCast(user_data orelse return));
    defer ctx.alloc.destroy(ctx);

    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(source_object orelse return));
    _ = web_view;

    var err: ?*c.GError = null;
    const js_result = c.webkit_web_view_evaluate_javascript_finish(
        @ptrCast(@alignCast(source_object)),
        result,
        &err,
    );

    const Server = @import("../socket/server.zig").Server;

    if (err) |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: {s}", .{std.mem.span(e.message)}) catch "error: js eval failed";
        Server.respond(ctx.fd, msg);
        c.g_error_free(e);
        return;
    }

    if (js_result) |jsc_value| {
        // Convert JSCValue to string
        const str = c.jsc_value_to_string(jsc_value);
        if (str) |s| {
            Server.respond(ctx.fd, std.mem.span(s));
            c.g_free(@ptrCast(@constCast(s)));
        } else {
            Server.respond(ctx.fd, "null");
        }
    } else {
        Server.respond(ctx.fd, "null");
    }
}

/// Take a screenshot of the web view. Returns PNG data path.
pub fn getSnapshot(
    widget: *gtk.Widget,
    alloc: std.mem.Allocator,
    client_fd: std.posix.fd_t,
) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));

    const ctx = alloc.create(EvalContext) catch {
        const Server = @import("../socket/server.zig").Server;
        Server.respond(client_fd, "error: alloc failed");
        return;
    };
    ctx.* = .{ .alloc = alloc, .fd = client_fd };

    c.webkit_web_view_get_snapshot(
        web_view,
        c.WEBKIT_SNAPSHOT_REGION_VISIBLE,
        c.WEBKIT_SNAPSHOT_OPTIONS_NONE,
        null, // cancellable
        &snapshotCallback,
        @ptrCast(ctx),
    );

    log.info("screenshot started", .{});
}

fn snapshotCallback(
    source_object: ?*c.GObject,
    result: ?*c.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const ctx: *EvalContext = @ptrCast(@alignCast(user_data orelse return));
    defer ctx.alloc.destroy(ctx);

    const Server = @import("../socket/server.zig").Server;

    var err: ?*c.GError = null;
    const texture = c.webkit_web_view_get_snapshot_finish(
        @ptrCast(@alignCast(source_object)),
        result,
        &err,
    );

    if (err) |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: {s}", .{std.mem.span(e.message)}) catch "error: snapshot failed";
        Server.respond(ctx.fd, msg);
        c.g_error_free(e);
        return;
    }

    if (texture) |tex| {
        // Save texture to a temp file as PNG
        const path = "/tmp/cmux-screenshot.png";
        const saved = c.gdk_texture_save_to_png(tex, path);
        if (saved != 0) {
            Server.respond(ctx.fd, path);
        } else {
            Server.respond(ctx.fd, "error: save failed");
        }
        c.g_object_unref(@ptrCast(tex));
    } else {
        Server.respond(ctx.fd, "error: no texture");
    }
}

/// Get the page source HTML via JavaScript.
pub fn getPageSource(
    widget: *gtk.Widget,
    alloc: std.mem.Allocator,
    client_fd: std.posix.fd_t,
) void {
    evaluateJavaScript(widget, "document.documentElement.outerHTML", alloc, client_fd);
}
