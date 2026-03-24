//! SSH stdio transport for JSON-RPC communication with cmuxd-remote.
//!
//! Spawns `ssh user@host 'cmuxd-remote serve --stdio'` and communicates
//! via stdin/stdout pipes. Each JSON-RPC request is a single line; responses
//! arrive as lines on stdout. Pushed stream events (proxy.stream.data/eof/error)
//! are dispatched to registered subscribers.
//!
//! Thread model:
//!   - Stdout reader thread: parses JSON lines, resolves pending calls or
//!     dispatches stream events
//!   - Stderr reader thread: drains into bounded buffer for diagnostics
//!   - Caller thread: call() registers a PendingCall, writes to stdin, waits
//!
//! Matches macOS WorkspaceRemoteDaemonRPCClient (Workspace.swift lines 791-1297).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const posix = std.posix;

const PendingCallRegistry = @import("PendingCallRegistry.zig");
const ssh_args = @import("ssh_args.zig");
const dispatch = @import("../dispatch.zig");
const workspace_mod = @import("../workspace/main.zig");
const remote = workspace_mod.remote;

const log = std.log.scoped(.cmux_daemon_rpc);

const DaemonRpcClient = @This();

/// Callback for stream events dispatched to subscribers.
pub const StreamEvent = union(enum) {
    data: []const u8, // base64-encoded bytes
    eof: []const u8, // may carry trailing data
    err: []const u8,
};

pub const StreamSubscription = struct {
    callback: *const fn (StreamEvent, ?*anyopaque) void,
    ctx: ?*anyopaque,
};

/// Callback when the daemon process terminates unexpectedly.
pub const TerminationCallback = struct {
    func: *const fn ([]const u8, ?*anyopaque) void,
    ctx: ?*anyopaque,
};

// --- Configuration ---
configuration: remote.Configuration,
remote_path: []const u8,
on_termination: ?TerminationCallback = null,

// --- Internal state (protected by mutex) ---
mutex: std.Thread.Mutex = .{},
process: ?std.process.Child = null,
is_closed: bool = false,
should_report_termination: bool = true,
pending_calls: PendingCallRegistry,
stream_subscriptions: std.StringHashMapUnmanaged(StreamSubscription) = .{},

// --- Threads ---
stdout_thread: ?std.Thread = null,
stderr_thread: ?std.Thread = null,

// --- Stderr buffer ---
stderr_buf: [8192]u8 = undefined,
stderr_len: usize = 0,

// --- Allocator ---
allocator: Allocator,

pub fn init(
    allocator: Allocator,
    config: remote.Configuration,
    remote_path: []const u8,
) DaemonRpcClient {
    return .{
        .configuration = config,
        .remote_path = remote_path,
        .pending_calls = PendingCallRegistry.init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *DaemonRpcClient) void {
    self.stop();
    self.pending_calls.deinit();
    self.stream_subscriptions.deinit(self.allocator);
}

/// Start the SSH process and reader threads. After this returns, call()
/// can be used to send RPC requests.
pub fn start(self: *DaemonRpcClient) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.process != null) return error.AlreadyStarted;
    self.is_closed = false;
    self.should_report_termination = true;

    // Build SSH command: ssh -T -S none [common_args] destination 'cmuxd-remote serve --stdio'
    var argv_list = std.ArrayListUnmanaged([]const u8){};
    defer argv_list.deinit(self.allocator);

    try argv_list.append(self.allocator, "ssh");
    try argv_list.append(self.allocator, "-T");
    try argv_list.appendSlice(self.allocator, &.{ "-S", "none" });

    const common_args = try ssh_args.buildCommonArgs(self.allocator, self.configuration, true);
    defer self.allocator.free(common_args);
    // Free any port strings that were allocated.
    defer {
        for (common_args) |a| {
            if (a.len <= 5 and a.len > 0) {
                if (std.fmt.parseInt(u16, a, 10)) |_| {
                    self.allocator.free(a);
                } else |_| {}
            }
        }
    }
    try argv_list.appendSlice(self.allocator, common_args);

    try argv_list.append(self.allocator, self.configuration.destination);

    // Remote command: exec the daemon in stdio mode.
    var cmd_buf: [512]u8 = undefined;
    const remote_cmd = std.fmt.bufPrint(&cmd_buf, "'{s}' serve --stdio", .{self.remote_path}) catch return error.PathTooLong;
    try argv_list.append(self.allocator, remote_cmd);

    var child = std.process.Child.init(argv_list.items, self.allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    self.process = child;

    // Start reader threads.
    self.stdout_thread = std.Thread.spawn(.{}, stdoutReaderThread, .{self}) catch |err| {
        log.err("failed to spawn stdout reader: {}", .{err});
        return err;
    };
    self.stderr_thread = std.Thread.spawn(.{}, stderrReaderThread, .{self}) catch |err| {
        log.err("failed to spawn stderr reader: {}", .{err});
        return err;
    };
}

/// Stop the SSH process and clean up threads.
pub fn stop(self: *DaemonRpcClient) void {
    // Copy state under lock.
    self.mutex.lock();
    self.is_closed = true;
    self.should_report_termination = false;
    const maybe_process = &self.process;
    const stdout_t = self.stdout_thread;
    const stderr_t = self.stderr_thread;
    self.stdout_thread = null;
    self.stderr_thread = null;
    self.mutex.unlock();

    if (maybe_process.*) |*proc| {
        _ = proc.kill() catch {};
    }

    // Fail all pending calls so waiters wake up.
    self.pending_calls.failAll("client stopped");

    // Join threads (safe — we own the handles now).
    if (stdout_t) |t| t.join();
    if (stderr_t) |t| t.join();

    if (self.process) |*proc| {
        _ = proc.wait() catch {};
        self.process = null;
    }

    self.pending_calls.reset();
}

/// Send an RPC call and wait for the response synchronously.
/// Timeout is in nanoseconds.
pub fn call(
    self: *DaemonRpcClient,
    method: []const u8,
    params: json.Value,
    timeout_ns: u64,
) !json.Value {
    const pending = try self.pending_calls.register();
    errdefer self.pending_calls.remove(pending);

    // Build JSON request line. 64KB to accommodate large base64 payloads.
    var buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try std.json.stringify(.{
        .id = pending.id,
        .method = method,
        .params = params,
    }, .{}, writer);
    try writer.writeByte('\n');
    const request_bytes = fbs.getWritten();

    // Write to stdin.
    {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_closed) return error.ClientClosed;
        if (self.process) |*proc| {
            if (proc.stdin) |stdin| {
                stdin.writeAll(request_bytes) catch return error.WriteFailed;
            } else return error.NoStdin;
        } else return error.NotStarted;
    }

    // Wait for response.
    const outcome = self.pending_calls.wait(pending, timeout_ns);
    return switch (outcome) {
        .response => |resp| resp,
        .failure => |msg| {
            log.err("RPC call '{s}' failed: {s}", .{ method, msg });
            return error.CallFailed;
        },
        .timed_out => {
            log.warn("RPC call '{s}' timed out", .{method});
            return error.Timeout;
        },
    };
}

/// Convenience: send the hello handshake and validate capabilities.
pub fn hello(self: *DaemonRpcClient) !HelloResult {
    const timeout = 8 * std.time.ns_per_s;
    const resp = try self.call("hello", .{ .object = json.ObjectMap.init(self.allocator) }, timeout);

    const result = switch (resp) {
        .object => |obj| obj,
        else => return error.InvalidResponse,
    };

    // Extract fields.
    const ok = result.get("ok") orelse .null;
    if (ok != .bool or !ok.bool) {
        return error.HelloRejected;
    }

    const inner = switch (result.get("result") orelse .null) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    var capabilities = std.ArrayListUnmanaged([]const u8){};
    if (inner.get("capabilities")) |caps_val| {
        switch (caps_val) {
            .array => |arr| {
                for (arr.items) |item| {
                    switch (item) {
                        .string => |s| try capabilities.append(self.allocator, s),
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    return .{
        .name = switch (inner.get("name") orelse .null) {
            .string => |s| s,
            else => "cmuxd-remote",
        },
        .version = switch (inner.get("version") orelse .null) {
            .string => |s| s,
            else => "dev",
        },
        .capabilities = capabilities.toOwnedSlice(self.allocator) catch &.{},
        .remote_path = switch (inner.get("remotePath") orelse .null) {
            .string => |s| s,
            else => self.remote_path,
        },
    };
}

pub const HelloResult = struct {
    name: []const u8,
    version: []const u8,
    capabilities: []const []const u8,
    remote_path: []const u8,

    /// Check if a capability is present.
    pub fn hasCapability(self: *const HelloResult, cap: []const u8) bool {
        for (self.capabilities) |c| {
            if (std.mem.eql(u8, c, cap)) return true;
        }
        return false;
    }
};

/// Open a proxy stream to a remote host:port.
pub fn openStream(self: *DaemonRpcClient, host: []const u8, port: u16, timeout_ms: u32) ![]const u8 {
    var params = json.ObjectMap.init(self.allocator);
    try params.put("host", .{ .string = host });
    try params.put("port", .{ .integer = @intCast(port) });
    try params.put("timeout_ms", .{ .integer = @intCast(timeout_ms) });

    const timeout_ns = @as(u64, timeout_ms + 5000) * std.time.ns_per_ms;
    const resp = try self.call("proxy.open", .{ .object = params }, timeout_ns);

    const result = switch (resp) {
        .object => |obj| obj,
        else => return error.InvalidResponse,
    };

    return switch (result.get("stream_id") orelse .null) {
        .string => |s| s,
        else => return error.InvalidResponse,
    };
}

/// Write data to a proxy stream (base64-encoded).
pub fn writeStream(self: *DaemonRpcClient, stream_id: []const u8, data_base64: []const u8) !void {
    var params = json.ObjectMap.init(self.allocator);
    try params.put("stream_id", .{ .string = stream_id });
    try params.put("data_base64", .{ .string = data_base64 });

    _ = try self.call("proxy.write", .{ .object = params }, 10 * std.time.ns_per_s);
}

/// Close a proxy stream.
pub fn closeStream(self: *DaemonRpcClient, stream_id: []const u8) void {
    var params = json.ObjectMap.init(self.allocator);
    params.put("stream_id", .{ .string = stream_id }) catch return;

    _ = self.call("proxy.close", .{ .object = params }, 5 * std.time.ns_per_s) catch {};
}

/// Subscribe to pushed events on a stream.
/// Sends the proxy.stream.subscribe RPC call and registers the local callback.
pub fn subscribeStream(self: *DaemonRpcClient, stream_id: []const u8, sub: StreamSubscription) !void {
    // Register local callback.
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.stream_subscriptions.put(self.allocator, stream_id, sub);
    }

    // Send subscribe RPC to daemon so it starts pushing events.
    var params = json.ObjectMap.init(self.allocator);
    try params.put("stream_id", .{ .string = stream_id });
    _ = try self.call("proxy.stream.subscribe", .{ .object = params }, 5 * std.time.ns_per_s);
}

// -----------------------------------------------------------------------
// Reader threads
// -----------------------------------------------------------------------

fn stdoutReaderThread(self: *DaemonRpcClient) void {
    const proc = self.process orelse return;
    const stdout = proc.stdout orelse return;
    const reader = stdout.reader();

    var line_buf: [65536]u8 = undefined;
    while (true) {
        const line = reader.readUntilDelimiter(&line_buf, '\n') catch |err| {
            switch (err) {
                error.EndOfStream => break,
                else => {
                    log.warn("stdout read error: {}", .{err});
                    break;
                },
            }
        };

        if (line.len == 0) continue;
        self.handleStdoutLine(line);
    }

    // Process exited — fail all pending calls.
    self.mutex.lock();
    const should_report = self.should_report_termination;
    self.mutex.unlock();

    self.pending_calls.failAll("daemon process exited");

    if (should_report) {
        if (self.on_termination) |cb| {
            const stderr_msg = self.stderr_buf[0..self.stderr_len];
            cb.func(stderr_msg, cb.ctx);
        }
    }
}

fn stderrReaderThread(self: *DaemonRpcClient) void {
    const proc = self.process orelse return;
    const stderr = proc.stderr orelse return;
    const reader = stderr.reader();

    while (true) {
        const byte = reader.readByte() catch break;
        if (self.stderr_len < self.stderr_buf.len) {
            self.stderr_buf[self.stderr_len] = byte;
            self.stderr_len += 1;
        }
    }
}

fn handleStdoutLine(self: *DaemonRpcClient, line: []const u8) void {
    // Parse JSON. Use a persistent arena that outlives this call for responses,
    // since PendingCall.response holds a reference to the parsed value.
    // For stream events, we dupe the data into the main allocator.
    var arena_impl = std.heap.ArenaAllocator.init(self.allocator);
    const arena = arena_impl.allocator();

    const parsed = json.parseFromSliceLeaky(json.Value, arena, line, .{
        .allocate = .alloc_if_needed,
    }) catch {
        log.warn("failed to parse daemon JSON: {d} bytes", .{line.len});
        arena_impl.deinit();
        return;
    };

    const obj = switch (parsed) {
        .object => |o| o,
        else => {
            arena_impl.deinit();
            return;
        },
    };

    // Check if this is a response (has "id" field) or a pushed event (has "event").
    if (obj.get("id")) |id_val| {
        // Response to a pending call. Do NOT free the arena — the caller
        // of call() will read the json.Value from PendingCall.response.
        // The arena memory is leaked intentionally; the caller's scope
        // owns the data lifetime. TODO: use a per-call arena for clean ownership.
        const id: u32 = switch (id_val) {
            .integer => |i| @intCast(i),
            else => {
                arena_impl.deinit();
                return;
            },
        };
        if (!self.pending_calls.resolve(id, parsed)) {
            arena_impl.deinit(); // No pending call — safe to free.
        }
        // If resolved, arena is intentionally NOT freed — caller owns it.
    } else if (obj.get("event")) |event_val| {
        // Pushed stream event (top-level "event" and "stream_id" fields).
        // Matches Mac's event dispatch format.
        defer arena_impl.deinit(); // Safe — we dupe data we need.

        const event_name = switch (event_val) {
            .string => |s| s,
            else => return,
        };
        self.handlePushedEvent(event_name, obj);
    } else {
        arena_impl.deinit();
    }
}

fn handlePushedEvent(self: *DaemonRpcClient, event_name: []const u8, obj: json.ObjectMap) void {
    // Stream events have stream_id and data_base64/error at the top level.
    const stream_id = switch (obj.get("stream_id") orelse .null) {
        .string => |s| s,
        else => return,
    };

    self.mutex.lock();
    const sub = self.stream_subscriptions.get(stream_id);
    self.mutex.unlock();

    if (sub) |s| {
        if (std.mem.eql(u8, event_name, "proxy.stream.data")) {
            const data = switch (obj.get("data_base64") orelse .null) {
                .string => |d| d,
                else => return,
            };
            s.callback(.{ .data = data }, s.ctx);
        } else if (std.mem.eql(u8, event_name, "proxy.stream.eof")) {
            const data = switch (obj.get("data_base64") orelse .null) {
                .string => |d| d,
                else => "",
            };
            s.callback(.{ .eof = data }, s.ctx);
        } else if (std.mem.eql(u8, event_name, "proxy.stream.error")) {
            const detail = switch (obj.get("error") orelse .null) {
                .string => |d| d,
                else => "unknown error",
            };
            s.callback(.{ .err = detail }, s.ctx);
        }
    }
}
