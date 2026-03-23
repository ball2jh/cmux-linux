// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
//
// Port scanner for cmux.
// Detects TCP ports in LISTEN state by parsing /proc/net/tcp and /proc/net/tcp6.
// Associates ports with workspace TTYs by cross-referencing socket inodes
// with /proc/{pid}/fd/ entries for processes on workspace PTYs.
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

/// Registered workspace TTY paths (e.g. "/dev/pts/5").
/// Used to scope port scanning to workspace processes.
var workspace_ttys: std.ArrayListUnmanaged(TtyEntry) = .empty;
var tty_mutex: std.Thread.Mutex = .{};

const TtyEntry = struct {
    workspace_id: u64,
    tty_path: []const u8,
};

/// Burst scan state — coalesce rapid triggers into a burst sequence.
var burst_timer: c_uint = 0;
var burst_stage: u8 = 0;
const burst_delays = [_]c_uint{ 500, 1000, 1500, 2000, 2500, 2500 }; // ms delays

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
    if (burst_timer != 0) {
        _ = glib.Source.remove(burst_timer);
        burst_timer = 0;
    }
    const alloc = global_alloc orelse return;
    {
        cache_mutex.lock();
        defer cache_mutex.unlock();
        cached_ports.deinit(alloc);
    }
    {
        tty_mutex.lock();
        defer tty_mutex.unlock();
        for (workspace_ttys.items) |entry| {
            alloc.free(entry.tty_path);
        }
        workspace_ttys.deinit(alloc);
    }
    global_alloc = null;
}

/// Register a TTY for a workspace. Called when a terminal surface is created.
pub fn registerTty(workspace_id: u64, tty_path: []const u8) void {
    const alloc = global_alloc orelse return;
    tty_mutex.lock();
    defer tty_mutex.unlock();

    // Don't register duplicates
    for (workspace_ttys.items) |entry| {
        if (entry.workspace_id == workspace_id and std.mem.eql(u8, entry.tty_path, tty_path)) {
            return;
        }
    }

    const path_copy = alloc.dupe(u8, tty_path) catch return;
    workspace_ttys.append(alloc, .{
        .workspace_id = workspace_id,
        .tty_path = path_copy,
    }) catch {
        alloc.free(path_copy);
    };
}

/// Unregister a TTY for a workspace. Called when a terminal surface is destroyed.
pub fn unregisterTty(workspace_id: u64, tty_path: []const u8) void {
    const alloc = global_alloc orelse return;
    tty_mutex.lock();
    defer tty_mutex.unlock();

    var i: usize = 0;
    while (i < workspace_ttys.items.len) {
        if (workspace_ttys.items[i].workspace_id == workspace_id and
            std.mem.eql(u8, workspace_ttys.items[i].tty_path, tty_path))
        {
            alloc.free(workspace_ttys.items[i].tty_path);
            _ = workspace_ttys.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

/// GLib timer callback.
fn scanCallback(_: ?*anyopaque) callconv(.c) c_int {
    doScan();
    return 1; // Keep timer
}

/// Burst scan callback — fires at increasing intervals after a trigger.
fn burstCallback(_: ?*anyopaque) callconv(.c) c_int {
    doScan();
    burst_stage += 1;
    if (burst_stage < burst_delays.len) {
        // Schedule next burst scan
        burst_timer = glib.timeoutAdd(burst_delays[burst_stage], &burstCallback, null);
    } else {
        burst_timer = 0;
        burst_stage = 0;
    }
    return 0; // Don't repeat — we schedule the next one explicitly
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

/// Get ports for a specific workspace by filtering against registered TTYs.
/// Falls back to all cached ports if no TTYs are registered for the workspace.
pub fn getPortsForWorkspace(alloc: Allocator, workspace_id: u64) ![]ListeningPort {
    // Get TTYs registered for this workspace
    var tty_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer tty_list.deinit(alloc);

    {
        tty_mutex.lock();
        defer tty_mutex.unlock();
        for (workspace_ttys.items) |entry| {
            if (entry.workspace_id == workspace_id) {
                try tty_list.append(alloc, entry.tty_path);
            }
        }
    }

    // If no TTYs registered, return all cached ports (backward compat)
    if (tty_list.items.len == 0) {
        cache_mutex.lock();
        defer cache_mutex.unlock();
        return try alloc.dupe(ListeningPort, cached_ports.items);
    }

    // Find PIDs on those TTYs and their listening ports
    return try findPortsForTtys(alloc, tty_list.items);
}

/// Find listening ports for processes running on specific TTYs.
/// Cross-references /proc/{pid}/fd with /proc/net/tcp socket inodes.
fn findPortsForTtys(alloc: Allocator, ttys: []const []const u8) ![]ListeningPort {
    // Step 1: Find PIDs that have any of the given TTYs
    var pids: std.ArrayListUnmanaged(i32) = .empty;
    defer pids.deinit(alloc);

    var proc_dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch {
        // Fallback: return all cached ports
        cache_mutex.lock();
        defer cache_mutex.unlock();
        return try alloc.dupe(ListeningPort, cached_ports.items);
    };
    defer proc_dir.close();

    var it = proc_dir.iterate();
    while (it.next() catch null) |entry| {
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;

        // Read /proc/{pid}/fd/0 (stdin) symlink to check if it points to our TTY
        var fd_path_buf: [64]u8 = undefined;
        const fd_path = std.fmt.bufPrint(&fd_path_buf, "/proc/{d}/fd/0", .{pid}) catch continue;

        var link_buf: [256]u8 = undefined;
        const link_target = std.fs.readLinkAbsolute(fd_path, &link_buf) catch continue;

        for (ttys) |tty| {
            if (std.mem.eql(u8, link_target, tty)) {
                try pids.append(alloc, pid);
                break;
            }
        }
    }

    if (pids.items.len == 0) {
        // No processes found on these TTYs, return empty
        return try alloc.alloc(ListeningPort, 0);
    }

    // Step 2: Get socket inodes for these PIDs
    var socket_inodes: std.AutoHashMapUnmanaged(u64, void) = .{};
    defer socket_inodes.deinit(alloc);

    for (pids.items) |pid| {
        collectSocketInodes(alloc, pid, &socket_inodes) catch continue;
    }

    // Step 3: Cross-reference with /proc/net/tcp to find matching ports
    var ports: std.ArrayListUnmanaged(ListeningPort) = .empty;
    errdefer ports.deinit(alloc);

    matchSocketsToPortsFile(alloc, "/proc/net/tcp", false, &socket_inodes, &ports);
    matchSocketsToPortsFile(alloc, "/proc/net/tcp6", true, &socket_inodes, &ports);

    // Sort and deduplicate
    std.sort.insertion(ListeningPort, ports.items, {}, struct {
        fn lessThan(_: void, a: ListeningPort, b: ListeningPort) bool {
            return a.port < b.port;
        }
    }.lessThan);

    var deduped: std.ArrayListUnmanaged(ListeningPort) = .empty;
    var last_port: u16 = 0;
    for (ports.items) |p| {
        if (p.port != last_port) {
            deduped.append(alloc, p) catch continue;
            last_port = p.port;
        }
    }
    ports.deinit(alloc);

    return try deduped.toOwnedSlice(alloc);
}

/// Collect socket inodes from /proc/{pid}/fd/ entries.
fn collectSocketInodes(alloc: Allocator, pid: i32, inodes: *std.AutoHashMapUnmanaged(u64, void)) !void {
    var fd_dir_buf: [64]u8 = undefined;
    const fd_dir_path = std.fmt.bufPrint(&fd_dir_buf, "/proc/{d}/fd", .{pid}) catch return;

    var dir = std.fs.openDirAbsolute(fd_dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var dir_it = dir.iterate();
    while (dir_it.next() catch null) |fd_entry| {
        var path_buf: [128]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ fd_dir_path, fd_entry.name }) catch continue;

        var link_buf: [256]u8 = undefined;
        const link = std.fs.readLinkAbsolute(full_path, &link_buf) catch continue;

        // Socket links look like "socket:[12345]"
        if (std.mem.startsWith(u8, link, "socket:[")) {
            const inode_str = link["socket:[".len .. link.len - 1];
            const inode = std.fmt.parseInt(u64, inode_str, 10) catch continue;
            try inodes.put(alloc, inode, {});
        }
    }
}

/// Match socket inodes against /proc/net/tcp entries to find listening ports.
fn matchSocketsToPortsFile(
    alloc: Allocator,
    path: []const u8,
    is_ipv6: bool,
    socket_inodes: *const std.AutoHashMapUnmanaged(u64, void),
    results: *std.ArrayListUnmanaged(ListeningPort),
) void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    // Use dynamic allocation to handle large /proc/net/tcp files
    const content = file.readToEndAlloc(alloc, 4 * 1024 * 1024) catch return;
    defer alloc.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // skip header

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t' });
        if (trimmed.len == 0) continue;

        // Format: sl local_address rem_address st tx_queue:rx_queue tr:tm->when retrnsmt uid timeout inode
        var fields = std.mem.tokenizeAny(u8, trimmed, " \t");

        _ = fields.next() orelse continue; // sl
        const local_addr = fields.next() orelse continue; // local_address
        _ = fields.next() orelse continue; // rem_address
        const state = fields.next() orelse continue; // st

        // Only LISTEN state
        if (!std.mem.eql(u8, state, "0A")) continue;

        _ = fields.next() orelse continue; // tx_queue:rx_queue
        _ = fields.next() orelse continue; // tr:tm->when
        _ = fields.next() orelse continue; // retrnsmt
        _ = fields.next() orelse continue; // uid
        _ = fields.next() orelse continue; // timeout
        const inode_str = fields.next() orelse continue; // inode

        const inode = std.fmt.parseInt(u64, inode_str, 10) catch continue;

        // Check if this socket belongs to one of our workspace processes
        if (socket_inodes.get(inode) == null) continue;

        // Parse port
        const colon_pos = std.mem.lastIndexOf(u8, local_addr, ":") orelse continue;
        const port_hex = local_addr[colon_pos + 1 ..];
        const port = std.fmt.parseInt(u16, port_hex, 16) catch continue;
        if (port == 0) continue;

        results.append(alloc, .{
            .port = port,
            .is_ipv6 = is_ipv6,
        }) catch continue;
    }
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

/// Format ports for a specific workspace as JSON.
pub fn formatJsonForWorkspace(alloc: Allocator, workspace_id: u64) ![]u8 {
    const ports = try getPortsForWorkspace(alloc, workspace_id);
    defer alloc.free(ports);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    try writer.writeAll("[");
    for (ports, 0..) |p, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{d}", .{p.port});
    }
    try writer.writeAll("]");

    return try buf.toOwnedSlice(alloc);
}

/// Trigger an immediate rescan (e.g. when a new terminal starts).
/// Uses burst strategy: 0.5s, 1.5s, 3s, 5s, 7.5s, 10s.
pub fn triggerScan() void {
    doScan();

    // Start burst sequence if not already running
    if (burst_timer == 0 and burst_stage == 0) {
        burst_stage = 0;
        burst_timer = glib.timeoutAdd(burst_delays[0], &burstCallback, null);
    }
}
