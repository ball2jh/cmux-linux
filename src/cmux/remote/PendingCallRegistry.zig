//! Request-ID to semaphore mapping for synchronous RPC calls.
//!
//! The DaemonRpcClient uses this to pair outgoing requests with incoming
//! responses over the SSH stdio transport. A call() registers a pending
//! entry, writes JSON to stdin, then waits on the ResetEvent. The stdout
//! reader thread resolves entries as responses arrive.
//!
//! Matches macOS WorkspaceRemoteDaemonPendingCallRegistry
//! (Workspace.swift lines 699-789).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const PendingCallRegistry = @This();

pub const WaitOutcome = union(enum) {
    response: json.Value,
    failure: []const u8,
    timed_out,
};

pub const PendingCall = struct {
    id: u32,
    event: std.Thread.ResetEvent = .{},
    response: ?json.Value = null,
    failure_message: ?[]const u8 = null,
};

mutex: std.Thread.Mutex = .{},
next_request_id: u32 = 1,
pending: std.AutoHashMapUnmanaged(u32, *PendingCall) = .{},
allocator: Allocator,

pub fn init(allocator: Allocator) PendingCallRegistry {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *PendingCallRegistry) void {
    // Clean up any remaining pending calls.
    var it = self.pending.iterator();
    while (it.next()) |entry| {
        self.allocator.destroy(entry.value_ptr.*);
    }
    self.pending.deinit(self.allocator);
}

/// Register a new pending call and return it. The caller should write the
/// request to stdin, then call wait().
pub fn register(self: *PendingCallRegistry) !*PendingCall {
    self.mutex.lock();
    defer self.mutex.unlock();

    const id = self.next_request_id;
    self.next_request_id +%= 1;

    const call = try self.allocator.create(PendingCall);
    call.* = .{ .id = id };
    try self.pending.put(self.allocator, id, call);
    return call;
}

/// Resolve a pending call with a response payload. Called by the stdout
/// reader thread when a response JSON line arrives.
/// Returns true if the call was found and resolved.
pub fn resolve(self: *PendingCallRegistry, id: u32, payload: json.Value) bool {
    self.mutex.lock();
    defer self.mutex.unlock();

    const call = self.pending.get(id) orelse return false;

    // Write response and signal while holding the lock to prevent
    // a race with failAll() writing to the same call.
    call.response = payload;
    call.event.set();
    return true;
}

/// Fail all pending calls with a message. Called when the SSH process
/// terminates unexpectedly.
pub fn failAll(self: *PendingCallRegistry, message: []const u8) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var it = self.pending.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.failure_message = message;
        entry.value_ptr.*.event.set();
    }
}

/// Wait for a pending call to complete with a timeout.
/// After this returns, the call is removed from the registry.
pub fn wait(self: *PendingCallRegistry, call: *PendingCall, timeout_ns: u64) WaitOutcome {
    call.event.timedWait(timeout_ns) catch {
        self.remove(call);
        return .timed_out;
    };

    const outcome: WaitOutcome = if (call.response) |resp|
        .{ .response = resp }
    else if (call.failure_message) |msg|
        .{ .failure = msg }
    else
        .timed_out;

    self.remove(call);
    return outcome;
}

/// Remove a call from the registry and free it.
pub fn remove(self: *PendingCallRegistry, call: *PendingCall) void {
    self.mutex.lock();
    _ = self.pending.remove(call.id);
    self.mutex.unlock();
    self.allocator.destroy(call);
}

/// Clear all pending calls without signaling them.
pub fn reset(self: *PendingCallRegistry) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var it = self.pending.iterator();
    while (it.next()) |entry| {
        self.allocator.destroy(entry.value_ptr.*);
    }
    self.pending.clearRetainingCapacity();
    self.next_request_id = 1;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "register and resolve" {
    const alloc = std.testing.allocator;
    var reg = PendingCallRegistry.init(alloc);
    defer reg.deinit();

    const call = try reg.register();
    const id = call.id;
    try std.testing.expectEqual(@as(u32, 1), id);

    // Resolve from another "thread" (inline for test).
    const resolved = reg.resolve(id, .{ .bool = true });
    try std.testing.expect(resolved);

    const outcome = reg.wait(call, 1_000_000_000);
    switch (outcome) {
        .response => |v| try std.testing.expect(v.bool),
        else => return error.TestUnexpectedResult,
    }
}

test "resolve unknown id returns false" {
    const alloc = std.testing.allocator;
    var reg = PendingCallRegistry.init(alloc);
    defer reg.deinit();

    try std.testing.expect(!reg.resolve(999, .null));
}

test "failAll signals all pending" {
    const alloc = std.testing.allocator;
    var reg = PendingCallRegistry.init(alloc);
    defer reg.deinit();

    const call1 = try reg.register();
    const call2 = try reg.register();

    reg.failAll("process terminated");

    const outcome1 = reg.wait(call1, 1_000_000_000);
    const outcome2 = reg.wait(call2, 1_000_000_000);

    switch (outcome1) {
        .failure => |msg| try std.testing.expectEqualStrings("process terminated", msg),
        else => return error.TestUnexpectedResult,
    }
    switch (outcome2) {
        .failure => |msg| try std.testing.expectEqualStrings("process terminated", msg),
        else => return error.TestUnexpectedResult,
    }
}
