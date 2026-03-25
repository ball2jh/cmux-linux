//! GSettings-backed preferences for cmux.
//!
//! Mirrors macOS UserDefaults/AppStorage. Each preference has a typed getter
//! and setter, backed by the `com.cmuxterm.app` GSettings schema.

const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const shortcut_routing = @import("shortcut_routing.zig");
const shortcut = @import("shortcut.zig");

const log = std.log.scoped(.cmux_settings);

const Settings = @This();

const schema_id = "com.cmuxterm.app";

/// The underlying GSettings instance, or null if schema unavailable.
gsettings: *gio.Settings,

// -------------------------------------------------------------------------
// Enum types for enum-valued settings
// -------------------------------------------------------------------------

pub const WorkspacePlacement = enum {
    top,
    after_current,
    end,

    fn toGSettings(self: WorkspacePlacement) [*:0]const u8 {
        return switch (self) {
            .top => "top",
            .after_current => "after-current",
            .end => "end",
        };
    }

    fn fromGSettings(val: []const u8) WorkspacePlacement {
        if (std.mem.eql(u8, val, "top")) return .top;
        if (std.mem.eql(u8, val, "end")) return .end;
        return .after_current;
    }
};

pub const SidebarIndicatorStyle = enum {
    left_rail,
    solid_fill,

    fn toGSettings(self: SidebarIndicatorStyle) [*:0]const u8 {
        return switch (self) {
            .left_rail => "left-rail",
            .solid_fill => "solid-fill",
        };
    }

    fn fromGSettings(val: []const u8) SidebarIndicatorStyle {
        if (std.mem.eql(u8, val, "solid-fill")) return .solid_fill;
        return .left_rail;
    }
};

pub const PresentationMode = enum {
    standard,
    minimal,

    fn toGSettings(self: PresentationMode) [*:0]const u8 {
        return switch (self) {
            .standard => "standard",
            .minimal => "minimal",
        };
    }

    fn fromGSettings(val: []const u8) PresentationMode {
        if (std.mem.eql(u8, val, "minimal")) return .minimal;
        return .standard;
    }
};

pub const ButtonsFadeMode = enum {
    enabled,
    disabled,

    fn toGSettings(self: ButtonsFadeMode) [*:0]const u8 {
        return switch (self) {
            .enabled => "enabled",
            .disabled => "disabled",
        };
    }

    fn fromGSettings(val: []const u8) ButtonsFadeMode {
        if (std.mem.eql(u8, val, "enabled")) return .enabled;
        return .disabled;
    }
};

pub const SocketControlMode = enum {
    off,
    cmux_only,
    automation,
    password,
    allow_all,

    fn toGSettings(self: SocketControlMode) [*:0]const u8 {
        return switch (self) {
            .off => "off",
            .cmux_only => "cmux-only",
            .automation => "automation",
            .password => "password",
            .allow_all => "allow-all",
        };
    }

    fn fromGSettings(val: []const u8) SocketControlMode {
        if (std.mem.eql(u8, val, "off")) return .off;
        if (std.mem.eql(u8, val, "automation")) return .automation;
        if (std.mem.eql(u8, val, "password")) return .password;
        if (std.mem.eql(u8, val, "allow-all")) return .allow_all;
        return .cmux_only;
    }
};

pub const BrowserThemeMode = enum {
    system,
    light,
    dark,

    fn toGSettings(self: BrowserThemeMode) [*:0]const u8 {
        return switch (self) {
            .system => "system",
            .light => "light",
            .dark => "dark",
        };
    }

    fn fromGSettings(val: []const u8) BrowserThemeMode {
        if (std.mem.eql(u8, val, "light")) return .light;
        if (std.mem.eql(u8, val, "dark")) return .dark;
        return .system;
    }
};

/// Re-export for convenience.
pub const AppearanceMode = shortcut.AppearanceMode;

// -------------------------------------------------------------------------
// Initialization
// -------------------------------------------------------------------------

/// Initialize a Settings instance. Tries to find the schema in:
///   1. Standard system schema directories
///   2. Build output directory (for development)
/// Returns null if the schema cannot be found.
pub fn init() ?Settings {
    // First, try loading from standard schema source.
    const default_source = gio.SettingsSchemaSource.getDefault() orelse {
        log.warn("no GSettings schema source available", .{});
        return tryDevSchema();
    };

    if (default_source.lookup(schema_id, 1)) |_| {
        return .{ .gsettings = gio.Settings.new(schema_id) };
    }

    log.info("schema '{s}' not found in system dirs, trying dev path", .{schema_id});
    return tryDevSchema();
}

/// Try to load schema from development build output directory.
fn tryDevSchema() ?Settings {
    // Look for schemas relative to the executable path.
    const exe_dir = getExeDir() orelse return null;
    defer std.heap.c_allocator.free(exe_dir);

    // Try: <exe_dir>/../share/glib-2.0/schemas/
    const schemas_dir = std.fs.path.join(std.heap.c_allocator, &.{
        exe_dir, "..", "share", "glib-2.0", "schemas",
    }) catch return null;
    defer std.heap.c_allocator.free(schemas_dir);

    const schemas_dir_z = std.heap.c_allocator.dupeZ(u8, schemas_dir) catch return null;
    defer std.heap.c_allocator.free(schemas_dir_z);

    const default_source = gio.SettingsSchemaSource.getDefault();

    var err: ?*glib.Error = null;
    const source = gio.SettingsSchemaSource.newFromDirectory(
        schemas_dir_z,
        default_source,
        0, // not trusted
        &err,
    ) orelse {
        if (err) |e| {
            if (e.f_message) |msg| {
                log.info("dev schema dir not available: {s}", .{std.mem.span(msg)});
            }
            e.free();
        }
        return null;
    };

    const found_schema = source.lookup(schema_id, 0) orelse {
        log.warn("schema '{s}' not found in dev dir: {s}", .{ schema_id, schemas_dir });
        return null;
    };

    const gs = gio.Settings.newFull(found_schema, null, null);
    log.info("loaded settings from dev schema dir: {s}", .{schemas_dir});
    return .{ .gsettings = gs };
}

fn getExeDir() ?[]const u8 {
    const exe_path = std.fs.selfExePathAlloc(std.heap.c_allocator) catch return null;
    defer std.heap.c_allocator.free(exe_path);
    const dir = std.fs.path.dirname(exe_path) orelse return null;
    return std.heap.c_allocator.dupe(u8, dir) catch null;
}

// -------------------------------------------------------------------------
// Boolean getters/setters
// -------------------------------------------------------------------------

pub fn getBool(self: *const Settings, comptime key: BoolKey) bool {
    return self.gsettings.getBoolean(key.name()) != 0;
}

pub fn setBool(self: *const Settings, comptime key: BoolKey, value: bool) void {
    _ = self.gsettings.setBoolean(key.name(), if (value) 1 else 0);
}

pub const BoolKey = enum {
    @"workspace-auto-reorder-on-notification",
    @"close-workspace-on-last-surface-shortcut",
    @"sidebar-branch-vertical-layout",
    @"sidebar-hide-all-details",
    @"sidebar-show-notification-message",
    @"workspace-titlebar-visible",
    @"pane-first-click-focus-enabled",
    @"warn-before-quit-shortcut",
    @"command-palette-rename-select-all-on-focus",
    @"command-palette-switcher-search-all-surfaces",
    @"notification-dock-badge-enabled",
    @"notification-pane-ring-enabled",
    @"notification-pane-flash-enabled",
    @"browser-search-suggestions-enabled",
    @"browser-open-terminal-links-in-cmux-browser",
    @"send-anonymous-telemetry",

    fn name(comptime self: BoolKey) [*:0]const u8 {
        return @tagName(self);
    }
};

// -------------------------------------------------------------------------
// String getters/setters
// -------------------------------------------------------------------------

pub fn getString(self: *const Settings, comptime key: StringKey) [:0]const u8 {
    const raw: [*:0]const u8 = self.gsettings.getString(key.name());
    return std.mem.span(raw);
}

pub fn setString(self: *const Settings, comptime key: StringKey, value: [*:0]const u8) void {
    _ = self.gsettings.setString(key.name(), value);
}

pub const StringKey = enum {
    @"browser-search-engine",

    fn name(comptime self: StringKey) [*:0]const u8 {
        return @tagName(self);
    }
};

// -------------------------------------------------------------------------
// Enum-like string getters/setters
// -------------------------------------------------------------------------

pub fn getWorkspacePlacement(self: *const Settings) WorkspacePlacement {
    return WorkspacePlacement.fromGSettings(self.getString_(.@"new-workspace-placement"));
}

pub fn setWorkspacePlacement(self: *const Settings, val: WorkspacePlacement) void {
    _ = self.gsettings.setString("new-workspace-placement", val.toGSettings());
}

pub fn getSidebarIndicatorStyle(self: *const Settings) SidebarIndicatorStyle {
    return SidebarIndicatorStyle.fromGSettings(self.getString_(.@"sidebar-active-tab-indicator-style"));
}

pub fn setSidebarIndicatorStyle(self: *const Settings, val: SidebarIndicatorStyle) void {
    _ = self.gsettings.setString("sidebar-active-tab-indicator-style", val.toGSettings());
}

pub fn getPresentationMode(self: *const Settings) PresentationMode {
    return PresentationMode.fromGSettings(self.getString_(.@"workspace-presentation-mode"));
}

pub fn setPresentationMode(self: *const Settings, val: PresentationMode) void {
    _ = self.gsettings.setString("workspace-presentation-mode", val.toGSettings());
}

pub fn getButtonsFadeMode(self: *const Settings) ButtonsFadeMode {
    return ButtonsFadeMode.fromGSettings(self.getString_(.@"workspace-buttons-fade-mode"));
}

pub fn setButtonsFadeMode(self: *const Settings, val: ButtonsFadeMode) void {
    _ = self.gsettings.setString("workspace-buttons-fade-mode", val.toGSettings());
}

pub fn getSocketControlMode(self: *const Settings) SocketControlMode {
    return SocketControlMode.fromGSettings(self.getString_(.@"socket-control-mode"));
}

pub fn setSocketControlMode(self: *const Settings, val: SocketControlMode) void {
    _ = self.gsettings.setString("socket-control-mode", val.toGSettings());
}

pub fn getAppearanceMode(self: *const Settings) AppearanceMode {
    const val = self.getString_(.@"appearance-mode");
    if (std.mem.eql(u8, val, "light")) return .light;
    if (std.mem.eql(u8, val, "dark")) return .dark;
    return .system;
}

pub fn setAppearanceMode(self: *const Settings, val: AppearanceMode) void {
    _ = self.gsettings.setString("appearance-mode", switch (val) {
        .system => "system",
        .light => "light",
        .dark => "dark",
    });
}

pub fn getBrowserThemeMode(self: *const Settings) BrowserThemeMode {
    return BrowserThemeMode.fromGSettings(self.getString_(.@"browser-theme-mode"));
}

pub fn setBrowserThemeMode(self: *const Settings, val: BrowserThemeMode) void {
    _ = self.gsettings.setString("browser-theme-mode", val.toGSettings());
}

/// Internal: get raw string for enum-like keys.
const EnumStringKey = enum {
    @"new-workspace-placement",
    @"sidebar-active-tab-indicator-style",
    @"workspace-presentation-mode",
    @"workspace-buttons-fade-mode",
    @"socket-control-mode",
    @"appearance-mode",
    @"browser-theme-mode",
};

fn getString_(self: *const Settings, comptime key: EnumStringKey) []const u8 {
    const raw: [*:0]const u8 = self.gsettings.getString(@tagName(key));
    return std.mem.span(raw);
}

// -------------------------------------------------------------------------
// Keyboard shortcut helpers
// -------------------------------------------------------------------------

/// Get the stored shortcut for a given action.
/// Falls back to the default if the stored value is the schema default
/// (which matches the hardcoded default anyway).
pub fn getShortcut(self: *const Settings, action: shortcut_routing.ShortcutAction) shortcut_routing.StoredShortcut {
    const key_name = shortcutKeyName(action) orelse return action.defaultShortcut();
    const accel: [*:0]const u8 = self.gsettings.getString(key_name);
    const accel_slice = std.mem.span(accel);

    if (accel_slice.len == 0) {
        return .{ .key = "" };
    }

    return fromGtkAccelerator(accel_slice) orelse action.defaultShortcut();
}

/// Set the shortcut for a given action.
pub fn setShortcut(self: *const Settings, action: shortcut_routing.ShortcutAction, sc: shortcut_routing.StoredShortcut) void {
    const key_name = shortcutKeyName(action) orelse return;
    var buf: [128]u8 = undefined;
    const accel = toGtkAccelerator(sc, &buf);
    _ = self.gsettings.setString(key_name, accel.ptr);
}

/// Reset a shortcut to its default value.
pub fn resetShortcut(self: *const Settings, action: shortcut_routing.ShortcutAction) void {
    const key_name = shortcutKeyName(action) orelse return;
    self.gsettings.reset(key_name);
}

/// Reset all settings to defaults.
pub fn resetAll(self: *const Settings) void {
    // Reset all boolean keys.
    inline for (std.meta.fields(BoolKey)) |field| {
        self.gsettings.reset(field.name);
    }
    // Reset all string keys.
    inline for (std.meta.fields(StringKey)) |field| {
        self.gsettings.reset(field.name);
    }
    // Reset all enum-string keys.
    inline for (std.meta.fields(EnumStringKey)) |field| {
        self.gsettings.reset(field.name);
    }
    // Reset all shortcut keys.
    const actions = std.meta.tags(shortcut_routing.ShortcutAction);
    for (actions) |action| {
        if (shortcutKeyName(action)) |key| {
            self.gsettings.reset(key);
        }
    }
}

// -------------------------------------------------------------------------
// Change notification
// -------------------------------------------------------------------------

/// Connect to the GSettings "changed" signal for a specific key.
/// The callback receives the settings instance and the key name that changed.
pub fn connectChanged(
    self: *const Settings,
    comptime detail: []const u8,
    comptime T: type,
    callback: *const fn (*gio.Settings, [*:0]u8, T) callconv(.c) void,
    user_data: T,
) void {
    _ = gio.Settings.signals.changed.connect(
        self.gsettings,
        T,
        callback,
        user_data,
        .{ .detail = detail },
    );
}

// -------------------------------------------------------------------------
// Shortcut key name mapping
// -------------------------------------------------------------------------

/// Map a ShortcutAction to its GSettings key name.
fn shortcutKeyName(action: shortcut_routing.ShortcutAction) ?[*:0]const u8 {
    return switch (action) {
        .new_tab, .new_workspace => "shortcut-new-tab",
        .close_surface, .close_workspace => "shortcut-close-workspace",
        .close_window => "shortcut-close-window",
        .toggle_sidebar => "shortcut-toggle-sidebar",
        .show_notifications => "shortcut-show-notifications",
        .rename_tab => "shortcut-rename-tab",
        .rename_workspace => "shortcut-rename-workspace",
        .next_surface => "shortcut-next-surface",
        .previous_surface => "shortcut-previous-surface",
        .command_palette => "shortcut-command-palette",
        .command_palette_switcher => "shortcut-command-palette-switcher",
        .trigger_flash => "shortcut-trigger-flash",
        // Actions without GSettings keys use built-in defaults.
        else => null,
    };
}

// -------------------------------------------------------------------------
// GTK accelerator conversion
// -------------------------------------------------------------------------

/// Convert a StoredShortcut to GTK accelerator format.
/// Returns a null-terminated slice into the provided buffer.
pub fn toGtkAccelerator(sc: shortcut_routing.StoredShortcut, buf: []u8) [:0]const u8 {
    if (sc.isNone()) {
        buf[0] = 0;
        return buf[0..0 :0];
    }

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    if (sc.control) writer.writeAll("<Control>") catch {};
    if (sc.shift) writer.writeAll("<Shift>") catch {};
    if (sc.option) writer.writeAll("<Alt>") catch {};
    if (sc.command) writer.writeAll("<Super>") catch {};
    writer.writeAll(sc.key) catch {};

    const pos = stream.pos;
    if (pos < buf.len) {
        buf[pos] = 0;
        return buf[0..pos :0];
    }
    // Overflow: return empty.
    buf[0] = 0;
    return buf[0..0 :0];
}

/// Parse a GTK accelerator string into a StoredShortcut.
/// Returns null if the format is unrecognizable.
pub fn fromGtkAccelerator(accel: []const u8) ?shortcut_routing.StoredShortcut {
    var sc = shortcut_routing.StoredShortcut{
        .key = "",
        .command = false,
        .shift = false,
        .option = false,
        .control = false,
    };

    var remaining = accel;
    while (remaining.len > 0) {
        if (std.mem.startsWith(u8, remaining, "<Control>")) {
            sc.control = true;
            remaining = remaining["<Control>".len..];
        } else if (std.mem.startsWith(u8, remaining, "<Shift>")) {
            sc.shift = true;
            remaining = remaining["<Shift>".len..];
        } else if (std.mem.startsWith(u8, remaining, "<Alt>")) {
            sc.option = true;
            remaining = remaining["<Alt>".len..];
        } else if (std.mem.startsWith(u8, remaining, "<Super>")) {
            sc.command = true;
            remaining = remaining["<Super>".len..];
        } else {
            // Everything left is the key name.
            sc.key = remaining;
            break;
        }
    }

    return sc;
}


// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "toGtkAccelerator basic" {
    var buf: [128]u8 = undefined;

    const sc1 = shortcut_routing.StoredShortcut{
        .key = "b",
        .control = true,
        .shift = true,
    };
    const accel1 = toGtkAccelerator(sc1, &buf);
    try std.testing.expectEqualStrings("<Control><Shift>b", accel1);
}

test "toGtkAccelerator with alt" {
    var buf: [128]u8 = undefined;

    const sc = shortcut_routing.StoredShortcut{
        .key = "n",
        .control = true,
        .shift = true,
        .option = true,
    };
    const accel = toGtkAccelerator(sc, &buf);
    try std.testing.expectEqualStrings("<Control><Shift><Alt>n", accel);
}

test "toGtkAccelerator empty" {
    var buf: [128]u8 = undefined;

    const sc = shortcut_routing.StoredShortcut{ .key = "" };
    const accel = toGtkAccelerator(sc, &buf);
    try std.testing.expectEqualStrings("", accel);
}

test "fromGtkAccelerator basic" {
    const sc = fromGtkAccelerator("<Control><Shift>b").?;
    try std.testing.expect(sc.control);
    try std.testing.expect(sc.shift);
    try std.testing.expect(!sc.option);
    try std.testing.expect(!sc.command);
    try std.testing.expectEqualStrings("b", sc.key);
}

test "fromGtkAccelerator with alt" {
    const sc = fromGtkAccelerator("<Control><Shift><Alt>Left").?;
    try std.testing.expect(sc.control);
    try std.testing.expect(sc.shift);
    try std.testing.expect(sc.option);
    try std.testing.expectEqualStrings("Left", sc.key);
}

test "fromGtkAccelerator roundtrip" {
    const original = shortcut_routing.StoredShortcut{
        .key = "Page_Down",
        .control = true,
        .shift = true,
    };

    var buf: [128]u8 = undefined;
    const accel = toGtkAccelerator(original, &buf);
    const parsed = fromGtkAccelerator(accel).?;

    try std.testing.expectEqualStrings(original.key, parsed.key);
    try std.testing.expectEqual(original.control, parsed.control);
    try std.testing.expectEqual(original.shift, parsed.shift);
    try std.testing.expectEqual(original.option, parsed.option);
    try std.testing.expectEqual(original.command, parsed.command);
}

