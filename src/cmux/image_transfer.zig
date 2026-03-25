//! Terminal image transfer planner.
//!
//! Handles paste and drag-drop of files/images onto terminal surfaces.
//! Detects content type and target (local vs remote SSH), then either inserts
//! shell-escaped paths or uploads files via SCP and inserts remote paths.
//!
//! Ports macOS TerminalImageTransfer.swift.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Uuid = @import("uuid.zig").Uuid;
const url_resolve = @import("url_resolve.zig");
const SshSessionDetector = @import("remote/SshSessionDetector.zig");

const log = std.log.scoped(.cmux_image_transfer);

// ── Data types ─────────────────────────────────────────────────────────

pub const Mode = enum {
    paste,
    drop,
};

pub const RemoteUploadTarget = union(enum) {
    workspace_remote,
    detected_ssh: SshSessionDetector.DetectedSession,
};

pub const Target = union(enum) {
    local,
    remote: RemoteUploadTarget,
};

pub const PreparedContent = union(enum) {
    insert_text: [:0]const u8,
    file_paths: []const []const u8,
    reject,
};

pub const Plan = union(enum) {
    insert_text: [:0]const u8,
    upload_files: UploadFilesPlan,
    reject,

    pub const UploadFilesPlan = struct {
        paths: []const []const u8,
        target: RemoteUploadTarget,
    };
};

// ── Operation (cancellable upload handle) ──────────────────────────────

/// Thread-safe cancellation state machine for upload operations.
/// Matches macOS TerminalImageTransferOperation.
pub const Operation = struct {
    mutex: std.Thread.Mutex = .{},
    state: State = .running,
    cancellation_fn: ?CancellationFn = null,
    cancellation_ctx: ?*anyopaque = null,

    const State = enum { running, cancelled, finished };
    const CancellationFn = *const fn (?*anyopaque) void;

    pub fn isCancelled(self: *Operation) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state == .cancelled;
    }

    /// Returns true if the operation was successfully cancelled.
    pub fn cancel(self: *Operation) bool {
        var handler: ?CancellationFn = null;
        var ctx: ?*anyopaque = null;

        self.mutex.lock();
        if (self.state != .running) {
            self.mutex.unlock();
            return false;
        }
        self.state = .cancelled;
        handler = self.cancellation_fn;
        ctx = self.cancellation_ctx;
        self.cancellation_fn = null;
        self.cancellation_ctx = null;
        self.mutex.unlock();

        if (handler) |h| h(ctx);
        return true;
    }

    /// Returns true if the operation was successfully finished.
    pub fn finish(self: *Operation) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .running) return false;
        self.state = .finished;
        self.cancellation_fn = null;
        self.cancellation_ctx = null;
        return true;
    }

    pub fn installCancellationHandler(
        self: *Operation,
        handler: CancellationFn,
        ctx: ?*anyopaque,
    ) void {
        var invoke_immediately = false;

        self.mutex.lock();
        switch (self.state) {
            .running => {
                self.cancellation_fn = handler;
                self.cancellation_ctx = ctx;
            },
            .cancelled => invoke_immediately = true,
            .finished => {},
        }
        self.mutex.unlock();

        if (invoke_immediately) handler(ctx);
    }

    pub fn clearCancellationHandler(self: *Operation) void {
        self.mutex.lock();
        if (self.state == .running) {
            self.cancellation_fn = null;
            self.cancellation_ctx = null;
        }
        self.mutex.unlock();
    }

    pub fn throwIfCancelled(self: *Operation) !void {
        if (self.isCancelled()) return error.Cancelled;
    }
};

// ── Planner ────────────────────────────────────────────────────────────

/// Plan a transfer given already-prepared content and a resolved target.
/// For `.insert_text` plans derived from file paths, the returned text
/// is allocated with `alloc` and must be freed by the caller.
pub fn plan(alloc: Allocator, content: PreparedContent, target: Target) Plan {
    switch (content) {
        .insert_text => |text| return .{ .insert_text = text },
        .reject => return .reject,
        .file_paths => |paths| return planFilePaths(alloc, paths, target),
    }
}

fn planFilePaths(alloc: Allocator, paths: []const []const u8, target: Target) Plan {
    if (paths.len == 0) return .reject;

    switch (target) {
        .local => return .{ .insert_text = joinEscapedPaths(alloc, paths) orelse return .reject },
        .remote => |remote_target| {
            // Check all paths are regular files (uploadable).
            for (paths) |p| {
                if (!isRegularFile(p)) {
                    return .{ .insert_text = joinEscapedPaths(alloc, paths) orelse return .reject };
                }
            }
            return .{ .upload_files = .{
                .paths = paths,
                .target = remote_target,
            } };
        },
    }
}

fn isRegularFile(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .file;
}

/// Join shell-escaped paths with spaces.
/// Returns a heap-allocated sentinel-terminated string owned by the caller.
pub fn joinEscapedPaths(alloc: Allocator, paths: []const []const u8) ?[:0]const u8 {
    var stream: std.Io.Writer.Allocating = .init(alloc);

    var escape_buf: [4096]u8 = undefined;
    for (paths, 0..) |p, i| {
        if (i > 0) stream.writer.writeAll(" ") catch return null;
        const escaped = url_resolve.escapeForShell(&escape_buf, p) orelse return null;
        stream.writer.writeAll(escaped) catch return null;
    }

    return stream.toOwnedSliceSentinel(0) catch null;
}

// ── Remote drop path ───────────────────────────────────────────────────

/// Generate a remote temporary path for a dropped file.
/// Format: /tmp/cmux-drop-{uuid}.{ext}
/// Matches macOS WorkspaceRemoteSessionController.remoteDropPath.
pub fn remoteDropPath(buf: []u8, extension: []const u8) ?[]const u8 {
    const uuid = Uuid.generate();
    const uuid_str = uuid.format();
    const has_ext = extension.len > 0;

    const prefix = "/tmp/cmux-drop-";
    const total_len = prefix.len + 36 + (if (has_ext) 1 + extension.len else 0);

    if (total_len > buf.len) return null;

    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    // UUID (lowercase).
    const uuid_bytes = uuid_str[0..36];
    for (uuid_bytes) |c| {
        buf[pos] = std.ascii.toLower(c);
        pos += 1;
    }

    if (has_ext) {
        buf[pos] = '.';
        pos += 1;
        for (extension) |c| {
            buf[pos] = std.ascii.toLower(c);
            pos += 1;
        }
    }

    return buf[0..pos];
}

/// Extract the file extension from a path (without the dot).
pub fn pathExtension(path: []const u8) []const u8 {
    // Find the last component.
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
        path[idx + 1 ..]
    else
        path;

    // Find the last dot in the basename.
    if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot_idx| {
        if (dot_idx + 1 < basename.len) {
            return basename[dot_idx + 1 ..];
        }
    }
    return "";
}

// ── Clipboard image save ───────────────────────────────────────────────

/// Save image data to a temporary PNG file.
/// Returns the path to the temp file, or null on failure.
/// Filename format: cmux-paste-{YYYY-MM-DD-HHmmss}-{8-char-uuid}.png
/// Max size: 10 MB.
pub fn saveImageToTempFile(
    alloc: Allocator,
    image_data: []const u8,
    extension: []const u8,
) ?[]const u8 {
    const max_clipboard_image_size = 10 * 1024 * 1024; // 10 MB
    if (image_data.len > max_clipboard_image_size) {
        log.warn("clipboard image too large: {} bytes (max {})", .{
            image_data.len,
            max_clipboard_image_size,
        });
        return null;
    }

    const ext = if (extension.len > 0) extension else "png";

    // Build filename: cmux-paste-{timestamp}-{short-uuid}.{ext}
    const uuid = Uuid.generate();
    const uuid_str = uuid.format();

    const timestamp: u64 = @intCast(std.time.timestamp());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = timestamp };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var filename_buf: [256]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buf, "/tmp/cmux-paste-{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{s}.{s}", .{
        year_day.year,
        @intFromEnum(month_day.month) + 1,
        @as(u32, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        uuid_str[0..8],
        ext,
    }) catch {
        log.err("failed to format temp image filename", .{});
        return null;
    };

    // Write the file.
    const file = std.fs.cwd().createFile(filename, .{}) catch |err| {
        log.err("failed to create temp image file: {}", .{err});
        return null;
    };
    defer file.close();

    file.writeAll(image_data) catch |err| {
        log.err("failed to write temp image file: {}", .{err});
        // Try to clean up.
        std.fs.cwd().deleteFile(filename) catch {};
        return null;
    };

    return alloc.dupe(u8, filename) catch null;
}

// ── SCP upload helpers ─────────────────────────────────────────────────

pub const UploadError = error{
    Cancelled,
    InvalidFile,
    UploadFailed,
    OutOfMemory,
};

pub const UploadResult = union(enum) {
    success: []const []const u8, // Remote paths.
    failure: []const u8, // Error message.
};

/// Upload files via SCP using a detected SSH session.
/// Blocks the calling thread. Check operation.isCancelled() periodically.
pub fn uploadViaDetectedSsh(
    alloc: Allocator,
    session: *const SshSessionDetector.DetectedSession,
    file_paths: []const []const u8,
    operation: *Operation,
) UploadResult {
    var remote_paths = std.ArrayListUnmanaged([]const u8){};

    for (file_paths) |local_path| {
        if (operation.isCancelled()) {
            cleanupRemotePaths(alloc, session, remote_paths.items);
            return .{ .failure = "cancelled" };
        }

        // Generate remote path.
        var rpath_buf: [256]u8 = undefined;
        const ext = pathExtension(local_path);
        const rpath = remoteDropPath(&rpath_buf, ext) orelse {
            cleanupRemotePaths(alloc, session, remote_paths.items);
            return .{ .failure = "failed to generate remote path" };
        };

        // Store a copy of the remote path.
        const rpath_owned = alloc.dupe(u8, rpath) catch {
            cleanupRemotePaths(alloc, session, remote_paths.items);
            return .{ .failure = "out of memory" };
        };

        // Build SCP args.
        const scp_args = SshSessionDetector.buildScpArgs(alloc, session, local_path, rpath) catch {
            alloc.free(rpath_owned);
            cleanupRemotePaths(alloc, session, remote_paths.items);
            return .{ .failure = "failed to build SCP arguments" };
        };
        defer alloc.free(scp_args);

        // Run SCP.
        const result = runScpProcess(alloc, scp_args);
        switch (result) {
            .success => {
                remote_paths.append(alloc, rpath_owned) catch {
                    alloc.free(rpath_owned);
                    cleanupRemotePaths(alloc, session, remote_paths.items);
                    return .{ .failure = "out of memory" };
                };
            },
            .failure => |detail| {
                alloc.free(rpath_owned);
                cleanupRemotePaths(alloc, session, remote_paths.items);
                return .{ .failure = detail };
            },
        }
    }

    return .{ .success = remote_paths.toOwnedSlice(alloc) catch &.{} };
}

const ScpResult = union(enum) {
    success,
    failure: []const u8,
};

fn runScpProcess(alloc: Allocator, args: []const []const u8) ScpResult {
    var child = std.process.Child.init(args, alloc);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    child.spawn() catch |err| {
        log.err("failed to spawn scp: {}", .{err});
        return .{ .failure = "failed to spawn scp" };
    };

    const term = child.wait() catch |err| {
        log.err("failed to wait for scp: {}", .{err});
        return .{ .failure = "scp process error" };
    };

    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        .Signal => 128,
        .Stopped => 127,
        .Unknown => 126,
    };

    if (exit_code != 0) {
        log.err("scp failed with exit code {}", .{exit_code});
        return .{ .failure = "scp upload failed" };
    }

    return .success;
}

fn cleanupRemotePaths(
    alloc: Allocator,
    session: *const SshSessionDetector.DetectedSession,
    remote_paths: []const []const u8,
) void {
    if (remote_paths.len == 0) return;

    // Build: ssh <args> <dest> "rm -f -- '/tmp/cmux-drop-xxx' '/tmp/cmux-drop-yyy'"
    var cmd_buf: [4096]u8 = undefined;
    var pos: usize = 0;

    const prefix = "rm -f --";
    @memcpy(cmd_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    for (remote_paths) |rp| {
        if (pos + 4 + rp.len > cmd_buf.len) break;
        cmd_buf[pos] = ' ';
        cmd_buf[pos + 1] = '\'';
        pos += 2;
        @memcpy(cmd_buf[pos..][0..rp.len], rp);
        pos += rp.len;
        cmd_buf[pos] = '\'';
        pos += 1;
    }

    const cleanup_cmd = cmd_buf[0..pos];

    // Build SSH args for cleanup.
    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(alloc);

    args.append(alloc, "ssh") catch return;
    args.appendSlice(alloc, &.{ "-o", "ConnectTimeout=6" }) catch return;
    args.appendSlice(alloc, &.{ "-o", "BatchMode=yes" }) catch return;
    args.appendSlice(alloc, &.{ "-o", "ControlMaster=no" }) catch return;

    if (session.port) |port| {
        var port_buf: [6]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return;
        args.appendSlice(alloc, &.{ "-p", alloc.dupe(u8, port_str) catch return }) catch return;
    }

    args.append(alloc, session.destination) catch return;
    args.append(alloc, alloc.dupe(u8, cleanup_cmd) catch return) catch return;

    var child = std.process.Child.init(args.items, alloc);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;

    child.spawn() catch {
        log.warn("failed to spawn cleanup SSH", .{});
        return;
    };

    // Fire-and-forget: wait briefly but don't block.
    _ = child.wait() catch {};
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "plan insert_text passes through" {
    const alloc = std.testing.allocator;
    const p = plan(alloc, .{ .insert_text = @as([:0]const u8, "hello") }, .local);
    switch (p) {
        .insert_text => |t| try std.testing.expectEqualStrings("hello", t),
        else => return error.TestUnexpectedResult,
    }
}

test "plan reject passes through" {
    const alloc = std.testing.allocator;
    const p = plan(alloc, .reject, .local);
    switch (p) {
        .reject => {},
        else => return error.TestUnexpectedResult,
    }
}

test "plan empty file_paths rejects" {
    const alloc = std.testing.allocator;
    const p = plan(alloc, .{ .file_paths = &.{} }, .local);
    switch (p) {
        .reject => {},
        else => return error.TestUnexpectedResult,
    }
}

test "plan local file_paths inserts escaped text" {
    const alloc = std.testing.allocator;
    const paths = &[_][]const u8{ "/tmp/a.txt", "/tmp/b.txt" };
    const p = plan(alloc, .{ .file_paths = paths }, .local);
    switch (p) {
        .insert_text => |t| {
            defer alloc.free(t);
            try std.testing.expectEqualStrings("/tmp/a.txt /tmp/b.txt", t);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "plan local file_paths with spaces" {
    const alloc = std.testing.allocator;
    const paths = &[_][]const u8{"/tmp/my file.txt"};
    const p = plan(alloc, .{ .file_paths = paths }, .local);
    switch (p) {
        .insert_text => |t| {
            defer alloc.free(t);
            try std.testing.expectEqualStrings("/tmp/my\\ file.txt", t);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "remoteDropPath format" {
    var buf: [256]u8 = undefined;
    const result = remoteDropPath(&buf, "png") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, result, "/tmp/cmux-drop-"));
    try std.testing.expect(std.mem.endsWith(u8, result, ".png"));
    // Total: "/tmp/cmux-drop-" (15) + UUID (36) + ".png" (4) = 55.
    try std.testing.expectEqual(@as(usize, 55), result.len);
}

test "remoteDropPath no extension" {
    var buf: [256]u8 = undefined;
    const result = remoteDropPath(&buf, "") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, result, "/tmp/cmux-drop-"));
    // No dot, no extension.
    try std.testing.expect(!std.mem.endsWith(u8, result, "."));
    // Total: "/tmp/cmux-drop-" (15) + UUID (36) = 51.
    try std.testing.expectEqual(@as(usize, 51), result.len);
}

test "pathExtension basic" {
    try std.testing.expectEqualStrings("png", pathExtension("/tmp/file.png"));
    try std.testing.expectEqualStrings("gz", pathExtension("/tmp/archive.tar.gz"));
    try std.testing.expectEqualStrings("", pathExtension("/tmp/noext"));
    try std.testing.expectEqualStrings("", pathExtension(""));
    try std.testing.expectEqualStrings("txt", pathExtension("file.txt"));
}

test "Operation state machine" {
    // Test basic cancel.
    {
        var op = Operation{};
        try std.testing.expect(!op.isCancelled());
        try std.testing.expect(op.cancel());
        try std.testing.expect(op.isCancelled());
        // Double cancel returns false.
        try std.testing.expect(!op.cancel());
    }
    // Test basic finish.
    {
        var op = Operation{};
        try std.testing.expect(op.finish());
        // Can't cancel after finish.
        try std.testing.expect(!op.cancel());
        // Can't finish twice.
        try std.testing.expect(!op.finish());
    }
    // Test cancel after finish fails.
    {
        var op = Operation{};
        try std.testing.expect(op.finish());
        try std.testing.expect(!op.cancel());
        try std.testing.expect(!op.isCancelled());
    }
    // Test throwIfCancelled.
    {
        var op = Operation{};
        try op.throwIfCancelled(); // Should not error.
        _ = op.cancel();
        const err = op.throwIfCancelled();
        try std.testing.expectError(error.Cancelled, err);
    }
}

test "Operation cancellation handler" {
    const Handler = struct {
        var called: bool = false;
        fn handle(_: ?*anyopaque) void {
            called = true;
        }
    };

    // Handler called on cancel.
    {
        Handler.called = false;
        var op = Operation{};
        op.installCancellationHandler(&Handler.handle, null);
        _ = op.cancel();
        try std.testing.expect(Handler.called);
    }

    // Handler called immediately if already cancelled.
    {
        Handler.called = false;
        var op = Operation{};
        _ = op.cancel();
        Handler.called = false;
        op.installCancellationHandler(&Handler.handle, null);
        try std.testing.expect(Handler.called);
    }

    // Handler not called on finish.
    {
        Handler.called = false;
        var op = Operation{};
        op.installCancellationHandler(&Handler.handle, null);
        _ = op.finish();
        try std.testing.expect(!Handler.called);
    }

    // Clear handler prevents call.
    {
        Handler.called = false;
        var op = Operation{};
        op.installCancellationHandler(&Handler.handle, null);
        op.clearCancellationHandler();
        _ = op.cancel();
        try std.testing.expect(!Handler.called);
    }
}
