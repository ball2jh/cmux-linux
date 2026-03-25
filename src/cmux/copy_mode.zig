/// Terminal copy/visual mode state machine.
///
/// A pure, platform-agnostic vim-like input handler for copy mode.
/// Ports the macOS `terminalKeyboardCopyModeAction`,
/// `terminalKeyboardCopyModeResolve`, and
/// `terminalKeyboardCopyModeInitialViewportRow` functions.
const std = @import("std");

// ── Actions ─────────────────────────────────────────────────────────

/// The result of interpreting a single key in copy mode.
pub const Action = enum {
    scroll_lines_down,
    scroll_lines_up,
    scroll_half_page_up,
    scroll_half_page_down,
    scroll_page_up,
    scroll_page_down,
    scroll_to_top,
    scroll_to_bottom,
    start_selection,
    clear_selection,
    copy_and_exit,
    copy_line_and_exit,
    exit,
    start_search,
    search_next,
    search_previous,
    jump_to_prompt_up,
    jump_to_prompt_down,
    adjust_selection_up,
    adjust_selection_down,
    adjust_selection_home,
    adjust_selection_end,
    adjust_selection_page_up,
    adjust_selection_page_down,
    adjust_selection_beginning_of_line,
    adjust_selection_end_of_line,
};

/// Simplified modifier flags (platform-agnostic).
pub const Modifiers = struct {
    shift: bool = false,
    control: bool = false,
    /// Super/Cmd/Meta
    command: bool = false,
    alt: bool = false,
    caps_lock: bool = false,
};

/// Returns true if the shortcut modifiers should bypass copy mode
/// (only command-based shortcuts are allowed through).
pub fn shouldBypassForShortcut(mods: Modifiers) bool {
    return mods.command;
}

/// Map a single key event to a copy mode action.
/// Returns null if the key is a prefix key (e.g. bare 'g') or unrecognized.
pub fn action(
    char: ?u8,
    mods: Modifiers,
    has_selection: bool,
) ?Action {
    // Strip caps lock — it should not block letter mappings.
    const effective_shift = mods.shift;
    const effective_ctrl = mods.control;

    // Control key combinations.
    if (effective_ctrl) {
        if (char) |c| {
            return switch (c) {
                // Ctrl+U = half page up (vim standard) — the terminal sends 0x15.
                0x15, 'u' => if (has_selection) .adjust_selection_page_up else .scroll_half_page_up,
                // Ctrl+D = half page down — 0x04.
                0x04, 'd' => if (has_selection) .adjust_selection_page_down else .scroll_half_page_down,
                // Ctrl+B = full page up — 0x02.
                0x02, 'b' => if (has_selection) .adjust_selection_page_up else .scroll_page_up,
                // Ctrl+F = full page down — 0x06.
                0x06, 'f' => if (has_selection) .adjust_selection_page_down else .scroll_page_down,
                // Ctrl+Y = scroll line up — 0x19.
                0x19, 'y' => if (has_selection) .adjust_selection_up else .scroll_lines_up,
                // Ctrl+E = scroll line down — 0x05.
                0x05, 'e' => if (has_selection) .adjust_selection_down else .scroll_lines_down,
                else => null,
            };
        }
        return null;
    }

    const c = char orelse return null;

    // Escape always exits.
    if (c == 0x1B) return .exit;

    // Shifted keys.
    if (effective_shift) {
        return switch (c) {
            'G' => .scroll_to_bottom,
            'V', 'v' => if (has_selection) .clear_selection else .start_selection,
            'Y' => .copy_line_and_exit,
            '{' => .jump_to_prompt_up,
            '}' => .jump_to_prompt_down,
            '^' => if (has_selection) .adjust_selection_beginning_of_line else null,
            '$' => if (has_selection) .adjust_selection_end_of_line else null,
            'N' => .search_previous,
            else => null,
        };
    }

    // Unshifted keys.
    return switch (c) {
        'j' => if (has_selection) .adjust_selection_down else .scroll_lines_down,
        'k' => if (has_selection) .adjust_selection_up else .scroll_lines_up,
        'v' => if (has_selection) .clear_selection else .start_selection,
        'y' => if (has_selection) .copy_and_exit else null, // bare 'y' without selection is operator prefix
        'g' => null, // prefix key (gg)
        'q' => .exit,
        '0' => if (has_selection) .adjust_selection_beginning_of_line else null,
        '/' => .start_search,
        'n' => .search_next,
        else => null,
    };
}

// ── Resolution state machine (handles counts, gg, yy) ──────────────

/// Pending input state for multi-key sequences and numeric counts.
pub const InputState = struct {
    count: ?u32 = null,
    pending_g: bool = false,
    pending_y: bool = false,

    pub fn eql(a: InputState, b: InputState) bool {
        return a.count == b.count and a.pending_g == b.pending_g and a.pending_y == b.pending_y;
    }
};

/// Result of resolving a key through the state machine.
pub const Resolution = union(enum) {
    /// Key was consumed (count digit, prefix key).
    consume,
    /// Action to perform with a repeat count.
    perform: struct {
        action: Action,
        count: u32,
    },

    pub fn eql(a: Resolution, b: Resolution) bool {
        return switch (a) {
            .consume => b == .consume,
            .perform => |ap| switch (b) {
                .perform => |bp| ap.action == bp.action and ap.count == bp.count,
                else => false,
            },
        };
    }
};

/// Feed a key event into the copy mode state machine. Returns .consume if the
/// key should be swallowed (digit accumulation, pending prefix), or a .perform
/// with the resolved action and count.
pub fn resolve(
    char: ?u8,
    mods: Modifiers,
    has_selection: bool,
    state: *InputState,
) Resolution {
    const c = char orelse {
        state.* = .{};
        return .consume;
    };

    // Strip caps_lock from effective modifiers (it should not affect key mapping).
    _ = mods.caps_lock;

    // ── Handle pending 'g' prefix ─────────────────────────────────
    if (state.pending_g) {
        state.pending_g = false;
        if (c == 'g' and !mods.shift and !mods.control) {
            const count = state.count orelse 1;
            state.count = null;
            if (has_selection) {
                return .{ .perform = .{ .action = .adjust_selection_home, .count = count } };
            }
            return .{ .perform = .{ .action = .scroll_to_top, .count = count } };
        }
        // Pending g was cancelled by a different key — fall through to normal handling.
        // The count is preserved for this key if it produces an action.
    }

    // ── Handle pending 'y' operator (yy or Y) ─────────────────────
    if (state.pending_y) {
        state.pending_y = false;
        if (c == 'y' and !mods.control) {
            const count = state.count orelse 1;
            state.count = null;
            return .{ .perform = .{ .action = .copy_line_and_exit, .count = count } };
        }
        if (mods.shift and (c == 'Y')) {
            const count = state.count orelse 1;
            state.count = null;
            return .{ .perform = .{ .action = .copy_line_and_exit, .count = count } };
        }
        // Pending y was cancelled — fall through.
    }

    // ── Shift+Y is always yank-line (with accumulated count) ──────
    if (mods.shift and c == 'Y' and !mods.control) {
        const count = state.count orelse 1;
        state.count = null;
        return .{ .perform = .{ .action = .copy_line_and_exit, .count = count } };
    }

    // ── Numeric count accumulation ────────────────────────────────
    if (!mods.shift and !mods.control) {
        if (c >= '1' and c <= '9') {
            const digit: u32 = c - '0';
            state.count = (state.count orelse 0) * 10 + digit;
            return .consume;
        }
        if (c == '0' and state.count != null) {
            state.count = state.count.? * 10;
            return .consume;
        }
    }

    // ── Try to get a single-key action ────────────────────────────
    if (action(char, mods, has_selection)) |a| {
        const count = state.count orelse 1;
        state.* = .{};
        return .{ .perform = .{ .action = a, .count = count } };
    }

    // ── Prefix keys ───────────────────────────────────────────────
    if (c == 'g' and !mods.shift and !mods.control) {
        state.pending_g = true;
        return .consume;
    }

    if (c == 'y' and !mods.shift and !mods.control and !has_selection) {
        state.pending_y = true;
        return .consume;
    }

    // ── Unrecognized key — clear pending state ────────────────────
    state.* = .{};
    return .consume;
}

// ── Viewport row calculation ────────────────────────────────────────

/// Calculate the initial viewport row for copy mode entry.
/// Uses the IME caret position to determine which terminal row the cursor is on.
/// The IME point reports the baseline (bottom) of the cell, so we subtract 1
/// from the computed row index to get the 0-based row.
pub fn initialViewportRow(
    rows: u32,
    ime_point_y: f64,
    ime_cell_height: f64,
    top_padding: f64,
) u32 {
    if (rows == 0) return 0;
    if (ime_cell_height <= 0) return rows - 1;

    const adjusted_y = ime_point_y - top_padding;
    if (adjusted_y <= 0) return 0;

    const raw_row = @floor(adjusted_y / ime_cell_height);
    if (raw_row < 1) return 0;
    const row: u32 = @intFromFloat(raw_row - 1);
    return @min(row, rows - 1);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "bypass allows only command shortcuts" {
    try testing.expect(shouldBypassForShortcut(.{ .command = true }));
    try testing.expect(shouldBypassForShortcut(.{ .command = true, .shift = true }));
    try testing.expect(shouldBypassForShortcut(.{ .command = true, .alt = true }));
    try testing.expect(!shouldBypassForShortcut(.{ .alt = true }));
    try testing.expect(!shouldBypassForShortcut(.{ .alt = true, .shift = true }));
    try testing.expect(!shouldBypassForShortcut(.{ .control = true }));
}

test "j/k without selection scroll by line" {
    try testing.expectEqual(Action.scroll_lines_down, action('j', .{}, false).?);
    try testing.expectEqual(Action.scroll_lines_up, action('k', .{}, false).?);
}

test "caps lock does not block letter mappings" {
    try testing.expectEqual(
        Action.scroll_lines_down,
        action('j', .{ .caps_lock = true }, false).?,
    );
}

test "j/k with selection adjust selection" {
    try testing.expectEqual(Action.adjust_selection_down, action('j', .{}, true).?);
    try testing.expectEqual(Action.adjust_selection_up, action('k', .{}, true).?);
}

test "ctrl paging supports printable and control characters" {
    // Ctrl+U = half-page up
    try testing.expectEqual(
        Action.scroll_half_page_up,
        action(0x15, .{ .control = true }, false).?,
    );
    // Ctrl+D with selection = page down
    try testing.expectEqual(
        Action.adjust_selection_page_down,
        action(0x04, .{ .control = true }, true).?,
    );
    // Ctrl+B = full page up
    try testing.expectEqual(
        Action.scroll_page_up,
        action(0x02, .{ .control = true }, false).?,
    );
    // Ctrl+F with selection = page down
    try testing.expectEqual(
        Action.adjust_selection_page_down,
        action(0x06, .{ .control = true }, true).?,
    );
    // Ctrl+Y = scroll line up
    try testing.expectEqual(
        Action.scroll_lines_up,
        action(0x19, .{ .control = true }, false).?,
    );
    // Ctrl+E with selection = down
    try testing.expectEqual(
        Action.adjust_selection_down,
        action(0x05, .{ .control = true }, true).?,
    );
}

test "v/g/y mapping" {
    try testing.expectEqual(Action.start_selection, action('v', .{}, false).?);
    try testing.expectEqual(Action.clear_selection, action('v', .{}, true).?);
    try testing.expectEqual(Action.copy_and_exit, action('y', .{}, true).?);
}

test "G and Shift+G mapping" {
    // Bare 'g' is a prefix key, not an immediate action.
    try testing.expect(action('g', .{}, false) == null);
    try testing.expectEqual(Action.scroll_to_bottom, action('G', .{ .shift = true }, false).?);
}

test "line boundary prompt and search mappings" {
    try testing.expectEqual(
        Action.adjust_selection_beginning_of_line,
        action('0', .{}, true).?,
    );
    try testing.expectEqual(
        Action.adjust_selection_beginning_of_line,
        action('^', .{ .shift = true }, true).?,
    );
    try testing.expectEqual(
        Action.adjust_selection_end_of_line,
        action('$', .{ .shift = true }, true).?,
    );
    try testing.expectEqual(
        Action.jump_to_prompt_up,
        action('{', .{ .shift = true }, false).?,
    );
    try testing.expectEqual(
        Action.jump_to_prompt_down,
        action('}', .{ .shift = true }, false).?,
    );
    // Unshifted '[' and ']' should not produce prompt jumps.
    try testing.expect(action('[', .{}, false) == null);
    try testing.expect(action(']', .{}, false) == null);
    // Unshifted '4' should not produce end-of-line.
    try testing.expect(action('4', .{}, true) == null);
    try testing.expectEqual(Action.start_search, action('/', .{}, false).?);
    try testing.expectEqual(Action.search_next, action('n', .{}, false).?);
    try testing.expectEqual(Action.search_previous, action('N', .{ .shift = true }, false).?);
}

test "shift+v matches visual toggle behavior" {
    try testing.expectEqual(
        Action.start_selection,
        action('V', .{ .shift = true }, false).?,
    );
    try testing.expectEqual(
        Action.clear_selection,
        action('V', .{ .shift = true }, true).?,
    );
}

test "escape always exits" {
    try testing.expectEqual(Action.exit, action(0x1B, .{}, false).?);
}

test "q always exits" {
    try testing.expectEqual(Action.exit, action('q', .{}, false).?);
}

// ── Resolution tests ────────────────────────────────────────────────

test "count prefix applies to motion" {
    var state = InputState{};
    try testing.expect(resolve('3', .{}, false, &state).eql(.consume));
    try testing.expect(resolve('j', .{}, false, &state).eql(.{ .perform = .{ .action = .scroll_lines_down, .count = 3 } }));
    try testing.expect(state.eql(InputState{}));
}

test "zero appends count or acts as motion" {
    var state = InputState{};
    try testing.expect(resolve('2', .{}, false, &state).eql(.consume));
    try testing.expect(resolve('0', .{}, false, &state).eql(.consume));
    try testing.expect(resolve('k', .{}, false, &state).eql(.{ .perform = .{ .action = .scroll_lines_up, .count = 20 } }));

    var sel_state = InputState{};
    try testing.expect(resolve('0', .{}, true, &sel_state).eql(.{ .perform = .{ .action = .adjust_selection_beginning_of_line, .count = 1 } }));
}

test "yank line operator supports yy and y with counts" {
    var yy_state = InputState{};
    try testing.expect(resolve('y', .{}, false, &yy_state).eql(.consume));
    try testing.expect(resolve('y', .{}, false, &yy_state).eql(.{ .perform = .{ .action = .copy_line_and_exit, .count = 1 } }));

    var counted_state = InputState{};
    try testing.expect(resolve('4', .{}, false, &counted_state).eql(.consume));
    try testing.expect(resolve('y', .{}, false, &counted_state).eql(.consume));
    try testing.expect(resolve('y', .{}, false, &counted_state).eql(.{ .perform = .{ .action = .copy_line_and_exit, .count = 4 } }));

    var shift_y_state = InputState{};
    try testing.expect(resolve('3', .{}, false, &shift_y_state).eql(.consume));
    try testing.expect(resolve('Y', .{ .shift = true }, false, &shift_y_state).eql(.{ .perform = .{ .action = .copy_line_and_exit, .count = 3 } }));
}

test "pending yank line does not swallow next command" {
    var state = InputState{};
    try testing.expect(resolve('y', .{}, false, &state).eql(.consume));
    try testing.expect(resolve('j', .{}, false, &state).eql(.{ .perform = .{ .action = .scroll_lines_down, .count = 1 } }));
    try testing.expect(state.eql(InputState{}));
}

test "search and prompt motions use counts" {
    var prompt_state = InputState{};
    try testing.expect(resolve('3', .{}, false, &prompt_state).eql(.consume));
    try testing.expect(resolve('}', .{ .shift = true }, false, &prompt_state).eql(.{ .perform = .{ .action = .jump_to_prompt_down, .count = 3 } }));

    var search_state = InputState{};
    try testing.expect(resolve('2', .{}, false, &search_state).eql(.consume));
    try testing.expect(resolve('n', .{}, false, &search_state).eql(.{ .perform = .{ .action = .search_next, .count = 2 } }));
}

test "invalid key clears pending state" {
    var state = InputState{};
    try testing.expect(resolve('2', .{}, false, &state).eql(.consume));
    try testing.expect(resolve('x', .{}, false, &state).eql(.consume));
    try testing.expect(state.eql(InputState{}));
}

test "gg scrolls to top" {
    var state = InputState{};
    try testing.expect(resolve('g', .{}, false, &state).eql(.consume));
    try testing.expect(resolve('g', .{}, false, &state).eql(.{ .perform = .{ .action = .scroll_to_top, .count = 1 } }));
    try testing.expect(state.eql(InputState{}));
}

test "gg with selection adjusts to home" {
    var state = InputState{};
    try testing.expect(resolve('g', .{}, true, &state).eql(.consume));
    try testing.expect(resolve('g', .{}, true, &state).eql(.{ .perform = .{ .action = .adjust_selection_home, .count = 1 } }));
    try testing.expect(state.eql(InputState{}));
}

test "counted gg" {
    var state = InputState{};
    try testing.expect(resolve('5', .{}, false, &state).eql(.consume));
    try testing.expect(resolve('g', .{}, false, &state).eql(.consume));
    try testing.expect(resolve('g', .{}, false, &state).eql(.{ .perform = .{ .action = .scroll_to_top, .count = 5 } }));
}

test "pending g cancelled by other key" {
    var state = InputState{};
    try testing.expect(resolve('g', .{}, false, &state).eql(.consume));
    try testing.expect(resolve('j', .{}, false, &state).eql(.{ .perform = .{ .action = .scroll_lines_down, .count = 1 } }));
    try testing.expect(state.eql(InputState{}));
}

test "shift+G still works immediately" {
    var state = InputState{};
    try testing.expect(resolve('G', .{ .shift = true }, false, &state).eql(.{ .perform = .{ .action = .scroll_to_bottom, .count = 1 } }));
    try testing.expect(state.eql(InputState{}));
}

test "ctrl+u half page" {
    var state = InputState{};
    try testing.expect(resolve('u', .{ .control = true }, false, &state).eql(.{ .perform = .{ .action = .scroll_half_page_up, .count = 1 } }));
}

test "ctrl+d half page" {
    var state = InputState{};
    try testing.expect(resolve('d', .{ .control = true }, false, &state).eql(.{ .perform = .{ .action = .scroll_half_page_down, .count = 1 } }));
}

test "ctrl+b full page" {
    var state = InputState{};
    try testing.expect(resolve('b', .{ .control = true }, false, &state).eql(.{ .perform = .{ .action = .scroll_page_up, .count = 1 } }));
}

test "ctrl+f full page" {
    var state = InputState{};
    try testing.expect(resolve('f', .{ .control = true }, false, &state).eql(.{ .perform = .{ .action = .scroll_page_down, .count = 1 } }));
}

// ── Viewport row tests ──────────────────────────────────────────────

test "initial viewport row uses ime point baseline" {
    try testing.expectEqual(@as(u32, 0), initialViewportRow(24, 24, 24, 0));
    try testing.expectEqual(@as(u32, 9), initialViewportRow(24, 240, 24, 0));
    try testing.expectEqual(@as(u32, 0), initialViewportRow(24, 48, 24, 24));
}

test "initial viewport row clamps bounds and falls back when height missing" {
    try testing.expectEqual(@as(u32, 0), initialViewportRow(24, 0, 24, 0));
    try testing.expectEqual(@as(u32, 23), initialViewportRow(24, 9999, 24, 0));
    try testing.expectEqual(@as(u32, 23), initialViewportRow(24, 123, 0, 0));
}

// ── Additional copy mode edge cases (ported from TerminalAndGhosttyTests) ──

test "ctrl paging with printable letter chars" {
    // Ensure 'u', 'd', 'b', 'f', 'y', 'e' (not just control codes) work.
    try testing.expectEqual(Action.scroll_half_page_up, action('u', .{ .control = true }, false).?);
    try testing.expectEqual(Action.scroll_half_page_down, action('d', .{ .control = true }, false).?);
    try testing.expectEqual(Action.scroll_page_up, action('b', .{ .control = true }, false).?);
    try testing.expectEqual(Action.scroll_page_down, action('f', .{ .control = true }, false).?);
    try testing.expectEqual(Action.scroll_lines_up, action('y', .{ .control = true }, false).?);
    try testing.expectEqual(Action.scroll_lines_down, action('e', .{ .control = true }, false).?);
}

test "null char returns null action" {
    try testing.expect(action(null, .{}, false) == null);
    try testing.expect(action(null, .{ .shift = true }, false) == null);
    try testing.expect(action(null, .{ .control = true }, false) == null);
}

test "shift+Y always maps to copy_line_and_exit" {
    try testing.expectEqual(Action.copy_line_and_exit, action('Y', .{ .shift = true }, false).?);
    try testing.expectEqual(Action.copy_line_and_exit, action('Y', .{ .shift = true }, true).?);
}

test "bare y without selection is null (operator prefix)" {
    try testing.expect(action('y', .{}, false) == null);
}

test "bare y with selection is copy_and_exit" {
    try testing.expectEqual(Action.copy_and_exit, action('y', .{}, true).?);
}

test "ctrl with unrecognized char returns null" {
    try testing.expect(action('z', .{ .control = true }, false) == null);
    try testing.expect(action('a', .{ .control = true }, false) == null);
}

test "0 without selection is null" {
    try testing.expect(action('0', .{}, false) == null);
}

test "caret and dollar without selection are null" {
    try testing.expect(action('^', .{ .shift = true }, false) == null);
    try testing.expect(action('$', .{ .shift = true }, false) == null);
}

test "resolve with null char clears state" {
    var state = InputState{};
    state.count = 5;
    state.pending_g = true;
    try testing.expect(resolve(null, .{}, false, &state).eql(.consume));
    try testing.expect(state.eql(InputState{}));
}

test "initial viewport row with zero rows" {
    try testing.expectEqual(@as(u32, 0), initialViewportRow(0, 100, 24, 0));
}

test "initial viewport row with negative adjusted y" {
    // top_padding exceeds ime_point_y
    try testing.expectEqual(@as(u32, 0), initialViewportRow(24, 10, 24, 50));
}

test "pending y then shift+Y fires copy_line" {
    var state = InputState{};
    try testing.expect(resolve('y', .{}, false, &state).eql(.consume));
    try testing.expect(resolve('Y', .{ .shift = true }, false, &state).eql(.{ .perform = .{ .action = .copy_line_and_exit, .count = 1 } }));
}

test "multi-digit count 123j" {
    var state = InputState{};
    try testing.expect(resolve('1', .{}, false, &state).eql(.consume));
    try testing.expect(resolve('2', .{}, false, &state).eql(.consume));
    try testing.expect(resolve('3', .{}, false, &state).eql(.consume));
    try testing.expect(resolve('j', .{}, false, &state).eql(.{ .perform = .{ .action = .scroll_lines_down, .count = 123 } }));
}
