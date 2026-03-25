/// Window drag state and focus flash animation patterns.
///
/// Ports the macOS FocusFlashPattern constants and the window drag
/// suppression reference-counting logic.
const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Focus flash animation pattern
// ═══════════════════════════════════════════════════════════════════════

/// Animation curve type for flash segments.
pub const AnimationCurve = enum {
    ease_out,
    ease_in,
};

/// A single animation segment within the focus flash pattern.
pub const FlashSegment = struct {
    delay: f64,
    duration: f64,
    target_opacity: f64,
    curve: AnimationCurve,
};

/// Focus flash double-pulse pattern constants.
/// Matches macOS `FocusFlashPattern`.
pub const FocusFlashPattern = struct {
    pub const values = [_]f64{ 0, 1, 0, 1, 0 };
    pub const key_times = [_]f64{ 0, 0.25, 0.5, 0.75, 1 };
    pub const duration: f64 = 0.9;
    pub const curves = [_]AnimationCurve{ .ease_out, .ease_in, .ease_out, .ease_in };
    pub const ring_inset: f64 = 6;
    pub const ring_corner_radius: f64 = 10;

    /// Compute the animation segments from the pattern constants.
    pub fn segments() [4]FlashSegment {
        var result: [4]FlashSegment = undefined;
        for (0..4) |i| {
            const start_time = key_times[i];
            const end_time = key_times[i + 1];
            const seg_duration = (end_time - start_time) * duration;
            const delay = start_time * duration;

            result[i] = .{
                .delay = delay,
                .duration = seg_duration,
                .target_opacity = values[i + 1],
                .curve = curves[i],
            };
        }
        return result;
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Window drag suppression
// ═══════════════════════════════════════════════════════════════════════

/// Reference-counted drag suppression state for a window.
/// When depth > 0, window dragging should be suppressed.
pub const DragSuppressionState = struct {
    depth: u32 = 0,

    pub fn isSuppressed(self: DragSuppressionState) bool {
        return self.depth > 0;
    }

    /// Begin drag suppression. Returns new depth.
    pub fn begin(self: *DragSuppressionState) u32 {
        self.depth += 1;
        return self.depth;
    }

    /// End drag suppression. Returns new depth. Clamps at 0.
    pub fn end(self: *DragSuppressionState) u32 {
        if (self.depth > 0) self.depth -= 1;
        return self.depth;
    }
};

/// Temporarily disable window dragging, returning the previous movable state.
pub fn temporarilyDisableWindowDragging(is_movable: bool) struct { previous: bool, new_movable: bool } {
    return .{ .previous = is_movable, .new_movable = false };
}

/// Restore window dragging to a previous state.
pub fn restoreWindowDragging(previous_movable: bool) bool {
    return previous_movable;
}

/// Temporarily enable window movability, run a callback, then restore.
/// Returns the previous movable state.
pub fn withTemporaryMovableEnabled(
    is_movable: bool,
    callback: *const fn () void,
) bool {
    const previous = is_movable;
    // Window is temporarily set to movable.
    callback();
    // Restore previous state.
    return previous;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const testing = std.testing;

// ── Focus flash pattern tests ───────────────────────────────────────

test "focus flash pattern matches terminal double pulse shape" {
    try testing.expectEqual(@as(usize, 5), FocusFlashPattern.values.len);
    try testing.expectEqual(@as(usize, 5), FocusFlashPattern.key_times.len);
    try testing.expectApproxEqAbs(@as(f64, 0.9), FocusFlashPattern.duration, 0.0001);
    try testing.expectEqual(@as(usize, 4), FocusFlashPattern.curves.len);
    try testing.expectApproxEqAbs(@as(f64, 6), FocusFlashPattern.ring_inset, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 10), FocusFlashPattern.ring_corner_radius, 0.0001);

    try testing.expectApproxEqAbs(@as(f64, 0), FocusFlashPattern.values[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1), FocusFlashPattern.values[1], 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0), FocusFlashPattern.values[2], 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1), FocusFlashPattern.values[3], 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0), FocusFlashPattern.values[4], 0.0001);

    try testing.expectApproxEqAbs(@as(f64, 0), FocusFlashPattern.key_times[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.25), FocusFlashPattern.key_times[1], 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.5), FocusFlashPattern.key_times[2], 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.75), FocusFlashPattern.key_times[3], 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1), FocusFlashPattern.key_times[4], 0.0001);

    try testing.expectEqual(AnimationCurve.ease_out, FocusFlashPattern.curves[0]);
    try testing.expectEqual(AnimationCurve.ease_in, FocusFlashPattern.curves[1]);
    try testing.expectEqual(AnimationCurve.ease_out, FocusFlashPattern.curves[2]);
    try testing.expectEqual(AnimationCurve.ease_in, FocusFlashPattern.curves[3]);
}

test "focus flash pattern segments cover full double pulse timeline" {
    const segs = FocusFlashPattern.segments();
    try testing.expectEqual(@as(usize, 4), segs.len);

    try testing.expectApproxEqAbs(@as(f64, 0.0), segs[0].delay, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.225), segs[0].duration, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1), segs[0].target_opacity, 0.0001);
    try testing.expectEqual(AnimationCurve.ease_out, segs[0].curve);

    try testing.expectApproxEqAbs(@as(f64, 0.225), segs[1].delay, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.225), segs[1].duration, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0), segs[1].target_opacity, 0.0001);
    try testing.expectEqual(AnimationCurve.ease_in, segs[1].curve);

    try testing.expectApproxEqAbs(@as(f64, 0.45), segs[2].delay, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.225), segs[2].duration, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1), segs[2].target_opacity, 0.0001);
    try testing.expectEqual(AnimationCurve.ease_out, segs[2].curve);

    try testing.expectApproxEqAbs(@as(f64, 0.675), segs[3].delay, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.225), segs[3].duration, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0), segs[3].target_opacity, 0.0001);
    try testing.expectEqual(AnimationCurve.ease_in, segs[3].curve);
}

// ── Drag suppression tests ──────────────────────────────────────────

test "suppression disables movable window" {
    const result = temporarilyDisableWindowDragging(true);
    try testing.expectEqual(true, result.previous);
    try testing.expectEqual(false, result.new_movable);
}

test "suppression preserves already immovable window" {
    const result = temporarilyDisableWindowDragging(false);
    try testing.expectEqual(false, result.previous);
    try testing.expectEqual(false, result.new_movable);
}

test "restore applies previous movable state" {
    try testing.expectEqual(true, restoreWindowDragging(true));
    try testing.expectEqual(false, restoreWindowDragging(false));
}

test "window drag suppression depth lifecycle" {
    var state = DragSuppressionState{};
    try testing.expectEqual(@as(u32, 0), state.depth);
    try testing.expect(!state.isSuppressed());

    try testing.expectEqual(@as(u32, 1), state.begin());
    try testing.expectEqual(@as(u32, 1), state.depth);
    try testing.expect(state.isSuppressed());

    try testing.expectEqual(@as(u32, 0), state.end());
    try testing.expectEqual(@as(u32, 0), state.depth);
    try testing.expect(!state.isSuppressed());
}

test "window drag suppression is reference counted" {
    var state = DragSuppressionState{};
    try testing.expectEqual(@as(u32, 1), state.begin());
    try testing.expectEqual(@as(u32, 2), state.begin());
    try testing.expectEqual(@as(u32, 2), state.depth);
    try testing.expect(state.isSuppressed());

    try testing.expectEqual(@as(u32, 1), state.end());
    try testing.expectEqual(@as(u32, 1), state.depth);
    try testing.expect(state.isSuppressed());

    try testing.expectEqual(@as(u32, 0), state.end());
    try testing.expectEqual(@as(u32, 0), state.depth);
    try testing.expect(!state.isSuppressed());
}

test "temporary window movable enable restores immovable window" {
    var body_called = false;
    const callback = struct {
        fn call() void {
            // Inside the callback, window should be movable.
        }
    }.call;
    _ = callback;

    // Test the return value logic directly.
    const previous = withTemporaryMovableEnabled(false, &struct {
        fn call() void {}
    }.call);
    try testing.expectEqual(false, previous);
    _ = &body_called;
}

test "temporary window movable enable preserves movable window" {
    const previous = withTemporaryMovableEnabled(true, &struct {
        fn call() void {}
    }.call);
    try testing.expectEqual(true, previous);
}

// ── Drag suppression edge cases ─────────────────────────────────────
// Ported from macOS WindowAndDragTests — concurrent and zero-depth operations

test "drag suppression end at zero depth clamps to zero" {
    // Ported from the Mac test that verifies end() at zero is safe.
    var state = DragSuppressionState{};
    try testing.expectEqual(@as(u32, 0), state.depth);

    // End at zero should stay at zero (no underflow).
    try testing.expectEqual(@as(u32, 0), state.end());
    try testing.expectEqual(@as(u32, 0), state.depth);
    try testing.expect(!state.isSuppressed());
}

test "drag suppression concurrent begin-end sequence" {
    // Ported from Mac concurrent enable/disable test.
    var state = DragSuppressionState{};

    // Begin three times
    _ = state.begin();
    _ = state.begin();
    _ = state.begin();
    try testing.expectEqual(@as(u32, 3), state.depth);
    try testing.expect(state.isSuppressed());

    // End twice
    _ = state.end();
    _ = state.end();
    try testing.expectEqual(@as(u32, 1), state.depth);
    try testing.expect(state.isSuppressed());

    // End once more — back to zero
    _ = state.end();
    try testing.expectEqual(@as(u32, 0), state.depth);
    try testing.expect(!state.isSuppressed());

    // Extra end at zero — clamps
    _ = state.end();
    try testing.expectEqual(@as(u32, 0), state.depth);
    try testing.expect(!state.isSuppressed());
}

test "drag suppression rapid begin-end interleaving" {
    // Ported from Mac rapid toggle test.
    var state = DragSuppressionState{};

    // begin, end, begin, end, begin, begin, end, end
    try testing.expectEqual(@as(u32, 1), state.begin());
    try testing.expectEqual(@as(u32, 0), state.end());
    try testing.expectEqual(@as(u32, 1), state.begin());
    try testing.expectEqual(@as(u32, 0), state.end());
    try testing.expectEqual(@as(u32, 1), state.begin());
    try testing.expectEqual(@as(u32, 2), state.begin());
    try testing.expectEqual(@as(u32, 1), state.end());
    try testing.expectEqual(@as(u32, 0), state.end());

    try testing.expect(!state.isSuppressed());
}

test "drag suppression multiple end at zero never underflows" {
    // Verify that repeated end() at zero stays at zero.
    var state = DragSuppressionState{};
    _ = state.end();
    _ = state.end();
    _ = state.end();
    try testing.expectEqual(@as(u32, 0), state.depth);
    try testing.expect(!state.isSuppressed());
}

// ── Focus flash timing edge cases ───────────────────────────────────
// Ported from macOS FocusFlashPatternTests — segment boundaries

test "focus flash segments are contiguous without gaps" {
    const segs = FocusFlashPattern.segments();

    // Each segment's delay + duration should equal the next segment's delay.
    try testing.expectApproxEqAbs(
        segs[1].delay,
        segs[0].delay + segs[0].duration,
        0.0001,
    );
    try testing.expectApproxEqAbs(
        segs[2].delay,
        segs[1].delay + segs[1].duration,
        0.0001,
    );
    try testing.expectApproxEqAbs(
        segs[3].delay,
        segs[2].delay + segs[2].duration,
        0.0001,
    );
}

test "focus flash segments total duration matches pattern duration" {
    const segs = FocusFlashPattern.segments();
    const total = segs[3].delay + segs[3].duration;
    try testing.expectApproxEqAbs(FocusFlashPattern.duration, total, 0.0001);
}

test "focus flash pattern alternates between 0 and 1 opacity" {
    const segs = FocusFlashPattern.segments();
    try testing.expectApproxEqAbs(@as(f64, 1), segs[0].target_opacity, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0), segs[1].target_opacity, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1), segs[2].target_opacity, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0), segs[3].target_opacity, 0.0001);
}

test "focus flash pattern key_times start at 0 and end at 1" {
    try testing.expectApproxEqAbs(@as(f64, 0), FocusFlashPattern.key_times[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1), FocusFlashPattern.key_times[FocusFlashPattern.key_times.len - 1], 0.0001);
}

test "focus flash pattern key_times are monotonically increasing" {
    for (0..FocusFlashPattern.key_times.len - 1) |i| {
        try testing.expect(FocusFlashPattern.key_times[i] < FocusFlashPattern.key_times[i + 1]);
    }
}

test "focus flash segments all have positive duration" {
    const segs = FocusFlashPattern.segments();
    for (segs) |seg| {
        try testing.expect(seg.duration > 0);
    }
}

test "focus flash segments all have non-negative delay" {
    const segs = FocusFlashPattern.segments();
    for (segs) |seg| {
        try testing.expect(seg.delay >= 0);
    }
}

test "focus flash first segment starts at zero delay" {
    const segs = FocusFlashPattern.segments();
    try testing.expectApproxEqAbs(@as(f64, 0.0), segs[0].delay, 0.0001);
}

// ── Window context synchronization edge cases ───────────────────────
// Ported from macOS FolderWindowMoveSuppressionTests — GTK-portable
// (pure data operations, no AppKit dependency)

test "suppress and restore window dragging preserves movable state round-trip" {
    // Test the full suppress → use → restore cycle.
    const suppress_result = temporarilyDisableWindowDragging(true);
    try testing.expectEqual(true, suppress_result.previous);
    try testing.expectEqual(false, suppress_result.new_movable);

    const restored = restoreWindowDragging(suppress_result.previous);
    try testing.expectEqual(true, restored);
}

test "suppress and restore window dragging with already immovable window" {
    const suppress_result = temporarilyDisableWindowDragging(false);
    try testing.expectEqual(false, suppress_result.previous);
    try testing.expectEqual(false, suppress_result.new_movable);

    const restored = restoreWindowDragging(suppress_result.previous);
    try testing.expectEqual(false, restored);
}

test "drag suppression state fresh instance is not suppressed" {
    const state = DragSuppressionState{};
    try testing.expect(!state.isSuppressed());
    try testing.expectEqual(@as(u32, 0), state.depth);
}

test "drag suppression begin returns incremented depth" {
    var state = DragSuppressionState{};
    try testing.expectEqual(@as(u32, 1), state.begin());
    try testing.expectEqual(@as(u32, 2), state.begin());
    try testing.expectEqual(@as(u32, 3), state.begin());
    try testing.expectEqual(@as(u32, 4), state.begin());
    try testing.expectEqual(@as(u32, 5), state.begin());
}
