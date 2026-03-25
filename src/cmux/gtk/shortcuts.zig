//! GTK accelerator sync for cmux keyboard shortcuts.
//!
//! Maps ShortcutAction defaults to GTK accelerator strings and registers
//! them via gtk.Application.setAccelsForAction.

const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");

const shortcut_routing = @import("../shortcut_routing.zig");
const ShortcutAction = shortcut_routing.ShortcutAction;
const StoredShortcut = shortcut_routing.StoredShortcut;
const KeyboardShortcutSettings = shortcut_routing.KeyboardShortcutSettings;

const log = std.log.scoped(.cmux_shortcuts);

/// Convert a StoredShortcut to a GTK accelerator string (e.g., "<Ctrl><Shift>d").
/// Returns null if the shortcut has no key or cannot be converted.
/// Writes into the provided buffer.
pub fn storedShortcutToGtkAccel(buf: *[256]u8, sc: StoredShortcut) ?[:0]const u8 {
    if (sc.isNone()) return null;

    var pos: usize = 0;

    // Build modifier prefix.
    if (sc.control) {
        const tag = "<Ctrl>";
        @memcpy(buf[pos..][0..tag.len], tag);
        pos += tag.len;
    }
    if (sc.shift) {
        const tag = "<Shift>";
        @memcpy(buf[pos..][0..tag.len], tag);
        pos += tag.len;
    }
    if (sc.option) {
        const tag = "<Alt>";
        @memcpy(buf[pos..][0..tag.len], tag);
        pos += tag.len;
    }
    if (sc.command) {
        const tag = "<Super>";
        @memcpy(buf[pos..][0..tag.len], tag);
        pos += tag.len;
    }

    // Append key name.
    const key = sc.key;
    if (pos + key.len >= buf.len) return null;
    @memcpy(buf[pos..][0..key.len], key);
    pos += key.len;

    // Null-terminate.
    buf[pos] = 0;
    return buf[0..pos :0];
}

/// Register GTK accelerators for all cmux ShortcutActions that have both
/// a GTK action name and a non-empty default shortcut.
pub fn syncAccelerators(app: *gtk.Application) void {
    const fields = @typeInfo(ShortcutAction).@"enum".fields;
    inline for (fields) |field| {
        const action = comptime @as(ShortcutAction, @enumFromInt(field.value));

        // Skip numbered actions (handled by EventControllerKey).
        if (comptime action.isNumberedAction()) continue;

        const gtk_action = comptime action.gtkActionName() orelse continue;
        const sc = comptime KeyboardShortcutSettings.getShortcut(action);
        if (comptime sc.isNone()) continue;

        var buf: [256]u8 = undefined;
        if (storedShortcutToGtkAccel(&buf, sc)) |accel| {
            const accels = [_:null]?[*:0]const u8{accel};
            app.setAccelsForAction(gtk_action, &accels);
        }
    }

    log.info("registered cmux keyboard accelerators", .{});
}

// =============================================================================
// Tests
// =============================================================================

test "storedShortcutToGtkAccel: Ctrl+Shift+b" {
    var buf: [256]u8 = undefined;
    const result = storedShortcutToGtkAccel(&buf, .{
        .key = "b",
        .control = true,
        .shift = true,
    });
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("<Ctrl><Shift>b", result.?);
}

test "storedShortcutToGtkAccel: Ctrl+Shift+Alt+d" {
    var buf: [256]u8 = undefined;
    const result = storedShortcutToGtkAccel(&buf, .{
        .key = "d",
        .control = true,
        .shift = true,
        .option = true,
    });
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("<Ctrl><Shift><Alt>d", result.?);
}

test "storedShortcutToGtkAccel: Alt+1" {
    var buf: [256]u8 = undefined;
    const result = storedShortcutToGtkAccel(&buf, .{
        .key = "1",
        .option = true,
    });
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("<Alt>1", result.?);
}

test "storedShortcutToGtkAccel: special key name" {
    var buf: [256]u8 = undefined;
    const result = storedShortcutToGtkAccel(&buf, .{
        .key = "Page_Down",
        .control = true,
        .shift = true,
    });
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("<Ctrl><Shift>Page_Down", result.?);
}

test "storedShortcutToGtkAccel: empty key returns null" {
    var buf: [256]u8 = undefined;
    const result = storedShortcutToGtkAccel(&buf, .{ .key = "" });
    try std.testing.expect(result == null);
}
