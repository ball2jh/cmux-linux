const std = @import("std");
const shortcut = @import("shortcut.zig");

// =============================================================================
// Production types and functions
// =============================================================================

/// A persisted keyboard shortcut.
/// Mirrors Mac's `StoredShortcut`.
pub const StoredShortcut = struct {
    key: []const u8,
    command: bool = false,
    shift: bool = false,
    option: bool = false,
    control: bool = false,

    pub fn modifierFlags(self: StoredShortcut) shortcut.ModifierFlags {
        return .{
            .command = self.command,
            .shift = self.shift,
            .option = self.option,
            .control = self.control,
        };
    }

    /// Returns true if this shortcut has no key binding (empty key).
    pub fn isNone(self: StoredShortcut) bool {
        return self.key.len == 0;
    }
};

/// Actions that can have keyboard shortcuts assigned.
/// Mirrors Mac's `KeyboardShortcutSettings.Action`.
pub const ShortcutAction = enum {
    new_tab,
    new_workspace,
    close_surface,
    close_workspace,
    close_window,
    toggle_sidebar,
    show_notifications,
    rename_tab,
    rename_workspace,
    next_surface,
    previous_surface,
    command_palette,
    command_palette_switcher,
    trigger_flash,
    jump_to_unread,
    open_feedback,
    open_settings,
    focus_address_bar,
    split_right,
    split_down,
    rename,
    find,
    goto_split_left,
    goto_split_down,
    goto_split_up,
    goto_split_right,
    pane_switch_left,
    pane_switch_right,
    open_browser_in_pane,
    zoom_toggle,
    confirm_close,

    /// Human-readable label for this action.
    pub fn label(action: ShortcutAction) []const u8 {
        return switch (action) {
            .new_tab => "New Tab",
            .new_workspace => "New Workspace",
            .close_surface => "Close Surface",
            .close_workspace => "Close Workspace",
            .close_window => "Close Window",
            .toggle_sidebar => "Toggle Sidebar",
            .show_notifications => "Show Notifications",
            .rename_tab => "Rename Tab",
            .rename_workspace => "Rename Workspace",
            .next_surface => "Next Surface",
            .previous_surface => "Previous Surface",
            .command_palette => "Command Palette",
            .command_palette_switcher => "Command Palette Switcher",
            .trigger_flash => "Trigger Flash",
            .jump_to_unread => "Jump to Unread",
            .open_feedback => "Open Feedback",
            .open_settings => "Open Settings",
            .focus_address_bar => "Focus Address Bar",
            .split_right => "Split Right",
            .split_down => "Split Down",
            .rename => "Rename",
            .find => "Find",
            .goto_split_left => "Go to Split Left",
            .goto_split_down => "Go to Split Down",
            .goto_split_up => "Go to Split Up",
            .goto_split_right => "Go to Split Right",
            .pane_switch_left => "Switch Pane Left",
            .pane_switch_right => "Switch Pane Right",
            .open_browser_in_pane => "Open Browser in Pane",
            .zoom_toggle => "Toggle Zoom",
            .confirm_close => "Confirm Close",
        };
    }

    /// Unique defaults/settings key for persisting this action's shortcut.
    pub fn defaultsKey(action: ShortcutAction) []const u8 {
        return switch (action) {
            .new_tab => "shortcut.newTab",
            .new_workspace => "shortcut.newWorkspace",
            .close_surface => "shortcut.closeSurface",
            .close_workspace => "shortcut.closeWorkspace",
            .close_window => "shortcut.closeWindow",
            .toggle_sidebar => "shortcut.toggleSidebar",
            .show_notifications => "shortcut.showNotifications",
            .rename_tab => "shortcut.renameTab",
            .rename_workspace => "shortcut.renameWorkspace",
            .next_surface => "shortcut.nextSurface",
            .previous_surface => "shortcut.previousSurface",
            .command_palette => "shortcut.commandPalette",
            .command_palette_switcher => "shortcut.commandPaletteSwitcher",
            .trigger_flash => "shortcut.triggerFlash",
            .jump_to_unread => "shortcut.jumpToUnread",
            .open_feedback => "shortcut.openFeedback",
            .open_settings => "shortcut.openSettings",
            .focus_address_bar => "shortcut.focusAddressBar",
            .split_right => "shortcut.splitRight",
            .split_down => "shortcut.splitDown",
            .rename => "shortcut.rename",
            .find => "shortcut.find",
            .goto_split_left => "shortcut.gotoSplitLeft",
            .goto_split_down => "shortcut.gotoSplitDown",
            .goto_split_up => "shortcut.gotoSplitUp",
            .goto_split_right => "shortcut.gotoSplitRight",
            .pane_switch_left => "shortcut.paneSwitchLeft",
            .pane_switch_right => "shortcut.paneSwitchRight",
            .open_browser_in_pane => "shortcut.openBrowserInPane",
            .zoom_toggle => "shortcut.zoomToggle",
            .confirm_close => "shortcut.confirmClose",
        };
    }

    /// Return the Linux default shortcut for this action.
    pub fn defaultShortcut(action: ShortcutAction) StoredShortcut {
        return switch (action) {
            .new_tab => .{ .key = "n", .control = true, .shift = true },
            .new_workspace => .{ .key = "n", .control = true, .shift = true },
            .close_surface => .{ .key = "w", .control = true, .shift = true },
            .close_workspace => .{ .key = "w", .control = true, .shift = true, .option = true },
            .close_window => .{ .key = "w", .control = true, .shift = true, .option = true },
            .toggle_sidebar => .{ .key = "b", .control = true },
            .show_notifications => .{ .key = "i", .control = true },
            .rename_tab => .{ .key = "r", .control = true, .shift = true },
            .rename_workspace => .{ .key = "r", .control = true, .shift = true, .option = true },
            .next_surface => .{ .key = "bracketright", .control = true, .shift = true },
            .previous_surface => .{ .key = "bracketleft", .control = true, .shift = true },
            .command_palette => .{ .key = "p", .control = true, .shift = true },
            .command_palette_switcher => .{ .key = "p", .control = true },
            .trigger_flash => .{ .key = "h", .control = true, .shift = true },
            .jump_to_unread => .{ .key = "u", .control = true, .shift = true },
            .open_feedback => .{ .key = "f", .control = true, .option = true },
            .open_settings => .{ .key = "comma", .control = true },
            .focus_address_bar => .{ .key = "l", .control = true },
            .split_right => .{ .key = "d", .control = true },
            .split_down => .{ .key = "d", .control = true, .shift = true },
            .rename => .{ .key = "r", .control = true },
            .find => .{ .key = "f", .control = true },
            .goto_split_left => .{ .key = "h", .control = true, .shift = true, .option = true },
            .goto_split_down => .{ .key = "j", .control = true, .shift = true, .option = true },
            .goto_split_up => .{ .key = "k", .control = true, .shift = true, .option = true },
            .goto_split_right => .{ .key = "l", .control = true, .shift = true, .option = true },
            .pane_switch_left => .{ .key = "Left", .control = true, .option = true },
            .pane_switch_right => .{ .key = "Right", .control = true, .option = true },
            .open_browser_in_pane => .{ .key = "l", .control = true, .shift = true },
            .zoom_toggle => .{ .key = "Return", .control = true, .shift = true },
            .confirm_close => .{ .key = "d", .control = true, .shift = true },
        };
    }

    /// Return the GTK action name for this shortcut action.
    pub fn gtkActionName(action: ShortcutAction) ?[:0]const u8 {
        return switch (action) {
            .new_tab => "win.new-tab",
            .new_workspace => "win.new-workspace",
            .close_surface => "win.close-panel",
            .close_workspace => "win.close-workspace",
            .close_window => "win.close-window",
            .toggle_sidebar => "win.toggle-sidebar",
            .show_notifications => "win.toggle-notifications",
            .rename_tab => "win.rename-tab",
            .rename_workspace => "win.rename-workspace",
            .next_surface => "win.next-surface",
            .previous_surface => "win.prev-surface",
            .command_palette => "win.command-palette-commands",
            .command_palette_switcher => "win.command-palette-switcher",
            .trigger_flash => "win.trigger-flash",
            .jump_to_unread => "win.jump-to-unread",
            .open_feedback => "win.open-feedback",
            .open_settings => "win.open-settings",
            .focus_address_bar => "win.focus-address-bar",
            .split_right => "win.split-right",
            .split_down => "win.split-down",
            .rename => "win.rename",
            .find => "win.find",
            .goto_split_left => "win.goto-split-left",
            .goto_split_down => "win.goto-split-down",
            .goto_split_up => "win.goto-split-up",
            .goto_split_right => "win.goto-split-right",
            .pane_switch_left => "win.pane-switch-left",
            .pane_switch_right => "win.pane-switch-right",
            .open_browser_in_pane => "win.open-browser-in-pane",
            .zoom_toggle => "win.zoom-toggle",
            .confirm_close => "win.confirm-close",
        };
    }

    /// Whether this action is a numbered action (e.g. switch-to-workspace-1..9).
    pub fn isNumberedAction(action: ShortcutAction) bool {
        _ = action;
        return false;
    }
};

/// Keyboard shortcut settings store.
/// Currently returns defaults; will later support user customization via GSettings.
pub const KeyboardShortcutSettings = struct {
    /// Get the shortcut for a given action.
    pub fn getShortcut(action: ShortcutAction) StoredShortcut {
        return action.defaultShortcut();
    }

    /// Set the shortcut for a given action.
    pub fn setShortcut(_shortcut_value: StoredShortcut, _action: ShortcutAction) void {
        _ = _shortcut_value;
        _ = _action;
    }

    /// Reset the shortcut for a given action to its default.
    pub fn resetShortcut(_action: ShortcutAction) void {
        _ = _action;
    }

    /// Reset all shortcuts to their defaults.
    pub fn resetAll() void {}
};

// ---------------------------------------------------------------------------
// macOS ANSI keycode constants (for test fidelity with Mac)
// ---------------------------------------------------------------------------

pub const kVK_ANSI_N: u16 = 45;
pub const kVK_ANSI_T: u16 = 17;
pub const kVK_ANSI_D: u16 = 2;
pub const kVK_ANSI_W: u16 = 13;
pub const kVK_ANSI_P: u16 = 35;
pub const kVK_ANSI_R: u16 = 15;
pub const kVK_ANSI_I: u16 = 34;
pub const kVK_ANSI_O: u16 = 31;
pub const kVK_ANSI_M: u16 = 46;
pub const kVK_ANSI_F: u16 = 3;
pub const kVK_ANSI_1: u16 = 18;
pub const kVK_ANSI_8: u16 = 28;
pub const kVK_ANSI_Slash: u16 = 44;
pub const kVK_ANSI_RightBracket: u16 = 30;
pub const kVK_ISO_Section: u16 = 10;
pub const kVK_Escape: u16 = 53;

// ---------------------------------------------------------------------------
// Shortcut character matching
// ---------------------------------------------------------------------------

pub fn eventMatchesShortcut(
    event_chars: []const u8,
    event_key_code: u16,
    event_flags: shortcut.ModifierFlags,
    target: StoredShortcut,
    layout_provider: ?shortcut.LayoutCharacterProvider,
) bool {
    const event_mods = shortcut.ModifierFlags{
        .command = event_flags.command,
        .control = event_flags.control,
        .shift = event_flags.shift,
        .option = event_flags.option,
        .caps_lock = false,
    };
    const target_mods = shortcut.ModifierFlags{
        .command = target.command,
        .control = target.control,
        .shift = target.shift,
        .option = target.option,
        .caps_lock = false,
    };
    if (!event_mods.eql(target_mods)) return false;

    const target_key = target.key;
    if (target_key.len != 1) return false;
    const target_ch = target_key[0];

    if (event_chars.len == 1) {
        const ch = event_chars[0];
        if (std.ascii.toLower(ch) == std.ascii.toLower(target_ch)) return true;

        if (target.shift and isDigit(target_ch)) {
            if (isDigitKeyCode(event_key_code) and
                digitForKeyCode(event_key_code) == target_ch)
            {
                return true;
            }
            return false;
        }

        if (target.shift and target_ch == '/') {
            if (event_key_code == kVK_ANSI_Slash) return true;
        }

        if (ch >= 0x20) {
            if (isDigit(target_ch) and isDigitKeyCode(event_key_code) and
                digitForKeyCode(event_key_code) == target_ch)
            {
                return true;
            }
            if (target_ch == ']' and event_key_code == kVK_ANSI_RightBracket) return true;
            if (target_ch == '[' and event_key_code == 33) return true;

            return false;
        }
    }

    if (layout_provider) |provider| {
        if (provider(event_key_code, .{ .command = true })) |lch| {
            return std.ascii.toLower(lch) == std.ascii.toLower(target_ch);
        }
        if (provider(event_key_code, .{})) |lch| {
            return std.ascii.toLower(lch) == std.ascii.toLower(target_ch);
        }
    }

    if (isDigit(target_ch) and isDigitKeyCode(event_key_code)) {
        return digitForKeyCode(event_key_code) == target_ch;
    }
    if (target_ch == ']' and event_key_code == kVK_ANSI_RightBracket) return true;
    if (target_ch == '[' and event_key_code == 33) return true;

    return false;
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn isDigitKeyCode(kc: u16) bool {
    return digitForKeyCode(kc) != 0;
}

fn digitForKeyCode(kc: u16) u8 {
    return switch (kc) {
        29 => '0',
        18 => '1',
        19 => '2',
        20 => '3',
        21 => '4',
        23 => '5',
        22 => '6',
        26 => '7',
        28 => '8',
        25 => '9',
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// Workspace presentation mode settings
// ---------------------------------------------------------------------------

pub const WorkspacePresentationMode = enum {
    standard,
    minimal,
};

pub const WorkspacePresentationModeSettings = struct {
    pub fn mode(stored_mode: ?[]const u8) WorkspacePresentationMode {
        if (stored_mode) |m| {
            if (std.mem.eql(u8, m, "minimal")) return .minimal;
            return .standard;
        }
        return .standard;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ShortcutRouting: Cmd+physical-I with Dvorak chars does not trigger show notifications" {
    const show_notif = StoredShortcut{ .key = "i", .command = true };
    const result = eventMatchesShortcut("c", kVK_ANSI_I, .{ .command = true }, show_notif, null);
    try std.testing.expect(!result);
}

test "ShortcutRouting: Cmd+P with caps lock still triggers command palette switcher" {
    const palette = StoredShortcut{ .key = "p", .command = true };
    const result = eventMatchesShortcut("p", kVK_ANSI_P, .{ .command = true, .caps_lock = true }, palette, null);
    try std.testing.expect(result);
}

test "ShortcutRouting: Cmd+Shift+P requests command palette commands" {
    const palette = StoredShortcut{ .key = "p", .command = true, .shift = true };
    const result = eventMatchesShortcut("P", kVK_ANSI_P, .{ .command = true, .shift = true }, palette, null);
    try std.testing.expect(result);
}

test "ShortcutRouting: workspace minimal mode defaults to standard presentation" {
    const mode_val = WorkspacePresentationModeSettings.mode(null);
    try std.testing.expectEqual(WorkspacePresentationMode.standard, mode_val);
}

test "ShortcutRouting: toggle sidebar default shortcut uses Ctrl+B" {
    const s = ShortcutAction.toggle_sidebar.defaultShortcut();
    try std.testing.expectEqualStrings("b", s.key);
    try std.testing.expect(s.control);
    try std.testing.expect(!s.shift);
}

test "ShortcutRouting: command palette switcher default shortcut" {
    const s = ShortcutAction.command_palette_switcher.defaultShortcut();
    try std.testing.expectEqualStrings("p", s.key);
    try std.testing.expect(s.control);
    try std.testing.expect(!s.shift);
}

test "ShortcutRouting: defaults keys are unique across all actions" {
    const all_actions = comptime std.enums.values(ShortcutAction);
    comptime {
        for (all_actions, 0..) |a, i| {
            for (all_actions[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.defaultsKey(), b.defaultsKey())) {
                    @compileError("Duplicate defaultsKey found: " ++ a.defaultsKey());
                }
            }
        }
    }
    inline for (all_actions) |action| {
        try std.testing.expect(action.defaultsKey().len > 0);
    }
}

test "ShortcutRouting: all actions have non-empty labels" {
    const all_actions = comptime std.enums.values(ShortcutAction);
    inline for (all_actions) |action| {
        try std.testing.expect(action.label().len > 0);
    }
}

test "ShortcutRouting: all actions have non-empty default shortcut key" {
    const all_actions = comptime std.enums.values(ShortcutAction);
    inline for (all_actions) |action| {
        try std.testing.expect(action.defaultShortcut().key.len > 0);
    }
}

test "ShortcutRouting: StoredShortcut.isNone returns true for empty key" {
    const empty = StoredShortcut{ .key = "" };
    try std.testing.expect(empty.isNone());
    const non_empty = StoredShortcut{ .key = "a", .control = true };
    try std.testing.expect(!non_empty.isNone());
}

test "ShortcutRouting: KeyboardShortcutSettings.getShortcut returns defaults" {
    const s = KeyboardShortcutSettings.getShortcut(.toggle_sidebar);
    try std.testing.expectEqualStrings("b", s.key);
    try std.testing.expect(s.control);
    try std.testing.expect(!s.shift);
}

test "ShortcutRouting: gtkActionName maps actions to win-scoped names" {
    try std.testing.expectEqualStrings("win.new-workspace", ShortcutAction.new_workspace.gtkActionName().?);
    try std.testing.expectEqualStrings("win.close-panel", ShortcutAction.close_surface.gtkActionName().?);
    try std.testing.expectEqualStrings("win.goto-split-left", ShortcutAction.goto_split_left.gtkActionName().?);
}
