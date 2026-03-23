// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
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

    const widget: *gtk.Widget = @ptrCast(@alignCast(web_view));

    // Inject error collection script and connect dialog signal
    injectErrorCollection(widget);
    connectDialogSignal(widget);
    setupDownloadTracking(widget);

    return widget;
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
        // Free the JSCValue to prevent memory leak
        c.g_object_unref(@ptrCast(jsc_value));
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

// === Cookie Manager (native WebKitGTK API, not JS workaround) ===

/// Get all cookies via native WebKitCookieManager. Async — writes result to fd.
pub fn getAllCookies(widget: *gtk.Widget, alloc: std.mem.Allocator, client_fd: std.posix.fd_t) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    const session = c.webkit_web_view_get_network_session(web_view);
    if (session == null) {
        const Server = @import("../socket/server.zig").Server;
        Server.respond(client_fd, "error: no network session");
        return;
    }
    const cookie_mgr = c.webkit_network_session_get_cookie_manager(session);
    if (cookie_mgr == null) {
        const Server = @import("../socket/server.zig").Server;
        Server.respond(client_fd, "error: no cookie manager");
        return;
    }

    const ctx = alloc.create(EvalContext) catch return;
    ctx.* = .{ .alloc = alloc, .fd = client_fd };

    c.webkit_cookie_manager_get_all_cookies(
        cookie_mgr,
        null, // cancellable
        &cookieGetCallback,
        @ptrCast(ctx),
    );
}

fn cookieGetCallback(
    source_object: ?*c.GObject,
    result: ?*c.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const ctx: *EvalContext = @ptrCast(@alignCast(user_data orelse return));
    defer ctx.alloc.destroy(ctx);

    const Server = @import("../socket/server.zig").Server;

    var err: ?*c.GError = null;
    const cookie_list = c.webkit_cookie_manager_get_all_cookies_finish(
        @ptrCast(@alignCast(source_object)),
        result,
        &err,
    );

    if (err) |e| {
        Server.respond(ctx.fd, "error: get cookies failed");
        c.g_error_free(e);
        return;
    }

    // Serialize cookie list to JSON
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    buf[0] = '[';
    len = 1;

    var count: usize = 0;
    var node: ?*c.GList = cookie_list;
    while (node) |n| {
        const cookie: *c.SoupCookie = @ptrCast(@alignCast(n.data));
        if (count > 0 and len < buf.len - 1) {
            buf[len] = ',';
            len += 1;
        }
        const name_c = c.soup_cookie_get_name(cookie);
        const value_c = c.soup_cookie_get_value(cookie);
        const domain_c = c.soup_cookie_get_domain(cookie);
        const path_c = c.soup_cookie_get_path(cookie);
        const http_only = c.soup_cookie_get_http_only(cookie);
        const secure = c.soup_cookie_get_secure(cookie);

        const name = if (name_c != null) std.mem.span(name_c) else "";
        const value = if (value_c != null) std.mem.span(value_c) else "";
        const domain = if (domain_c != null) std.mem.span(domain_c) else "";
        const path = if (path_c != null) std.mem.span(path_c) else "";

        const written = std.fmt.bufPrint(buf[len..], "{{\"name\":\"{s}\",\"value\":\"{s}\",\"domain\":\"{s}\",\"path\":\"{s}\",\"httpOnly\":{s},\"secure\":{s}}}", .{
            name,  value,  domain, path,
            if (http_only != 0) "true" else "false",
            if (secure != 0) "true" else "false",
        }) catch break;
        len += written.len;
        count += 1;
        node = n.next;
    }

    if (len < buf.len - 1) {
        buf[len] = ']';
        len += 1;
    }

    Server.respond(ctx.fd, buf[0..len]);

    if (cookie_list != null) {
        // Free the cookie list
        var free_node: ?*c.GList = cookie_list;
        while (free_node) |fn_node| {
            c.soup_cookie_free(@ptrCast(@alignCast(fn_node.data)));
            free_node = fn_node.next;
        }
        c.g_list_free(cookie_list);
    }
}

/// Add a cookie via native API.
pub fn addCookie(
    widget: *gtk.Widget,
    name: [*:0]const u8,
    value: [*:0]const u8,
    domain: [*:0]const u8,
    path: [*:0]const u8,
    alloc: std.mem.Allocator,
    client_fd: std.posix.fd_t,
) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    const session = c.webkit_web_view_get_network_session(web_view) orelse return;
    const cookie_mgr = c.webkit_network_session_get_cookie_manager(session) orelse return;

    const cookie = c.soup_cookie_new(name, value, domain, path, -1); // -1 = session cookie
    if (cookie == null) return;

    const ctx = alloc.create(EvalContext) catch return;
    ctx.* = .{ .alloc = alloc, .fd = client_fd };

    c.webkit_cookie_manager_add_cookie(
        cookie_mgr,
        cookie,
        null,
        &cookieAddCallback,
        @ptrCast(ctx),
    );
}

fn cookieAddCallback(
    source_object: ?*c.GObject,
    result: ?*c.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const ctx: *EvalContext = @ptrCast(@alignCast(user_data orelse return));
    defer ctx.alloc.destroy(ctx);

    const Server = @import("../socket/server.zig").Server;
    var err: ?*c.GError = null;
    _ = c.webkit_cookie_manager_add_cookie_finish(
        @ptrCast(@alignCast(source_object)),
        result,
        &err,
    );

    if (err) |e| {
        Server.respond(ctx.fd, "error: add cookie failed");
        c.g_error_free(e);
    } else {
        Server.respond(ctx.fd, "ok");
    }
}

/// Clear all cookies by replacing with empty list.
pub fn clearCookies(widget: *gtk.Widget, alloc: std.mem.Allocator, client_fd: std.posix.fd_t) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    const session = c.webkit_web_view_get_network_session(web_view) orelse return;
    const cookie_mgr = c.webkit_network_session_get_cookie_manager(session) orelse return;

    const ctx = alloc.create(EvalContext) catch return;
    ctx.* = .{ .alloc = alloc, .fd = client_fd };

    c.webkit_cookie_manager_replace_cookies(
        cookie_mgr,
        null, // empty list = clear all
        null,
        &cookieClearCallback,
        @ptrCast(ctx),
    );
}

fn cookieClearCallback(
    source_object: ?*c.GObject,
    result: ?*c.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const ctx: *EvalContext = @ptrCast(@alignCast(user_data orelse return));
    defer ctx.alloc.destroy(ctx);
    const Server = @import("../socket/server.zig").Server;
    var err: ?*c.GError = null;
    _ = c.webkit_cookie_manager_replace_cookies_finish(
        @ptrCast(@alignCast(source_object)),
        result,
        &err,
    );
    if (err) |e| {
        Server.respond(ctx.fd, "error: clear cookies failed");
        c.g_error_free(e);
    } else {
        Server.respond(ctx.fd, "cleared");
    }
}

// === Geolocation (native WebKitGeolocationManager API) ===

/// Set a fake geolocation position.
pub fn setGeolocation(widget: *gtk.Widget, latitude: f64, longitude: f64) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    const session = c.webkit_web_view_get_network_session(web_view) orelse return;
    // Get geolocation manager from the web context
    _ = session;
    // WebKitGeolocationManager is accessed via WebKitWebContext, not session
    const context = c.webkit_web_view_get_context(web_view);
    if (context == null) return;
    const geo_mgr = c.webkit_web_context_get_geolocation_manager(context);
    if (geo_mgr == null) return;

    const position = c.webkit_geolocation_position_new(latitude, longitude, 100.0); // 100m accuracy
    if (position == null) return;
    defer c.webkit_geolocation_position_free(position);

    c.webkit_geolocation_manager_update_position(geo_mgr, position);
    log.info("geolocation set to ({d}, {d})", .{ latitude, longitude });
}

// === Network/Offline (native WebKitNetworkProxySettings API) ===

/// Set offline mode by configuring proxy to block all requests.
pub fn setOffline(widget: *gtk.Widget, offline: bool) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    const session = c.webkit_web_view_get_network_session(web_view) orelse return;

    if (offline) {
        // Set proxy to a non-existent proxy to simulate offline
        c.webkit_network_session_set_proxy_settings(
            session,
            c.WEBKIT_NETWORK_PROXY_MODE_CUSTOM,
            null, // null settings with CUSTOM mode = no connection
        );
    } else {
        // Restore default proxy
        c.webkit_network_session_set_proxy_settings(
            session,
            c.WEBKIT_NETWORK_PROXY_MODE_DEFAULT,
            null,
        );
    }
    log.info("offline mode: {}", .{offline});
}

// === Script Dialogs (native WebKitScriptDialog API) ===

/// State for pending dialog responses.
var pending_dialog_action: enum { none, accept, dismiss } = .none;
var pending_dialog: ?*c.WebKitScriptDialog = null;

/// Connect the script-dialog signal on a web view.
pub fn connectDialogSignal(widget: *gtk.Widget) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    _ = c.g_signal_connect_data(
        @ptrCast(web_view),
        "script-dialog",
        @ptrCast(&onScriptDialog),
        null,
        null,
        0,
    );
}

fn onScriptDialog(
    _: *c.WebKitWebView,
    dialog: *c.WebKitScriptDialog,
    _: ?*anyopaque,
) callconv(.c) c_int {
    // Store the dialog reference for accept/dismiss commands
    pending_dialog = c.webkit_script_dialog_ref(dialog);

    // If there's a pending action, apply it immediately
    switch (pending_dialog_action) {
        .accept => {
            c.webkit_script_dialog_confirm_set_confirmed(dialog, 1);
            c.webkit_script_dialog_close(dialog);
            pending_dialog_action = .none;
        },
        .dismiss => {
            c.webkit_script_dialog_confirm_set_confirmed(dialog, 0);
            c.webkit_script_dialog_close(dialog);
            pending_dialog_action = .none;
        },
        .none => {},
    }

    return 1; // Handled
}

/// Accept the next dialog.
pub fn acceptDialog() void {
    if (pending_dialog) |dialog| {
        c.webkit_script_dialog_confirm_set_confirmed(dialog, 1);
        c.webkit_script_dialog_close(dialog);
        c.webkit_script_dialog_unref(dialog);
        pending_dialog = null;
    } else {
        pending_dialog_action = .accept;
    }
}

/// Dismiss the next dialog.
pub fn dismissDialog() void {
    if (pending_dialog) |dialog| {
        c.webkit_script_dialog_confirm_set_confirmed(dialog, 0);
        c.webkit_script_dialog_close(dialog);
        c.webkit_script_dialog_unref(dialog);
        pending_dialog = null;
    } else {
        pending_dialog_action = .dismiss;
    }
}

// === Downloads (native WebKitDownload API) ===

/// State for tracking the current download.
var download_complete: bool = false;
var download_path: ?[*:0]const u8 = null;

/// Wait for the next download to complete. Connects to download-started signal.
pub fn setupDownloadTracking(widget: *gtk.Widget) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    _ = c.g_signal_connect_data(
        @ptrCast(web_view),
        "download-started",
        @ptrCast(&onDownloadStarted),
        null,
        null,
        0,
    );
}

fn onDownloadStarted(
    _: *c.WebKitWebView,
    download: *c.WebKitDownload,
    _: ?*anyopaque,
) callconv(.c) void {
    download_complete = false;
    _ = c.g_signal_connect_data(
        @ptrCast(download),
        "finished",
        @ptrCast(&onDownloadFinished),
        null,
        null,
        0,
    );
}

fn onDownloadFinished(
    download: *c.WebKitDownload,
    _: ?*anyopaque,
) callconv(.c) void {
    download_path = c.webkit_download_get_destination(download);
    download_complete = true;
    log.info("download completed", .{});
}

/// Check if the last download completed.
pub fn isDownloadComplete() bool {
    return download_complete;
}

/// Inject error collection script into the web view.
/// Captures JS errors into window.__cmux_errors for browser.errors.list.
pub fn injectErrorCollection(widget: *gtk.Widget) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    const ucm = c.webkit_web_view_get_user_content_manager(web_view);
    if (ucm == null) return;

    const script = c.webkit_user_script_new(
        "window.__cmux_errors=[];window.addEventListener('error',function(e){window.__cmux_errors.push({message:e.message,source:e.filename,line:e.lineno,col:e.colno,timestamp:Date.now()});});window.addEventListener('unhandledrejection',function(e){window.__cmux_errors.push({message:String(e.reason),source:'promise',line:0,col:0,timestamp:Date.now()});});",
        c.WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
        c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
        null, // allow list
        null, // block list
    );
    if (script) |s| {
        c.webkit_user_content_manager_add_script(ucm, s);
        c.webkit_user_script_unref(s);
        log.info("error collection script injected", .{});
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

/// Set the zoom level on a WebKitWebView.
pub fn setZoomLevel(widget: *gtk.Widget, level: f64) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    c.webkit_web_view_set_zoom_level(web_view, level);
    log.debug("zoom level set to {d:.2}", .{level});
}

/// Get the current zoom level of a WebKitWebView.
pub fn getZoomLevel(widget: *gtk.Widget) f64 {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    return c.webkit_web_view_get_zoom_level(web_view);
}

/// Show the Web Inspector (developer tools) for a WebKitWebView.
pub fn showInspector(widget: *gtk.Widget) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    // Enable developer extras in settings first
    const settings = c.webkit_web_view_get_settings(web_view);
    if (settings != null) {
        c.webkit_settings_set_enable_developer_extras(settings, 1);
    }
    const inspector = c.webkit_web_view_get_inspector(web_view);
    if (inspector != null) {
        c.webkit_web_inspector_show(inspector);
        log.info("web inspector shown", .{});
    }
}

/// Hide the Web Inspector (developer tools).
pub fn hideInspector(widget: *gtk.Widget) void {
    const web_view: *c.WebKitWebView = @ptrCast(@alignCast(widget));
    const inspector = c.webkit_web_view_get_inspector(web_view);
    if (inspector != null) {
        c.webkit_web_inspector_close(inspector);
    }
}
