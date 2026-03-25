/// StatusNotifierItem (SNI) D-Bus implementation for the system tray.
///
/// Registers as `org.kde.StatusNotifierItem-{PID}-1` on the session bus,
/// exports the SNI interface at `/StatusNotifierItem` and a dbusmenu
/// interface at `/StatusNotifierMenu`. Registers with the
/// `org.kde.StatusNotifierWatcher` so the tray host discovers us.
///
/// Uses `@cImport` of `gio/gio.h` for the low-level GDBus registration
/// functions (following the `flatpak.zig` pattern), since the zig-gobject
/// bindings don't expose `g_dbus_connection_register_object`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const notification = @import("../notification/main.zig");
const badge = @import("../notification/badge.zig");
const workspace = @import("../workspace/main.zig");
const icon = @import("icon.zig");
const menu_model = @import("MenuModel.zig");
const MenuModel = menu_model.MenuModel;
const Callbacks = menu_model.Callbacks;

const log = std.log.scoped(.cmux_status_notifier);

const c = @cImport({
    @cInclude("gio/gio.h");
});

// ── D-Bus introspection XML ──────────────────────────────────

const sni_introspection_xml =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<node>
    \\  <interface name="org.kde.StatusNotifierItem">
    \\    <method name="Activate">
    \\      <arg name="x" type="i" direction="in"/>
    \\      <arg name="y" type="i" direction="in"/>
    \\    </method>
    \\    <method name="SecondaryActivate">
    \\      <arg name="x" type="i" direction="in"/>
    \\      <arg name="y" type="i" direction="in"/>
    \\    </method>
    \\    <method name="ContextMenu">
    \\      <arg name="x" type="i" direction="in"/>
    \\      <arg name="y" type="i" direction="in"/>
    \\    </method>
    \\    <method name="Scroll">
    \\      <arg name="delta" type="i" direction="in"/>
    \\      <arg name="orientation" type="s" direction="in"/>
    \\    </method>
    \\    <signal name="NewIcon"/>
    \\    <signal name="NewTooltip"/>
    \\    <signal name="NewStatus">
    \\      <arg name="status" type="s"/>
    \\    </signal>
    \\    <property name="Category" type="s" access="read"/>
    \\    <property name="Id" type="s" access="read"/>
    \\    <property name="Title" type="s" access="read"/>
    \\    <property name="Status" type="s" access="read"/>
    \\    <property name="IconName" type="s" access="read"/>
    \\    <property name="IconPixmap" type="a(iiay)" access="read"/>
    \\    <property name="AttentionIconName" type="s" access="read"/>
    \\    <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    \\    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    \\    <property name="Menu" type="o" access="read"/>
    \\    <property name="ItemIsMenu" type="b" access="read"/>
    \\    <property name="IconThemePath" type="s" access="read"/>
    \\  </interface>
    \\</node>
;

const menu_introspection_xml =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<node>
    \\  <interface name="com.canonical.dbusmenu">
    \\    <method name="GetLayout">
    \\      <arg name="parentId" type="i" direction="in"/>
    \\      <arg name="recursionDepth" type="i" direction="in"/>
    \\      <arg name="propertyNames" type="as" direction="in"/>
    \\      <arg name="revision" type="u" direction="out"/>
    \\      <arg name="layout" type="(ia{sv}av)" direction="out"/>
    \\    </method>
    \\    <method name="GetGroupProperties">
    \\      <arg name="ids" type="ai" direction="in"/>
    \\      <arg name="propertyNames" type="as" direction="in"/>
    \\      <arg name="properties" type="a(ia{sv})" direction="out"/>
    \\    </method>
    \\    <method name="GetProperty">
    \\      <arg name="id" type="i" direction="in"/>
    \\      <arg name="name" type="s" direction="in"/>
    \\      <arg name="value" type="v" direction="out"/>
    \\    </method>
    \\    <method name="Event">
    \\      <arg name="id" type="i" direction="in"/>
    \\      <arg name="eventId" type="s" direction="in"/>
    \\      <arg name="data" type="v" direction="in"/>
    \\      <arg name="timestamp" type="u" direction="in"/>
    \\    </method>
    \\    <method name="EventGroup">
    \\      <arg name="events" type="a(isvu)" direction="in"/>
    \\      <arg name="idErrors" type="ai" direction="out"/>
    \\    </method>
    \\    <method name="AboutToShow">
    \\      <arg name="id" type="i" direction="in"/>
    \\      <arg name="needUpdate" type="b" direction="out"/>
    \\    </method>
    \\    <method name="AboutToShowGroup">
    \\      <arg name="ids" type="ai" direction="in"/>
    \\      <arg name="updatesNeeded" type="ai" direction="out"/>
    \\      <arg name="idErrors" type="ai" direction="out"/>
    \\    </method>
    \\    <signal name="LayoutUpdated">
    \\      <arg name="revision" type="u"/>
    \\      <arg name="parent" type="i"/>
    \\    </signal>
    \\    <signal name="ItemsPropertiesUpdated">
    \\      <arg name="updatedProps" type="a(ia{sv})"/>
    \\      <arg name="removedProps" type="a(ias)"/>
    \\    </signal>
    \\    <property name="Version" type="u" access="read"/>
    \\    <property name="TextDirection" type="s" access="read"/>
    \\    <property name="Status" type="s" access="read"/>
    \\    <property name="IconThemePath" type="as" access="read"/>
    \\  </interface>
    \\</node>
;

// ── StatusNotifier struct ────────────────────────────────────

pub const StatusNotifier = struct {
    alloc: Allocator,

    // D-Bus state
    dbus: ?*c.GDBusConnection = null,
    bus_name_id: c_uint = 0,
    sni_registration_id: c_uint = 0,
    menu_registration_id: c_uint = 0,
    sni_node_info: ?*c.GDBusNodeInfo = null,
    menu_node_info: ?*c.GDBusNodeInfo = null,

    // App state
    notification_store: *notification.Store,
    workspace_manager: ?*const workspace.Manager = null,
    menu: MenuModel,

    // Icon pixmap buffer (22x22 ARGB32)
    icon_buf: [icon_size * icon_size * 4]u8 = undefined,
    last_unread_count: u32 = std.math.maxInt(u32), // force initial refresh

    // Bus name (formatted once)
    bus_name_buf: [64]u8 = undefined,
    bus_name_len: usize = 0,

    const icon_size: u32 = 22;

    pub fn init(
        alloc: Allocator,
        store: *notification.Store,
        manager: ?*const workspace.Manager,
        callbacks: Callbacks,
    ) StatusNotifier {
        return .{
            .alloc = alloc,
            .notification_store = store,
            .workspace_manager = manager,
            .menu = MenuModel.init(callbacks),
        };
    }

    pub fn deinit(self: *StatusNotifier) void {
        self.stop();
    }

    /// Start the StatusNotifier: connect to D-Bus, register objects, register with watcher.
    pub fn start(self: *StatusNotifier) void {
        // Format the bus name.
        const pid = std.os.linux.getpid();
        const name = std.fmt.bufPrintZ(&self.bus_name_buf, "org.kde.StatusNotifierItem-{d}-1", .{pid}) catch {
            log.warn("failed to format bus name", .{});
            return;
        };
        self.bus_name_len = name.len;

        // Parse introspection XML.
        var err: ?*c.GError = null;

        self.sni_node_info = c.g_dbus_node_info_new_for_xml(sni_introspection_xml, &err);
        if (err) |e| {
            log.warn("failed to parse SNI introspection XML: {s}", .{e.*.message});
            c.g_error_free(e);
            return;
        }

        err = null;
        self.menu_node_info = c.g_dbus_node_info_new_for_xml(menu_introspection_xml, &err);
        if (err) |e| {
            log.warn("failed to parse menu introspection XML: {s}", .{e.*.message});
            c.g_error_free(e);
            return;
        }

        // Get session bus.
        err = null;
        self.dbus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &err);
        if (err) |e| {
            log.warn("failed to connect to session bus: {s}", .{e.*.message});
            c.g_error_free(e);
            return;
        }

        const dbus = self.dbus orelse {
            log.warn("session bus connection is null", .{});
            return;
        };

        // Register the SNI object.
        const sni_vtable = c.GDBusInterfaceVTable{
            .method_call = &sniMethodCall,
            .get_property = &sniGetProperty,
            .set_property = null,
            .padding = .{ null, null, null, null, null, null, null, null },
        };

        err = null;
        self.sni_registration_id = c.g_dbus_connection_register_object(
            dbus,
            "/StatusNotifierItem",
            self.sni_node_info.?.*.interfaces[0],
            &sni_vtable,
            @ptrCast(self),
            null,
            &err,
        );
        if (err) |e| {
            log.warn("failed to register SNI object: {s}", .{e.*.message});
            c.g_error_free(e);
            return;
        }

        // Register the dbusmenu object.
        const menu_vtable = c.GDBusInterfaceVTable{
            .method_call = &menuMethodCall,
            .get_property = &menuGetProperty,
            .set_property = null,
            .padding = .{ null, null, null, null, null, null, null, null },
        };

        err = null;
        self.menu_registration_id = c.g_dbus_connection_register_object(
            dbus,
            "/StatusNotifierMenu",
            self.menu_node_info.?.*.interfaces[0],
            &menu_vtable,
            @ptrCast(self),
            null,
            &err,
        );
        if (err) |e| {
            log.warn("failed to register menu object: {s}", .{e.*.message});
            c.g_error_free(e);
            return;
        }

        // Own the bus name.
        self.bus_name_id = c.g_bus_own_name_on_connection(
            dbus,
            name.ptr,
            c.G_BUS_NAME_OWNER_FLAGS_NONE,
            null, // name acquired
            null, // name lost
            null,
            null,
        );

        // Do initial refresh.
        self.refresh();

        // Register with the StatusNotifierWatcher.
        self.registerWithWatcher();

        log.info("StatusNotifier started as {s}", .{name});
    }

    /// Stop the StatusNotifier and release D-Bus resources.
    pub fn stop(self: *StatusNotifier) void {
        if (self.dbus) |dbus| {
            if (self.sni_registration_id != 0) {
                _ = c.g_dbus_connection_unregister_object(dbus, self.sni_registration_id);
                self.sni_registration_id = 0;
            }
            if (self.menu_registration_id != 0) {
                _ = c.g_dbus_connection_unregister_object(dbus, self.menu_registration_id);
                self.menu_registration_id = 0;
            }
        }
        if (self.bus_name_id != 0) {
            c.g_bus_unown_name(self.bus_name_id);
            self.bus_name_id = 0;
        }
        if (self.sni_node_info) |info| {
            c.g_dbus_node_info_unref(info);
            self.sni_node_info = null;
        }
        if (self.menu_node_info) |info| {
            c.g_dbus_node_info_unref(info);
            self.menu_node_info = null;
        }
        self.dbus = null;
    }

    /// Refresh the icon, tooltip, and menu from current notification state.
    /// Should be called on the main thread.
    pub fn refresh(self: *StatusNotifier) void {
        const store = self.notification_store;
        self.menu.rebuild(store, self.workspace_manager);

        const unread = store.getUnreadCount();
        const changed = (unread != self.last_unread_count);
        self.last_unread_count = unread;

        // Re-render icon.
        _ = icon.renderIcon(&self.icon_buf, icon_size, unread);

        // Emit D-Bus signals if connected and state changed.
        if (changed) {
            if (self.dbus) |dbus| {
                self.emitSignal(dbus, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewIcon");
                self.emitSignal(dbus, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewTooltip");

                const status: [*:0]const u8 = if (unread > 0) "NeedsAttention" else "Active";
                _ = c.g_dbus_connection_emit_signal(
                    dbus,
                    null,
                    "/StatusNotifierItem",
                    "org.kde.StatusNotifierItem",
                    "NewStatus",
                    c.g_variant_new("(s)", status),
                    null,
                );
            }
        }

        // Always emit LayoutUpdated so the menu refreshes.
        if (self.dbus) |dbus| {
            _ = c.g_dbus_connection_emit_signal(
                dbus,
                null,
                "/StatusNotifierMenu",
                "com.canonical.dbusmenu",
                "LayoutUpdated",
                c.g_variant_new("(ui)", self.menu.revision, @as(c_int, 0)),
                null,
            );
        }
    }

    // ── Private helpers ──────────────────────────────────────

    fn emitSignal(self: *StatusNotifier, dbus: *c.GDBusConnection, path: [*:0]const u8, iface: [*:0]const u8, name: [*:0]const u8) void {
        _ = self;
        _ = c.g_dbus_connection_emit_signal(
            dbus,
            null,
            path,
            iface,
            name,
            null,
            null,
        );
    }

    fn registerWithWatcher(self: *StatusNotifier) void {
        const dbus = self.dbus orelse return;
        const name = self.bus_name_buf[0..self.bus_name_len :0];

        c.g_dbus_connection_call(
            dbus,
            "org.kde.StatusNotifierWatcher",
            "/StatusNotifierWatcher",
            "org.kde.StatusNotifierWatcher",
            "RegisterStatusNotifierItem",
            c.g_variant_new("(s)", name.ptr),
            null,
            c.G_DBUS_CALL_FLAGS_NONE,
            -1,
            null,
            &watcherRegistrationCallback,
            @ptrCast(self),
        );
    }

    fn watcherRegistrationCallback(
        source: ?*c.GObject,
        result: ?*c.GAsyncResult,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        _ = user_data;
        var err: ?*c.GError = null;
        const conn: ?*c.GDBusConnection = @ptrCast(@alignCast(source));
        const reply = c.g_dbus_connection_call_finish(conn, result, &err);
        if (err) |e| {
            log.info("StatusNotifierWatcher registration: {s} (tray may not be running)", .{e.*.message});
            c.g_error_free(e);
            return;
        }
        if (reply) |r| c.g_variant_unref(r);
        log.info("registered with StatusNotifierWatcher", .{});
    }

    // ── SNI D-Bus method/property handlers ───────────────────

    fn sniMethodCall(
        _: ?*c.GDBusConnection,
        _: ?[*:0]const u8,
        _: ?[*:0]const u8,
        _: ?[*:0]const u8,
        method_name: ?[*:0]const u8,
        _: ?*c.GVariant,
        invocation: ?*c.GDBusMethodInvocation,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *StatusNotifier = @ptrCast(@alignCast(user_data orelse return));
        const method = std.mem.span(method_name orelse return);

        if (std.mem.eql(u8, method, "Activate")) {
            // Left click — show notifications / bring window to front.
            if (self.menu.callbacks.on_show_notifications) |cb| cb();
        } else if (std.mem.eql(u8, method, "ContextMenu") or std.mem.eql(u8, method, "SecondaryActivate")) {
            // Right click / middle click — handled by dbusmenu, nothing to do.
        }

        c.g_dbus_method_invocation_return_value(invocation, null);
    }

    fn sniGetProperty(
        _: ?*c.GDBusConnection,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        property_name: [*c]const u8,
        _: [*c][*c]c.GError,
        user_data: ?*anyopaque,
    ) callconv(.c) ?*c.GVariant {
        const self: *StatusNotifier = @ptrCast(@alignCast(user_data orelse return null));
        const prop_ptr: ?[*:0]const u8 = @ptrCast(property_name);
        const prop = std.mem.span(prop_ptr orelse return null);

        if (std.mem.eql(u8, prop, "Category")) {
            return c.g_variant_new_string("ApplicationStatus");
        } else if (std.mem.eql(u8, prop, "Id")) {
            return c.g_variant_new_string("cmux");
        } else if (std.mem.eql(u8, prop, "Title")) {
            return c.g_variant_new_string("cmux");
        } else if (std.mem.eql(u8, prop, "Status")) {
            return c.g_variant_new_string(if (self.last_unread_count > 0) "NeedsAttention" else "Active");
        } else if (std.mem.eql(u8, prop, "IconName")) {
            return c.g_variant_new_string("");
        } else if (std.mem.eql(u8, prop, "IconPixmap")) {
            return self.buildIconPixmapVariant();
        } else if (std.mem.eql(u8, prop, "AttentionIconName")) {
            return c.g_variant_new_string("");
        } else if (std.mem.eql(u8, prop, "AttentionIconPixmap")) {
            return self.buildIconPixmapVariant();
        } else if (std.mem.eql(u8, prop, "ToolTip")) {
            return self.buildTooltipVariant();
        } else if (std.mem.eql(u8, prop, "Menu")) {
            return c.g_variant_new_object_path("/StatusNotifierMenu");
        } else if (std.mem.eql(u8, prop, "ItemIsMenu")) {
            return c.g_variant_new_boolean(0);
        } else if (std.mem.eql(u8, prop, "IconThemePath")) {
            return c.g_variant_new_string("");
        }

        return null;
    }

    /// Build the IconPixmap GVariant: a(iiay) — array of (width, height, ARGB_data).
    fn buildIconPixmapVariant(self: *StatusNotifier) ?*c.GVariant {
        const builder = c.g_variant_builder_new(c.g_variant_type_new("a(iiay)"));
        defer c.g_variant_builder_unref(builder);

        const data_bytes = c.g_variant_new_fixed_array(
            c.g_variant_type_new("y"),
            @ptrCast(&self.icon_buf),
            icon_size * icon_size * 4,
            1,
        );

        c.g_variant_builder_add(
            builder,
            "(ii@ay)",
            @as(c_int, @intCast(icon_size)),
            @as(c_int, @intCast(icon_size)),
            data_bytes,
        );

        return c.g_variant_builder_end(builder);
    }

    /// Build the ToolTip GVariant: (sa(iiay)ss) — (icon_name, icon_pixmap, title, description).
    fn buildTooltipVariant(self: *StatusNotifier) ?*c.GVariant {
        var buf: [128]u8 = undefined;
        const tooltip_text = self.menu.stateHintText(&buf);
        var tooltip_z: [129]u8 = undefined;
        @memcpy(tooltip_z[0..tooltip_text.len], tooltip_text);
        tooltip_z[tooltip_text.len] = 0;

        // Empty icon pixmap array for tooltip.
        const empty_pixmap = c.g_variant_builder_new(c.g_variant_type_new("a(iiay)"));
        defer c.g_variant_builder_unref(empty_pixmap);

        return c.g_variant_new(
            "(s@a(iiay)ss)",
            @as([*:0]const u8, ""),
            c.g_variant_builder_end(empty_pixmap),
            @as([*:0]const u8, "cmux"),
            @as([*:0]const u8, @ptrCast(&tooltip_z)),
        );
    }

    // ── Dbusmenu D-Bus method/property handlers ──────────────

    fn menuMethodCall(
        _: ?*c.GDBusConnection,
        _: ?[*:0]const u8,
        _: ?[*:0]const u8,
        _: ?[*:0]const u8,
        method_name: ?[*:0]const u8,
        parameters: ?*c.GVariant,
        invocation: ?*c.GDBusMethodInvocation,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *StatusNotifier = @ptrCast(@alignCast(user_data orelse return));
        const method = std.mem.span(method_name orelse return);

        if (std.mem.eql(u8, method, "GetLayout")) {
            self.handleGetLayout(invocation);
        } else if (std.mem.eql(u8, method, "Event")) {
            self.handleMenuEvent(parameters);
            c.g_dbus_method_invocation_return_value(invocation, null);
        } else if (std.mem.eql(u8, method, "EventGroup")) {
            self.handleMenuEventGroup(parameters);
            // Return empty error list.
            const empty_ai = c.g_variant_builder_new(c.g_variant_type_new("ai"));
            defer c.g_variant_builder_unref(empty_ai);
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(@ai)", c.g_variant_builder_end(empty_ai)));
        } else if (std.mem.eql(u8, method, "AboutToShow")) {
            // Refresh before showing.
            self.refresh();
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(b)", @as(c_int, 1)));
        } else if (std.mem.eql(u8, method, "AboutToShowGroup")) {
            self.refresh();
            const empty_ai = c.g_variant_builder_new(c.g_variant_type_new("ai"));
            defer c.g_variant_builder_unref(empty_ai);
            const empty_ai2 = c.g_variant_builder_new(c.g_variant_type_new("ai"));
            defer c.g_variant_builder_unref(empty_ai2);
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(@ai@ai)", c.g_variant_builder_end(empty_ai), c.g_variant_builder_end(empty_ai2)));
        } else if (std.mem.eql(u8, method, "GetGroupProperties")) {
            // Return empty array.
            const empty = c.g_variant_builder_new(c.g_variant_type_new("a(ia{sv})"));
            defer c.g_variant_builder_unref(empty);
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(@a(ia{sv}))", c.g_variant_builder_end(empty)));
        } else if (std.mem.eql(u8, method, "GetProperty")) {
            // Return empty variant.
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(v)", c.g_variant_new_string("")));
        } else {
            c.g_dbus_method_invocation_return_value(invocation, null);
        }
    }

    fn menuGetProperty(
        _: ?*c.GDBusConnection,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        property_name: [*c]const u8,
        _: [*c][*c]c.GError,
        _: ?*anyopaque,
    ) callconv(.c) ?*c.GVariant {
        const prop_ptr: ?[*:0]const u8 = @ptrCast(property_name);
        const prop = std.mem.span(prop_ptr orelse return null);

        if (std.mem.eql(u8, prop, "Version")) {
            return c.g_variant_new_uint32(3);
        } else if (std.mem.eql(u8, prop, "TextDirection")) {
            return c.g_variant_new_string("ltr");
        } else if (std.mem.eql(u8, prop, "Status")) {
            return c.g_variant_new_string("normal");
        } else if (std.mem.eql(u8, prop, "IconThemePath")) {
            const builder = c.g_variant_builder_new(c.g_variant_type_new("as"));
            defer c.g_variant_builder_unref(builder);
            return c.g_variant_builder_end(builder);
        }

        return null;
    }

    // ── GetLayout implementation ─────────────────────────────

    fn handleGetLayout(self: *StatusNotifier, invocation: ?*c.GDBusMethodInvocation) void {
        // Build the menu layout as (u(ia{sv}av))
        const layout = self.buildMenuLayout();
        c.g_dbus_method_invocation_return_value(
            invocation,
            c.g_variant_new("(u@(ia{sv}av))", self.menu.revision, layout),
        );
    }

    /// Build the full menu tree as a GVariant of type (ia{sv}av).
    fn buildMenuLayout(self: *StatusNotifier) ?*c.GVariant {
        const children = c.g_variant_builder_new(c.g_variant_type_new("av"));
        defer c.g_variant_builder_unref(children);

        // 1. State hint (disabled label)
        {
            var hint_buf: [128]u8 = undefined;
            const hint_text = self.menu.stateHintText(&hint_buf);
            var hint_z: [129]u8 = undefined;
            @memcpy(hint_z[0..hint_text.len], hint_text);
            hint_z[hint_text.len] = 0;

            c.g_variant_builder_add(children, "v", buildMenuItem(
                menu_model.id_state_hint,
                @ptrCast(&hint_z),
                false,
                true,
                false,
            ));
        }

        // 2. Separator (before notifications, hidden if none)
        if (self.menu.inline_count > 0) {
            c.g_variant_builder_add(children, "v", buildSeparator(menu_model.id_sep_after_notifications));
        }

        // 3. Inline notification items
        for (0..self.menu.inline_count) |i| {
            const label = self.menu.inlineLabel(i);
            var label_z: [menu_model.max_label_len + 1]u8 = undefined;
            const len = @min(label.len, menu_model.max_label_len);
            @memcpy(label_z[0..len], label[0..len]);
            label_z[len] = 0;

            c.g_variant_builder_add(children, "v", buildMenuItem(
                menu_model.id_notification_base + @as(i32, @intCast(i)),
                @ptrCast(&label_z),
                true,
                true,
                false,
            ));
        }

        // 4. Separator (before action items)
        c.g_variant_builder_add(children, "v", buildSeparator(menu_model.id_sep_before_actions));

        // 5. Show Notifications
        c.g_variant_builder_add(children, "v", buildMenuItem(
            menu_model.id_show_notifications,
            "Show Notifications",
            true,
            true,
            false,
        ));

        // 6. Jump to Latest Unread
        c.g_variant_builder_add(children, "v", buildMenuItem(
            menu_model.id_jump_to_unread,
            "Jump to Latest Unread",
            self.menu.unread_count > 0,
            true,
            false,
        ));

        // 7. Mark All Read
        c.g_variant_builder_add(children, "v", buildMenuItem(
            menu_model.id_mark_all_read,
            "Mark All Read",
            self.menu.unread_count > 0,
            true,
            false,
        ));

        // 8. Clear All
        c.g_variant_builder_add(children, "v", buildMenuItem(
            menu_model.id_clear_all,
            "Clear All",
            self.menu.total_count > 0,
            true,
            false,
        ));

        // 9. Separator
        c.g_variant_builder_add(children, "v", buildSeparator(menu_model.id_sep_before_prefs));

        // 10. Preferences...
        c.g_variant_builder_add(children, "v", buildMenuItem(
            menu_model.id_preferences,
            "Preferences\xe2\x80\xa6",
            true,
            true,
            false,
        ));

        // 11. Separator
        c.g_variant_builder_add(children, "v", buildSeparator(menu_model.id_sep_before_quit));

        // 12. Quit cmux
        c.g_variant_builder_add(children, "v", buildMenuItem(
            menu_model.id_quit,
            "Quit cmux",
            true,
            true,
            false,
        ));

        // Root item.
        const root_props = c.g_variant_builder_new(c.g_variant_type_new("a{sv}"));
        defer c.g_variant_builder_unref(root_props);
        c.g_variant_builder_add(root_props, "{sv}", @as([*:0]const u8, "children-display"), c.g_variant_new_string("submenu"));

        return c.g_variant_new("(i@a{sv}@av)",
            @as(c_int, menu_model.id_root),
            c.g_variant_builder_end(root_props),
            c.g_variant_builder_end(children),
        );
    }

    // ── Menu Event handling ──────────────────────────────────

    fn handleMenuEvent(self: *StatusNotifier, parameters: ?*c.GVariant) void {
        if (parameters == null) return;

        var id: c_int = 0;
        var event_id: ?[*:0]const u8 = null;
        c.g_variant_get_child(parameters.?, 0, "i", &id);
        c.g_variant_get_child(parameters.?, 1, "&s", &event_id);

        const event = std.mem.span(event_id orelse return);
        if (std.mem.eql(u8, event, "clicked")) {
            self.menu.handleEvent(id);
        }
    }

    fn handleMenuEventGroup(self: *StatusNotifier, parameters: ?*c.GVariant) void {
        if (parameters == null) return;

        // EventGroup receives a(isvu) — iterate and dispatch each.
        const events = c.g_variant_get_child_value(parameters.?, 0);
        if (events == null) return;
        defer c.g_variant_unref(events);

        var iter: c.GVariantIter = undefined;
        _ = c.g_variant_iter_init(&iter, events);

        var id: c_int = undefined;
        var event_id: ?[*:0]const u8 = undefined;
        var data: ?*c.GVariant = undefined;
        var timestamp: c_uint = undefined;
        while (c.g_variant_iter_next(&iter, "(is@vu)", &id, &event_id, &data, &timestamp) != 0) {
            if (data) |d| c.g_variant_unref(d);
            const event = std.mem.span(event_id orelse continue);
            if (std.mem.eql(u8, event, "clicked")) {
                self.menu.handleEvent(id);
            }
        }
    }
};

// ── Static helpers for building dbusmenu GVariants ───────────

/// Build a menu item GVariant of type (ia{sv}av).
fn buildMenuItem(
    id: i32,
    label: [*:0]const u8,
    enabled: bool,
    visible: bool,
    is_separator: bool,
) ?*c.GVariant {
    _ = is_separator;
    const props = c.g_variant_builder_new(c.g_variant_type_new("a{sv}"));
    defer c.g_variant_builder_unref(props);

    c.g_variant_builder_add(props, "{sv}", @as([*:0]const u8, "label"), c.g_variant_new_string(label));
    c.g_variant_builder_add(props, "{sv}", @as([*:0]const u8, "enabled"), c.g_variant_new_boolean(@intFromBool(enabled)));
    c.g_variant_builder_add(props, "{sv}", @as([*:0]const u8, "visible"), c.g_variant_new_boolean(@intFromBool(visible)));

    const no_children = c.g_variant_builder_new(c.g_variant_type_new("av"));
    defer c.g_variant_builder_unref(no_children);

    return c.g_variant_new("(i@a{sv}@av)",
        @as(c_int, id),
        c.g_variant_builder_end(props),
        c.g_variant_builder_end(no_children),
    );
}

/// Build a separator menu item.
fn buildSeparator(id: i32) ?*c.GVariant {
    const props = c.g_variant_builder_new(c.g_variant_type_new("a{sv}"));
    defer c.g_variant_builder_unref(props);

    c.g_variant_builder_add(props, "{sv}", @as([*:0]const u8, "type"), c.g_variant_new_string("separator"));
    c.g_variant_builder_add(props, "{sv}", @as([*:0]const u8, "visible"), c.g_variant_new_boolean(1));

    const no_children = c.g_variant_builder_new(c.g_variant_type_new("av"));
    defer c.g_variant_builder_unref(no_children);

    return c.g_variant_new("(i@a{sv}@av)",
        @as(c_int, id),
        c.g_variant_builder_end(props),
        c.g_variant_builder_end(no_children),
    );
}
