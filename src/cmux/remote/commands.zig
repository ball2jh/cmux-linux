//! V2 socket command handlers for workspace.remote.* methods.
//!
//! Five commands:
//!   workspace.remote.configure
//!   workspace.remote.reconnect
//!   workspace.remote.disconnect
//!   workspace.remote.status
//!   workspace.remote.terminal_session_end
//!
//! Matches macOS TerminalController v2WorkspaceRemote* handlers
//! (TerminalController.swift lines 3676-3945).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const v2 = @import("../v2.zig");
const Server = @import("../Server.zig");
const RefMap = @import("../RefMap.zig");
const Uuid = @import("../uuid.zig").Uuid;
const workspace_mod = @import("../workspace/main.zig");
const remote = workspace_mod.remote;

const log = std.log.scoped(.cmux_remote_commands);

/// All workspace.remote.* method names for system.capabilities registration.
pub const method_names = [_][]const u8{
    "workspace.remote.configure",
    "workspace.remote.reconnect",
    "workspace.remote.disconnect",
    "workspace.remote.status",
    "workspace.remote.terminal_session_end",
};

// -----------------------------------------------------------------------
// workspace.remote.configure
// -----------------------------------------------------------------------

pub fn handleConfigure(
    server: *Server,
    arena: Allocator,
    writer: *@import("../client_handler.zig").ResponseWriter,
    req: v2.Request,
) void {
    // Destination is required.
    const destination = trimToNull(jsonStr(req.params.get("destination")));
    if (destination == null) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing destination") catch {};
        return;
    }

    // Validate port fields.
    const port = parsePort(req.params, "port") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Invalid port (must be 1-65535)") catch {};
        return;
    };
    const local_proxy_port = parsePort(req.params, "local_proxy_port") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Invalid local_proxy_port (must be 1-65535)") catch {};
        return;
    };
    const relay_port = parsePort(req.params, "relay_port") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Invalid relay_port (must be 1-65535)") catch {};
        return;
    };

    // If relay_port is set, relay_id and relay_token are required.
    const relay_id = trimToNull(jsonStr(req.params.get("relay_id")));
    const relay_token = trimToNull(jsonStr(req.params.get("relay_token")));
    if (relay_port != null) {
        if (relay_id == null) {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "relay_id required when relay_port is set") catch {};
            return;
        }
        if (relay_token == null or !isValidRelayToken(relay_token.?)) {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "relay_token must be 64 lowercase hex characters") catch {};
            return;
        }
    }

    const auto_connect = jsonBool(req.params.get("auto_connect")) orelse true;
    const ssh_options = jsonStrArray(arena, req.params.get("ssh_options"));

    const config = remote.Configuration{
        .destination = destination.?,
        .port = port,
        .identity_file = trimToNull(jsonStr(req.params.get("identity_file"))),
        .ssh_options = ssh_options,
        .local_proxy_port = local_proxy_port,
        .relay_port = relay_port,
        .relay_id = relay_id,
        .relay_token = relay_token,
        .local_socket_path = trimToNull(jsonStr(req.params.get("local_socket_path"))),
        .terminal_startup_command = trimToNull(jsonStr(req.params.get("terminal_startup_command"))),
    };

    // Resolve workspace and configure.
    const ws_id = resolveWorkspaceId(server, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    const mgr = server.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    const ws = mgr.workspaceById(ws_id) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    ws.configureRemoteConnection(config, auto_connect);
    mgr.notify(.{ .workspace_remote_state_changed = ws_id });

    writeWorkspaceRemoteResponse(server, arena, writer, req.id, ws_id, null, null);
}

// -----------------------------------------------------------------------
// workspace.remote.reconnect
// -----------------------------------------------------------------------

pub fn handleReconnect(
    server: *Server,
    arena: Allocator,
    writer: *@import("../client_handler.zig").ResponseWriter,
    req: v2.Request,
) void {
    const ws_id = resolveWorkspaceId(server, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    const mgr = server.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    const ws = mgr.workspaceById(ws_id) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    // Must have existing configuration.
    if (ws.remote_state.configuration == null) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_state, "Remote workspace is not configured") catch {};
        return;
    }

    ws.reconnectRemoteConnection();
    mgr.notify(.{ .workspace_remote_state_changed = ws_id });

    writeWorkspaceRemoteResponse(server, arena, writer, req.id, ws_id, null, null);
}

// -----------------------------------------------------------------------
// workspace.remote.disconnect
// -----------------------------------------------------------------------

pub fn handleDisconnect(
    server: *Server,
    arena: Allocator,
    writer: *@import("../client_handler.zig").ResponseWriter,
    req: v2.Request,
) void {
    const ws_id = resolveWorkspaceId(server, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    const mgr = server.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    const ws = mgr.workspaceById(ws_id) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    const clear = jsonBool(req.params.get("clear")) orelse false;
    ws.disconnectRemoteConnection(clear);
    mgr.notify(.{ .workspace_remote_state_changed = ws_id });

    writeWorkspaceRemoteResponse(server, arena, writer, req.id, ws_id, null, null);
}

// -----------------------------------------------------------------------
// workspace.remote.status
// -----------------------------------------------------------------------

pub fn handleStatus(
    server: *Server,
    arena: Allocator,
    writer: *@import("../client_handler.zig").ResponseWriter,
    req: v2.Request,
) void {
    const ws_id = resolveWorkspaceId(server, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    const mgr = server.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    if (mgr.workspaceById(ws_id) == null) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    }

    writeWorkspaceRemoteResponse(server, arena, writer, req.id, ws_id, null, null);
}

// -----------------------------------------------------------------------
// workspace.remote.terminal_session_end
// -----------------------------------------------------------------------

pub fn handleTerminalSessionEnd(
    server: *Server,
    arena: Allocator,
    writer: *@import("../client_handler.zig").ResponseWriter,
    req: v2.Request,
) void {
    // All three params are required.
    const ws_id = server.v2UUID(req.params, "workspace_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing or invalid workspace_id") catch {};
        return;
    };
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing or invalid surface_id") catch {};
        return;
    };
    const relay_port = parsePort(req.params, "relay_port") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing or invalid relay_port (must be 1-65535)") catch {};
        return;
    };
    if (relay_port == null) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing relay_port") catch {};
        return;
    }

    const mgr = server.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    const ws = mgr.workspaceById(ws_id) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    ws.markRemoteTerminalSessionEnded(surface_id, relay_port);
    mgr.notify(.{ .workspace_remote_state_changed = ws_id });

    writeWorkspaceRemoteResponse(server, arena, writer, req.id, ws_id, surface_id, relay_port);
}

// -----------------------------------------------------------------------
// Response builder
// -----------------------------------------------------------------------

/// Build and write the standard workspace.remote.* response.
/// Includes workspace_id, workspace_ref, remote status payload,
/// and optionally surface_id/surface_ref/relay_port for terminal_session_end.
fn writeWorkspaceRemoteResponse(
    server: *Server,
    arena: Allocator,
    writer: anytype,
    req_id: json.Value,
    ws_id: Uuid,
    surface_id: ?Uuid,
    relay_port: ?u16,
) void {
    const mgr = server.workspace_manager orelse return;
    const ws = mgr.workspaceById(ws_id) orelse return;

    var result = json.ObjectMap.init(arena);
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch return;
    result.put("workspace_ref", server.v2Ref(.workspace, ws_id)) catch return;

    // Build remote status payload.
    const remote_payload = buildRemoteStatusPayload(arena, ws);
    result.put("remote", remote_payload) catch return;

    // Extra fields for terminal_session_end.
    if (surface_id) |sid| {
        result.put("surface_id", .{ .string = formatUuid(arena, sid) }) catch return;
        result.put("surface_ref", server.v2Ref(.surface, sid)) catch return;
    }
    if (relay_port) |rp| {
        result.put("relay_port", .{ .integer = @intCast(rp) }) catch return;
    }

    v2.writeOk(writer, arena, req_id, .{ .object = result }) catch {};
}

fn formatUuid(arena: Allocator, id: Uuid) []const u8 {
    var buf: [36]u8 = undefined;
    _ = id.formatBuf(&buf);
    return arena.dupe(u8, &buf) catch "";
}

/// Build the `remote` status payload object.
/// Matches macOS Workspace.remoteStatusPayload() (Workspace.swift lines 6485-6555).
fn buildRemoteStatusPayload(arena: Allocator, ws: *const workspace_mod.Workspace) json.Value {
    var obj = json.ObjectMap.init(arena);

    const config = ws.remote_state.configuration;
    const enabled = config != null;
    const state = ws.remote_state.connection_state;

    obj.put("enabled", .{ .bool = enabled }) catch return .null;
    obj.put("state", .{ .string = connectionStateStr(state) }) catch return .null;
    obj.put("connected", .{ .bool = state == .connected }) catch return .null;
    obj.put("active_terminal_sessions", .{ .integer = @intCast(ws.active_remote_terminal_session_count) }) catch return .null;

    // Daemon status.
    const daemon = buildDaemonPayload(arena, &ws.remote_state.daemon_status);
    obj.put("daemon", daemon) catch return .null;

    // Port arrays.
    obj.put("detected_ports", portArray(arena, ws.remote_state.detected_ports)) catch return .null;
    obj.put("forwarded_ports", portArray(arena, ws.remote_state.forwarded_ports)) catch return .null;
    obj.put("conflicted_ports", portArray(arena, ws.remote_state.port_conflicts)) catch return .null;

    // Detail (error/retry message).
    obj.put("detail", jsonNullableStr(ws.remote_state.connection_detail)) catch return .null;

    // Heartbeat.
    const heartbeat = buildHeartbeatPayload(arena, ws);
    obj.put("heartbeat", heartbeat) catch return .null;

    // Proxy — placeholder until ProxyBroker is implemented in Phase 4.
    const proxy = buildProxyPayload(arena, state);
    obj.put("proxy", proxy) catch return .null;

    // Configuration fields (null if not configured).
    if (config) |c| {
        obj.put("destination", .{ .string = c.destination }) catch return .null;
        obj.put("port", if (c.port) |p| json.Value{ .integer = @intCast(p) } else .null) catch return .null;
        obj.put("has_identity_file", .{ .bool = c.identity_file != null }) catch return .null;
        obj.put("has_ssh_options", .{ .bool = c.ssh_options.len > 0 }) catch return .null;
        obj.put("local_proxy_port", if (c.local_proxy_port) |p| json.Value{ .integer = @intCast(p) } else .null) catch return .null;
    } else {
        obj.put("destination", .null) catch return .null;
        obj.put("port", .null) catch return .null;
        obj.put("has_identity_file", .{ .bool = false }) catch return .null;
        obj.put("has_ssh_options", .{ .bool = false }) catch return .null;
        obj.put("local_proxy_port", .null) catch return .null;
    }

    return .{ .object = obj };
}

fn buildDaemonPayload(arena: Allocator, d: *const remote.DaemonStatus) json.Value {
    var obj = json.ObjectMap.init(arena);
    obj.put("state", .{ .string = daemonStateStr(d.state) }) catch return .null;
    obj.put("detail", jsonNullableStr(d.detail)) catch return .null;
    obj.put("version", jsonNullableStr(d.version)) catch return .null;
    obj.put("name", jsonNullableStr(d.name)) catch return .null;

    // Capabilities array.
    var caps = json.Array.init(arena);
    for (d.capabilities) |c| {
        caps.append(.{ .string = c }) catch continue;
    }
    obj.put("capabilities", .{ .array = caps }) catch return .null;

    obj.put("remote_path", jsonNullableStr(d.remote_path)) catch return .null;
    return .{ .object = obj };
}

fn buildHeartbeatPayload(arena: Allocator, ws: *const workspace_mod.Workspace) json.Value {
    var obj = json.ObjectMap.init(arena);
    obj.put("count", .{ .integer = @intCast(ws.remote_state.heartbeat_count) }) catch return .null;

    // last_seen_at: null for now; full ISO 8601 formatting comes with Phase 5.
    if (ws.remote_state.last_heartbeat_at) |ts| {
        // Store epoch seconds as integer for now; proper ISO formatting in Phase 5.
        obj.put("last_seen_at", .{ .integer = ts }) catch return .null;
        // age_seconds: seconds since last heartbeat.
        const now = std.time.timestamp();
        const age = now - ts;
        obj.put("age_seconds", .{ .integer = if (age >= 0) age else 0 }) catch return .null;
    } else {
        obj.put("last_seen_at", .null) catch return .null;
        obj.put("age_seconds", .null) catch return .null;
    }

    return .{ .object = obj };
}

fn buildProxyPayload(arena: Allocator, state: remote.ConnectionState) json.Value {
    var obj = json.ObjectMap.init(arena);

    // No proxy endpoint until ProxyBroker is wired. State mapping matches Mac.
    const proxy_state: []const u8 = switch (state) {
        .connected => "unavailable", // Becomes "ready" once proxy endpoint exists.
        .connecting => "connecting",
        .disconnected => "unavailable",
        .@"error" => "error",
    };

    const error_code: json.Value = if (state == .@"error")
        .{ .string = "proxy_unavailable" }
    else
        .null;

    obj.put("state", .{ .string = proxy_state }) catch return .null;
    obj.put("host", .null) catch return .null;
    obj.put("port", .null) catch return .null;

    var schemes = json.Array.init(arena);
    schemes.append(.{ .string = "socks5" }) catch {};
    schemes.append(.{ .string = "http_connect" }) catch {};
    obj.put("schemes", .{ .array = schemes }) catch return .null;

    obj.put("url", .null) catch return .null;
    obj.put("error_code", error_code) catch return .null;

    return .{ .object = obj };
}

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

/// Resolve workspace_id from params. If the param is present but invalid,
/// returns null (caller should return invalid_params error). If absent,
/// falls back to selected workspace. Matches Mac's two-step validation.
fn resolveWorkspaceId(server: *const Server, params: json.ObjectMap) ?Uuid {
    // If param is present and non-null, it MUST be a valid UUID.
    const raw = params.get("workspace_id");
    if (raw) |val| {
        switch (val) {
            .null => {}, // Treat null as absent — fall through to default.
            .string => |s| {
                if (s.len > 0) {
                    // Param present — must resolve or fail.
                    return server.v2UUID(params, "workspace_id");
                }
            },
            else => return null, // Non-string, non-null = invalid.
        }
    }
    // Param absent — fall back to selected workspace.
    const mgr = server.workspace_manager orelse return null;
    return mgr.selected_id;
}

fn jsonStr(val: ?json.Value) []const u8 {
    const v = val orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn jsonBool(val: ?json.Value) ?bool {
    const v = val orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn jsonStrArray(arena: Allocator, val: ?json.Value) []const []const u8 {
    const v = val orelse return &.{};
    const arr = switch (v) {
        .array => |a| a,
        else => return &.{},
    };
    if (arr.items.len == 0) return &.{};

    const result = arena.alloc([]const u8, arr.items.len) catch return &.{};
    var count: usize = 0;
    for (arr.items) |item| {
        switch (item) {
            .string => |s| {
                result[count] = s;
                count += 1;
            },
            else => {},
        }
    }
    return result[0..count];
}

/// Parse a port parameter. Returns:
///   - `@as(?u16, null)` if the param is missing (ok, optional)
///   - `@as(?u16, value)` if valid
///   - null (the optional itself) if invalid — caller should return error
fn parsePort(params: json.ObjectMap, key: []const u8) ??u16 {
    const val = params.get(key) orelse return @as(?u16, null);
    switch (val) {
        .integer => |i| {
            if (i >= 1 and i <= 65535) return @as(?u16, @intCast(i));
            return null; // out of range
        },
        .string => |s| {
            const num = std.fmt.parseInt(u16, s, 10) catch return null;
            if (num >= 1) return @as(?u16, num);
            return null;
        },
        .null => return @as(?u16, null),
        else => return null,
    }
}

fn trimToNull(s: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\n\r");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn isValidRelayToken(token: []const u8) bool {
    if (token.len != 64) return false;
    for (token) |c| {
        if (!std.ascii.isHex(c)) return false;
        // Must be lowercase hex.
        if (c >= 'A' and c <= 'F') return false;
    }
    return true;
}

fn connectionStateStr(state: remote.ConnectionState) []const u8 {
    return switch (state) {
        .disconnected => "disconnected",
        .connecting => "connecting",
        .connected => "connected",
        .@"error" => "error",
    };
}

fn daemonStateStr(state: remote.DaemonState) []const u8 {
    return switch (state) {
        .unavailable => "unavailable",
        .bootstrapping => "bootstrapping",
        .ready => "ready",
        .@"error" => "error",
    };
}

fn jsonNullableStr(s: ?[]const u8) json.Value {
    if (s) |str| return .{ .string = str };
    return .null;
}

fn portArray(arena: Allocator, ports: []const u16) json.Value {
    var arr = json.Array.init(arena);
    for (ports) |p| {
        arr.append(.{ .integer = @intCast(p) }) catch continue;
    }
    return .{ .array = arr };
}
