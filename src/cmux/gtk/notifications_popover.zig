//! Notifications popover — a GtkPopover showing notification history.
//!
//! Toggled by Ctrl+I. Contains a header with "Jump to Latest" and "Clear All"
//! buttons, a scrollable list of notification rows, and an empty-state label.
//!
//! Accessibility names expected by tests:
//!   - notificationsPopover.jumpToLatest (push button)
//!   - notificationsPopover.clearAll (push button)
//!   - NotificationPopoverRow.N (notification row widgets)
//!   - "No notifications yet" (label shown when empty)

const std = @import("std");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");

const cmux = @import("../main.zig");

const log = std.log.scoped(.notifications_popover);

/// Manages the notifications GtkPopover lifecycle and content.
/// This is NOT a GObject subclass — it's a plain struct that owns
/// a GtkPopover widget and rebuilds its content from the Store.
pub const NotificationsPopover = struct {
    popover: *gtk.Popover,
    content_box: *gtk.Box,
    list_box: *gtk.ListBox,
    empty_label: *gtk.Label,
    jump_btn: *gtk.Button,
    clear_btn: *gtk.Button,
    content_stack: *gtk.Stack,

    notification_store: ?*cmux.notification.Store = null,

    /// Callback: jump to a notification's workspace/surface.
    on_jump_to_unread: ?*const fn () void = null,

    /// Callback: close the popover (return focus to terminal).
    on_close: ?*const fn () void = null,

    pub fn create(parent: *gtk.Widget) NotificationsPopover {
        // --- Root popover ---
        const popover = gtk.Popover.new();
        popover.as(gtk.Widget).setParent(parent);
        popover.setHasArrow(0);
        popover.as(gtk.Widget).setSizeRequest(400, 480);
        popover.as(gtk.Widget).setHalign(.end);
        popover.as(gtk.Widget).setValign(.start);

        // --- Main vertical box ---
        const main_box = gtk.Box.new(.vertical, 0);

        // --- Header ---
        const header = gtk.Box.new(.horizontal, 8);
        header.as(gtk.Widget).setMarginStart(16);
        header.as(gtk.Widget).setMarginEnd(16);
        header.as(gtk.Widget).setMarginTop(12);
        header.as(gtk.Widget).setMarginBottom(8);

        const title_label = gtk.Label.new("Notifications");
        title_label.as(gtk.Widget).addCssClass("title-3");
        header.append(title_label.as(gtk.Widget));

        // Spacer
        const spacer = gtk.Box.new(.horizontal, 0);
        spacer.as(gtk.Widget).setHexpand(1);
        header.append(spacer.as(gtk.Widget));

        // Jump to Latest button
        const jump_btn = gtk.Button.newWithLabel("Jump to Latest");
        jump_btn.as(gtk.Widget).addCssClass("flat");
        jump_btn.as(gtk.Widget).setName("notificationsPopover.jumpToLatest");
        jump_btn.as(gtk.Widget).setTooltipText("Ctrl+Shift+U");
        header.append(jump_btn.as(gtk.Widget));

        // Clear All button
        const clear_btn = gtk.Button.newWithLabel("Clear All");
        clear_btn.as(gtk.Widget).addCssClass("flat");
        clear_btn.as(gtk.Widget).setName("notificationsPopover.clearAll");
        header.append(clear_btn.as(gtk.Widget));

        main_box.append(header.as(gtk.Widget));

        // --- Separator ---
        const sep = gtk.Separator.new(.horizontal);
        main_box.append(sep.as(gtk.Widget));

        // --- Content stack (list vs empty) ---
        const content_stack = gtk.Stack.new();
        content_stack.as(gtk.Widget).setVexpand(1);
        content_stack.as(gtk.Widget).setHexpand(1);
        content_stack.setTransitionType(.crossfade);

        // "list" page: ScrolledWindow > ListBox
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setPolicy(.never, .automatic);
        scrolled.as(gtk.Widget).setVexpand(1);

        const list_box = gtk.ListBox.new();
        list_box.setSelectionMode(.none);
        list_box.as(gtk.Widget).addCssClass("boxed-list");
        list_box.as(gtk.Widget).setMarginStart(12);
        list_box.as(gtk.Widget).setMarginEnd(12);
        list_box.as(gtk.Widget).setMarginTop(8);
        list_box.as(gtk.Widget).setMarginBottom(12);
        scrolled.setChild(list_box.as(gtk.Widget));

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

        const empty_label = gtk.Label.new("No notifications yet");
        empty_label.as(gtk.Widget).addCssClass("title-4");
        empty_label.as(gtk.Widget).setName("No notifications yet");
        empty_box.append(empty_label.as(gtk.Widget));

        _ = content_stack.addNamed(empty_box.as(gtk.Widget), "empty");

        main_box.append(content_stack.as(gtk.Widget));

        // Show empty state initially
        content_stack.setVisibleChildName("empty");

        popover.setChild(main_box.as(gtk.Widget));

        return NotificationsPopover{
            .popover = popover,
            .content_box = main_box,
            .list_box = list_box,
            .empty_label = empty_label,
            .jump_btn = jump_btn,
            .clear_btn = clear_btn,
            .content_stack = content_stack,
        };
    }

    /// Wire signal handlers. Must be called after the struct is at a stable
    /// address (e.g., heap-allocated or in GObject private data).
    pub fn connectSignals(self: *NotificationsPopover) void {
        // Jump to Latest button
        _ = gtk.Button.signals.clicked.connect(
            self.jump_btn,
            *NotificationsPopover,
            onJumpClicked,
            self,
            .{},
        );

        // Clear All button
        _ = gtk.Button.signals.clicked.connect(
            self.clear_btn,
            *NotificationsPopover,
            onClearClicked,
            self,
            .{},
        );
    }

    fn onJumpClicked(_: *gtk.Button, self: *NotificationsPopover) callconv(.c) void {
        if (self.on_jump_to_unread) |cb| cb();
    }

    fn onClearClicked(_: *gtk.Button, self: *NotificationsPopover) callconv(.c) void {
        const store = self.notification_store orelse return;
        store.clearAll();
        self.refresh();
    }

    /// Toggle the popover open/closed.
    pub fn toggle(self: *NotificationsPopover) void {
        if (self.isVisible()) {
            self.popover.popdown();
        } else {
            self.refresh();
            self.popover.popup();
        }
    }

    /// Close the popover if open.
    pub fn close(self: *NotificationsPopover) void {
        if (self.isVisible()) {
            self.popover.popdown();
        }
    }

    /// Returns true if the popover is currently visible.
    pub fn isVisible(self: *NotificationsPopover) bool {
        return self.popover.as(gtk.Widget).getVisible() != 0;
    }

    /// Rebuild the notification list from the store.
    pub fn refresh(self: *NotificationsPopover) void {
        const store = self.notification_store orelse {
            self.content_stack.setVisibleChildName("empty");
            return;
        };

        // Remove all existing rows
        while (true) {
            const row = self.list_box.getRowAtIndex(0) orelse break;
            self.list_box.remove(row.as(gtk.Widget));
        }

        const notifications = store.getNotifications();

        if (notifications.len == 0) {
            self.content_stack.setVisibleChildName("empty");
            return;
        }

        self.content_stack.setVisibleChildName("list");

        for (notifications, 0..) |n, idx| {
            const row = buildNotificationRow(&n, idx);
            self.list_box.append(row.as(gtk.Widget));
        }
    }

    fn buildNotificationRow(n: *const cmux.notification.Notification, index: usize) *gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.setActivatable(0);

        // Set accessibility name: NotificationPopoverRow.N
        var name_buf: [64:0]u8 = undefined;
        const name_str = std.fmt.bufPrint(name_buf[0..63], "NotificationPopoverRow.{d}", .{index}) catch return row;
        name_buf[name_str.len] = 0;
        row.as(gtk.Widget).setName(@ptrCast(name_buf[0..name_str.len :0]));

        const hbox = gtk.Box.new(.horizontal, 12);
        hbox.as(gtk.Widget).setMarginStart(8);
        hbox.as(gtk.Widget).setMarginEnd(8);
        hbox.as(gtk.Widget).setMarginTop(8);
        hbox.as(gtk.Widget).setMarginBottom(8);

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

        // Subtitle (only if non-empty)
        if (n.subtitle.len > 0) {
            var sub_buf: [512:0]u8 = undefined;
            const sub_z = sliceToZ(&sub_buf, n.subtitle);
            const sub_label = gtk.Label.new(sub_z);
            sub_label.setXalign(0);
            sub_label.as(gtk.Widget).addCssClass("dim-label");
            content_vbox.append(sub_label.as(gtk.Widget));
        }

        // Body (only if non-empty)
        if (n.body.len > 0) {
            var body_buf: [1024:0]u8 = undefined;
            const body_z = sliceToZ(&body_buf, n.body);
            const body_label = gtk.Label.new(body_z);
            body_label.setXalign(0);
            body_label.as(gtk.Widget).addCssClass("dim-label");
            body_label.setEllipsize(.end);
            body_label.setLines(3);
            body_label.setMaxWidthChars(60);
            content_vbox.append(body_label.as(gtk.Widget));
        }

        hbox.append(content_vbox.as(gtk.Widget));
        row.setChild(hbox.as(gtk.Widget));

        return row;
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

    fn formatTimestamp(buf: *[32:0]u8, millis: i64) [*:0]const u8 {
        const secs = @divTrunc(millis, 1000);
        const c_import = @cImport({
            @cInclude("time.h");
        });
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

    pub fn destroy(self: *NotificationsPopover) void {
        self.popover.as(gtk.Widget).unparent();
    }
};
