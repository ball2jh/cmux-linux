//! Orchestrator for the remote workspace connection lifecycle.
//!
//! Manages the full bootstrap sequence: probe platform, download/verify
//! daemon binary, start daemon via DaemonRpcClient, acquire proxy lease,
//! and optionally start CLI relay. Handles reconnect with retry logic.
//!
//! Runs on a dedicated worker thread (replaces Mac's GCD serial queue).
//! State updates are published to the Workspace via dispatch.idleAdd()
//! for GTK main thread delivery.
//!
//! Matches macOS WorkspaceRemoteSessionController
//! (Workspace.swift lines 2915-4600+).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const DaemonRpcClient = @import("DaemonRpcClient.zig");
const DaemonManifest = @import("DaemonManifest.zig");
const ProxyBroker = @import("ProxyBroker.zig");
const process_mod = @import("process.zig");
const ssh_args = @import("ssh_args.zig");
const dispatch = @import("../dispatch.zig");
const workspace_mod = @import("../workspace/main.zig");
const remote = workspace_mod.remote;
const Uuid = @import("../uuid.zig").Uuid;

const log = std.log.scoped(.cmux_session_controller);

const SessionController = @This();

/// State update callback — delivers connection state changes to the Workspace
/// on the GTK main thread.
pub const StateCallback = struct {
    on_connection_state: *const fn (remote.ConnectionState, ?[]const u8, ?*anyopaque) void,
    on_daemon_status: *const fn (remote.DaemonStatus, ?*anyopaque) void,
    ctx: ?*anyopaque,
};

// --- Configuration ---
workspace_id: Uuid,
configuration: remote.Configuration,
state_callback: ?StateCallback = null,
proxy_broker: ?*ProxyBroker = null,

// --- Worker state ---
mutex: std.Thread.Mutex = .{},
worker_thread: ?std.Thread = null,
is_stopping: bool = false,
controller_id: Uuid,
reconnect_retry_count: u32 = 0,

// --- Runtime ---
rpc_client: ?*DaemonRpcClient = null,
proxy_lease: ?*ProxyBroker.Lease = null,
daemon_ready: bool = false,
daemon_remote_path: ?[]const u8 = null,

allocator: Allocator,

pub fn init(
    allocator: Allocator,
    workspace_id: Uuid,
    config: remote.Configuration,
) SessionController {
    return .{
        .workspace_id = workspace_id,
        .configuration = config,
        .controller_id = Uuid.generate(),
        .allocator = allocator,
    };
}

pub fn deinit(self: *SessionController) void {
    self.stop();
}

/// Start the connection sequence on a background worker thread.
pub fn start(self: *SessionController) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.worker_thread != null) return; // Already running.
    self.is_stopping = false;

    self.worker_thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
        log.err("failed to spawn worker thread: {}", .{err});
        self.publishConnectionState(.@"error", "Failed to start connection worker");
        return;
    };
}

/// Stop the connection sequence and clean up all resources.
pub fn stop(self: *SessionController) void {
    self.mutex.lock();
    self.is_stopping = true;
    self.mutex.unlock();

    // Stop RPC client (unblocks any waiting calls).
    if (self.rpc_client) |client| {
        client.stop();
    }

    // Release proxy lease.
    if (self.proxy_lease) |lease| {
        lease.release();
        self.proxy_lease = null;
    }

    // Join worker thread.
    if (self.worker_thread) |t| {
        t.join();
        self.worker_thread = null;
    }

    // Clean up RPC client.
    if (self.rpc_client) |client| {
        client.deinit();
        self.allocator.destroy(client);
        self.rpc_client = null;
    }

    self.daemon_ready = false;
    self.daemon_remote_path = null;
}

// -----------------------------------------------------------------------
// Worker thread
// -----------------------------------------------------------------------

fn workerMain(self: *SessionController) void {
    defer {
        self.mutex.lock();
        self.worker_thread = null;
        self.mutex.unlock();
    }

    self.publishConnectionState(.connecting, null);
    self.publishDaemonStatus(.{ .state = .bootstrapping });

    // Step 1: Probe platform.
    const probe_result = self.probePlatform() catch |err| {
        log.err("platform probe failed: {}", .{err});
        self.publishConnectionState(.@"error", "Platform probe failed");
        self.scheduleReconnect();
        return;
    };

    if (self.shouldStop()) return;

    // Step 2: Bootstrap daemon (check/download/upload binary).
    const remote_path = self.bootstrapDaemon(probe_result) catch |err| {
        log.err("daemon bootstrap failed: {}", .{err});
        self.publishConnectionState(.@"error", "Daemon bootstrap failed");
        self.scheduleReconnect();
        return;
    };

    if (self.shouldStop()) return;

    // Step 3: Start persistent daemon via RPC client.
    self.startDaemon(remote_path) catch |err| {
        log.err("daemon start failed: {}", .{err});
        self.publishConnectionState(.@"error", "Daemon start failed");
        self.scheduleReconnect();
        return;
    };

    if (self.shouldStop()) return;

    // Step 4: Acquire proxy lease.
    if (self.proxy_broker) |broker| {
        self.acquireProxy(broker) catch |err| {
            log.warn("proxy acquisition failed: {}", .{err});
            // Non-fatal — connection is still usable without proxy.
        };
    }

    // Step 5: Mark connected.
    self.daemon_ready = true;
    self.publishConnectionState(.connected, null);
    self.reconnect_retry_count = 0;

    log.info("remote workspace connected: {s}", .{self.configuration.destination});
}

fn probePlatform(self: *SessionController) !DaemonManifest.ProbeResult {
    const version = "0.1.0"; // TODO: read from build config.
    var script_buf: [2048]u8 = undefined;
    const script = try DaemonManifest.probeScript(&script_buf, version);

    // Build SSH command for probe.
    const common_args = try ssh_args.buildCommonArgs(self.allocator, self.configuration, true);
    defer self.allocator.free(common_args);
    defer {
        for (common_args) |a| {
            if (a.len <= 5 and a.len > 0) {
                if (std.fmt.parseInt(u16, a, 10)) |_| {
                    self.allocator.free(a);
                } else |_| {}
            }
        }
    }

    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(self.allocator);

    try argv.append(self.allocator, "ssh");
    try argv.append(self.allocator, "-T");
    try argv.appendSlice(self.allocator, &.{ "-S", "none" });
    try argv.appendSlice(self.allocator, common_args);
    try argv.append(self.allocator, self.configuration.destination);

    // Wrap script in sh -c.
    var cmd_buf: [2200]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "sh -c '{s}'", .{script}) catch return error.ScriptTooLong;
    try argv.append(self.allocator, cmd);

    var result = try process_mod.run(self.allocator, argv.items, 8000);
    defer process_mod.freeResult(self.allocator, &result);

    if (result.timed_out) return error.ProbeTimeout;
    if (result.exit_code != 0) return error.ProbeExitCode;

    return DaemonManifest.parseProbeOutput(result.stdout) orelse error.ProbeParseFailed;
}

fn bootstrapDaemon(self: *SessionController, probe: DaemonManifest.ProbeResult) ![]const u8 {
    const go_os = DaemonManifest.mapUnameOS(probe.os) orelse return error.UnsupportedOS;
    const go_arch = DaemonManifest.mapUnameArch(probe.arch) orelse return error.UnsupportedArch;

    _ = go_os;
    _ = go_arch;

    if (probe.binary_exists) {
        // Binary already on remote — build the path.
        const version = "0.1.0"; // TODO: read from build config.
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "$HOME/.cmux/bin/cmuxd-remote/{s}/{s}-{s}/cmuxd-remote", .{
            version,
            DaemonManifest.mapUnameOS(probe.os) orelse return error.UnsupportedOS,
            DaemonManifest.mapUnameArch(probe.arch) orelse return error.UnsupportedArch,
        }) catch return error.PathTooLong;
        return try self.allocator.dupe(u8, path);
    }

    // TODO: Download from GitHub releases, verify SHA-256, upload via SCP.
    // For now, return error — this will be filled in when we have the
    // manifest embedded in the binary.
    return error.DaemonNotAvailable;
}

fn startDaemon(self: *SessionController, remote_path: []const u8) !void {
    self.daemon_remote_path = remote_path;

    // Create and start RPC client.
    const client = try self.allocator.create(DaemonRpcClient);
    client.* = DaemonRpcClient.init(self.allocator, self.configuration, remote_path);
    self.rpc_client = client;

    try client.start();

    // Hello handshake.
    const hello_result = try client.hello();

    // Verify required capability.
    if (!hello_result.hasCapability("proxy.stream.push") and
        !hello_result.hasCapability("proxy_stream"))
    {
        log.err("daemon missing required capability: proxy.stream.push", .{});
        return error.MissingCapability;
    }

    self.publishDaemonStatus(.{
        .state = .ready,
        .version = hello_result.version,
        .name = hello_result.name,
        .capabilities = hello_result.capabilities,
        .remote_path = hello_result.remote_path,
    });
}

fn acquireProxy(self: *SessionController, broker: *ProxyBroker) !void {
    const client = self.rpc_client orelse return error.NoRpcClient;

    self.proxy_lease = try broker.acquire(
        self.configuration,
        self.daemon_remote_path orelse "",
        client,
        self.workspace_id,
        .{
            .callback = &struct {
                fn cb(_: ProxyBroker.Update, _: ?*anyopaque) void {
                    // TODO: forward proxy updates to workspace state.
                }
            }.cb,
            .ctx = null,
        },
    );
}

// -----------------------------------------------------------------------
// Reconnect logic
// -----------------------------------------------------------------------

fn scheduleReconnect(self: *SessionController) void {
    if (self.shouldStop()) return;

    self.reconnect_retry_count += 1;
    const delay_ms: c_uint = 4000; // 4 seconds, matching Mac.

    log.info("scheduling reconnect attempt #{d} in {d}ms", .{
        self.reconnect_retry_count,
        delay_ms,
    });

    // Schedule via GLib timeout on main thread.
    // We pack self as the userdata.
    const self_ptr: *SessionController = self;
    dispatch.timeoutAdd(delay_ms, &struct {
        fn cb(data: ?*anyopaque) callconv(.c) c_int {
            const ctrl: *SessionController = @ptrCast(@alignCast(data orelse return 0));
            if (ctrl.shouldStop()) return 0;
            ctrl.start();
            return 0; // G_SOURCE_REMOVE
        }
    }.cb, @ptrCast(self_ptr));
}

// -----------------------------------------------------------------------
// State publishing
// -----------------------------------------------------------------------

fn publishConnectionState(self: *SessionController, state: remote.ConnectionState, detail: ?[]const u8) void {
    if (self.state_callback) |cb| {
        cb.on_connection_state(state, detail, cb.ctx);
    }
}

fn publishDaemonStatus(self: *SessionController, status: remote.DaemonStatus) void {
    if (self.state_callback) |cb| {
        cb.on_daemon_status(status, cb.ctx);
    }
}

fn shouldStop(self: *SessionController) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.is_stopping;
}

// --- File upload via SCP ---

const image_transfer_mod = @import("../image_transfer.zig");

/// Upload files to the remote host via SCP using this session's configuration.
/// Blocks the calling thread. Suitable for calling from a background thread.
pub fn uploadDroppedFiles(
    self: *SessionController,
    file_paths: []const []const u8,
    operation: *image_transfer_mod.Operation,
) image_transfer_mod.UploadResult {
    const alloc = self.allocator;
    var remote_paths = std.ArrayListUnmanaged([]const u8){};

    for (file_paths) |local_path| {
        if (operation.isCancelled()) {
            cleanupRemotePaths(alloc, self.configuration, remote_paths.items);
            return .{ .failure = "cancelled" };
        }

        var rpath_buf: [256]u8 = undefined;
        const ext = image_transfer_mod.pathExtension(local_path);
        const rpath = image_transfer_mod.remoteDropPath(&rpath_buf, ext) orelse {
            cleanupRemotePaths(alloc, self.configuration, remote_paths.items);
            return .{ .failure = "failed to generate remote path" };
        };

        const rpath_owned = alloc.dupe(u8, rpath) catch {
            cleanupRemotePaths(alloc, self.configuration, remote_paths.items);
            return .{ .failure = "out of memory" };
        };

        // Build remote destination: "dest:path".
        const remote_dest = std.fmt.allocPrint(alloc, "{s}:{s}", .{
            self.configuration.destination, rpath,
        }) catch {
            alloc.free(rpath_owned);
            cleanupRemotePaths(alloc, self.configuration, remote_paths.items);
            return .{ .failure = "out of memory" };
        };
        defer alloc.free(remote_dest);

        const scp_args = ssh_args.buildScpArgs(
            alloc, self.configuration, local_path, remote_dest,
        ) catch {
            alloc.free(rpath_owned);
            cleanupRemotePaths(alloc, self.configuration, remote_paths.items);
            return .{ .failure = "failed to build SCP arguments" };
        };
        defer alloc.free(scp_args);

        // Prepend "scp" binary.
        var argv = std.ArrayListUnmanaged([]const u8){};
        defer argv.deinit(alloc);
        argv.append(alloc, "scp") catch {
            alloc.free(rpath_owned);
            cleanupRemotePaths(alloc, self.configuration, remote_paths.items);
            return .{ .failure = "out of memory" };
        };
        argv.appendSlice(alloc, scp_args) catch {
            alloc.free(rpath_owned);
            cleanupRemotePaths(alloc, self.configuration, remote_paths.items);
            return .{ .failure = "out of memory" };
        };

        const result = process_mod.run(alloc, argv.items, 45_000) catch {
            alloc.free(rpath_owned);
            cleanupRemotePaths(alloc, self.configuration, remote_paths.items);
            return .{ .failure = "scp process error" };
        };

        if (result.exit_code != 0) {
            alloc.free(rpath_owned);
            cleanupRemotePaths(alloc, self.configuration, remote_paths.items);
            if (result.stderr.len > 0) {
                log.err("scp failed: {s}", .{result.stderr});
            }
            return .{ .failure = "scp upload failed" };
        }

        remote_paths.append(alloc, rpath_owned) catch {
            alloc.free(rpath_owned);
            cleanupRemotePaths(alloc, self.configuration, remote_paths.items);
            return .{ .failure = "out of memory" };
        };
    }

    return .{ .success = remote_paths.toOwnedSlice(alloc) catch &.{} };
}

fn cleanupRemotePaths(alloc: Allocator, config: remote.Configuration, paths: []const []const u8) void {
    if (paths.len == 0) return;

    // Build cleanup command: rm -f -- '/path1' '/path2'
    var cmd_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const prefix = "rm -f --";
    @memcpy(cmd_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    for (paths) |rp| {
        if (pos + 4 + rp.len > cmd_buf.len) break;
        cmd_buf[pos] = ' ';
        cmd_buf[pos + 1] = '\'';
        pos += 2;
        @memcpy(cmd_buf[pos..][0..rp.len], rp);
        pos += rp.len;
        cmd_buf[pos] = '\'';
        pos += 1;
    }

    // Build SSH command for cleanup.
    const common_args = ssh_args.buildCommonArgs(alloc, config, true) catch return;
    defer alloc.free(common_args);

    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(alloc);
    argv.append(alloc, "ssh") catch return;
    argv.appendSlice(alloc, common_args) catch return;
    argv.append(alloc, config.destination) catch return;
    argv.append(alloc, alloc.dupe(u8, cmd_buf[0..pos]) catch return) catch return;

    _ = process_mod.run(alloc, argv.items, 8_000) catch {};
}
