/// First-click focus policy for inactive panes.
///
/// Settings-driven boolean: should an inactive pane accept the first click
/// event, or should the first click only focus the pane without triggering
/// the underlying widget's action?
///
/// Ports the macOS `InactivePaneFirstClickFocus` test logic.
const std = @import("std");

/// View types that the focus policy applies to.
pub const ViewType = enum {
    terminal,
    browser,
    markdown,
};

/// Determine whether the first click on an inactive pane should be
/// accepted (passed through to the widget) based on the setting.
///
/// When enabled, the first click both focuses the pane AND triggers
/// the widget action (e.g., clicking a link in a browser pane).
/// When disabled, the first click only focuses the pane.
pub fn acceptsFirstClick(setting_enabled: bool) bool {
    return setting_enabled;
}

/// Per-view-type override capability. Currently all view types follow
/// the same global setting, but this provides the extension point.
pub fn acceptsFirstClickForView(setting_enabled: bool, view_type: ViewType) bool {
    _ = view_type;
    return setting_enabled;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "terminal view accepts first mouse when setting enabled" {
    try testing.expect(acceptsFirstClickForView(true, .terminal));
}

test "terminal view rejects first mouse when setting disabled" {
    try testing.expect(!acceptsFirstClickForView(false, .terminal));
}

test "browser view accepts first mouse when setting enabled" {
    try testing.expect(acceptsFirstClickForView(true, .browser));
}

test "browser view rejects first mouse when setting disabled" {
    try testing.expect(!acceptsFirstClickForView(false, .browser));
}

test "markdown view accepts first mouse when setting enabled" {
    try testing.expect(acceptsFirstClickForView(true, .markdown));
}

test "markdown view rejects first mouse when setting disabled" {
    try testing.expect(!acceptsFirstClickForView(false, .markdown));
}
