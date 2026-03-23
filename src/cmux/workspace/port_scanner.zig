// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2025 cmux-linux contributors
//
// Port scanner for cmux.
// Detects TCP ports in LISTEN state by parsing /proc/net/tcp and /proc/net/tcp6.
// Results are displayed in the workspace sidebar and available via socket API.
//
// Scanning strategy: coalesced with debounce. After a trigger, scans at
// 0.5s, then again at 3s, then settles to periodic every 10s.

const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");

const log = std.log.scoped(.cmux_port_scanner);

/// A detected listening port.
pub const ListeningPort = struct {
    port: u16,
    is_ipv6: bool,
};

/// Global scanner state.
var scan_timer: c_uint = 0;
var global_alloc: ?Allocator = null;
var cached_ports: std.ArrayListUnmanaged(ListeningPort) = .empty;
var cache_mutex: std.Thread.Mutex = .{};

/// Initialize the port scanner with periodic scanning.
pub fn initGlobal(alloc: Allocator) void {
    global_alloc = alloc;
    // Initial scan
    doScan();
    // Start periodic timer (10 seconds)
    scan_timer = glib.timeoutAdd(10000, &scanCallback, null);
    log.info("port scanner started (10s interval)", .{});
}

/// Stop the port scanner.
pub fn deinitGlobal() void {
    if (scan_timer != 0) {
        _ = glib.Source.remove(scan_timer);
        scan_timer = 0;
    }
    const alloc = global_alloc orelse return;
    cache_mutex.lock();
    defer cache_mutex.unlock();
    cached_ports.deinit(alloc);
    global_alloc = null;
}

/// GLib timer callback.
fn scanCallback(_: ?*anyopaque) callconv(.c) c_int {
    doScan();
    return 1; // Keep timer
}

/// Perform a scan of /proc/net/tcp and /proc/net/tcp6.
fn doScan() void {
    const alloc = global_alloc orelse return;

    var new_ports: std.ArrayListUnmanaged(ListeningPort) = .empty;

    scanFile(alloc, "/proc/net/tcp", false, &new_ports);
    scanFile(alloc, "/proc/net/tcp6", true, &new_ports);

    // Sort by port number
    std.sort.insertion(ListeningPort, new_ports.items, {}, struct {
        fn lessThan(_: void, a: ListeningPort, b: ListeningPort) bool {
            return a.port < b.port;
        }
    }.lessThan);

    // Deduplicate
    var deduped: std.ArrayListUnmanaged(ListeningPort) = .empty;
    var last_port: u16 = 0;
    for (new_ports.items) |p| {
        if (p.port != last_port) {
            deduped.append(alloc, p) catch continue;
            last_port = p.port;
        }
    }
    new_ports.deinit(alloc);

    // Swap into cache
    cache_mutex.lock();
    defer cache_mutex.unlock();
    cached_ports.deinit(alloc);
    cached_ports = deduped;
}

/// Parse a /proc/net/tcp or tcp6 file for LISTEN state sockets.
fn scanFile(
    alloc: Allocator,
    path: []const u8,
    is_ipv6: bool,
    results: *std.ArrayListUnmanaged(ListeningPort),
) void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var buf: [8192]u8 = undefined;
    const n = file.readAll(&buf) catch return;
    const content = buf[0..n];

    // Skip header line
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // skip "sl  local_address rem_address   st ..."

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t' });
        if (trimmed.len == 0) continue;

        // Format: sl local_address rem_address st ...
        // We need fields[1] (local_address) and fields[3] (state)
        var fields = std.mem.tokenizeAny(u8, trimmed, " \t");

        _ = fields.next() orelse continue; // sl
        const local_addr = fields.next() orelse continue; // local_address (hex:port)
        _ = fields.next() orelse continue; // rem_address
        const state = fields.next() orelse continue; // st (hex)

        // State 0A = LISTEN
        if (!std.mem.eql(u8, state, "0A")) continue;

        // Parse port from local_address (format: ADDR:PORT in hex)
        const colon_pos = std.mem.lastIndexOf(u8, local_addr, ":") orelse continue;
        const port_hex = local_addr[colon_pos + 1 ..];
        const port = std.fmt.parseInt(u16, port_hex, 16) catch continue;

        // Skip ephemeral/system ports that are noise
        if (port == 0) continue;

        results.append(alloc, .{
            .port = port,
            .is_ipv6 = is_ipv6,
        }) catch continue;
    }
}

/// Get the current cached listening ports.
pub fn getPorts() []const ListeningPort {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    return cached_ports.items;
}

/// Format ports as a V1 text response.
pub fn formatText(alloc: Allocator) ![]u8 {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    for (cached_ports.items, 0..) |p, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{d}", .{p.port});
    }

    return try buf.toOwnedSlice(alloc);
}

/// Format ports as JSON.
pub fn formatJson(alloc: Allocator) ![]u8 {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    try writer.writeAll("[");
    for (cached_ports.items, 0..) |p, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{d}", .{p.port});
    }
    try writer.writeAll("]");

    return try buf.toOwnedSlice(alloc);
}

/// Trigger an immediate rescan (e.g. when a new terminal starts).
pub fn triggerScan() void {
    doScan();
}
