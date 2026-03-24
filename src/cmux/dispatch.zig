//! Main-thread dispatch helpers for the socket server.
//!
//! Socket commands that mutate UI state must execute on the GTK main thread.
//! This module provides a callback-based dispatch mechanism that the GTK
//! application layer wires up at server creation time. This keeps cmux
//! modules independent of GLib/GTK bindings.
//!
//! The GTK layer is expected to set `idle_add_fn` and `timeout_add_fn` to
//! wrappers around g_idle_add and g_timeout_add. Until wired up, the stubs
//! execute callbacks directly on the calling thread (safe for testing and
//! non-GUI usage).

const std = @import("std");

const log = std.log.scoped(.cmux_dispatch);

/// Signature matching GLib's GSourceFunc: returns G_SOURCE_REMOVE (0) or
/// G_SOURCE_CONTINUE (1). The opaque pointer carries user data.
pub const SourceFunc = *const fn (?*anyopaque) callconv(.c) c_int;

/// Schedule a callback on the GLib main loop (idle priority).
/// Wraps g_idle_add when wired up; direct call otherwise.
pub var idle_add_fn: *const fn (SourceFunc, ?*anyopaque) callconv(.c) c_uint = &stubIdleAdd;

/// Schedule a callback on the GLib main loop after a delay.
/// Wraps g_timeout_add when wired up; sleeps then calls otherwise.
pub var timeout_add_fn: *const fn (c_uint, SourceFunc, ?*anyopaque) callconv(.c) c_uint = &stubTimeoutAdd;

/// Execute `func` on the main thread. Non-blocking — the callback runs
/// asynchronously via the event loop.
pub fn idleAdd(func: SourceFunc, userdata: ?*anyopaque) void {
    _ = idle_add_fn(func, userdata);
}

/// Schedule `func` to run on the main thread after `delay_ms` milliseconds.
/// Used by the accept loop for rearm/resume scheduling.
pub fn timeoutAdd(delay_ms: c_uint, func: SourceFunc, userdata: ?*anyopaque) void {
    _ = timeout_add_fn(delay_ms, func, userdata);
}

/// Synchronously dispatch a callback on the main thread and block until
/// it completes. Uses mutex + condition variable for signaling.
///
/// WARNING: Will deadlock if called from the main thread. The accept loop
/// and client handler threads are always background threads so this is safe
/// in normal operation.
pub fn syncOnMainThread(func: SourceFunc, userdata: ?*anyopaque) void {
    var state = SyncState{};
    // We pack both the user's callback and our sync state into a wrapper.
    var ctx = SyncContext{
        .func = func,
        .userdata = userdata,
        .state = &state,
    };

    _ = idle_add_fn(&syncWrapper, @ptrCast(&ctx));

    // Wait for completion.
    state.mutex.lock();
    defer state.mutex.unlock();
    while (!state.done) {
        state.cond.wait(&state.mutex);
    }
}

const SyncState = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,
};

const SyncContext = struct {
    func: SourceFunc,
    userdata: ?*anyopaque,
    state: *SyncState,
};

fn syncWrapper(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncContext = @ptrCast(@alignCast(data orelse return 0));

    // Run the user's callback.
    _ = ctx.func(ctx.userdata);

    // Signal completion.
    ctx.state.mutex.lock();
    ctx.state.done = true;
    ctx.state.cond.signal();
    ctx.state.mutex.unlock();

    return 0; // G_SOURCE_REMOVE
}

// --- Stubs for testing / non-GTK usage ---

fn stubIdleAdd(func: SourceFunc, userdata: ?*anyopaque) callconv(.c) c_uint {
    _ = func(userdata);
    return 0;
}

fn stubTimeoutAdd(delay_ms: c_uint, func: SourceFunc, userdata: ?*anyopaque) callconv(.c) c_uint {
    if (delay_ms > 0) {
        std.Thread.sleep(@as(u64, delay_ms) * std.time.ns_per_ms);
    }
    _ = func(userdata);
    return 0;
}

// --- Tests ---

test "idleAdd with stub executes immediately" {
    const S = struct {
        var called = false;
        fn callback(_: ?*anyopaque) callconv(.c) c_int {
            called = true;
            return 0;
        }
    };
    S.called = false;
    idleAdd(&S.callback, null);
    try std.testing.expect(S.called);
}

test "syncOnMainThread with stub executes and signals" {
    const S = struct {
        var value: u32 = 0;
        fn callback(_: ?*anyopaque) callconv(.c) c_int {
            value = 42;
            return 0;
        }
    };
    S.value = 0;
    syncOnMainThread(&S.callback, null);
    try std.testing.expectEqual(@as(u32, 42), S.value);
}
