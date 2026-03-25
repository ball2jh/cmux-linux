//! UI test harness — observability layer for automated tests.
//!
//! When the app is launched with CMUX_UI_TEST=1 (or any CMUX_UI_TEST_* env var),
//! this module provides:
//!   - Environment variable parsing for all UI test flags
//!   - Atomic JSON data file writing (write-to-tmp then rename)
//!   - Counter structs for keyequiv tracking (addTabInvocations, etc.)
//!   - Pane focus tracking structs (goto_split test)
//!   - Child exit keyboard test harness state
//!   - Diagnostics / render stats recording
//!
//! Matches macOS Sources/UITestRecorder.swift and the AppDelegate.swift test
//! harness methods.

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.cmux_ui_test);

// ---------------------------------------------------------------------------
// Global singleton — initialised once at startup, never freed.
// All fields are read-only after init() except the counters which use atomics.
// ---------------------------------------------------------------------------

var global: Config = .{};
var global_initialized: bool = false;

/// UI test configuration parsed from environment variables at startup.
pub const Config = struct {
    /// CMUX_UI_TEST=1 — master flag.
    is_test_mode: bool = false,

    /// CMUX_SOCKET_CONTROL_MODE — "off" or "cmuxOnly".
    socket_control_mode: SocketControlMode = .cmux_only,

    /// CMUX_UI_TEST_SOCKET_SANITY=1.
    socket_sanity: bool = false,

    /// CMUX_UI_TEST_KEYEQUIV_PATH — path to write key-equivalent counter JSON.
    keyequiv_path: ?[]const u8 = null,

    /// CMUX_UI_TEST_GOTO_SPLIT_PATH — path to write goto-split focus JSON.
    goto_split_path: ?[]const u8 = null,

    /// CMUX_UI_TEST_GOTO_SPLIT_SETUP=1.
    goto_split_setup: bool = false,

    /// CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY=1.
    goto_split_record_only: bool = false,

    /// CMUX_UI_TEST_GOTO_SPLIT_USE_GHOSTTY_CONFIG=1.
    goto_split_use_ghostty_config: bool = false,

    /// CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP=1.
    goto_split_input_setup: bool = false,

    /// CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP=1.
    child_exit_setup: bool = false,

    /// CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH.
    child_exit_path: ?[]const u8 = null,

    /// CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT — "lr", "lr_left_vertical", etc.
    child_exit_layout: []const u8 = "lr",

    /// CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER.
    child_exit_expected_panels: u32 = 1,

    /// CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER=1.
    child_exit_auto_trigger: bool = false,

    /// CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT=1.
    child_exit_strict: bool = false,

    /// CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_TRIGGER_MODE — "shell_input", "early_ctrl_d", etc.
    child_exit_trigger_mode: []const u8 = "shell_input",

    /// CMUX_UI_TEST_DIAGNOSTICS_PATH — path to write diagnostics JSON.
    diagnostics_path: ?[]const u8 = null,

    /// CMUX_UI_TEST_DISPLAY_RENDER_STATS=1.
    display_render_stats: bool = false,

    /// CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE=1.
    force_confirm_close_workspace: bool = false,
};

pub const SocketControlMode = enum {
    off,
    cmux_only,

    pub fn shouldCreateSocket(self: SocketControlMode) bool {
        return self != .off;
    }
};

/// Initialise the global config from the process environment.
/// Must be called exactly once, early in startup (before any test
/// harness functions are used). Safe to call in release builds — it
/// will detect no env vars and leave everything at defaults.
pub fn init() void {
    if (global_initialized) return;
    global_initialized = true;

    const env = posix.getenv;

    // Master test-mode flag. Also consider the presence of *any*
    // CMUX_UI_TEST_* variable as evidence we're in test mode (matches
    // the Mac's `environment.keys.contains(where:)` heuristic).
    global.is_test_mode = envBool("CMUX_UI_TEST") or hasAnyUITestEnv();

    // Socket control mode.
    if (env("CMUX_SOCKET_CONTROL_MODE")) |raw| {
        if (std.mem.eql(u8, raw, "off")) {
            global.socket_control_mode = .off;
        } else {
            global.socket_control_mode = .cmux_only;
        }
    }

    global.socket_sanity = envBool("CMUX_UI_TEST_SOCKET_SANITY");

    // Key-equivalent recorder path.
    global.keyequiv_path = envNonEmpty("CMUX_UI_TEST_KEYEQUIV_PATH");

    // Goto-split test harness.
    global.goto_split_path = envNonEmpty("CMUX_UI_TEST_GOTO_SPLIT_PATH");
    global.goto_split_setup = envBool("CMUX_UI_TEST_GOTO_SPLIT_SETUP");
    global.goto_split_record_only = envBool("CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY");
    global.goto_split_use_ghostty_config = envBool("CMUX_UI_TEST_GOTO_SPLIT_USE_GHOSTTY_CONFIG");
    global.goto_split_input_setup = envBool("CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP");

    // Child exit keyboard test harness.
    global.child_exit_setup = envBool("CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP");
    global.child_exit_path = envNonEmpty("CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH");
    if (envNonEmpty("CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT")) |layout| {
        global.child_exit_layout = layout;
    }
    if (envNonEmpty("CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER")) |raw| {
        global.child_exit_expected_panels = @max(1, std.fmt.parseInt(u32, raw, 10) catch 1);
    }
    global.child_exit_auto_trigger = envBool("CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER");
    global.child_exit_strict = envBool("CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT");
    if (envNonEmpty("CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_TRIGGER_MODE")) |mode| {
        global.child_exit_trigger_mode = mode;
    }

    // Diagnostics.
    global.diagnostics_path = envNonEmpty("CMUX_UI_TEST_DIAGNOSTICS_PATH");
    global.display_render_stats = envBool("CMUX_UI_TEST_DISPLAY_RENDER_STATS");

    // Close workspace confirmation override.
    global.force_confirm_close_workspace = envBool("CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE");

    if (global.is_test_mode) {
        log.info("UI test mode active (socket_control={s}, keyequiv={s}, goto_split={s}, child_exit={s}, diag={s})", .{
            @tagName(global.socket_control_mode),
            if (global.keyequiv_path != null) "yes" else "no",
            if (global.goto_split_path != null) "yes" else "no",
            if (global.child_exit_path != null) "yes" else "no",
            if (global.diagnostics_path != null) "yes" else "no",
        });
    }
}

// ---------------------------------------------------------------------------
// Public query API
// ---------------------------------------------------------------------------

pub fn isTestMode() bool {
    return global.is_test_mode;
}

pub fn config() Config {
    return global;
}

pub fn shouldCreateSocket() bool {
    return global.socket_control_mode.shouldCreateSocket();
}

// ---------------------------------------------------------------------------
// Key-equivalent recorder (matches UITestRecorder.swift)
// ---------------------------------------------------------------------------

/// Record string key/value pairs into the keyequiv JSON file.
/// No-op when CMUX_UI_TEST_KEYEQUIV_PATH is not set.
pub fn recordKeyequiv(updates: []const KeyValue) void {
    const path = global.keyequiv_path orelse return;
    mergeAndWrite(path, updates, &.{});
}

/// Increment an integer counter in the keyequiv JSON file.
/// No-op when CMUX_UI_TEST_KEYEQUIV_PATH is not set.
pub fn incrementKeyequiv(key: []const u8) void {
    const path = global.keyequiv_path orelse return;
    mergeAndWrite(path, &.{}, &.{key});
}

// ---------------------------------------------------------------------------
// Goto-split test data writer
// ---------------------------------------------------------------------------

pub fn isGotoSplitRecordingEnabled() bool {
    return global.goto_split_setup or global.goto_split_record_only;
}

/// Write key/value pairs to the goto-split test data file.
pub fn writeGotoSplitData(updates: []const KeyValue) void {
    if (!isGotoSplitRecordingEnabled()) return;
    const path = global.goto_split_path orelse return;
    mergeAndWrite(path, updates, &.{});
}

// ---------------------------------------------------------------------------
// Child exit keyboard test data writer
// ---------------------------------------------------------------------------

/// Write key/value pairs (and optional increments) to the child exit test data file.
pub fn writeChildExitData(updates: []const KeyValue) void {
    if (!global.child_exit_setup) return;
    const path = global.child_exit_path orelse return;
    mergeAndWrite(path, updates, &.{});
}

pub fn writeChildExitDataWithIncrements(updates: []const KeyValue, increments: []const []const u8) void {
    if (!global.child_exit_setup) return;
    const path = global.child_exit_path orelse return;
    mergeAndWrite(path, updates, increments);
}

// ---------------------------------------------------------------------------
// Diagnostics writer
// ---------------------------------------------------------------------------

/// Write diagnostic key/value pairs. Includes render stats if enabled.
pub fn writeDiagnostics(updates: []const KeyValue) void {
    const path = global.diagnostics_path orelse return;
    mergeAndWrite(path, updates, &.{});
}

/// Write socket sanity diagnostics into the diagnostics file.
pub fn writeSocketDiagnostics(updates: []const KeyValue) void {
    if (!global.socket_sanity) return;
    const path = global.diagnostics_path orelse return;
    mergeAndWrite(path, updates, &.{});
}

/// Write render stats diagnostics into the diagnostics file.
pub fn writeRenderDiagnostics(updates: []const KeyValue) void {
    if (!global.display_render_stats) return;
    const path = global.diagnostics_path orelse return;
    mergeAndWrite(path, updates, &.{});
}

// ---------------------------------------------------------------------------
// Key-value pair type used by all writers
// ---------------------------------------------------------------------------

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

// ---------------------------------------------------------------------------
// Atomic JSON merge-and-write (matches Mac's load → merge → write .atomic)
// ---------------------------------------------------------------------------

/// Read the existing JSON at `path` (if any), merge `updates` on top,
/// increment any keys listed in `increments`, then atomically write the
/// result (write .tmp, rename).
fn mergeAndWrite(path: []const u8, updates: []const KeyValue, increments: []const []const u8) void {
    // We use a 16 KB stack buffer for the JSON payload. UI test data files
    // are always small (< 4 KB), so this is safe.
    var buf: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = fba.allocator();

    // 1. Load existing payload (if any).
    var map = std.StringArrayHashMap([]const u8).init(alloc);
    if (std.fs.openFileAbsolute(path, .{})) |file| {
        defer file.close();
        var read_buf: [8192]u8 = undefined;
        const n = file.readAll(&read_buf) catch 0;
        if (n > 0) {
            parseJsonMap(alloc, read_buf[0..n], &map);
        }
    } else |_| {}

    // 2. Apply increments.
    for (increments) |key| {
        const current: u64 = if (map.get(key)) |v| (std.fmt.parseInt(u64, v, 10) catch 0) else 0;
        var num_buf: [20]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{current + 1}) catch continue;
        const duped = alloc.dupe(u8, num_str) catch continue;
        map.put(key, duped) catch continue;
    }

    // 3. Apply updates.
    for (updates) |kv| {
        const duped = alloc.dupe(u8, kv.value) catch continue;
        map.put(kv.key, duped) catch continue;
    }

    // 4. Serialize to JSON.
    var out_buf: [8192]u8 = undefined;
    const payload = serializeJsonMap(&map, &out_buf) orelse return;

    // 5. Atomic write: write to .tmp then rename.
    atomicWriteFile(path, payload);
}

/// Parse a flat JSON object `{"key":"value", ...}` into the provided map.
/// Silently ignores malformed input.
fn parseJsonMap(alloc: std.mem.Allocator, data: []const u8, map: *std.StringArrayHashMap([]const u8)) void {
    // Use a simple manual parser for flat {"key":"value"} objects.
    // The std.json scanner is heavy; we only need flat string maps.
    var i: usize = 0;

    // Skip whitespace and opening brace.
    while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == '\r')) : (i += 1) {}
    if (i >= data.len or data[i] != '{') return;
    i += 1;

    while (i < data.len) {
        // Skip whitespace and commas.
        while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == '\r' or data[i] == ',')) : (i += 1) {}
        if (i >= data.len or data[i] == '}') break;

        // Parse key string.
        const key = parseJsonString(data, &i) orelse break;
        // Skip colon.
        while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == '\r')) : (i += 1) {}
        if (i >= data.len or data[i] != ':') break;
        i += 1;
        // Parse value string.
        const value = parseJsonString(data, &i) orelse break;

        const key_dup = alloc.dupe(u8, key) catch continue;
        const val_dup = alloc.dupe(u8, value) catch continue;
        map.put(key_dup, val_dup) catch continue;
    }
}

/// Parse a JSON string starting at data[pos], advancing pos past the closing quote.
/// Returns the unescaped content (without surrounding quotes), or null on error.
fn parseJsonString(data: []const u8, pos: *usize) ?[]const u8 {
    var i = pos.*;
    // Skip whitespace.
    while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == '\r')) : (i += 1) {}
    if (i >= data.len or data[i] != '"') return null;
    i += 1; // skip opening quote
    const start = i;
    while (i < data.len and data[i] != '"') {
        if (data[i] == '\\') {
            i += 1; // skip escaped char
        }
        i += 1;
    }
    if (i >= data.len) return null;
    const end = i;
    i += 1; // skip closing quote
    pos.* = i;
    return data[start..end];
}

/// Serialize a flat string map to JSON `{"key":"value",...}` into the provided buffer.
fn serializeJsonMap(map: *const std.StringArrayHashMap([]const u8), out: *[8192]u8) ?[]const u8 {
    var pos: usize = 0;

    if (pos >= out.len) return null;
    out[pos] = '{';
    pos += 1;

    var first = true;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (!first) {
            if (pos >= out.len) return null;
            out[pos] = ',';
            pos += 1;
        }
        first = false;

        // Write "key":"value"
        pos = writeJsonString(out, pos, entry.key_ptr.*) orelse return null;
        if (pos >= out.len) return null;
        out[pos] = ':';
        pos += 1;
        pos = writeJsonString(out, pos, entry.value_ptr.*) orelse return null;
    }

    if (pos >= out.len) return null;
    out[pos] = '}';
    pos += 1;

    return out[0..pos];
}

/// Write a JSON-encoded string (with quotes) into `out` at `pos`.
/// Returns the new position, or null if out of space.
fn writeJsonString(out: *[8192]u8, start: usize, s: []const u8) ?usize {
    var pos = start;
    if (pos >= out.len) return null;
    out[pos] = '"';
    pos += 1;

    for (s) |c| {
        switch (c) {
            '"', '\\' => {
                if (pos + 1 >= out.len) return null;
                out[pos] = '\\';
                pos += 1;
                out[pos] = c;
                pos += 1;
            },
            '\n' => {
                if (pos + 1 >= out.len) return null;
                out[pos] = '\\';
                pos += 1;
                out[pos] = 'n';
                pos += 1;
            },
            '\r' => {
                if (pos + 1 >= out.len) return null;
                out[pos] = '\\';
                pos += 1;
                out[pos] = 'r';
                pos += 1;
            },
            '\t' => {
                if (pos + 1 >= out.len) return null;
                out[pos] = '\\';
                pos += 1;
                out[pos] = 't';
                pos += 1;
            },
            else => {
                if (pos >= out.len) return null;
                out[pos] = c;
                pos += 1;
            },
        }
    }

    if (pos >= out.len) return null;
    out[pos] = '"';
    pos += 1;

    return pos;
}

/// Atomically write `data` to `path` by writing to a .tmp sibling first,
/// then renaming over the target. Falls back to direct write if rename fails.
fn atomicWriteFile(path: []const u8, data: []const u8) void {
    // Build the tmp path: append ".tmp" to the target.
    var tmp_buf: [std.posix.PATH_MAX + 4]u8 = undefined;
    if (path.len + 4 > tmp_buf.len) {
        directWriteFile(path, data);
        return;
    }
    @memcpy(tmp_buf[0..path.len], path);
    @memcpy(tmp_buf[path.len..][0..4], ".tmp");
    const tmp_path = tmp_buf[0 .. path.len + 4];

    // Write to tmp file.
    const file = std.fs.createFileAbsolute(tmp_path, .{ .truncate = true, .mode = 0o644 }) catch {
        directWriteFile(path, data);
        return;
    };
    file.writeAll(data) catch {
        file.close();
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return;
    };
    file.close();

    // Rename over target.
    std.fs.renameAbsolute(tmp_path, path) catch {
        // Fallback: delete tmp, write directly.
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        directWriteFile(path, data);
    };
}

fn directWriteFile(path: []const u8, data: []const u8) void {
    const file = std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 }) catch return;
    defer file.close();
    file.writeAll(data) catch {};
}

// ---------------------------------------------------------------------------
// Environment helpers
// ---------------------------------------------------------------------------

fn envBool(name: [*:0]const u8) bool {
    const val = posix.getenv(name) orelse return false;
    return std.mem.eql(u8, val, "1");
}

fn envNonEmpty(name: [*:0]const u8) ?[]const u8 {
    const val = posix.getenv(name) orelse return null;
    return if (val.len > 0) val else null;
}

/// Check whether any environment variable starting with CMUX_UI_TEST_ is set.
/// This matches the Mac's heuristic in SocketControlSettings and AppDelegate.
fn hasAnyUITestEnv() bool {
    // Walk the environ array looking for the prefix.
    const environ: [*:null]const ?[*:0]const u8 = std.c.environ;
    var i: usize = 0;
    while (environ[i]) |entry| : (i += 1) {
        const s: [*:0]const u8 = entry;
        // Check prefix "CMUX_UI_TEST_".
        const prefix = "CMUX_UI_TEST_";
        var matches = true;
        for (prefix, 0..) |ch, j| {
            if (s[j] == 0 or s[j] != ch) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseJsonString basic" {
    const data = "\"hello\"";
    var pos: usize = 0;
    const result = parseJsonString(data, &pos);
    try std.testing.expectEqualStrings("hello", result.?);
    try std.testing.expectEqual(@as(usize, 7), pos);
}

test "parseJsonMap basic" {
    const data = "{\"a\":\"1\",\"b\":\"2\"}";
    var map = std.StringArrayHashMap([]const u8).init(std.testing.allocator);
    defer map.deinit();
    parseJsonMap(std.testing.allocator, data, &map);
    defer {
        var it = map.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
    }
    try std.testing.expectEqualStrings("1", map.get("a").?);
    try std.testing.expectEqualStrings("2", map.get("b").?);
}

test "serializeJsonMap roundtrip" {
    var map = std.StringArrayHashMap([]const u8).init(std.testing.allocator);
    defer map.deinit();
    try map.put("key", "value");
    var out: [8192]u8 = undefined;
    const result = serializeJsonMap(&map, &out);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{\"key\":\"value\"}", result.?);
}

test "writeJsonString escapes" {
    var out: [8192]u8 = undefined;
    const end = writeJsonString(&out, 0, "a\"b\\c\n").?;
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", out[0..end]);
}
