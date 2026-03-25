//! Thin Zig wrapper around WebKitGTK 6.0 C API.
//!
//! Mirrors Mac's CmuxWebView.swift — provides only the subset of WebKitGTK
//! needed for browser panel basics: navigation, state queries, JS eval,
//! and GObject signal connection.

const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const c = @cImport({
    @cInclude("webkit/webkit.h");
});

/// Opaque handle to a WebKitWebView.
pub const WebView = opaque {
    /// Create a new WebKitWebView. Returns a GTK widget that can be
    /// added to any container.
    pub fn new() *gtk.Widget {
        return @ptrCast(@alignCast(c.webkit_web_view_new()));
    }

    fn ptr(self: *WebView) *c.WebKitWebView {
        return @ptrCast(@alignCast(self));
    }

    /// Load the given URI.
    pub fn loadUri(self: *WebView, uri: [*:0]const u8) void {
        c.webkit_web_view_load_uri(self.ptr(), uri);
    }

    /// Navigate back in history.
    pub fn goBack(self: *WebView) void {
        c.webkit_web_view_go_back(self.ptr());
    }

    /// Navigate forward in history.
    pub fn goForward(self: *WebView) void {
        c.webkit_web_view_go_forward(self.ptr());
    }

    /// Reload the current page.
    pub fn reload(self: *WebView) void {
        c.webkit_web_view_reload(self.ptr());
    }

    /// Stop the current page load.
    pub fn stopLoading(self: *WebView) void {
        c.webkit_web_view_stop_loading(self.ptr());
    }

    /// Whether the web view can navigate back.
    pub fn canGoBack(self: *WebView) bool {
        return c.webkit_web_view_can_go_back(self.ptr()) != 0;
    }

    /// Whether the web view can navigate forward.
    pub fn canGoForward(self: *WebView) bool {
        return c.webkit_web_view_can_go_forward(self.ptr()) != 0;
    }

    /// Get the current page URI. May be null before any navigation.
    pub fn getUri(self: *WebView) ?[*:0]const u8 {
        return c.webkit_web_view_get_uri(self.ptr());
    }

    /// Get the current page title. May be null.
    pub fn getTitle(self: *WebView) ?[*:0]const u8 {
        return c.webkit_web_view_get_title(self.ptr());
    }

    /// Whether the web view is currently loading a page.
    pub fn isLoading(self: *WebView) bool {
        return c.webkit_web_view_is_loading(self.ptr()) != 0;
    }

    /// Estimated load progress, 0.0 to 1.0.
    pub fn getEstimatedLoadProgress(self: *WebView) f64 {
        return c.webkit_web_view_get_estimated_load_progress(self.ptr());
    }

    /// Get the favicon as a GdkTexture (opaque pointer). May be null.
    pub fn getFavicon(self: *WebView) ?*anyopaque {
        return c.webkit_web_view_get_favicon(self.ptr());
    }

    /// Asynchronously evaluate JavaScript. The callback fires on the
    /// GLib main loop when execution completes.
    pub fn evaluateJavascript(
        self: *WebView,
        script: [*:0]const u8,
        length: isize,
        cancellable: ?*anyopaque,
        callback: c.GAsyncReadyCallback,
        user_data: ?*anyopaque,
    ) void {
        _ = cancellable;
        c.webkit_web_view_evaluate_javascript(
            self.ptr(),
            script,
            length,
            null, // world_name
            null, // source_uri
            null, // cancellable
            callback,
            user_data,
        );
    }

    /// Finish an async JS evaluation. Returns the JSCValue result or null on error.
    pub fn evaluateJavascriptFinish(self: *WebView, result: *anyopaque) ?*anyopaque {
        var err: ?*c.GError = null;
        const jsc_value = c.webkit_web_view_evaluate_javascript_finish(
            self.ptr(),
            @ptrCast(result),
            &err,
        );
        if (err) |e| {
            c.g_error_free(e);
            return null;
        }
        return @ptrCast(jsc_value);
    }

    /// Cast this WebView to a GObject for signal connections.
    pub fn asGObject(self: *WebView) *gobject.Object {
        return @ptrCast(@alignCast(self));
    }

    /// Load HTML content directly (no network fetch).
    pub fn loadHtml(self: *WebView, html: [*:0]const u8, base_uri: ?[*:0]const u8) void {
        c.webkit_web_view_load_html(self.ptr(), html, base_uri);
    }

    /// Set vertical expand on the underlying widget.
    pub fn setVexpand(self: *WebView, expand: c_int) void {
        c.gtk_widget_set_vexpand(@ptrCast(@alignCast(self)), expand);
    }

    /// Set horizontal expand on the underlying widget.
    pub fn setHexpand(self: *WebView, expand: c_int) void {
        c.gtk_widget_set_hexpand(@ptrCast(@alignCast(self)), expand);
    }

    /// Cast this WebView to a GTK Widget.
    pub fn asWidget(self: *WebView) *gtk.Widget {
        return @ptrCast(@alignCast(self));
    }
};

/// Cast a GTK Widget to a WebView. The widget must actually be a WebKitWebView.
pub fn fromWidget(widget: *gtk.Widget) *WebView {
    return @ptrCast(@alignCast(widget));
}

// --- JSC Value helpers ---

/// Convert a JSCValue to a string. Returns null if the value is not a string.
/// The returned string is owned by the caller and must be freed with g_free.
pub fn jscValueToString(jsc_value: *anyopaque) ?[*:0]u8 {
    const jsc: *c.JSCValue = @ptrCast(@alignCast(jsc_value));
    return c.jsc_value_to_string(jsc);
}

/// Free a string returned by jscValueToString.
pub fn gFree(ptr: ?*anyopaque) void {
    c.g_free(ptr);
}

// --- Signal connection helpers ---

/// GObject notify callback type for C interop.
pub const NotifyCallback = *const fn (
    instance: *anyopaque,
    pspec: *anyopaque,
    user_data: ?*anyopaque,
) callconv(.c) void;

/// Connect a notify signal on a GObject (e.g. "notify::title").
/// Uses C-level g_signal_connect_data since WebKitWebView isn't in zig-gobject.
pub fn connectNotify(
    instance: *anyopaque,
    signal_name: [*:0]const u8,
    callback: NotifyCallback,
    user_data: ?*anyopaque,
) void {
    _ = c.g_signal_connect_data(
        instance,
        signal_name,
        @ptrCast(callback),
        user_data,
        null,
        0,
    );
}

/// The C-level GAsyncReadyCallback type for JS eval.
pub const AsyncReadyCallback = c.GAsyncReadyCallback;

// --- JSC Value type checking ---

pub fn jscValueIsString(jsc_value: *anyopaque) bool {
    return c.jsc_value_is_string(@ptrCast(@alignCast(jsc_value))) != 0;
}

pub fn jscValueIsNumber(jsc_value: *anyopaque) bool {
    return c.jsc_value_is_number(@ptrCast(@alignCast(jsc_value))) != 0;
}

pub fn jscValueIsBoolean(jsc_value: *anyopaque) bool {
    return c.jsc_value_is_boolean(@ptrCast(@alignCast(jsc_value))) != 0;
}

pub fn jscValueIsNull(jsc_value: *anyopaque) bool {
    return c.jsc_value_is_null(@ptrCast(@alignCast(jsc_value))) != 0;
}

pub fn jscValueIsUndefined(jsc_value: *anyopaque) bool {
    return c.jsc_value_is_undefined(@ptrCast(@alignCast(jsc_value))) != 0;
}

/// Convert a JSCValue to a JSON string. Returns owned string (free with gFree).
/// The `indent` parameter controls pretty-printing (0 = compact).
pub fn jscValueToJson(jsc_value: *anyopaque, indent: c_uint) ?[*:0]u8 {
    return c.jsc_value_to_json(@ptrCast(@alignCast(jsc_value)), indent);
}

// --- GMainLoop helpers (for async-to-sync bridge) ---

pub const GMainLoop = opaque {
    pub fn new() *GMainLoop {
        return @ptrCast(@alignCast(c.g_main_loop_new(null, 0)));
    }

    pub fn run(self: *GMainLoop) void {
        c.g_main_loop_run(@ptrCast(@alignCast(self)));
    }

    pub fn quit(self: *GMainLoop) void {
        c.g_main_loop_quit(@ptrCast(@alignCast(self)));
    }

    pub fn unref(self: *GMainLoop) void {
        c.g_main_loop_unref(@ptrCast(@alignCast(self)));
    }
};

/// Schedule a one-shot timeout on the GLib main loop (milliseconds).
/// Returns the source ID.
pub fn timeoutAdd(interval_ms: c_uint, callback: *const fn (?*anyopaque) callconv(.c) c_int, user_data: ?*anyopaque) c_uint {
    return c.g_timeout_add(interval_ms, @ptrCast(callback), user_data);
}
