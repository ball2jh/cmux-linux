//! Markdown panel GTK widget — mirrors Mac's MarkdownPanelView.swift.
//!
//! Renders a markdown file as styled HTML in a WebKitGTK WebView.
//! Watches the file for changes via inotify and live-reloads on edit.
//! Shows a "File unavailable" state when the file is missing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const cmux = @import("../main.zig");
const webkit = @import("webkit.zig");
const markdown_html = @import("../markdown_html.zig");

const log = std.log.scoped(.markdown_panel_view);

pub const MarkdownPanelView = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "CmuxMarkdownPanelView",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        panel_id: cmux.Uuid = cmux.Uuid.nil,
        workspace_id: cmux.Uuid = cmux.Uuid.nil,
        webview: ?*webkit.WebView = null,
        file_path_label: ?*gtk.Label = null,
        content_stack: ?*gtk.Stack = null,
        is_dark: bool = false,
        allocator: Allocator = std.heap.c_allocator,

        // inotify file watching
        inotify_fd: std.posix.fd_t = -1,
        watch_descriptor: i32 = -1,
        inotify_source_id: c_uint = 0,

        // File path (null-terminated copy)
        file_path: ?[:0]const u8 = null,

        pub var offset: c_int = 0;
    };

    const C = @import("../../apprt/gtk/class.zig").Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    // -----------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------

    pub fn new(
        panel_id: cmux.Uuid,
        workspace_id: cmux.Uuid,
        file_path: [*:0]const u8,
    ) *Self {
        const self: *Self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.panel_id = panel_id;
        priv.workspace_id = workspace_id;

        // Store file path
        const path_slice = std.mem.span(file_path);
        priv.file_path = priv.allocator.dupeZ(u8, path_slice) catch null;

        // Set the breadcrumb label
        if (priv.file_path_label) |label| {
            label.setText(file_path);
        }

        // Detect dark mode
        const style_manager = adw.StyleManager.getDefault();
        priv.is_dark = style_manager.getDark() != 0;

        // Load initial content
        self.loadContent();

        // Start file watcher
        self.startFileWatcher();

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();

        self.as(gtk.Orientable).setOrientation(.vertical);

        // --- Breadcrumb header ---
        const header = gtk.Box.new(.horizontal, 6);
        header.as(gtk.Widget).setMarginStart(16);
        header.as(gtk.Widget).setMarginEnd(16);
        header.as(gtk.Widget).setMarginTop(6);
        header.as(gtk.Widget).setMarginBottom(6);

        const doc_icon = gtk.Image.newFromIconName("text-x-generic-symbolic");
        doc_icon.setPixelSize(12);
        doc_icon.as(gtk.Widget).addCssClass("dim-label");
        header.append(doc_icon.as(gtk.Widget));

        const path_label = gtk.Label.new("");
        path_label.setEllipsize(.middle);
        path_label.as(gtk.Widget).setHexpand(1);
        path_label.setXalign(0);
        path_label.as(gtk.Widget).addCssClass("dim-label");
        path_label.as(gtk.Widget).addCssClass("caption");
        header.append(path_label.as(gtk.Widget));
        priv.file_path_label = path_label;

        self.as(gtk.Box).append(header.as(gtk.Widget));

        // --- Separator ---
        const sep = gtk.Separator.new(.horizontal);
        self.as(gtk.Box).append(sep.as(gtk.Widget));

        // --- Content stack ---
        const content_stack = gtk.Stack.new();
        content_stack.as(gtk.Widget).setVexpand(1);
        content_stack.as(gtk.Widget).setHexpand(1);
        content_stack.setTransitionType(.crossfade);
        priv.content_stack = content_stack;

        // "content" page: WebView
        const webview_widget = webkit.WebView.new();
        const wv = webkit.fromWidget(webview_widget);
        wv.setVexpand(1);
        wv.setHexpand(1);
        priv.webview = wv;
        _ = content_stack.addNamed(webview_widget, "content");

        // "unavailable" page: centered message
        const unavail_box = gtk.Box.new(.vertical, 8);
        unavail_box.as(gtk.Widget).setValign(.center);
        unavail_box.as(gtk.Widget).setHalign(.center);
        unavail_box.as(gtk.Widget).setVexpand(1);

        const q_icon = gtk.Image.newFromIconName("dialog-question-symbolic");
        q_icon.setPixelSize(40);
        q_icon.as(gtk.Widget).addCssClass("dim-label");
        unavail_box.append(q_icon.as(gtk.Widget));

        const unavail_title = gtk.Label.new("File unavailable");
        unavail_title.as(gtk.Widget).addCssClass("title-3");
        unavail_box.append(unavail_title.as(gtk.Widget));

        const unavail_path = gtk.Label.new("");
        unavail_path.as(gtk.Widget).addCssClass("dim-label");
        unavail_path.as(gtk.Widget).addCssClass("caption");
        unavail_box.append(unavail_path.as(gtk.Widget));

        const unavail_desc = gtk.Label.new("The file may have been moved or deleted.");
        unavail_desc.as(gtk.Widget).addCssClass("dim-label");
        unavail_desc.as(gtk.Widget).addCssClass("caption");
        unavail_box.append(unavail_desc.as(gtk.Widget));

        _ = content_stack.addNamed(unavail_box.as(gtk.Widget), "unavailable");

        self.as(gtk.Box).append(content_stack.as(gtk.Widget));
        content_stack.setVisibleChildName("content");
    }

    // -----------------------------------------------------------------
    // Content loading
    // -----------------------------------------------------------------

    fn loadContent(self: *Self) void {
        const priv = self.private();
        const wv = priv.webview orelse return;
        const file_path = priv.file_path orelse return;
        const content_stack = priv.content_stack orelse return;

        // Read file
        const content = std.fs.cwd().readFileAlloc(priv.allocator, file_path, 4 * 1024 * 1024) catch {
            // File not readable — show unavailable state
            content_stack.setVisibleChildName("unavailable");
            return;
        };
        defer priv.allocator.free(content);

        // Convert to HTML
        const html = markdown_html.renderToHtml(priv.allocator, content, priv.is_dark) catch {
            log.warn("failed to render markdown to HTML", .{});
            return;
        };
        defer priv.allocator.free(html);

        wv.loadHtml(html, null);
        content_stack.setVisibleChildName("content");
    }

    // -----------------------------------------------------------------
    // File watching via inotify
    // -----------------------------------------------------------------

    fn startFileWatcher(self: *Self) void {
        const priv = self.private();
        const file_path = priv.file_path orelse return;

        const linux = std.os.linux;
        const fd = std.posix.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC) catch {
            log.warn("inotify_init1 failed", .{});
            return;
        };
        priv.inotify_fd = fd;

        priv.watch_descriptor = std.posix.inotify_add_watch(
            fd,
            file_path,
            linux.IN.MODIFY | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF,
        ) catch {
            log.warn("inotify_add_watch failed", .{});
            return;
        };

        // Integrate with GLib main loop via g_unix_fd_add
        const c_import = @cImport({
            @cInclude("glib-unix.h");
        });
        priv.inotify_source_id = c_import.g_unix_fd_add(
            fd,
            1, // G_IO_IN
            &inotifyCallback,
            @ptrCast(self),
        );
    }

    fn stopFileWatcher(self: *Self) void {
        const priv = self.private();
        if (priv.inotify_source_id != 0) {
            const c_import = @cImport({
                @cInclude("glib.h");
            });
            _ = c_import.g_source_remove(priv.inotify_source_id);
            priv.inotify_source_id = 0;
        }
        if (priv.inotify_fd >= 0) {
            std.posix.close(priv.inotify_fd);
            priv.inotify_fd = -1;
            priv.watch_descriptor = -1;
        }
    }

    fn inotifyCallback(fd: c_int, _: c_uint, user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(user_data orelse return 1));
        const priv = self.private();

        // Read and consume all inotify events
        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        var file_modified = false;
        var file_gone = false;

        while (true) {
            const n = std.posix.read(fd, &buf) catch break;
            if (n == 0) break;
            var offset: usize = 0;
            while (offset < n) {
                const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(buf[offset..].ptr));
                if (event.mask & std.os.linux.IN.MODIFY != 0) file_modified = true;
                if (event.mask & (std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF) != 0) file_gone = true;
                offset += @sizeOf(std.os.linux.inotify_event) + event.len;
            }
        }

        if (file_gone) {
            if (priv.content_stack) |stack| {
                stack.setVisibleChildName("unavailable");
            }
            // Try to re-watch in case it reappears
            self.stopFileWatcher();
            // Schedule a retry after a short delay
            const c_import = @cImport({
                @cInclude("glib.h");
            });
            _ = c_import.g_timeout_add(500, &retryFileWatch, @ptrCast(self));
        } else if (file_modified) {
            self.loadContent();
        }

        return 1; // G_SOURCE_CONTINUE
    }

    fn retryFileWatch(user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(user_data orelse return 0));
        const priv = self.private();
        const file_path = priv.file_path orelse return 0;

        // Check if file exists now
        std.fs.cwd().access(file_path, .{}) catch return 0;

        // File is back — reload and re-watch
        self.loadContent();
        self.startFileWatcher();
        return 0; // G_SOURCE_REMOVE
    }

    // -----------------------------------------------------------------
    // Public API
    // -----------------------------------------------------------------

    pub fn getPanelId(self: *Self) cmux.Uuid {
        return self.private().panel_id;
    }

    pub fn getWorkspaceId(self: *Self) cmux.Uuid {
        return self.private().workspace_id;
    }

    // -----------------------------------------------------------------
    // GObject class boilerplate
    // -----------------------------------------------------------------

    pub const Class = extern struct {
        parent_class: Parent.Class,

        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        pub fn init(_: *Class) callconv(.c) void {}
    };
};
