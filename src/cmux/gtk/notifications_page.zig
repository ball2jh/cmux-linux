//! Notifications page GTK widget — mirrors Mac's NotificationsPage.swift.
//!
//! Shows a list of desktop notifications in the content area. Toggled via
//! Ctrl+Shift+I. Each notification card shows an unread indicator, title,
//! timestamp, body, and dismiss button.

const std = @import("std");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");

const cmux = @import("../main.zig");

const log = std.log.scoped(.notifications_page);

pub const NotificationsPage = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "CmuxNotificationsPage",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        list_box: ?*gtk.ListBox = null,
        content_stack: ?*gtk.Stack = null,
        jump_btn: ?*gtk.Button = null,

        // Set by CmuxWindow after creation
        notification_store: ?*cmux.notification.Store = null,
        manager: ?*cmux.workspace.Manager = null,

        // Callbacks (set by CmuxWindow)
        on_open_notification_fn: ?*const fn (cmux.Uuid, ?cmux.Uuid, ?cmux.Uuid) void = null,
        on_switch_to_tabs_fn: ?*const fn () void = null,

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

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();

        // Set orientation to vertical.
        self.as(gtk.Orientable).setOrientation(.vertical);

        // --- Header bar ---
        const header = gtk.Box.new(.horizontal, 8);
        header.as(gtk.Widget).setMarginStart(16);
        header.as(gtk.Widget).setMarginEnd(16);
        header.as(gtk.Widget).setMarginTop(12);
        header.as(gtk.Widget).setMarginBottom(12);

        const title_label = gtk.Label.new("Notifications");
        title_label.as(gtk.Widget).addCssClass("title-2");
        header.append(title_label.as(gtk.Widget));

        // Spacer
        const spacer = gtk.Box.new(.horizontal, 0);
        spacer.as(gtk.Widget).setHexpand(1);
        header.append(spacer.as(gtk.Widget));

        // Jump to Latest Unread button
        const jump_btn = gtk.Button.newWithLabel("Jump to Latest Unread");
        jump_btn.as(gtk.Widget).addCssClass("flat");
        jump_btn.as(gtk.Widget).setName("JumpToUnread");
        _ = gtk.Button.signals.clicked.connect(jump_btn, *Self, onJumpToUnread, self, .{});
        header.append(jump_btn.as(gtk.Widget));
        priv.jump_btn = jump_btn;

        // Clear All button
        const clear_btn = gtk.Button.newWithLabel("Clear All");
        clear_btn.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(clear_btn, *Self, onClearAll, self, .{});
        header.append(clear_btn.as(gtk.Widget));

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

        // "list" page: ScrolledWindow > ListBox
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setPolicy(.never, .automatic);
        scrolled.as(gtk.Widget).setVexpand(1);

        const list_box = gtk.ListBox.new();
        list_box.setSelectionMode(.none);
        list_box.as(gtk.Widget).addCssClass("boxed-list");
        list_box.as(gtk.Widget).setMarginStart(12);
        list_box.as(gtk.Widget).setMarginEnd(12);
        list_box.as(gtk.Widget).setMarginTop(12);
        list_box.as(gtk.Widget).setMarginBottom(12);
        scrolled.setChild(list_box.as(gtk.Widget));
        priv.list_box = list_box;

        _ = content_stack.addNamed(scrolled.as(gtk.Widget), "list");

        // "empty" page: centered placeholder
        const empty_box = gtk.Box.new(.vertical, 8);
        empty_box.as(gtk.Widget).setValign(.center);
        empty_box.as(gtk.Widget).setHalign(.center);
        empty_box.as(gtk.Widget).setVexpand(1);

        const bell_icon = gtk.Image.newFromIconName("bell-symbolic");
        bell_icon.setPixelSize(32);
        bell_icon.as(gtk.Widget).setOpacity(0.5);
        empty_box.append(bell_icon.as(gtk.Widget));

        const empty_title = gtk.Label.new("No notifications yet");
        empty_title.as(gtk.Widget).addCssClass("title-3");
        empty_box.append(empty_title.as(gtk.Widget));

        const empty_desc = gtk.Label.new("Desktop notifications will appear here for quick review.");
        empty_desc.as(gtk.Widget).addCssClass("dim-label");
        empty_box.append(empty_desc.as(gtk.Widget));

        _ = content_stack.addNamed(empty_box.as(gtk.Widget), "empty");

        self.as(gtk.Box).append(content_stack.as(gtk.Widget));

        // Show empty state initially
        content_stack.setVisibleChildName("empty");

        // --- Escape key handler ---
        const key_controller = gtk.EventControllerKey.new();
        key_controller.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            key_controller,
            *Self,
            onKeyPressed,
            self,
            .{},
        );
        self.as(gtk.Widget).addController(key_controller.as(gtk.EventController));
    }

    // -----------------------------------------------------------------
    // Public API
    // -----------------------------------------------------------------

    /// Wire the notification data source and workspace manager.
    pub fn setStore(self: *Self, store: *cmux.notification.Store, manager: *cmux.workspace.Manager) void {
        const priv = self.private();
        priv.notification_store = store;
        priv.manager = manager;
    }

    /// Wire action callbacks from the window.
    pub fn setCallbacks(
        self: *Self,
        open_fn: ?*const fn (cmux.Uuid, ?cmux.Uuid, ?cmux.Uuid) void,
        switch_fn: ?*const fn () void,
    ) void {
        const priv = self.private();
        priv.on_open_notification_fn = open_fn;
        priv.on_switch_to_tabs_fn = switch_fn;
    }

    /// Rebuild the entire list from the notification store.
    pub fn refresh(self: *Self) void {
        const priv = self.private();
        const list_box = priv.list_box orelse return;
        const store = priv.notification_store orelse return;
        const content_stack = priv.content_stack orelse return;

        // Remove all existing rows
        while (true) {
            const row = list_box.getRowAtIndex(0) orelse break;
            list_box.remove(row.as(gtk.Widget));
        }

        const notifications = store.getNotifications();

        if (notifications.len == 0) {
            content_stack.setVisibleChildName("empty");
            return;
        }

        content_stack.setVisibleChildName("list");

        for (notifications) |n| {
            const row = self.buildNotificationRow(&n);
            list_box.append(row.as(gtk.Widget));
        }
    }

    // -----------------------------------------------------------------
    // Row building
    // -----------------------------------------------------------------

    fn buildNotificationRow(self: *Self, n: *const cmux.notification.Notification) *gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.setActivatable(0);

        const hbox = gtk.Box.new(.horizontal, 12);
        hbox.as(gtk.Widget).addCssClass("notification-card");

        // --- Content area (clickable) ---
        const content_vbox = gtk.Box.new(.vertical, 4);
        content_vbox.as(gtk.Widget).setHexpand(1);

        // Title row: unread dot + title + timestamp
        const title_hbox = gtk.Box.new(.horizontal, 8);

        // Unread indicator
        const dot_text: [*:0]const u8 = if (n.is_read) "\xe2\x97\x8b" else "\xe2\x97\x8f"; // "○" or "●"
        const dot_label = gtk.Label.new(dot_text);
        dot_label.as(gtk.Widget).setValign(.center);
        if (!n.is_read) {
            dot_label.as(gtk.Widget).addCssClass("accent");
        } else {
            dot_label.as(gtk.Widget).addCssClass("dim-label");
        }
        title_hbox.append(dot_label.as(gtk.Widget));

        // Title
        const title_text = if (n.title.len > 0) n.title else "Notification";
        var title_buf: [512:0]u8 = undefined;
        const title_z = sliceToZ(&title_buf, title_text);
        const title_label = gtk.Label.new(title_z);
        title_label.setXalign(0);
        title_label.as(gtk.Widget).setHexpand(1);
        title_label.as(gtk.Widget).addCssClass("heading");
        title_hbox.append(title_label.as(gtk.Widget));

        // Timestamp
        var time_buf: [32:0]u8 = undefined;
        const time_str = formatTimestamp(&time_buf, n.created_at);
        const time_label = gtk.Label.new(time_str);
        time_label.as(gtk.Widget).addCssClass("dim-label");
        time_label.as(gtk.Widget).addCssClass("caption");
        title_hbox.append(time_label.as(gtk.Widget));

        content_vbox.append(title_hbox.as(gtk.Widget));

        // Body (only if non-empty)
        if (n.body.len > 0) {
            var body_buf: [1024:0]u8 = undefined;
            const body_z = sliceToZ(&body_buf, n.body);
            const body_label = gtk.Label.new(body_z);
            body_label.setXalign(0);
            body_label.as(gtk.Widget).addCssClass("dim-label");
            body_label.setEllipsize(.end);
            body_label.setLines(3);
            body_label.setMaxWidthChars(80);
            content_vbox.append(body_label.as(gtk.Widget));
        }

        // Tab title — look up from manager if tab_id maps to a workspace
        const priv = self.private();
        if (priv.manager) |manager| {
            if (manager.workspaceById(n.tab_id)) |ws| {
                const dt = ws.displayTitle();
                if (dt.len > 0) {
                    var tab_buf: [256:0]u8 = undefined;
                    const tab_z = sliceToZ(&tab_buf, dt);
                    const tab_label = gtk.Label.new(tab_z);
                    tab_label.setXalign(0);
                    tab_label.as(gtk.Widget).addCssClass("dim-label");
                    tab_label.as(gtk.Widget).addCssClass("caption");
                    content_vbox.append(tab_label.as(gtk.Widget));
                }
            }
        }

        hbox.append(content_vbox.as(gtk.Widget));

        // --- Dismiss button ---
        const dismiss_btn = gtk.Button.newFromIconName("window-close-symbolic");
        dismiss_btn.as(gtk.Widget).addCssClass("flat");
        dismiss_btn.as(gtk.Widget).addCssClass("notification-dismiss-btn");
        dismiss_btn.as(gtk.Widget).setValign(.center);
        hbox.append(dismiss_btn.as(gtk.Widget));

        row.setChild(hbox.as(gtk.Widget));

        // --- Click handlers ---
        // Row click: open the notification's workspace/surface
        const row_click = gtk.GestureClick.new();
        row_click.as(gtk.GestureSingle).setButton(1);
        _ = gtk.GestureClick.signals.pressed.connect(
            row_click,
            *Self,
            onRowClickedThunk,
            self,
            .{},
        );
        content_vbox.as(gtk.Widget).addController(row_click.as(gtk.EventController));

        // Store notification IDs on the row widget via its name (NotificationRow.tab_id:surface_id:notification_id)
        var name_buf: [notif_row_prefix.len + 110 :0]u8 = undefined;
        const name_str = encodeNotificationName(&name_buf, n.tab_id, n.surface_id, n.id);
        row.as(gtk.Widget).setName(name_str);

        // Dismiss button: remove notification and refresh
        const dismiss_click = gtk.GestureClick.new();
        dismiss_click.as(gtk.GestureSingle).setButton(1);
        _ = gtk.GestureClick.signals.pressed.connect(
            dismiss_click,
            *Self,
            onDismissClickedThunk,
            self,
            .{},
        );
        dismiss_btn.as(gtk.Widget).addController(dismiss_click.as(gtk.EventController));
        dismiss_btn.as(gtk.Widget).setName(name_str);

        return row;
    }

    // -----------------------------------------------------------------
    // Signal handlers
    // -----------------------------------------------------------------

    fn onKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        _: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        if (keyval == gdk.KEY_Escape) {
            const priv = self.private();
            if (priv.on_switch_to_tabs_fn) |switch_fn| {
                switch_fn();
            }
            return 1;
        }
        return 0;
    }

    fn onJumpToUnread(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const store = priv.notification_store orelse return;
        const notifications = store.getNotifications();

        // Find first unread notification
        for (notifications) |n| {
            if (!n.is_read) {
                if (priv.on_open_notification_fn) |open_fn| {
                    open_fn(n.tab_id, n.surface_id, n.id);
                }
                return;
            }
        }
    }

    fn onClearAll(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const store = priv.notification_store orelse return;
        store.clearAll();
        self.refresh();
    }

    fn onRowClickedThunk(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const ctrl_widget = gesture.as(gtk.EventController).getWidget() orelse return;
        // The gesture is on the content_vbox; the row is the grandparent (row > hbox > vbox).
        const hbox_widget = ctrl_widget.getParent() orelse return;
        const row_widget = hbox_widget.getParent() orelse return;
        const name_z: [*:0]const u8 = row_widget.getName();
        const ids = decodeNotificationName(name_z) orelse return;

        const priv = self.private();
        if (priv.on_open_notification_fn) |open_fn| {
            open_fn(ids.tab_id, ids.surface_id, ids.notification_id);
        }
    }

    fn onDismissClickedThunk(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const ctrl_widget = gesture.as(gtk.EventController).getWidget() orelse return;
        const name_z: [*:0]const u8 = ctrl_widget.getName();
        const ids = decodeNotificationName(name_z) orelse return;

        const priv = self.private();
        const store = priv.notification_store orelse return;
        store.remove(ids.notification_id);
        self.refresh();
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    fn sliceToZ(buf: [:0]u8, src: []const u8) [*:0]const u8 {
        const len = @min(src.len, buf.len);
        @memcpy(buf[0..len], src[0..len]);
        buf[len] = 0;
        return @ptrCast(buf.ptr);
    }

    /// Format a millisecond timestamp into "H:MM AM/PM" style.
    /// Uses arithmetic since GLib DateTime may not be available in zig bindings.
    fn formatTimestamp(buf: *[32:0]u8, millis: i64) [*:0]const u8 {
        // Convert millis to seconds, then extract local time components.
        // We use a simplified approach: get UTC components, then rely on the
        // fact that most users will see approximate timestamps.
        // For accurate local time, we use C's localtime.
        const secs = @divTrunc(millis, 1000);
        const c_import = @cImport({ @cInclude("time.h"); });
        var c_time: c_import.time_t = @intCast(secs);
        const local = c_import.localtime(&c_time);
        if (local) |tm| {
            const hour_24: u32 = @intCast(tm.*.tm_hour);
            const minute: u32 = @intCast(tm.*.tm_min);
            const am_pm: [*:0]const u8 = if (hour_24 >= 12) "PM" else "AM";
            const hour_12: u32 = blk: {
                const h = hour_24 % 12;
                break :blk if (h == 0) 12 else h;
            };

            const result = std.fmt.bufPrint(buf[0..31], "{d}:{d:0>2} {s}", .{ hour_12, minute, std.mem.span(am_pm) }) catch {
                buf[0] = 0;
                return @ptrCast(buf);
            };
            buf[result.len] = 0;
            return @ptrCast(buf);
        }

        buf[0] = 0;
        return @ptrCast(buf);
    }

    const notif_row_prefix = "NotificationRow.";

    /// Encode tab_id, surface_id, notification_id into a widget name string.
    /// Format: "NotificationRow.tab_uuid:surface_uuid_or_nil:notification_uuid"
    fn encodeNotificationName(buf: *[notif_row_prefix.len + 110 :0]u8, tab_id: cmux.Uuid, surface_id: ?cmux.Uuid, notification_id: cmux.Uuid) [*:0]const u8 {
        const tab_fmt = tab_id.format();
        const notif_fmt = notification_id.format();

        var pos: usize = 0;

        // Accessibility prefix
        @memcpy(buf[pos..][0..notif_row_prefix.len], notif_row_prefix);
        pos += notif_row_prefix.len;

        // tab_id (36 chars)
        @memcpy(buf[pos..][0..36], &tab_fmt);
        pos += 36;

        buf[pos] = ':';
        pos += 1;

        // surface_id (36 chars or "nil")
        if (surface_id) |sid| {
            const sid_fmt = sid.format();
            @memcpy(buf[pos..][0..36], &sid_fmt);
            pos += 36;
        } else {
            @memcpy(buf[pos..][0..3], "nil");
            pos += 3;
        }

        buf[pos] = ':';
        pos += 1;

        // notification_id (36 chars)
        @memcpy(buf[pos..][0..36], &notif_fmt);
        pos += 36;

        buf[pos] = 0;
        return @ptrCast(buf);
    }

    const DecodedIds = struct {
        tab_id: cmux.Uuid,
        surface_id: ?cmux.Uuid,
        notification_id: cmux.Uuid,
    };

    /// Decode a widget name back into notification IDs.
    /// Strips the "NotificationRow." prefix if present.
    fn decodeNotificationName(name_z: [*:0]const u8) ?DecodedIds {
        const raw = std.mem.span(name_z);
        // Strip prefix if present.
        const name = if (std.mem.startsWith(u8, raw, notif_row_prefix))
            raw[notif_row_prefix.len..]
        else
            raw;
        if (name.len < 3) return null;

        // Find first ':'
        const first_colon = std.mem.indexOfScalar(u8, name, ':') orelse return null;
        if (first_colon < 36) return null;

        const tab_str = name[0..36];
        const rest = name[first_colon + 1 ..];

        // Find second ':'
        const second_colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;

        const surface_str = rest[0..second_colon];
        const notif_str = rest[second_colon + 1 ..];

        const tab_id = cmux.Uuid.parse(tab_str) catch return null;
        const surface_id: ?cmux.Uuid = if (std.mem.eql(u8, surface_str, "nil"))
            null
        else
            cmux.Uuid.parse(surface_str[0..@min(surface_str.len, 36)]) catch return null;

        if (notif_str.len < 36) return null;
        const notification_id = cmux.Uuid.parse(notif_str[0..36]) catch return null;

        return .{
            .tab_id = tab_id,
            .surface_id = surface_id,
            .notification_id = notification_id,
        };
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
