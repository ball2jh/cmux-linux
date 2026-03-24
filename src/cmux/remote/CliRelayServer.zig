//! TCP server with HMAC-SHA256 challenge-response auth for CLI relay.
//!
//! Enables running `cmux` commands from within remote SSH sessions.
//! A reverse SSH tunnel forwards a remote port back to this local server.
//! Each connection authenticates via HMAC-SHA256 before forwarding the
//! command to the local Unix domain socket.
//!
//! Protocol:
//!   1. Server sends: {"protocol":"cmux-relay-auth","version":1,"relay_id":"...","nonce":"<hex>"}
//!   2. Client sends: {"relay_id":"...","mac":"<hmac-sha256-hex>"}
//!   3. Server verifies MAC of "relay_id=<id>\nnonce=<nonce>\nversion=1"
//!   4. On success: {"ok":true}, then read command, forward to socket, return response
//!
//! Matches macOS WorkspaceRemoteCLIRelayServer (Workspace.swift lines 2435-2913).

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const json = std.json;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

const log = std.log.scoped(.cmux_cli_relay);

const CliRelayServer = @This();

// --- Configuration ---
relay_id: []const u8,
relay_token: [32]u8, // 32 bytes (decoded from 64 hex chars)
local_socket_path: []const u8,

// --- State ---
listener_fd: posix.socket_t = -1,
local_port: u16 = 0,
accept_thread: ?std.Thread = null,
is_running: bool = false,
mutex: std.Thread.Mutex = .{},
allocator: Allocator,

pub fn init(
    allocator: Allocator,
    relay_id: []const u8,
    relay_token_hex: []const u8,
    local_socket_path: []const u8,
) !CliRelayServer {
    if (relay_token_hex.len != 64) return error.InvalidTokenLength;

    var token: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&token, relay_token_hex) catch return error.InvalidTokenHex;

    return .{
        .relay_id = relay_id,
        .relay_token = token,
        .local_socket_path = local_socket_path,
        .allocator = allocator,
    };
}

pub fn deinit(self: *CliRelayServer) void {
    self.stop();
}

/// Start listening on an ephemeral port. Returns the allocated port.
pub fn start(self: *CliRelayServer) !u16 {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.is_running) return error.AlreadyRunning;

    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);

    const one: c_int = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one));

    const addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0,
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

    var bound_addr: posix.sockaddr.in = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(fd, @ptrCast(&bound_addr), &addr_len);
    self.local_port = std.mem.bigToNative(u16, bound_addr.port);

    try posix.listen(fd, 8);

    self.listener_fd = fd;
    self.is_running = true;
    self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});

    log.info("CLI relay server listening on 127.0.0.1:{d}", .{self.local_port});
    return self.local_port;
}

/// Stop the server.
pub fn stop(self: *CliRelayServer) void {
    self.mutex.lock();
    if (!self.is_running) {
        self.mutex.unlock();
        return;
    }
    self.is_running = false;
    const fd = self.listener_fd;
    self.listener_fd = -1;
    self.mutex.unlock();

    if (fd != -1) posix.close(fd);

    if (self.accept_thread) |t| {
        t.join();
        self.accept_thread = null;
    }
}

// -----------------------------------------------------------------------
// Accept loop
// -----------------------------------------------------------------------

fn acceptLoop(self: *CliRelayServer) void {
    while (true) {
        self.mutex.lock();
        const running = self.is_running;
        const fd = self.listener_fd;
        self.mutex.unlock();

        if (!running or fd == -1) break;

        const client_fd = posix.accept(fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
            if (!self.is_running) break;
            log.warn("relay accept failed: {}", .{err});
            continue;
        };

        const SessionCtx = struct {
            server: *CliRelayServer,
            fd: posix.socket_t,
        };
        const ctx = self.allocator.create(SessionCtx) catch {
            posix.close(client_fd);
            continue;
        };
        ctx.* = .{ .server = self, .fd = client_fd };
        _ = std.Thread.spawn(.{}, struct {
            fn run(c: *SessionCtx) void {
                defer {
                    posix.close(c.fd);
                    c.server.allocator.destroy(c);
                }
                handleSession(c.server, c.fd);
            }
        }.run, .{ctx}) catch {
            posix.close(client_fd);
            self.allocator.destroy(ctx);
            continue;
        };
    }
}

fn handleSession(self: *CliRelayServer, fd: posix.socket_t) void {
    // Step 1: Generate nonce and send challenge.
    var nonce_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&nonce_bytes);
    var nonce_hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&nonce_hex, "{s}", .{std.fmt.fmtSliceHexLower(&nonce_bytes)}) catch return;

    var challenge_buf: [512]u8 = undefined;
    const challenge = std.fmt.bufPrint(&challenge_buf, "{{\"protocol\":\"cmux-relay-auth\",\"version\":1,\"relay_id\":\"{s}\",\"nonce\":\"{s}\"}}\n", .{
        self.relay_id,
        &nonce_hex,
    }) catch return;

    _ = posix.write(fd, challenge) catch return;

    // Step 2: Read client response.
    var resp_buf: [1024]u8 = undefined;
    const resp_len = posix.read(fd, &resp_buf) catch return;
    if (resp_len == 0) return;

    const resp_line = std.mem.trim(u8, resp_buf[0..resp_len], "\r\n");

    // Parse JSON response.
    var arena_impl = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const parsed = json.parseFromSliceLeaky(json.Value, arena, resp_line, .{
        .allocate = .alloc_if_needed,
    }) catch {
        sendFail(fd);
        return;
    };

    const obj = switch (parsed) {
        .object => |o| o,
        else => {
            sendFail(fd);
            return;
        },
    };

    // Validate relay_id matches.
    const client_relay_id = switch (obj.get("relay_id") orelse .null) {
        .string => |s| s,
        else => {
            sendFail(fd);
            return;
        },
    };
    if (!std.mem.eql(u8, client_relay_id, self.relay_id)) {
        sendFail(fd);
        return;
    }

    // Validate HMAC.
    const client_mac_hex = switch (obj.get("mac") orelse .null) {
        .string => |s| s,
        else => {
            sendFail(fd);
            return;
        },
    };

    // Compute expected MAC: HMAC-SHA256(token, "relay_id=<id>\nnonce=<nonce>\nversion=1")
    var mac_input_buf: [512]u8 = undefined;
    const mac_input = std.fmt.bufPrint(&mac_input_buf, "relay_id={s}\nnonce={s}\nversion=1", .{
        self.relay_id,
        &nonce_hex,
    }) catch return;

    var expected_mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected_mac, mac_input, &self.relay_token);

    var expected_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&expected_hex, "{s}", .{std.fmt.fmtSliceHexLower(&expected_mac)}) catch return;

    // Constant-time comparison.
    if (client_mac_hex.len != 64 or !std.crypto.timing_safe.eql([64]u8, client_mac_hex[0..64].*, expected_hex)) {
        log.warn("relay auth failed: MAC mismatch", .{});
        sendFail(fd);
        return;
    }

    // Step 3: Auth OK.
    _ = posix.write(fd, "{\"ok\":true}\n") catch return;

    // Step 4: Read command and forward to local socket.
    var cmd_buf: [16384]u8 = undefined;
    const cmd_len = posix.read(fd, &cmd_buf) catch return;
    if (cmd_len == 0) return;

    const command = std.mem.trim(u8, cmd_buf[0..cmd_len], "\r\n");

    // Connect to local Unix socket, forward command, relay response.
    forwardToSocket(self, fd, command) catch |err| {
        log.warn("relay forward failed: {}", .{err});
    };
}

fn sendFail(fd: posix.socket_t) void {
    // Minimum delay to prevent timing attacks.
    std.time.sleep(50 * std.time.ns_per_ms);
    _ = posix.write(fd, "{\"ok\":false}\n") catch {};
}

/// Forward a command to the local Unix socket and relay the response
/// directly to the client fd. Avoids returning stack-local buffers.
fn forwardToSocket(self: *CliRelayServer, client_fd: posix.socket_t, command: []const u8) !void {
    // Connect to the local Unix domain socket.
    const sock_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(sock_fd);

    var addr: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = undefined,
    };
    @memset(&addr.path, 0);
    if (self.local_socket_path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..self.local_socket_path.len], self.local_socket_path);

    try posix.connect(sock_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // Send command.
    _ = try posix.write(sock_fd, command);
    _ = try posix.write(sock_fd, "\n");

    // Read response and write directly to client.
    var resp_buf: [65536]u8 = undefined;
    const n = try posix.read(sock_fd, &resp_buf);
    if (n == 0) return error.EmptyResponse;

    _ = try posix.write(client_fd, resp_buf[0..n]);
    _ = try posix.write(client_fd, "\n");
}
