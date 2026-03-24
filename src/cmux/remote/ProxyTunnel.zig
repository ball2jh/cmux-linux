//! Local SOCKS5/HTTP CONNECT proxy tunnel.
//!
//! Listens on 127.0.0.1:<port> and for each accepted connection:
//!   1. Reads first byte to determine protocol (0x05 = SOCKS5, else HTTP CONNECT)
//!   2. Completes the handshake
//!   3. Opens a daemon stream via DaemonRpcClient.openStream()
//!   4. Bidirectionally forwards: local socket <-> daemon stream RPC
//!
//! Matches macOS WorkspaceRemoteDaemonProxyTunnel (Workspace.swift lines 1578-2197).

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const json = std.json;

const DaemonRpcClient = @import("DaemonRpcClient.zig");

const log = std.log.scoped(.cmux_proxy_tunnel);

/// Read exactly `buf.len` bytes from fd, looping on short reads.
fn readExact(fd: posix.socket_t, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try posix.read(fd, buf[total..]);
        if (n == 0) return error.EndOfStream;
        total += n;
    }
}

const ProxyTunnel = @This();

/// Callback when the tunnel encounters a fatal error.
pub const ErrorCallback = struct {
    func: *const fn (?*anyopaque) void,
    ctx: ?*anyopaque = null,
};

// --- Configuration ---
rpc_client: *DaemonRpcClient,
on_error: ?ErrorCallback = null,

// --- State ---
listener_fd: posix.socket_t = -1,
port: u16 = 0,
accept_thread: ?std.Thread = null,
is_running: bool = false,
mutex: std.Thread.Mutex = .{},
allocator: Allocator,
active_sessions: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

pub fn init(allocator: Allocator, rpc_client: *DaemonRpcClient) ProxyTunnel {
    return .{
        .rpc_client = rpc_client,
        .allocator = allocator,
    };
}

pub fn deinit(self: *ProxyTunnel) void {
    self.stop();
}

/// Start listening on an ephemeral port. Returns the allocated port.
pub fn start(self: *ProxyTunnel) !u16 {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.is_running) return error.AlreadyRunning;

    // Create TCP socket.
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);

    // Set SO_REUSEADDR.
    const one: c_int = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one));

    // Bind to 127.0.0.1:0 (ephemeral port).
    const addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0, // OS picks port
        .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
    };
    try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

    // Get assigned port.
    var bound_addr: posix.sockaddr.in = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(fd, @ptrCast(&bound_addr), &addr_len);
    self.port = std.mem.bigToNative(u16, bound_addr.port);

    // Listen.
    try posix.listen(fd, 16);

    self.listener_fd = fd;
    self.is_running = true;

    // Start accept thread.
    self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});

    log.info("proxy tunnel listening on 127.0.0.1:{d}", .{self.port});
    return self.port;
}

/// Stop the tunnel and close all connections.
pub fn stop(self: *ProxyTunnel) void {
    self.mutex.lock();
    if (!self.is_running) {
        self.mutex.unlock();
        return;
    }
    self.is_running = false;
    const fd = self.listener_fd;
    self.listener_fd = -1;
    self.mutex.unlock();

    // Close listener to unblock accept().
    if (fd != -1) posix.close(fd);

    // Join accept thread.
    if (self.accept_thread) |t| {
        t.join();
        self.accept_thread = null;
    }

    // Wait for active sessions to finish (max 5 seconds).
    var wait_count: u32 = 0;
    while (self.active_sessions.load(.monotonic) > 0 and wait_count < 50) : (wait_count += 1) {
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

/// Get the local proxy endpoint.
pub fn endpoint(self: *const ProxyTunnel) ?struct { host: []const u8, port: u16 } {
    if (!self.is_running) return null;
    return .{ .host = "127.0.0.1", .port = self.port };
}

// -----------------------------------------------------------------------
// Accept loop
// -----------------------------------------------------------------------

fn acceptLoop(self: *ProxyTunnel) void {
    while (true) {
        self.mutex.lock();
        const running = self.is_running;
        const fd = self.listener_fd;
        self.mutex.unlock();

        if (!running or fd == -1) break;

        const client_fd = posix.accept(fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
            if (!self.is_running) break; // Shutting down.
            log.warn("accept failed: {}", .{err});
            continue;
        };

        // Spawn a thread per connection.
        const session = self.allocator.create(ProxySession) catch {
            posix.close(client_fd);
            continue;
        };
        session.* = .{
            .client_fd = client_fd,
            .rpc_client = self.rpc_client,
            .allocator = self.allocator,
            .tunnel = self,
        };

        _ = std.Thread.spawn(.{}, handleSession, .{session}) catch {
            posix.close(client_fd);
            self.allocator.destroy(session);
            continue;
        };
        self.active_sessions.fetchAdd(1, .monotonic);
    }
}

// -----------------------------------------------------------------------
// Per-connection session
// -----------------------------------------------------------------------

const ProxySession = struct {
    client_fd: posix.socket_t,
    rpc_client: *DaemonRpcClient,
    allocator: Allocator,
    tunnel: *ProxyTunnel,
};

fn handleSession(session: *ProxySession) void {
    defer {
        session.tunnel.active_sessions.fetchSub(1, .monotonic);
        posix.close(session.client_fd);
        session.allocator.destroy(session);
    }

    // Read first byte to determine protocol.
    var first_byte: [1]u8 = undefined;
    const n = posix.read(session.client_fd, &first_byte) catch return;
    if (n == 0) return;

    if (first_byte[0] == 0x05) {
        // SOCKS5.
        handleSocks5(session, first_byte[0]) catch |err| {
            log.debug("SOCKS5 session error: {}", .{err});
        };
    } else {
        // HTTP CONNECT.
        handleHttpConnect(session, first_byte[0]) catch |err| {
            log.debug("HTTP CONNECT session error: {}", .{err});
        };
    }
}

// -----------------------------------------------------------------------
// SOCKS5 protocol
// -----------------------------------------------------------------------

fn handleSocks5(session: *ProxySession, _: u8) !void {
    const fd = session.client_fd;

    // Greeting: version(0x05) already read, read nmethods + methods.
    var nmethods_buf: [1]u8 = undefined;
    try readExact(fd, &nmethods_buf);
    const nmethods = nmethods_buf[0];

    // Read method bytes.
    var method_buf: [255]u8 = undefined;
    if (nmethods > 0) {
        try readExact(fd, method_buf[0..nmethods]);
    }

    // Validate client offers no-auth method (0x00).
    var has_no_auth = false;
    for (method_buf[0..nmethods]) |m| {
        if (m == 0x00) { has_no_auth = true; break; }
    }
    if (!has_no_auth) {
        _ = try posix.write(fd, &[_]u8{ 0x05, 0xFF });
        return error.NoAcceptableAuthMethod;
    }

    // Reply: no auth required.
    _ = try posix.write(fd, &[_]u8{ 0x05, 0x00 });

    // Request: VER CMD RSV ATYP DST.ADDR DST.PORT.
    var req_header: [4]u8 = undefined;
    try readExact(fd, &req_header);

    if (req_header[0] != 0x05 or req_header[1] != 0x01) {
        // Only CONNECT (0x01) is supported.
        _ = try posix.write(fd, &[_]u8{ 0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0 });
        return error.UnsupportedCommand;
    }

    // Parse destination address.
    var host_buf: [256]u8 = undefined;
    var host_len: usize = 0;

    switch (req_header[3]) {
        0x01 => { // IPv4
            var ip4: [4]u8 = undefined;
            try readExact(fd, &ip4);
            host_len = (std.fmt.bufPrint(&host_buf, "{d}.{d}.{d}.{d}", .{ ip4[0], ip4[1], ip4[2], ip4[3] }) catch return error.FormatError).len;
        },
        0x03 => { // Domain name
            var domain_len_buf: [1]u8 = undefined;
            try readExact(fd, &domain_len_buf);
            const dlen = domain_len_buf[0];
            try readExact(fd, host_buf[0..dlen]);
            host_len = dlen;
        },
        0x04 => { // IPv6 (read 16 bytes, format as hex)
            var ip6: [16]u8 = undefined;
            try readExact(fd, &ip6);
            // Simplified: just use hex representation.
            host_len = (std.fmt.bufPrint(&host_buf, "[{x}]", .{std.fmt.fmtSliceHexLower(&ip6)}) catch return error.FormatError).len;
        },
        else => {
            _ = try posix.write(fd, &[_]u8{ 0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0 });
            return error.UnsupportedAddressType;
        },
    }

    // Read port (2 bytes, big-endian).
    var port_buf: [2]u8 = undefined;
    try readExact(fd, &port_buf);
    const port = std.mem.readInt(u16, &port_buf, .big);

    const host = host_buf[0..host_len];

    log.debug("SOCKS5 CONNECT to {s}:{d}", .{ host, port });

    // Open daemon stream.
    const stream_id = session.rpc_client.openStream(host, port, 10000) catch {
        _ = try posix.write(fd, &[_]u8{ 0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0 });
        return error.StreamOpenFailed;
    };

    // Success reply.
    _ = try posix.write(fd, &[_]u8{ 0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0 });

    // Bidirectional forwarding.
    forwardBidirectional(session, stream_id) catch {};

    session.rpc_client.closeStream(stream_id);
}

// -----------------------------------------------------------------------
// HTTP CONNECT protocol
// -----------------------------------------------------------------------

fn handleHttpConnect(session: *ProxySession, first_byte: u8) !void {
    const fd = session.client_fd;

    // Read the rest of the request line. We already have the first byte.
    var line_buf: [4096]u8 = undefined;
    line_buf[0] = first_byte;
    var pos: usize = 1;

    while (pos < line_buf.len - 1) {
        var byte: [1]u8 = undefined;
        const n = posix.read(fd, &byte) catch break;
        if (n == 0) break;
        line_buf[pos] = byte[0];
        pos += 1;
        if (pos >= 2 and line_buf[pos - 2] == '\r' and line_buf[pos - 1] == '\n') break;
    }

    const request_line = std.mem.trim(u8, line_buf[0..pos], "\r\n");

    // Parse "CONNECT host:port HTTP/1.x"
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.InvalidRequest;
    if (!std.ascii.eqlIgnoreCase(method, "CONNECT")) return error.InvalidRequest;

    const target = parts.next() orelse return error.InvalidRequest;

    // Parse host:port from target.
    const colon_pos = std.mem.lastIndexOfScalar(u8, target, ':') orelse return error.InvalidRequest;
    const host = target[0..colon_pos];
    const port = std.fmt.parseInt(u16, target[colon_pos + 1 ..], 10) catch return error.InvalidRequest;

    // Read remaining headers until empty line.
    while (true) {
        var hdr_buf: [1024]u8 = undefined;
        var hdr_pos: usize = 0;
        while (hdr_pos < hdr_buf.len - 1) {
            var byte: [1]u8 = undefined;
            const n = posix.read(fd, &byte) catch break;
            if (n == 0) break;
            hdr_buf[hdr_pos] = byte[0];
            hdr_pos += 1;
            if (hdr_pos >= 2 and hdr_buf[hdr_pos - 2] == '\r' and hdr_buf[hdr_pos - 1] == '\n') break;
        }
        if (hdr_pos <= 2) break; // Empty line = end of headers.
    }

    log.debug("HTTP CONNECT to {s}:{d}", .{ host, port });

    // Open daemon stream.
    const stream_id = session.rpc_client.openStream(host, port, 10000) catch {
        const err_resp = "HTTP/1.1 502 Bad Gateway\r\n\r\n";
        _ = posix.write(fd, err_resp) catch {};
        return error.StreamOpenFailed;
    };

    // Send 200 response.
    const ok_resp = "HTTP/1.1 200 Connection Established\r\n\r\n";
    _ = try posix.write(fd, ok_resp);

    // Bidirectional forwarding.
    forwardBidirectional(session, stream_id) catch {};

    session.rpc_client.closeStream(stream_id);
}

// -----------------------------------------------------------------------
// Bidirectional forwarding
// -----------------------------------------------------------------------

fn forwardBidirectional(session: *ProxySession, stream_id: []const u8) !void {
    // Subscribe to pushed stream events.
    const CtxData = struct {
        fd: posix.socket_t,
        done: std.Thread.ResetEvent = .{},
    };
    var ctx_data = CtxData{ .fd = session.client_fd };

    try session.rpc_client.subscribeStream(stream_id, .{
        .callback = &struct {
            fn cb(event: DaemonRpcClient.StreamEvent, ctx: ?*anyopaque) void {
                const data: *CtxData = @ptrCast(@alignCast(ctx orelse return));
                switch (event) {
                    .data => |base64_data| {
                        // Decode base64 and write to client socket.
                        var decode_buf: [65536]u8 = undefined;
                        const decoded = std.base64.standard.Decoder.decode(&decode_buf, base64_data) catch return;
                        _ = posix.write(data.fd, decoded[0..decoded.len]) catch {
                            data.done.set();
                        };
                    },
                    .eof => |trailing| {
                        if (trailing.len > 0) {
                            var eof_buf: [65536]u8 = undefined;
                            const dec = std.base64.standard.Decoder.decode(&eof_buf, trailing) catch &.{};
                            if (dec.len > 0) _ = posix.write(data.fd, dec[0..dec.len]) catch {};
                        }
                        data.done.set();
                    },
                    .err => data.done.set(),
                }
            }
        }.cb,
        .ctx = @ptrCast(&ctx_data),
    });

    // Forward local -> remote in a loop.
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = posix.read(session.client_fd, &buf) catch break;
        if (n == 0) break;

        // Base64-encode and send via RPC.
        var encode_buf: [12288]u8 = undefined; // ceil(8192 * 4/3)
        const encoded = std.base64.standard.Encoder.encode(&encode_buf, buf[0..n]);
        session.rpc_client.writeStream(stream_id, encoded) catch break;
    }

    // Wait for remote side to finish.
    ctx_data.done.timedWait(5 * std.time.ns_per_s) catch {};
}
