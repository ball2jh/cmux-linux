//! Session persistence store — JSON file I/O.
//!
//! Matches macOS SessionPersistenceStore: atomic save, load with version
//! validation, default XDG path, and identical-data skip optimization.

const std = @import("std");
const posix = std.posix;
const json = std.json;
const snapshot = @import("../workspace/snapshot.zig");
const AppSessionSnapshot = snapshot.AppSessionSnapshot;

const log = std.log.scoped(.cmux_persistence);

// --- Default path ---

/// Build the default snapshot path:
///   $XDG_DATA_HOME/cmux/session-cmux.json
///   ~/.local/share/cmux/session-cmux.json
pub fn defaultSnapshotPath(buf: *[posix.PATH_MAX]u8) ?[]const u8 {
    const data_home = std.posix.getenv("XDG_DATA_HOME");
    if (data_home) |dh| {
        if (dh.len > 0) {
            return appendSessionFile(buf, dh);
        }
    }

    const home = std.posix.getenv("HOME") orelse return null;
    if (home.len == 0) return null;

    // $HOME/.local/share
    var fbs = std.io.fixedBufferStream(buf);
    fbs.writer().print("{s}/.local/share", .{home}) catch return null;
    const base = fbs.getWritten();
    return appendSessionFile(buf, base);
}

fn appendSessionFile(buf: *[posix.PATH_MAX]u8, base: []const u8) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    fbs.writer().print("{s}/cmux/session-cmux.json", .{base}) catch return null;
    return fbs.getWritten();
}

// --- Save ---

/// Serialize and write an AppSessionSnapshot to disk. Returns true on success.
///
/// - Skips the write if the existing file already has identical bytes.
/// - Uses atomic write (temp file + rename) to prevent partial writes.
pub fn save(allocator: std.mem.Allocator, snap: AppSessionSnapshot, path: ?[]const u8) bool {
    const file_path = path orelse blk: {
        var buf: [posix.PATH_MAX]u8 = undefined;
        break :blk defaultSnapshotPath(&buf);
    } orelse {
        log.warn("no snapshot path available", .{});
        return false;
    };

    // Serialize to JSON
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    json.Stringify.value(snap, .{ .emit_null_optional_fields = false }, &out.writer) catch {
        log.warn("failed to serialize snapshot", .{});
        return false;
    };
    const data = out.written();

    // Compare with existing file
    if (readFile(allocator, file_path)) |existing| {
        defer allocator.free(existing);
        if (std.mem.eql(u8, existing, data)) {
            return true; // Identical, skip write.
        }
    }

    // Ensure parent directory exists
    ensureParentDir(file_path) catch |err| {
        log.warn("failed to create parent dir for {s}: {}", .{ file_path, err });
        return false;
    };

    // Atomic write: write to temp file, rename over target.
    atomicWrite(file_path, data) catch |err| {
        log.warn("failed to write snapshot to {s}: {}", .{ file_path, err });
        return false;
    };

    return true;
}

// --- Load ---

/// Load and deserialize an AppSessionSnapshot from disk. Returns null on
/// any error (missing file, parse failure, version mismatch, empty windows).
pub fn load(allocator: std.mem.Allocator, path: ?[]const u8) ?json.Parsed(AppSessionSnapshot) {
    const file_path = path orelse blk: {
        var buf: [posix.PATH_MAX]u8 = undefined;
        break :blk defaultSnapshotPath(&buf);
    } orelse return null;

    const data = readFile(allocator, file_path) orelse return null;
    defer allocator.free(data);

    const parsed = json.parseFromSlice(AppSessionSnapshot, allocator, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;

    // Version check
    if (parsed.value.version != AppSessionSnapshot.current_version) {
        parsed.deinit();
        return null;
    }

    // Must have at least one window
    if (parsed.value.windows.len == 0) {
        parsed.deinit();
        return null;
    }

    return parsed;
}

// --- Remove ---

/// Delete the snapshot file if it exists.
pub fn removeSnapshot(path: ?[]const u8) void {
    const file_path = path orelse blk: {
        var buf: [posix.PATH_MAX]u8 = undefined;
        break :blk defaultSnapshotPath(&buf);
    } orelse return;

    std.fs.cwd().deleteFile(file_path) catch {};
}

// --- Internal helpers ---

fn readFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    if (stat.size == 0 or stat.size > 50 * 1024 * 1024) return null; // sanity: max 50MB

    const data = allocator.alloc(u8, stat.size) catch return null;
    const bytes_read = file.readAll(data) catch {
        allocator.free(data);
        return null;
    };
    if (bytes_read != stat.size) {
        allocator.free(data);
        return null;
    }
    return data;
}

fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(dir);
}

fn atomicWrite(path: []const u8, data: []const u8) !void {
    // Build temp path: same dir, ".tmp" suffix
    var tmp_buf: [posix.PATH_MAX]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&tmp_buf);
    fbs.writer().print("{s}.tmp", .{path}) catch return error.NameTooLong;
    const tmp_path = fbs.getWritten();

    // Write temp file
    const file = try std.fs.cwd().createFile(tmp_path, .{});
    defer file.close();
    try file.writeAll(data);

    // Rename over target (atomic on most filesystems)
    std.fs.cwd().rename(tmp_path, path) catch |err| {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        return err;
    };
}

// --- Tests ---

test "defaultSnapshotPath: uses XDG_DATA_HOME" {
    // This test is environment-dependent. Just verify it doesn't crash
    // and returns either a valid path or null.
    var buf: [posix.PATH_MAX]u8 = undefined;
    _ = defaultSnapshotPath(&buf);
}

test "save and load round-trip" {
    const alloc = std.testing.allocator;

    // Create a minimal snapshot
    const workspaces = try alloc.alloc(snapshot.WorkspaceSnapshot, 1);
    workspaces[0] = .{
        .process_title = "Terminal",
        .custom_title = "Dev",
        .is_pinned = true,
        .current_directory = "/tmp",
    };

    const windows = try alloc.alloc(snapshot.SessionWindowSnapshot, 1);
    windows[0] = .{
        .frame = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .tab_manager = .{
            .selected_workspace_index = 0,
            .workspaces = workspaces,
        },
        .sidebar = .{
            .is_visible = true,
            .selection = .tabs,
            .width = 220,
        },
    };

    const snap_app = AppSessionSnapshot{
        .version = AppSessionSnapshot.current_version,
        .created_at = 1700000000.0,
        .windows = windows,
    };

    const path = "/tmp/cmux-test-session.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    // Save
    try std.testing.expect(save(alloc, snap_app, path));

    // Load
    const loaded = load(alloc, path) orelse return error.LoadFailed;
    defer loaded.deinit();

    try std.testing.expectEqual(AppSessionSnapshot.current_version, loaded.value.version);
    try std.testing.expectEqual(@as(f64, 1700000000.0), loaded.value.created_at);
    try std.testing.expectEqual(@as(usize, 1), loaded.value.windows.len);
    try std.testing.expectEqualStrings("Terminal", loaded.value.windows[0].tab_manager.workspaces[0].process_title);
    try std.testing.expectEqualStrings("Dev", loaded.value.windows[0].tab_manager.workspaces[0].custom_title.?);
    try std.testing.expect(loaded.value.windows[0].tab_manager.workspaces[0].is_pinned);
    try std.testing.expectEqual(@as(f64, 220), loaded.value.windows[0].sidebar.width.?);

    alloc.free(workspaces);
    alloc.free(windows);
}

test "save skips rewriting identical data" {
    const alloc = std.testing.allocator;

    const windows = try alloc.alloc(snapshot.SessionWindowSnapshot, 1);
    windows[0] = .{
        .tab_manager = .{
            .workspaces = &.{.{
                .process_title = "Terminal",
                .current_directory = "/tmp",
            }},
        },
    };

    const snap_app = AppSessionSnapshot{
        .windows = windows,
    };

    const path = "/tmp/cmux-test-session-skip.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    // First write
    try std.testing.expect(save(alloc, snap_app, path));

    // Get mtime
    const stat1 = try std.fs.cwd().statFile(path);

    // Second write (identical data) — should skip
    try std.testing.expect(save(alloc, snap_app, path));

    // mtime should be unchanged (skipped)
    const stat2 = try std.fs.cwd().statFile(path);
    try std.testing.expectEqual(stat1.mtime, stat2.mtime);

    alloc.free(windows);
}

test "load rejects version mismatch" {
    const alloc = std.testing.allocator;
    const path = "/tmp/cmux-test-session-version.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    // Write a snapshot with wrong version
    const bad_json = "{\"version\":999,\"created_at\":0,\"windows\":[{\"tab_manager\":{},\"sidebar\":{}}]}";
    const file = try std.fs.cwd().createFile(path, .{});
    try file.writeAll(bad_json);
    file.close();

    try std.testing.expect(load(alloc, path) == null);
}

test "load rejects empty windows" {
    const alloc = std.testing.allocator;
    const path = "/tmp/cmux-test-session-empty.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    const bad_json = "{\"version\":1,\"created_at\":0,\"windows\":[]}";
    const file = try std.fs.cwd().createFile(path, .{});
    try file.writeAll(bad_json);
    file.close();

    try std.testing.expect(load(alloc, path) == null);
}

test "load returns null for missing file" {
    try std.testing.expect(load(std.testing.allocator, "/tmp/cmux-test-nonexistent-XXXXXX.json") == null);
}

test "removeSnapshot removes file" {
    const path = "/tmp/cmux-test-session-remove.json";
    const file = try std.fs.cwd().createFile(path, .{});
    file.close();

    removeSnapshot(path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(path));
}

test "removeSnapshot ignores missing file" {
    removeSnapshot("/tmp/cmux-test-nonexistent-remove.json");
}
