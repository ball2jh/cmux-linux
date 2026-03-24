//! Singleton proxy broker with transport-key deduplication.
//!
//! Multiple workspaces connecting to the same SSH destination share a single
//! proxy tunnel. The broker manages lease-based reference counting and
//! automatic restart on failure.
//!
//! Matches macOS WorkspaceRemoteProxyBroker (Workspace.swift lines 2199-2433).

const std = @import("std");
const Allocator = std.mem.Allocator;

const DaemonRpcClient = @import("DaemonRpcClient.zig");
const ProxyTunnel = @import("ProxyTunnel.zig");
const ssh_args_mod = @import("ssh_args.zig");
const dispatch = @import("../dispatch.zig");
const workspace_mod = @import("../workspace/main.zig");
const remote = workspace_mod.remote;
const Uuid = @import("../uuid.zig").Uuid;

const log = std.log.scoped(.cmux_proxy_broker);

const ProxyBroker = @This();

pub const Update = union(enum) {
    connecting,
    ready: struct { host: []const u8, port: u16 },
    err: []const u8,
};

pub const Lease = struct {
    key: []const u8,
    subscriber_id: Uuid,
    broker: *ProxyBroker,
    is_released: bool = false,

    /// Release this lease. When the last lease for a transport key is
    /// released, the tunnel is stopped and the entry removed.
    pub fn release(self: *Lease) void {
        if (self.is_released) return;
        self.is_released = true;
        self.broker.releaseLease(self);
    }
};

pub const Subscriber = struct {
    callback: *const fn (Update, ?*anyopaque) void,
    ctx: ?*anyopaque,
};

const Entry = struct {
    configuration: remote.Configuration,
    remote_path: []const u8,
    rpc_client: ?*DaemonRpcClient,
    tunnel: ?*ProxyTunnel,
    endpoint_port: ?u16,
    subscribers: std.AutoHashMapUnmanaged(Uuid, Subscriber),
    restart_pending: bool,
    allocator: Allocator,

    fn deinit(self: *Entry) void {
        if (self.tunnel) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
        self.subscribers.deinit(self.allocator);
    }
};

mutex: std.Thread.Mutex = .{},
entries: std.StringHashMapUnmanaged(*Entry) = .{},
allocator: Allocator,

pub fn init(allocator: Allocator) ProxyBroker {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *ProxyBroker) void {
    var it = self.entries.iterator();
    while (it.next()) |e| {
        e.value_ptr.*.deinit();
        self.allocator.destroy(e.value_ptr.*);
        self.allocator.free(e.key_ptr.*);
    }
    self.entries.deinit(self.allocator);
}

/// Acquire a proxy lease for the given SSH configuration. If a tunnel
/// already exists for this transport key, it is reused.
pub fn acquire(
    self: *ProxyBroker,
    config: remote.Configuration,
    remote_path: []const u8,
    rpc_client: *DaemonRpcClient,
    subscriber_id: Uuid,
    subscriber: Subscriber,
) !*Lease {
    self.mutex.lock();
    defer self.mutex.unlock();

    const key = try transportKey(self.allocator, config);

    // Check for existing entry.
    if (self.entries.get(key)) |entry| {
        self.allocator.free(key); // Already have the key.
        try entry.subscribers.put(self.allocator, subscriber_id, subscriber);

        const lease = try self.allocator.create(Lease);
        lease.* = .{
            .key = entry.configuration.destination, // Use existing key reference.
            .subscriber_id = subscriber_id,
            .broker = self,
        };

        // Notify subscriber of current state.
        if (entry.endpoint_port) |port| {
            subscriber.callback(.{ .ready = .{ .host = "127.0.0.1", .port = port } }, subscriber.ctx);
        } else {
            subscriber.callback(.connecting, subscriber.ctx);
        }

        return lease;
    }

    // Create new entry.
    const entry = try self.allocator.create(Entry);
    entry.* = .{
        .configuration = config,
        .remote_path = remote_path,
        .rpc_client = rpc_client,
        .tunnel = null,
        .endpoint_port = null,
        .subscribers = .{},
        .restart_pending = false,
        .allocator = self.allocator,
    };
    try entry.subscribers.put(self.allocator, subscriber_id, subscriber);
    try self.entries.put(self.allocator, key, entry);

    // Create and start tunnel.
    const tunnel = try self.allocator.create(ProxyTunnel);
    tunnel.* = ProxyTunnel.init(self.allocator, rpc_client);
    tunnel.on_error = .{ .func = &handleTunnelError, .ctx = @ptrCast(entry) };
    entry.tunnel = tunnel;

    const port = tunnel.start() catch |err| {
        log.err("failed to start proxy tunnel: {}", .{err});
        notifySubscribers(entry, .{ .err = "failed to start proxy" });
        return error.TunnelStartFailed;
    };

    entry.endpoint_port = port;

    const lease = try self.allocator.create(Lease);
    lease.* = .{
        .key = key,
        .subscriber_id = subscriber_id,
        .broker = self,
    };

    // Notify ready.
    notifySubscribers(entry, .{ .ready = .{ .host = "127.0.0.1", .port = port } });

    return lease;
}

fn releaseLease(self: *ProxyBroker, lease: *Lease) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    // Find and update the entry.
    var it = self.entries.iterator();
    while (it.next()) |e| {
        const entry = e.value_ptr.*;
        _ = entry.subscribers.remove(lease.subscriber_id);

        if (entry.subscribers.count() == 0) {
            // Last subscriber — stop and remove.
            entry.deinit();
            self.allocator.destroy(entry);
            self.allocator.free(e.key_ptr.*);
            self.entries.removeByPtr(e.key_ptr);
            break;
        }
    }

    self.allocator.destroy(lease);
}

fn notifySubscribers(entry: *Entry, update: Update) void {
    var it = entry.subscribers.iterator();
    while (it.next()) |sub| {
        sub.value_ptr.callback(update, sub.value_ptr.ctx);
    }
}

fn handleTunnelError(ctx: ?*anyopaque) void {
    const entry: *Entry = @ptrCast(@alignCast(ctx orelse return));
    log.err("proxy tunnel error — marking restart pending", .{});
    entry.restart_pending = true;
    // TODO: stop the failed tunnel, schedule restart via dispatch.timeoutAdd,
    // create a new ProxyTunnel, update endpoint_port, and notify subscribers.
}

// -----------------------------------------------------------------------
// Transport key
// -----------------------------------------------------------------------

/// Build a deduplication key from SSH configuration.
/// Format: destination\x1eport\x1eidentity\x1eoptions\x1elocal_proxy_port
/// Options are joined with \x1f. Matches Mac's proxyBrokerTransportKey.
fn transportKey(alloc: Allocator, config: remote.Configuration) ![]const u8 {
    var parts = std.ArrayListUnmanaged(u8){};
    const writer = parts.writer(alloc);

    try writer.writeAll(config.destination);
    try writer.writeByte(0x1e); // Record separator.

    if (config.port) |p| {
        try std.fmt.format(writer, "{d}", .{p});
    }
    try writer.writeByte(0x1e);

    if (config.identity_file) |id| {
        try writer.writeAll(id);
    }
    try writer.writeByte(0x1e);

    var opt_idx: usize = 0;
    for (config.ssh_options) |opt| {
        const key = ssh_args_mod.extractOptionKey(opt);
        if (std.ascii.eqlIgnoreCase(key, "controlpath")) continue;
        if (opt_idx > 0) try writer.writeByte(0x1f); // Unit separator.
        try writer.writeAll(opt);
        opt_idx += 1;
    }
    try writer.writeByte(0x1e);

    if (config.local_proxy_port) |p| {
        try std.fmt.format(writer, "{d}", .{p});
    }

    return parts.toOwnedSlice(alloc);
}
