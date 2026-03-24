/// Workspace manual-unread decision logic.
///
/// Ports the macOS `Workspace.shouldClearManualUnread` and
/// `Workspace.shouldShowUnreadIndicator` pure functions used to
/// manage the per-panel "manually marked as unread" state.
const std = @import("std");

/// Determine whether a manual-unread flag should be cleared when the
/// focused panel changes (or stays the same after a grace period).
///
/// Matches macOS `Workspace.shouldClearManualUnread(
///     previousFocusedPanelId:nextFocusedPanelId:isManuallyUnread:markedAt:now:sameTabGraceInterval:
/// )`.
///
/// `marked_at_ms` and `now_ms` are millisecond timestamps (e.g. std.time.milliTimestamp()).
/// `same_tab_grace_ms` is the grace period in milliseconds (default 200).
pub fn shouldClearManualUnread(
    previous_focused_panel_id: ?u128,
    next_focused_panel_id: u128,
    is_manually_unread: bool,
    marked_at_ms: i64,
    now_ms: i64,
    same_tab_grace_ms: i64,
) bool {
    if (!is_manually_unread) return false;

    if (previous_focused_panel_id) |prev_id| {
        if (prev_id != next_focused_panel_id) {
            // Focus moved to a different panel — always clear.
            return true;
        }
        // Same panel: only clear if the grace period has elapsed.
        return (now_ms - marked_at_ms) >= same_tab_grace_ms;
    } else {
        // No previous focus (e.g. initial focus): apply grace check.
        return (now_ms - marked_at_ms) >= same_tab_grace_ms;
    }
}

/// Determine whether an unread indicator dot should be shown on a
/// workspace/panel row.
///
/// Matches macOS `Workspace.shouldShowUnreadIndicator(
///     hasUnreadNotification:isManuallyUnread:
/// )`.
pub fn shouldShowUnreadIndicator(
    has_unread_notification: bool,
    is_manually_unread: bool,
) bool {
    return has_unread_notification or is_manually_unread;
}

// ══════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "Workspace.unread: should clear manual unread when focus moves to different panel" {
    const prev: u128 = 1;
    const next: u128 = 2;
    const now: i64 = 1000;
    try testing.expect(shouldClearManualUnread(prev, next, true, now, now, 200));
}

test "Workspace.unread: should not clear manual unread when focus stays on same panel within grace" {
    const panel: u128 = 1;
    const now: i64 = 1000;
    const marked_at: i64 = now - 50; // 50ms ago, within 200ms grace
    try testing.expect(!shouldClearManualUnread(panel, panel, true, marked_at, now, 200));
}

test "Workspace.unread: should clear manual unread when focus stays on same panel after grace" {
    const panel: u128 = 1;
    const now: i64 = 1000;
    const marked_at: i64 = now - 250; // 250ms ago, past 200ms grace
    try testing.expect(shouldClearManualUnread(panel, panel, true, marked_at, now, 200));
}

test "Workspace.unread: should not clear manual unread when not manually unread" {
    const prev: u128 = 1;
    const next: u128 = 2;
    const now: i64 = 1000;
    try testing.expect(!shouldClearManualUnread(prev, next, false, now, now, 200));
}

test "Workspace.unread: should not clear manual unread when no previous focus and within grace" {
    const next: u128 = 1;
    const now: i64 = 1000;
    const marked_at: i64 = now - 50; // 50ms ago, within 200ms grace
    try testing.expect(!shouldClearManualUnread(null, next, true, marked_at, now, 200));
}

test "Workspace.unread: should show unread indicator when notification is unread" {
    try testing.expect(shouldShowUnreadIndicator(true, false));
}

test "Workspace.unread: should show unread indicator when manual unread is set" {
    try testing.expect(shouldShowUnreadIndicator(false, true));
}

test "Workspace.unread: should hide unread indicator when neither notification nor manual unread" {
    try testing.expect(!shouldShowUnreadIndicator(false, false));
}
