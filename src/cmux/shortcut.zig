const std = @import("std");

// =============================================================================
// Production types and functions (TODO: implement to match Mac's shortcut and
// command palette behavior helpers)
// =============================================================================

/// Modifier flags, mirroring the relevant subset of GDK/macOS modifier flags.
pub const ModifierFlags = packed struct {
    command: bool = false, // Super on Linux
    control: bool = false,
    shift: bool = false,
    option: bool = false, // Alt on Linux
    caps_lock: bool = false,

    pub fn eql(a: ModifierFlags, b: ModifierFlags) bool {
        return a.command == b.command and
            a.control == b.control and
            a.shift == b.shift and
            a.option == b.option and
            a.caps_lock == b.caps_lock;
    }
};

// ---------------------------------------------------------------------------
// Split shortcut transient focus guard
// ---------------------------------------------------------------------------

/// Whether a split shortcut should be suppressed when the focus target is in
/// a transient state (first responder fell back to the window, hosted view is
/// tiny or detached).
/// Mirrors Mac's `shouldSuppressSplitShortcutForTransientTerminalFocusInputs`.
pub fn shouldSuppressSplitShortcutForTransientFocus(
    first_responder_is_window: bool,
    hosted_width: f64,
    hosted_height: f64,
    hosted_hidden_in_hierarchy: bool,
    hosted_attached_to_window: bool,
) bool {
    _ = hosted_hidden_in_hierarchy;
    if (!first_responder_is_window) return false;
    const is_tiny = hosted_width < 80 or hosted_height < 1;
    if (is_tiny) return true;
    if (!hosted_attached_to_window) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Full screen shortcut matching
// ---------------------------------------------------------------------------

/// Layout character provider callback — given a hardware keycode and modifier
/// flags, returns the character the layout produces, or null.
pub const LayoutCharacterProvider = *const fn (key_code: u16, flags: ModifierFlags) ?u8;

fn defaultLayoutCharacterProvider(_key_code: u16, _flags: ModifierFlags) ?u8 {
    _ = _key_code;
    _ = _flags;
    return null;
}

/// Whether this key event should toggle fullscreen (Cmd+Ctrl+F).
/// Mirrors Mac's `shouldToggleMainWindowFullScreenForCommandControlFShortcut`.
pub fn shouldToggleFullScreenForCommandControlF(
    flags: ModifierFlags,
    chars: []const u8,
    key_code: u16,
    layout_provider: ?LayoutCharacterProvider,
) bool {
    // Require exactly command + control, nothing else (capslock is ignored).
    const normalized = ModifierFlags{
        .command = flags.command,
        .control = flags.control,
        .shift = flags.shift,
        .option = flags.option,
        .caps_lock = false,
    };
    const required = ModifierFlags{ .command = true, .control = true };
    if (!normalized.eql(required)) return false;

    // Try character match first.
    if (chars.len == 1) {
        if (chars[0] == 'f' or chars[0] == 'F') return true;
        // If it's a printable non-f character, reject — layout produced a different key.
        if (chars[0] >= 0x20) return false;
    }

    // Character is a control sequence or empty — try layout translation.
    const provider = layout_provider orelse &defaultLayoutCharacterProvider;
    // Try with command modifier for command-aware layouts.
    if (provider(key_code, .{ .command = true })) |ch| {
        return ch == 'f' or ch == 'F';
    }
    // Try without modifiers.
    if (provider(key_code, .{})) |ch| {
        return ch == 'f' or ch == 'F';
    }

    // Last resort: ANSI keycode fallback (keyCode 3 = kVK_ANSI_F on Mac).
    return key_code == 3;
}

// ---------------------------------------------------------------------------
// Command palette keyboard navigation
// ---------------------------------------------------------------------------

/// Return the selection delta for a keyboard navigation event in the command
/// palette, or null if the event is not a recognized navigation key.
/// Mirrors Mac's `commandPaletteSelectionDeltaForKeyboardNavigation`.
pub fn commandPaletteSelectionDelta(
    flags: ModifierFlags,
    chars: []const u8,
    key_code: u16,
) ?i32 {
    const normalized = ModifierFlags{
        .command = flags.command,
        .control = flags.control,
        .shift = flags.shift,
        .option = flags.option,
        .caps_lock = false,
    };

    // Plain arrow keys (no modifiers).
    const no_mods = ModifierFlags{};
    if (normalized.eql(no_mods)) {
        if (key_code == 125) return 1; // Down arrow
        if (key_code == 126) return -1; // Up arrow
    }

    // Control+letter navigation.
    const ctrl_only = ModifierFlags{ .control = true };
    if (normalized.eql(ctrl_only)) {
        // Accept both printable character and control character form.
        const ch: u8 = if (chars.len == 1) chars[0] else 0;
        // Ctrl+N / Ctrl+J = down.
        if (key_code == 45 and (ch == 'n' or ch == 0x0e)) return 1;
        if (key_code == 38 and (ch == 'j' or ch == 0x0a)) return 1;
        // Ctrl+P / Ctrl+K = up.
        if (key_code == 35 and (ch == 'p' or ch == 0x10)) return -1;
        if (key_code == 40 and (ch == 'k' or ch == 0x0b)) return -1;
    }

    return null;
}

// ---------------------------------------------------------------------------
// Command palette shortcut consumption
// ---------------------------------------------------------------------------

// macOS keycodes for reference.
const kVK_LeftArrow: u16 = 123;
const kVK_RightArrow: u16 = 124;
const kVK_DownArrow: u16 = 125;
const kVK_UpArrow: u16 = 126;
const kVK_Delete: u16 = 51;
const kVK_ForwardDelete: u16 = 117;
const kVK_Escape: u16 = 53;

/// Whether a shortcut should be consumed (suppressed) while the command palette
/// is visible.
/// Mirrors Mac's `shouldConsumeShortcutWhileCommandPaletteVisible`.
pub fn shouldConsumeShortcutWhileCommandPaletteVisible(
    is_visible: bool,
    flags: ModifierFlags,
    chars: []const u8,
    key_code: u16,
) bool {
    if (!is_visible) return false;

    // Escape is always consumed.
    if (key_code == kVK_Escape) return true;

    const has_command = flags.command;

    // Allow clipboard and undo shortcuts for text editing inside the palette.
    if (has_command) {
        const ch: u8 = if (chars.len == 1) chars[0] else 0;
        // Cmd+C, Cmd+V, Cmd+X, Cmd+A, Cmd+Z, Cmd+Shift+Z — allow through.
        if (ch == 'v' or ch == 'V') return false;
        if (ch == 'c' or ch == 'C') return false;
        if (ch == 'x' or ch == 'X') return false;
        if (ch == 'a' or ch == 'A') return false;
        if (ch == 'z' or ch == 'Z') return false;

        // Allow arrow keys and delete with command (text editing).
        if (key_code == kVK_LeftArrow or key_code == kVK_RightArrow or
            key_code == kVK_UpArrow or key_code == kVK_DownArrow or
            key_code == kVK_Delete or key_code == kVK_ForwardDelete)
        {
            return false;
        }
    }

    // All other command-modified shortcuts are consumed.
    if (has_command) return true;

    return false;
}

// ---------------------------------------------------------------------------
// Browser address bar restore focus
// ---------------------------------------------------------------------------

/// Whether the browser address bar focus should be restored after command
/// palette dismiss.
/// Mirrors Mac's `ContentView.shouldRestoreBrowserAddressBarAfterCommandPaletteDismiss`.
pub fn shouldRestoreBrowserAddressBarAfterDismiss(
    focused_panel_is_browser: bool,
    focused_browser_address_bar_panel_id: ?u128,
    focused_panel_id: ?u128,
) bool {
    if (!focused_panel_is_browser) return false;
    if (focused_browser_address_bar_panel_id == null or focused_panel_id == null) return false;
    return focused_browser_address_bar_panel_id.? == focused_panel_id.?;
}

// ---------------------------------------------------------------------------
// Rename selection settings
// ---------------------------------------------------------------------------

/// Whether the rename palette should select-all on focus (defaults to true).
/// Mirrors Mac's `CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled`.
pub fn renameSelectAllOnFocusEnabled(stored_value: ?bool) bool {
    return stored_value orelse true;
}

// ---------------------------------------------------------------------------
// Shortcut hint modifier policy
// ---------------------------------------------------------------------------

pub const ShortcutHintModifierPolicy = struct {
    pub const intentional_hold_delay: f64 = 0.30;

    /// Whether shortcut hints should be shown for the given modifier flags.
    /// Mirrors Mac's `ShortcutHintModifierPolicy.shouldShowHints`.
    pub fn shouldShowHints(
        flags: ModifierFlags,
        show_on_command_hold_enabled: ?bool,
    ) bool {
        const enabled = show_on_command_hold_enabled orelse true;
        if (!enabled) return false;
        // Require exactly command, nothing else.
        return flags.command and
            !flags.control and
            !flags.shift and
            !flags.option;
    }

    /// Whether the given window is the current window for hint display purposes.
    /// Mirrors Mac's `ShortcutHintModifierPolicy.isCurrentWindow`.
    pub fn isCurrentWindow(
        host_window_number: i32,
        host_window_is_key: bool,
        event_window_number: i32,
        _key_window_number: i32,
    ) bool {
        _ = _key_window_number;
        if (!host_window_is_key) return false;
        return host_window_number == event_window_number;
    }

    /// Window-scoped hint display, falling back to key window when no event window.
    /// Mirrors the overload of `ShortcutHintModifierPolicy.shouldShowHints` that
    /// takes window numbers.
    pub fn shouldShowHintsForWindow(
        flags: ModifierFlags,
        host_window_number: i32,
        host_window_is_key: bool,
        event_window_number: ?i32,
        key_window_number: i32,
        show_on_command_hold_enabled: ?bool,
    ) bool {
        if (!shouldShowHints(flags, show_on_command_hold_enabled)) return false;
        const effective_event_window = event_window_number orelse key_window_number;
        return isCurrentWindow(
            host_window_number,
            host_window_is_key,
            effective_event_window,
            key_window_number,
        );
    }
};

// ---------------------------------------------------------------------------
// Shortcut hint debug settings
// ---------------------------------------------------------------------------

pub const ShortcutHintDebugSettings = struct {
    pub const offset_range_min: f64 = -50.0;
    pub const offset_range_max: f64 = 50.0;

    pub const default_sidebar_hint_x: f64 = 0.0;
    pub const default_sidebar_hint_y: f64 = 0.0;
    pub const default_titlebar_hint_x: f64 = 4.0;
    pub const default_titlebar_hint_y: f64 = 0.0;
    pub const default_pane_hint_x: f64 = 0.0;
    pub const default_pane_hint_y: f64 = 0.0;
    pub const default_always_show_hints: bool = false;
    pub const default_show_hints_on_command_hold: bool = true;

    pub fn clamped(value: f64) f64 {
        return @max(offset_range_min, @min(offset_range_max, value));
    }

    pub fn showHintsOnCommandHoldEnabled(stored_value: ?bool) bool {
        return stored_value orelse default_show_hints_on_command_hold;
    }

    /// Reset visibility defaults to their factory values.
    /// Returns the reset values as a tuple.
    pub const ResetResult = struct {
        always_show_hints: bool,
        show_hints_on_command_hold: bool,
    };

    pub fn resetVisibilityDefaults() ResetResult {
        return .{
            .always_show_hints = default_always_show_hints,
            .show_hints_on_command_hold = default_show_hints_on_command_hold,
        };
    }
};

// ---------------------------------------------------------------------------
// Shortcut hint lane planner
// ---------------------------------------------------------------------------

pub const ShortcutHintLanePlanner = struct {
    /// Assign lane indices to a list of vertical intervals so that overlapping
    /// intervals (with less than `min_spacing` gap) are placed on different lanes.
    /// Returns a slice of lane indices (caller must free).
    pub fn assignLanes(
        allocator: std.mem.Allocator,
        intervals: []const [2]f64, // each is [lower, upper]
        min_spacing: f64,
    ) ![]usize {
        const n = intervals.len;
        const lanes = try allocator.alloc(usize, n);
        @memset(lanes, 0);

        // Track the upper bound of the last interval placed on each lane.
        // Use a fixed-size buffer — 64 lanes should be more than enough.
        var lane_ends: [64]f64 = undefined;
        var lane_count: usize = 0;

        for (0..n) |i| {
            const lower = intervals[i][0];
            var placed = false;
            for (0..lane_count) |lane_idx| {
                if (lower - lane_ends[lane_idx] >= min_spacing) {
                    lanes[i] = lane_idx;
                    lane_ends[lane_idx] = intervals[i][1];
                    placed = true;
                    break;
                }
            }
            if (!placed) {
                lanes[i] = lane_count;
                lane_ends[lane_count] = intervals[i][1];
                lane_count += 1;
            }
        }

        return lanes;
    }
};

// ---------------------------------------------------------------------------
// Shortcut hint horizontal planner
// ---------------------------------------------------------------------------

pub const ShortcutHintHorizontalPlanner = struct {
    /// Assign right edges for a list of horizontal intervals, pushing overlapping
    /// intervals rightward to maintain `min_spacing`.
    /// Returns a slice of right edges (caller must free).
    pub fn assignRightEdges(
        allocator: std.mem.Allocator,
        intervals: []const [2]f64, // each is [lower, upper]
        min_spacing: f64,
    ) ![]f64 {
        const n = intervals.len;
        const right_edges = try allocator.alloc(f64, n);

        // Start with original right edges.
        for (0..n) |i| {
            right_edges[i] = intervals[i][1];
        }

        // Push overlapping intervals rightward.
        for (1..n) |i| {
            const prev_width = intervals[i - 1][1] - intervals[i - 1][0];
            const prev_left = right_edges[i - 1] - prev_width;
            const curr_width = intervals[i][1] - intervals[i][0];
            const curr_left = right_edges[i] - curr_width;
            _ = curr_left;

            const gap = (right_edges[i] - curr_width) - right_edges[i - 1];
            _ = prev_left;
            if (gap < min_spacing) {
                right_edges[i] = right_edges[i - 1] + min_spacing + curr_width;
            }
        }

        return right_edges;
    }
};

// ---------------------------------------------------------------------------
// Last surface close shortcut settings
// ---------------------------------------------------------------------------

/// Whether closing the last surface should also close the workspace (defaults to true).
/// Mirrors Mac's `LastSurfaceCloseShortcutSettings.closesWorkspace`.
pub fn lastSurfaceClosesWorkspace(stored_value: ?bool) bool {
    return stored_value orelse true;
}

// ---------------------------------------------------------------------------
// Dev build banner debug settings
// ---------------------------------------------------------------------------

/// Whether the sidebar dev-build banner should be shown (defaults to true).
pub fn showSidebarBanner(stored_value: ?bool) bool {
    return stored_value orelse true;
}

// ---------------------------------------------------------------------------
// Appearance settings
// ---------------------------------------------------------------------------

pub const AppearanceMode = enum {
    system,
    light,
    dark,
};

/// Resolve the appearance mode, defaulting to .system if unset.
/// Mirrors Mac's `AppearanceSettings.resolvedMode`.
pub fn resolvedAppearanceMode(stored_value: ?[]const u8) AppearanceMode {
    const val = stored_value orelse return .system;
    if (std.mem.eql(u8, val, "light")) return .light;
    if (std.mem.eql(u8, val, "dark")) return .dark;
    return .system;
}

// ---------------------------------------------------------------------------
// Quit warning settings
// ---------------------------------------------------------------------------

/// Whether the warn-before-quit dialog should be shown (defaults to true).
/// Mirrors Mac's `QuitWarningSettings.isEnabled`.
pub fn quitWarningEnabled(stored_value: ?bool) bool {
    return stored_value orelse true;
}

// =============================================================================
// Tests
// =============================================================================

// ---------------------------------------------------------------------------
// SplitShortcutTransientFocusGuard
// ---------------------------------------------------------------------------

test "SplitShortcutGuard: suppresses when first responder falls back and hosted view is tiny" {
    try std.testing.expect(shouldSuppressSplitShortcutForTransientFocus(
        true,
        79,
        0,
        false,
        true,
    ));
}

test "SplitShortcutGuard: suppresses when first responder falls back and hosted view is detached" {
    try std.testing.expect(shouldSuppressSplitShortcutForTransientFocus(
        true,
        1051.5,
        1207,
        false,
        false,
    ));
}

test "SplitShortcutGuard: allows when first responder falls back but geometry is healthy" {
    try std.testing.expect(!shouldSuppressSplitShortcutForTransientFocus(
        true,
        1051.5,
        1207,
        false,
        true,
    ));
}

test "SplitShortcutGuard: allows when first responder is terminal even if view is tiny" {
    try std.testing.expect(!shouldSuppressSplitShortcutForTransientFocus(
        false,
        79,
        0,
        false,
        true,
    ));
}

// ---------------------------------------------------------------------------
// FullScreenShortcut
// ---------------------------------------------------------------------------

test "FullScreenShortcut: matches Cmd+Ctrl+F" {
    try std.testing.expect(shouldToggleFullScreenForCommandControlF(
        .{ .command = true, .control = true },
        "f",
        3,
        null,
    ));
}

test "FullScreenShortcut: matches Cmd+Ctrl+F from keycode when chars unavailable" {
    const provider: LayoutCharacterProvider = struct {
        fn f(_: u16, _: ModifierFlags) ?u8 {
            return null;
        }
    }.f;
    try std.testing.expect(shouldToggleFullScreenForCommandControlF(
        .{ .command = true, .control = true },
        "",
        3,
        provider,
    ));
}

test "FullScreenShortcut: does not fallback to ANSI when layout translation returns non-F" {
    const provider: LayoutCharacterProvider = struct {
        fn f(_: u16, _: ModifierFlags) ?u8 {
            return 'u';
        }
    }.f;
    try std.testing.expect(!shouldToggleFullScreenForCommandControlF(
        .{ .command = true, .control = true },
        "",
        3,
        provider,
    ));
}

test "FullScreenShortcut: matches when command-aware layout provides F" {
    const provider: LayoutCharacterProvider = struct {
        fn f(_: u16, mods: ModifierFlags) ?u8 {
            return if (mods.command) 'f' else 'u';
        }
    }.f;
    try std.testing.expect(shouldToggleFullScreenForCommandControlF(
        .{ .command = true, .control = true },
        "",
        3,
        provider,
    ));
}

test "FullScreenShortcut: matches when chars are control sequence" {
    const provider: LayoutCharacterProvider = struct {
        fn f(_: u16, _: ModifierFlags) ?u8 {
            return null;
        }
    }.f;
    try std.testing.expect(shouldToggleFullScreenForCommandControlF(
        .{ .command = true, .control = true },
        "\x06",
        3,
        provider,
    ));
}

test "FullScreenShortcut: rejects physical F when character represents different layout key" {
    try std.testing.expect(!shouldToggleFullScreenForCommandControlF(
        .{ .command = true, .control = true },
        "u",
        3,
        null,
    ));
}

test "FullScreenShortcut: ignores caps lock" {
    try std.testing.expect(shouldToggleFullScreenForCommandControlF(
        .{ .command = true, .control = true, .caps_lock = true },
        "f",
        3,
        null,
    ));
}

test "FullScreenShortcut: rejects when control is missing" {
    try std.testing.expect(!shouldToggleFullScreenForCommandControlF(
        .{ .command = true },
        "f",
        3,
        null,
    ));
}

test "FullScreenShortcut: rejects additional modifiers" {
    try std.testing.expect(!shouldToggleFullScreenForCommandControlF(
        .{ .command = true, .control = true, .shift = true },
        "f",
        3,
        null,
    ));
    try std.testing.expect(!shouldToggleFullScreenForCommandControlF(
        .{ .command = true, .control = true, .option = true },
        "f",
        3,
        null,
    ));
}

test "FullScreenShortcut: rejects when command is missing" {
    try std.testing.expect(!shouldToggleFullScreenForCommandControlF(
        .{ .control = true },
        "f",
        3,
        null,
    ));
}

test "FullScreenShortcut: rejects non-F key" {
    try std.testing.expect(!shouldToggleFullScreenForCommandControlF(
        .{ .command = true, .control = true },
        "r",
        15,
        null,
    ));
}

// ---------------------------------------------------------------------------
// CommandPaletteKeyboardNavigation
// ---------------------------------------------------------------------------

test "PaletteNav: arrow keys move selection without modifiers" {
    try std.testing.expectEqual(@as(?i32, 1), commandPaletteSelectionDelta(
        .{},
        "",
        125,
    ));
    try std.testing.expectEqual(@as(?i32, -1), commandPaletteSelectionDelta(
        .{},
        "",
        126,
    ));
    try std.testing.expect(commandPaletteSelectionDelta(
        .{ .shift = true },
        "",
        125,
    ) == null);
}

test "PaletteNav: control letter navigation supports printable and control chars" {
    // Ctrl+N
    try std.testing.expectEqual(@as(?i32, 1), commandPaletteSelectionDelta(
        .{ .control = true },
        "n",
        45,
    ));
    try std.testing.expectEqual(@as(?i32, 1), commandPaletteSelectionDelta(
        .{ .control = true },
        "\x0e",
        45,
    ));

    // Ctrl+P
    try std.testing.expectEqual(@as(?i32, -1), commandPaletteSelectionDelta(
        .{ .control = true },
        "p",
        35,
    ));
    try std.testing.expectEqual(@as(?i32, -1), commandPaletteSelectionDelta(
        .{ .control = true },
        "\x10",
        35,
    ));

    // Ctrl+J
    try std.testing.expectEqual(@as(?i32, 1), commandPaletteSelectionDelta(
        .{ .control = true },
        "j",
        38,
    ));
    try std.testing.expectEqual(@as(?i32, 1), commandPaletteSelectionDelta(
        .{ .control = true },
        "\x0a",
        38,
    ));

    // Ctrl+K
    try std.testing.expectEqual(@as(?i32, -1), commandPaletteSelectionDelta(
        .{ .control = true },
        "k",
        40,
    ));
    try std.testing.expectEqual(@as(?i32, -1), commandPaletteSelectionDelta(
        .{ .control = true },
        "\x0b",
        40,
    ));
}

test "PaletteNav: ignores unsupported modifiers and keys" {
    // Command modifier.
    try std.testing.expect(commandPaletteSelectionDelta(
        .{ .command = true },
        "n",
        45,
    ) == null);
    // Control+Shift.
    try std.testing.expect(commandPaletteSelectionDelta(
        .{ .control = true, .shift = true },
        "n",
        45,
    ) == null);
    // Control + unrecognized key.
    try std.testing.expect(commandPaletteSelectionDelta(
        .{ .control = true },
        "x",
        7,
    ) == null);
}

// ---------------------------------------------------------------------------
// CommandPaletteOpenShortcutConsumption
// ---------------------------------------------------------------------------

test "ShortcutConsumption: does not consume when palette is not visible" {
    try std.testing.expect(!shouldConsumeShortcutWhileCommandPaletteVisible(
        false,
        .{ .command = true },
        "n",
        45,
    ));
}

test "ShortcutConsumption: consumes app command shortcuts when palette is visible" {
    try std.testing.expect(shouldConsumeShortcutWhileCommandPaletteVisible(
        true,
        .{ .command = true },
        "n",
        45,
    ));
    try std.testing.expect(shouldConsumeShortcutWhileCommandPaletteVisible(
        true,
        .{ .command = true },
        "t",
        17,
    ));
    try std.testing.expect(shouldConsumeShortcutWhileCommandPaletteVisible(
        true,
        .{ .command = true, .shift = true },
        ",",
        43,
    ));
}

test "ShortcutConsumption: allows clipboard and undo shortcuts for palette text editing" {
    try std.testing.expect(!shouldConsumeShortcutWhileCommandPaletteVisible(
        true,
        .{ .command = true },
        "v",
        9,
    ));
    try std.testing.expect(!shouldConsumeShortcutWhileCommandPaletteVisible(
        true,
        .{ .command = true },
        "z",
        6,
    ));
    try std.testing.expect(!shouldConsumeShortcutWhileCommandPaletteVisible(
        true,
        .{ .command = true, .shift = true },
        "z",
        6,
    ));
}

test "ShortcutConsumption: allows arrow and delete editing commands for palette text editing" {
    // Cmd+LeftArrow.
    try std.testing.expect(!shouldConsumeShortcutWhileCommandPaletteVisible(
        true,
        .{ .command = true },
        "",
        123,
    ));
    // Cmd+Delete.
    try std.testing.expect(!shouldConsumeShortcutWhileCommandPaletteVisible(
        true,
        .{ .command = true },
        "",
        51,
    ));
}

test "ShortcutConsumption: consumes escape when palette is visible" {
    try std.testing.expect(shouldConsumeShortcutWhileCommandPaletteVisible(
        true,
        .{},
        "",
        53,
    ));
}

// ---------------------------------------------------------------------------
// CommandPaletteRestoreFocusStateMachine
// ---------------------------------------------------------------------------

test "RestoreFocus: restores browser address bar when palette opened from focused address bar" {
    const panel_id: u128 = 42;
    try std.testing.expect(shouldRestoreBrowserAddressBarAfterDismiss(
        true,
        panel_id,
        panel_id,
    ));
}

test "RestoreFocus: does not restore when focused panel is not browser" {
    const panel_id: u128 = 42;
    try std.testing.expect(!shouldRestoreBrowserAddressBarAfterDismiss(
        false,
        panel_id,
        panel_id,
    ));
}

test "RestoreFocus: does not restore when another panel had address bar focus" {
    try std.testing.expect(!shouldRestoreBrowserAddressBarAfterDismiss(
        true,
        @as(u128, 1),
        @as(u128, 2),
    ));
}

// ---------------------------------------------------------------------------
// CommandPaletteRenameSelectionSettings
// ---------------------------------------------------------------------------

test "RenameSelection: defaults to select-all when unset" {
    try std.testing.expect(renameSelectAllOnFocusEnabled(null));
}

test "RenameSelection: returns false when stored false" {
    try std.testing.expect(!renameSelectAllOnFocusEnabled(false));
}

test "RenameSelection: returns true when stored true" {
    try std.testing.expect(renameSelectAllOnFocusEnabled(true));
}

// ---------------------------------------------------------------------------
// ShortcutHintModifierPolicy
// ---------------------------------------------------------------------------

test "ShortcutHintPolicy: requires enabled command-only modifier" {
    try std.testing.expect(ShortcutHintModifierPolicy.shouldShowHints(.{ .command = true }, true));
    try std.testing.expect(!ShortcutHintModifierPolicy.shouldShowHints(.{ .control = true }, true));
    try std.testing.expect(!ShortcutHintModifierPolicy.shouldShowHints(.{}, true));
    try std.testing.expect(!ShortcutHintModifierPolicy.shouldShowHints(.{ .command = true, .shift = true }, true));
    try std.testing.expect(!ShortcutHintModifierPolicy.shouldShowHints(.{ .control = true, .shift = true }, true));
    try std.testing.expect(!ShortcutHintModifierPolicy.shouldShowHints(.{ .command = true, .option = true }, true));
    try std.testing.expect(!ShortcutHintModifierPolicy.shouldShowHints(.{ .control = true, .option = true }, true));
    try std.testing.expect(!ShortcutHintModifierPolicy.shouldShowHints(.{ .command = true, .control = true }, true));
}

test "ShortcutHintPolicy: command hint can be disabled in settings" {
    try std.testing.expect(!ShortcutHintModifierPolicy.shouldShowHints(.{ .command = true }, false));
    try std.testing.expect(!ShortcutHintModifierPolicy.shouldShowHints(.{ .control = true }, false));
}

test "ShortcutHintPolicy: command hint defaults to enabled when setting missing" {
    try std.testing.expect(ShortcutHintModifierPolicy.shouldShowHints(.{ .command = true }, null));
    try std.testing.expect(!ShortcutHintModifierPolicy.shouldShowHints(.{ .control = true }, null));
}

test "ShortcutHintPolicy: intentional hold delay" {
    try std.testing.expect(@abs(ShortcutHintModifierPolicy.intentional_hold_delay - 0.30) < 0.001);
}

test "ShortcutHintPolicy: current window requires host window to be key and match event window" {
    try std.testing.expect(ShortcutHintModifierPolicy.isCurrentWindow(42, true, 42, 42));
    try std.testing.expect(!ShortcutHintModifierPolicy.isCurrentWindow(42, true, 7, 42));
    try std.testing.expect(!ShortcutHintModifierPolicy.isCurrentWindow(42, false, 42, 42));
}

test "ShortcutHintPolicy: window-scoped hints use key window when no event window available" {
    try std.testing.expect(ShortcutHintModifierPolicy.shouldShowHintsForWindow(
        .{ .command = true },
        42,
        true,
        null,
        42,
        true,
    ));
    try std.testing.expect(!ShortcutHintModifierPolicy.shouldShowHintsForWindow(
        .{ .command = true },
        42,
        true,
        null,
        7,
        true,
    ));
    // With control only.
    try std.testing.expect(!ShortcutHintModifierPolicy.shouldShowHintsForWindow(
        .{ .control = true },
        42,
        true,
        null,
        42,
        true,
    ));
}

// ---------------------------------------------------------------------------
// ShortcutHintDebugSettings
// ---------------------------------------------------------------------------

test "ShortcutHintDebugSettings: clamp keeps values within supported range" {
    try std.testing.expect(ShortcutHintDebugSettings.clamped(0.0) == 0.0);
    try std.testing.expect(ShortcutHintDebugSettings.clamped(4.0) == 4.0);
    try std.testing.expect(ShortcutHintDebugSettings.clamped(-100.0) == ShortcutHintDebugSettings.offset_range_min);
    try std.testing.expect(ShortcutHintDebugSettings.clamped(100.0) == ShortcutHintDebugSettings.offset_range_max);
}

test "ShortcutHintDebugSettings: default offsets match current badge placements" {
    try std.testing.expect(ShortcutHintDebugSettings.default_sidebar_hint_x == 0.0);
    try std.testing.expect(ShortcutHintDebugSettings.default_sidebar_hint_y == 0.0);
    try std.testing.expect(ShortcutHintDebugSettings.default_titlebar_hint_x == 4.0);
    try std.testing.expect(ShortcutHintDebugSettings.default_titlebar_hint_y == 0.0);
    try std.testing.expect(ShortcutHintDebugSettings.default_pane_hint_x == 0.0);
    try std.testing.expect(ShortcutHintDebugSettings.default_pane_hint_y == 0.0);
    try std.testing.expect(!ShortcutHintDebugSettings.default_always_show_hints);
    try std.testing.expect(ShortcutHintDebugSettings.default_show_hints_on_command_hold);
}

test "ShortcutHintDebugSettings: show hints on command hold respects stored value" {
    try std.testing.expect(ShortcutHintDebugSettings.showHintsOnCommandHoldEnabled(null));
    try std.testing.expect(!ShortcutHintDebugSettings.showHintsOnCommandHoldEnabled(false));
    try std.testing.expect(ShortcutHintDebugSettings.showHintsOnCommandHoldEnabled(true));
}

test "ShortcutHintDebugSettings: reset visibility defaults restores flags" {
    const result = ShortcutHintDebugSettings.resetVisibilityDefaults();
    try std.testing.expect(result.always_show_hints == ShortcutHintDebugSettings.default_always_show_hints);
    try std.testing.expect(result.show_hints_on_command_hold == ShortcutHintDebugSettings.default_show_hints_on_command_hold);
}

// ---------------------------------------------------------------------------
// ShortcutHintLanePlanner
// ---------------------------------------------------------------------------

test "LanePlanner: assigns separated intervals to single lane" {
    const alloc = std.testing.allocator;
    const intervals = [_][2]f64{ .{ 0, 20 }, .{ 28, 40 }, .{ 48, 64 } };
    const lanes = try ShortcutHintLanePlanner.assignLanes(alloc, &intervals, 4);
    defer alloc.free(lanes);

    try std.testing.expectEqual(@as(usize, 0), lanes[0]);
    try std.testing.expectEqual(@as(usize, 0), lanes[1]);
    try std.testing.expectEqual(@as(usize, 0), lanes[2]);
}

test "LanePlanner: stacks overlapping intervals into additional lanes" {
    const alloc = std.testing.allocator;
    const intervals = [_][2]f64{ .{ 0, 20 }, .{ 18, 34 }, .{ 22, 38 }, .{ 40, 56 } };
    const lanes = try ShortcutHintLanePlanner.assignLanes(alloc, &intervals, 4);
    defer alloc.free(lanes);

    try std.testing.expectEqual(@as(usize, 0), lanes[0]);
    try std.testing.expectEqual(@as(usize, 1), lanes[1]);
    try std.testing.expectEqual(@as(usize, 2), lanes[2]);
    try std.testing.expectEqual(@as(usize, 0), lanes[3]);
}

// ---------------------------------------------------------------------------
// ShortcutHintHorizontalPlanner
// ---------------------------------------------------------------------------

test "HorizontalPlanner: resolves overlap with minimum spacing" {
    const alloc = std.testing.allocator;
    const intervals = [_][2]f64{ .{ 0, 20 }, .{ 18, 34 }, .{ 30, 46 } };
    const right_edges = try ShortcutHintHorizontalPlanner.assignRightEdges(alloc, &intervals, 6);
    defer alloc.free(right_edges);

    try std.testing.expectEqual(@as(usize, 3), right_edges.len);

    // Verify spacing between adjusted intervals.
    for (1..right_edges.len) |i| {
        const prev_width = intervals[i - 1][1] - intervals[i - 1][0];
        const curr_width = intervals[i][1] - intervals[i][0];
        _ = prev_width;
        const curr_left = right_edges[i] - curr_width;
        const gap = curr_left - right_edges[i - 1];
        try std.testing.expect(gap >= 6.0 - 0.001);
    }
}

test "HorizontalPlanner: keeps already separated intervals in place" {
    const alloc = std.testing.allocator;
    const intervals = [_][2]f64{ .{ 0, 12 }, .{ 20, 32 }, .{ 40, 52 } };
    const right_edges = try ShortcutHintHorizontalPlanner.assignRightEdges(alloc, &intervals, 4);
    defer alloc.free(right_edges);

    try std.testing.expect(@abs(right_edges[0] - 12.0) < 0.001);
    try std.testing.expect(@abs(right_edges[1] - 32.0) < 0.001);
    try std.testing.expect(@abs(right_edges[2] - 52.0) < 0.001);
}

// ---------------------------------------------------------------------------
// LastSurfaceCloseShortcutSettings
// ---------------------------------------------------------------------------

test "LastSurfaceClose: default closes workspace" {
    try std.testing.expect(lastSurfaceClosesWorkspace(null));
}

test "LastSurfaceClose: stored true closes workspace" {
    try std.testing.expect(lastSurfaceClosesWorkspace(true));
}

test "LastSurfaceClose: stored false keeps workspace open" {
    try std.testing.expect(!lastSurfaceClosesWorkspace(false));
}

// ---------------------------------------------------------------------------
// DevBuildBannerDebugSettings
// ---------------------------------------------------------------------------

test "DevBuildBanner: show sidebar banner defaults to visible" {
    try std.testing.expect(showSidebarBanner(null));
}

test "DevBuildBanner: show sidebar banner respects stored value" {
    try std.testing.expect(!showSidebarBanner(false));
    try std.testing.expect(showSidebarBanner(true));
}

// ---------------------------------------------------------------------------
// AppearanceSettings
// ---------------------------------------------------------------------------

test "AppearanceSettings: resolved mode defaults to system when unset" {
    try std.testing.expectEqual(AppearanceMode.system, resolvedAppearanceMode(null));
}

// ---------------------------------------------------------------------------
// QuitWarningSettings
// ---------------------------------------------------------------------------

test "QuitWarning: default is enabled when unset" {
    try std.testing.expect(quitWarningEnabled(null));
}

test "QuitWarning: stored preference overrides default" {
    try std.testing.expect(!quitWarningEnabled(false));
    try std.testing.expect(quitWarningEnabled(true));
}
