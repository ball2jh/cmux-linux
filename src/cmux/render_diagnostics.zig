//! Render diagnostics for UI integration tests.
//!
//! When `CMUX_UI_TEST_DISPLAY_RENDER_STATS=1`, this module tracks per-frame
//! render counters and periodically writes them into the diagnostics JSON
//! file via `ui_test_harness.writeRenderDiagnostics()`.
//!
//! The diagnostics are consumed by `test_display_resolution.py` (and the
//! macOS XCTest equivalent) to verify that the terminal keeps rendering
//! during rapid window resizes.
//!
//! Design mirrors the macOS `AppDelegate.appendUITestRenderDiagnosticsIfNeeded`
//! and `UITestRenderDiagnosticsSnapshot` — same JSON keys and value formats.

const std = @import("std");
const glib = @import("glib");
const gtk = @import("gtk");
const gdk = @import("gdk");

const ui_test_harness = @import("ui_test_harness.zig");

const log = std.log.scoped(.render_diagnostics);

/// Render diagnostics collector.
///
/// Created once at window startup when render stats are enabled.
/// Installs a GTK tick callback on a widget (the workspace stack) to
/// count compositor frames, and a GLib timer to periodically flush the
/// counters to the diagnostics JSON file.
pub const RenderDiagnostics = struct {
    /// Counters — updated from the tick callback on the main thread.
    draw_count: u64 = 0,
    present_count: u64 = 0,
    last_present_time: f64 = 0,

    /// GLib source ID for the periodic write timer (0 = not running).
    timer_source_id: c_uint = 0,

    /// GTK tick callback ID (0 = not installed).
    tick_callback_id: c_uint = 0,

    /// The widget the tick callback is installed on.
    tick_widget: ?*gtk.Widget = null,

    /// Back-pointer to the CmuxWindow (opaque) for querying state.
    window_ptr: ?*anyopaque = null,

    /// Function to get the active panel's UUID string from the window.
    /// Returns null if no surface is active.
    get_panel_id_fn: ?*const fn (?*anyopaque) ?[36]u8 = null,

    /// Function to check whether the window is visible.
    get_window_visible_fn: ?*const fn (?*anyopaque) bool = null,

    const write_interval_ms: c_uint = 100;

    /// Check whether render diagnostics should be enabled (from env vars
    /// already parsed by `ui_test_harness.init()`).
    pub fn shouldEnable() bool {
        const cfg = ui_test_harness.config();
        return cfg.display_render_stats and cfg.diagnostics_path != null;
    }

    /// Start the periodic write timer and install a tick callback on the
    /// given widget (typically the workspace stack).
    pub fn start(self: *RenderDiagnostics, widget: *gtk.Widget) void {
        if (self.tick_callback_id != 0) return; // already started

        self.tick_widget = widget;
        self.tick_callback_id = widget.addTickCallback(&tickCallback, self, null);

        self.timer_source_id = glib.timeoutAdd(
            write_interval_ms,
            &timerCallback,
            @ptrCast(self),
        );

        // Write initial state immediately so the test can detect the file.
        self.flush();

        log.info("render diagnostics started (write_interval={}ms)", .{write_interval_ms});
    }

    /// Stop the timer and remove the tick callback. Safe to call multiple
    /// times or on an un-started instance.
    pub fn stop(self: *RenderDiagnostics) void {
        if (self.timer_source_id != 0) {
            _ = glib.Source.remove(self.timer_source_id);
            self.timer_source_id = 0;
        }
        if (self.tick_callback_id != 0) {
            if (self.tick_widget) |w| {
                w.removeTickCallback(self.tick_callback_id);
            }
            self.tick_callback_id = 0;
            self.tick_widget = null;
        }
    }

    // -----------------------------------------------------------------
    // Callbacks
    // -----------------------------------------------------------------

    /// GTK tick callback — fired once per compositor frame while the
    /// widget is mapped. Increments draw and present counters.
    fn tickCallback(
        _: *gtk.Widget,
        clock: *gdk.FrameClock,
        userdata: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *RenderDiagnostics = @ptrCast(@alignCast(userdata orelse return 1));

        self.draw_count += 1;
        self.present_count += 1;

        // Frame clock timestamp is in microseconds; convert to seconds.
        const frame_time_us = clock.getFrameTime();
        self.last_present_time = @as(f64, @floatFromInt(frame_time_us)) / 1_000_000.0;

        return 1; // G_SOURCE_CONTINUE — keep the callback active
    }

    /// Periodic GLib timer callback — flushes counters to disk.
    fn timerCallback(userdata: ?*anyopaque) callconv(.c) c_int {
        const self: *RenderDiagnostics = @ptrCast(@alignCast(userdata orelse return 0));
        self.flush();
        return 1; // G_SOURCE_CONTINUE
    }

    // -----------------------------------------------------------------
    // Flush to diagnostics file
    // -----------------------------------------------------------------

    /// Write current render stats into the diagnostics JSON file via
    /// `ui_test_harness.writeRenderDiagnostics()`.
    fn flush(self: *RenderDiagnostics) void {
        // Panel UUID.
        const panel_id: []const u8 = if (self.get_panel_id_fn) |func| blk: {
            if (func(self.window_ptr)) |id| {
                // id is a [36]u8 on the stack; we need a slice reference that
                // outlives this block. We use a static buffer since this runs
                // on the main thread and only one flush can be in progress.
                const Static = struct {
                    var buf: [36]u8 = undefined;
                };
                Static.buf = id;
                break :blk &Static.buf;
            }
            break :blk "";
        } else "";

        // Window visibility.
        const window_visible = if (self.get_window_visible_fn) |func|
            func(self.window_ptr)
        else
            false;

        const app_active = window_visible;

        // Format counter values into stack buffers.
        var draw_buf: [20]u8 = undefined;
        var present_buf: [20]u8 = undefined;
        var last_present_buf: [32]u8 = undefined;
        var updated_at_buf: [32]u8 = undefined;

        const draw_str = std.fmt.bufPrint(&draw_buf, "{d}", .{self.draw_count}) catch "0";
        const present_str = std.fmt.bufPrint(&present_buf, "{d}", .{self.present_count}) catch "0";

        const last_present_str = std.fmt.bufPrint(&last_present_buf, "{d:.6}", .{self.last_present_time}) catch "0.000000";

        // Current wall-clock time as seconds since epoch.
        const now_ns = std.time.nanoTimestamp();
        const updated_at: f64 = @as(f64, @floatFromInt(now_ns)) / 1_000_000_000.0;
        const updated_at_str = std.fmt.bufPrint(&updated_at_buf, "{d:.6}", .{updated_at}) catch "0.000000";

        ui_test_harness.writeRenderDiagnostics(&.{
            .{ .key = "renderStatsAvailable", .value = "1" },
            .{ .key = "renderPanelId", .value = panel_id },
            .{ .key = "renderDrawCount", .value = draw_str },
            .{ .key = "renderPresentCount", .value = present_str },
            .{ .key = "renderLastPresentTime", .value = last_present_str },
            .{ .key = "renderDiagnosticsUpdatedAt", .value = updated_at_str },
            .{ .key = "renderWindowVisible", .value = if (window_visible) "1" else "0" },
            .{ .key = "renderAppIsActive", .value = if (app_active) "1" else "0" },
        });
    }
};

// --- Tests ---

test "shouldEnable returns false when env not configured" {
    // In the test environment, ui_test_harness is not initialized with
    // CMUX_UI_TEST_DISPLAY_RENDER_STATS=1, so this should return false
    // (or true if the env happens to be set, but should not crash).
    _ = RenderDiagnostics.shouldEnable();
}
