//! Reverse SSH tunnel management for CLI relay.
//!
//! Manages the `ssh -N -R 127.0.0.1:<relay_port>:127.0.0.1:<local_port>`
//! process that forwards the remote relay port back to the local relay server.
//!
//! Matches macOS reverse tunnel setup in WorkspaceRemoteSessionController.

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const ssh_args_mod = @import("ssh_args.zig");
const workspace_mod = @import("../workspace/main.zig");
const remote = workspace_mod.remote;

const log = std.log.scoped(.cmux_relay_tunnel);

/// Start a reverse SSH tunnel.
///
/// Returns the spawned child process. Caller is responsible for
/// stopping it via kill + wait.
pub fn startReverseTunnel(
    alloc: Allocator,
    config: remote.Configuration,
    relay_port: u16,
    local_port: u16,
) !std.process.Child {
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(alloc);

    try argv.append(alloc, "ssh");
    try argv.appendSlice(alloc, &.{ "-N", "-T" });
    try argv.appendSlice(alloc, &.{ "-S", "none" });
    try argv.appendSlice(alloc, &.{ "-o", "ExitOnForwardFailure=yes" });
    try argv.appendSlice(alloc, &.{ "-o", "RequestTTY=no" });

    const common = try ssh_args_mod.buildCommonArgs(alloc, config, true);
    defer alloc.free(common);
    defer {
        for (common) |a| {
            if (a.len <= 5 and a.len > 0) {
                if (std.fmt.parseInt(u16, a, 10)) |_| {
                    alloc.free(a);
                } else |_| {}
            }
        }
    }
    try argv.appendSlice(alloc, common);

    // Reverse tunnel: -R remote_bind:local_bind.
    var tunnel_spec_buf: [128]u8 = undefined;
    const tunnel_spec = std.fmt.bufPrint(&tunnel_spec_buf, "127.0.0.1:{d}:127.0.0.1:{d}", .{
        relay_port,
        local_port,
    }) catch return error.FormatError;
    try argv.appendSlice(alloc, &.{ "-R", tunnel_spec });

    try argv.append(alloc, config.destination);

    var child = std.process.Child.init(argv.items, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    log.info("reverse tunnel started: {s}:{d} -> 127.0.0.1:{d}", .{
        config.destination,
        relay_port,
        local_port,
    });

    return child;
}

/// Write relay metadata files on the remote host.
/// Creates ~/.cmux/relay/<port>.auth and ~/.cmux/relay/<port>.daemon_path.
pub fn writeRelayMetadata(
    alloc: Allocator,
    config: remote.Configuration,
    relay_port: u16,
    relay_id: []const u8,
    relay_token: []const u8,
    daemon_path: []const u8,
) !void {
    // Build the SSH command to write metadata files.
    var script_buf: [2048]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf,
        \\umask 077 && \
        \\mkdir -p "$HOME/.cmux/relay" && \
        \\chmod 700 "$HOME/.cmux/relay" && \
        \\printf '{{"relay_id":"{s}","relay_token":"{s}"}}\n' > "$HOME/.cmux/relay/{d}.auth" && \
        \\chmod 600 "$HOME/.cmux/relay/{d}.auth" && \
        \\printf '{s}\n' > "$HOME/.cmux/relay/{d}.daemon_path" && \
        \\printf '127.0.0.1:{d}\n' > "$HOME/.cmux/socket_addr"
    , .{
        relay_id,
        relay_token,
        relay_port,
        relay_port,
        daemon_path,
        relay_port,
        relay_port,
    }) catch return error.ScriptTooLong;

    const common = try ssh_args_mod.buildCommonArgs(alloc, config, true);
    defer alloc.free(common);
    defer {
        for (common) |a| {
            if (a.len <= 5 and a.len > 0) {
                if (std.fmt.parseInt(u16, a, 10)) |_| {
                    alloc.free(a);
                } else |_| {}
            }
        }
    }

    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(alloc);

    try argv.append(alloc, "ssh");
    try argv.append(alloc, "-T");
    try argv.appendSlice(alloc, &.{ "-S", "none" });
    try argv.appendSlice(alloc, common);
    try argv.append(alloc, config.destination);
    try argv.append(alloc, script);

    var child = std.process.Child.init(argv.items, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const term = try child.wait();

    if (term != .exited or term.exited != 0) {
        log.warn("failed to write relay metadata on remote", .{});
        return error.MetadataWriteFailed;
    }
}

/// Clean up relay metadata and kill orphaned tunnel processes.
pub fn cleanupOrphanedRelays(
    alloc: Allocator,
    config: remote.Configuration,
    relay_port: u16,
) void {
    // Remove metadata files on remote.
    var script_buf: [512]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf,
        \\rm -f "$HOME/.cmux/relay/{d}.auth" "$HOME/.cmux/relay/{d}.daemon_path" && \
        \\rm -f "$HOME/.cmux/socket_addr"
    , .{ relay_port, relay_port }) catch return;

    const common = ssh_args_mod.buildCommonArgs(alloc, config, true) catch return;
    defer alloc.free(common);
    defer {
        for (common) |a| {
            if (a.len <= 5 and a.len > 0) {
                if (std.fmt.parseInt(u16, a, 10)) |_| {
                    alloc.free(a);
                } else |_| {}
            }
        }
    }

    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(alloc);

    argv.append(alloc, "ssh") catch return;
    argv.append(alloc, "-T") catch return;
    argv.appendSlice(alloc, &.{ "-S", "none" }) catch return;
    argv.appendSlice(alloc, common) catch return;
    argv.append(alloc, config.destination) catch return;
    argv.append(alloc, script) catch return;

    var child = std.process.Child.init(argv.items, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    if (child.spawn()) |_| {
        _ = child.wait() catch {};
    } else |_| {}
}
