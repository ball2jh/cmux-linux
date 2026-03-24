//! SSH argument builder shared by DaemonRpcClient, SessionController,
//! CliRelayServer, and SCP upload logic.
//!
//! Matches macOS Workspace.sshCommonArguments (Workspace.swift line ~1300).

const std = @import("std");
const Allocator = std.mem.Allocator;
const workspace_mod = @import("../workspace/main.zig");
const remote = workspace_mod.remote;

/// Build the common SSH argument list used by all SSH-spawning code.
///
/// Argument order (matching Mac exactly):
///   1. Base: ConnectTimeout, ServerAliveInterval, ServerAliveCountMax
///   2. Conditional: StrictHostKeyChecking=accept-new (if not in user options)
///   3. Batch mode: BatchMode=yes, ControlMaster=no
///   4. Port: -p <port>
///   5. Identity: -i <path>
///   6. User SSH options: -o <option> (filtered in batch mode)
pub fn buildCommonArgs(
    alloc: Allocator,
    config: remote.Configuration,
    batch_mode: bool,
) ![]const []const u8 {
    var args = std.ArrayListUnmanaged([]const u8){};

    // 1. Base options (always present).
    try args.appendSlice(alloc, &.{
        "-o", "ConnectTimeout=6",
        "-o", "ServerAliveInterval=20",
        "-o", "ServerAliveCountMax=2",
    });

    // 2. StrictHostKeyChecking (only if user hasn't overridden it).
    if (!hasOptionKey(config.ssh_options, "stricthostkeychecking")) {
        try args.appendSlice(alloc, &.{ "-o", "StrictHostKeyChecking=accept-new" });
    }

    // 3. Batch mode arguments.
    if (batch_mode) {
        try args.appendSlice(alloc, &.{
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        });
    }

    // 4. Port.
    if (config.port) |port| {
        var buf: [6]u8 = undefined;
        const port_str = std.fmt.bufPrint(&buf, "{d}", .{port}) catch unreachable;
        try args.appendSlice(alloc, &.{ "-p", try alloc.dupe(u8, port_str) });
    }

    // 5. Identity file.
    if (config.identity_file) |identity| {
        if (identity.len > 0) {
            try args.appendSlice(alloc, &.{ "-i", identity });
        }
    }

    // 6. User SSH options (filtered in batch mode).
    for (config.ssh_options) |opt| {
        if (batch_mode and isControlOption(opt)) continue;
        try args.appendSlice(alloc, &.{ "-o", opt });
    }

    return args.toOwnedSlice(alloc);
}

/// Build SCP arguments for binary upload.
/// SCP uses -P (capital) for port instead of -p.
pub fn buildScpArgs(
    alloc: Allocator,
    config: remote.Configuration,
    local_path: []const u8,
    remote_dest: []const u8,
) ![]const []const u8 {
    var args = std.ArrayListUnmanaged([]const u8){};

    try args.append(alloc, "-q"); // Quiet mode.

    // StrictHostKeyChecking.
    if (!hasOptionKey(config.ssh_options, "stricthostkeychecking")) {
        try args.appendSlice(alloc, &.{ "-o", "StrictHostKeyChecking=accept-new" });
    }

    try args.appendSlice(alloc, &.{ "-o", "ControlMaster=no" });

    // Port (SCP uses -P).
    if (config.port) |port| {
        var buf: [6]u8 = undefined;
        const port_str = std.fmt.bufPrint(&buf, "{d}", .{port}) catch unreachable;
        try args.appendSlice(alloc, &.{ "-P", try alloc.dupe(u8, port_str) });
    }

    // Identity file.
    if (config.identity_file) |identity| {
        if (identity.len > 0) {
            try args.appendSlice(alloc, &.{ "-i", identity });
        }
    }

    // User SSH options (always filtered for background).
    for (config.ssh_options) |opt| {
        if (isControlOption(opt)) continue;
        try args.appendSlice(alloc, &.{ "-o", opt });
    }

    // Source and destination.
    try args.append(alloc, local_path);
    try args.append(alloc, remote_dest);

    return args.toOwnedSlice(alloc);
}

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

/// Check if the user's SSH options contain a specific key (case-insensitive).
fn hasOptionKey(options: []const []const u8, key: []const u8) bool {
    for (options) |opt| {
        if (optionKeyMatches(opt, key)) return true;
    }
    return false;
}

/// Check if an SSH option string has a key matching the target (case-insensitive).
/// Options are in KEY=VALUE format.
fn optionKeyMatches(opt: []const u8, target: []const u8) bool {
    const key = extractOptionKey(opt);
    if (key.len != target.len) return false;
    return std.ascii.eqlIgnoreCase(key, target);
}

/// Extract the key part from a KEY=VALUE or KEY VALUE option string.
pub fn extractOptionKey(opt: []const u8) []const u8 {
    for (opt, 0..) |c, i| {
        if (c == '=' or c == ' ' or c == '\t') return opt[0..i];
    }
    return opt; // No separator — entire string is the key.
}

/// Check if an option is a ControlMaster or ControlPersist option.
/// These are filtered out in batch mode to avoid interference.
fn isControlOption(opt: []const u8) bool {
    const key = extractOptionKey(opt);
    return std.ascii.eqlIgnoreCase(key, "controlmaster") or
        std.ascii.eqlIgnoreCase(key, "controlpersist");
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "buildCommonArgs basic" {
    const alloc = std.testing.allocator;
    const config = remote.Configuration{
        .destination = "user@host",
    };
    const args = try buildCommonArgs(alloc, config, false);
    defer alloc.free(args);

    // Should contain base options + StrictHostKeyChecking.
    try std.testing.expect(args.len >= 8);
    try std.testing.expectEqualStrings("-o", args[0]);
    try std.testing.expectEqualStrings("ConnectTimeout=6", args[1]);
}

test "buildCommonArgs batch mode" {
    const alloc = std.testing.allocator;
    const config = remote.Configuration{
        .destination = "user@host",
        .port = 2222,
    };
    const args = try buildCommonArgs(alloc, config, true);
    defer {
        // Free the port string we allocated.
        for (args) |a| {
            // Only free if it's a numeric port string we allocated.
            if (a.len <= 5 and a.len > 0) {
                if (std.fmt.parseInt(u16, a, 10)) |_| {
                    alloc.free(a);
                } else |_| {}
            }
        }
        alloc.free(args);
    }

    // Should contain BatchMode=yes and ControlMaster=no.
    var has_batch = false;
    var has_control = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "BatchMode=yes")) has_batch = true;
        if (std.mem.eql(u8, a, "ControlMaster=no")) has_control = true;
    }
    try std.testing.expect(has_batch);
    try std.testing.expect(has_control);
}

test "buildCommonArgs user StrictHostKeyChecking not duplicated" {
    const alloc = std.testing.allocator;
    const opts = [_][]const u8{"StrictHostKeyChecking=no"};
    const config = remote.Configuration{
        .destination = "user@host",
        .ssh_options = &opts,
    };
    const args = try buildCommonArgs(alloc, config, false);
    defer alloc.free(args);

    var count: usize = 0;
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "StrictHostKeyChecking")) count += 1;
    }
    // Only the user's option, not our default.
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "isControlOption" {
    try std.testing.expect(isControlOption("ControlMaster=auto"));
    try std.testing.expect(isControlOption("controlmaster=auto"));
    try std.testing.expect(isControlOption("ControlPersist=yes"));
    try std.testing.expect(!isControlOption("ConnectTimeout=6"));
    try std.testing.expect(!isControlOption("BatchMode=yes"));
}

test "extractOptionKey" {
    try std.testing.expectEqualStrings("ConnectTimeout", extractOptionKey("ConnectTimeout=6"));
    try std.testing.expectEqualStrings("BatchMode", extractOptionKey("BatchMode yes"));
    try std.testing.expectEqualStrings("IdentityFile", extractOptionKey("IdentityFile"));
}
