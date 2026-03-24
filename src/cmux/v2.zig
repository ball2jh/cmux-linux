//! V2 socket protocol: JSON-RPC-style, newline-delimited.
//!
//! Request:  {"id": <any>, "method": "system.ping", "params": {...}}\n
//! Success:  {"id": <any>, "ok": true, "result": <payload>}\n
//! Error:    {"id": <any>, "ok": false, "error": {"code": "...", "message": "..."}}\n
//!
//! Method names use dot notation (system.ping, workspace.list, surface.focus).
//! Responses are always single-line JSON — literal newlines within values
//! are escaped as \\n. Matches macOS TerminalController V2 protocol (line 1989).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

pub const Request = struct {
    /// Correlation ID echoed in the response. May be any JSON type.
    id: json.Value,
    /// Dot-delimited method name (e.g., "system.ping").
    method: []const u8,
    /// Parameters object. Empty map if not provided.
    params: json.ObjectMap,
};

/// Result of a V2 command handler.
pub const CallResult = union(enum) {
    ok: json.Value,
    err: ErrorPayload,

    pub const ErrorPayload = struct {
        code: []const u8,
        message: []const u8,
        data: ?json.Value = null,
    };
};

/// Standard error codes matching macOS reference.
pub const ErrorCode = struct {
    pub const parse_error = "parse_error";
    pub const invalid_request = "invalid_request";
    pub const method_not_found = "method_not_found";
    pub const invalid_params = "invalid_params";
    pub const auth_required = "auth_required";
    pub const auth_failed = "auth_failed";
    pub const auth_unconfigured = "auth_unconfigured";
    pub const encode_error = "encode_error";
    pub const not_found = "not_found";
    pub const invalid_state = "invalid_state";
    pub const internal_error = "internal_error";
};

/// Parse a V2 JSON request line.
/// All strings within the returned Request are owned by `arena`.
pub fn parseRequest(arena: Allocator, line: []const u8) error{ ParseError, OutOfMemory }!Request {
    const parsed = json.parseFromSliceLeaky(json.Value, arena, line, .{
        .allocate = .alloc_if_needed,
    }) catch return error.ParseError;

    const obj = switch (parsed) {
        .object => |m| m,
        else => return error.ParseError,
    };

    const method = switch (obj.get("method") orelse return error.ParseError) {
        .string => |s| s,
        else => return error.ParseError,
    };

    const id = obj.get("id") orelse .null;

    const params: json.ObjectMap = if (obj.get("params")) |p| switch (p) {
        .object => |m| m,
        else => json.ObjectMap.init(arena),
    } else json.ObjectMap.init(arena);

    return .{
        .id = id,
        .method = method,
        .params = params,
    };
}

/// Write a V2 success response: {"id": ..., "ok": true, "result": ...}\n
pub fn writeOk(writer: anytype, arena: Allocator, id: json.Value, result: json.Value) !void {
    try writeJsonLine(writer, arena, buildOk(arena, id, result));
}

/// Write a V2 error response: {"id": ..., "ok": false, "error": {"code": ..., "message": ...}}\n
pub fn writeError(
    writer: anytype,
    arena: Allocator,
    id: json.Value,
    code: []const u8,
    message: []const u8,
) !void {
    try writeJsonLine(writer, arena, buildError(arena, id, code, message, null));
}

/// Write a V2 error response with optional data field.
pub fn writeErrorWithData(
    writer: anytype,
    arena: Allocator,
    id: json.Value,
    code: []const u8,
    message: []const u8,
    data: ?json.Value,
) !void {
    try writeJsonLine(writer, arena, buildError(arena, id, code, message, data));
}

/// Write a V2 response from a CallResult.
pub fn writeResult(writer: anytype, arena: Allocator, id: json.Value, result: CallResult) !void {
    switch (result) {
        .ok => |payload| try writeOk(writer, arena, id, payload),
        .err => |e| try writeErrorWithData(writer, arena, id, e.code, e.message, e.data),
    }
}

// --- Internal helpers ---

fn buildOk(arena: Allocator, id: json.Value, result: json.Value) json.Value {
    var map = json.ObjectMap.init(arena);
    map.put("id", id) catch {};
    map.put("ok", .{ .bool = true }) catch {};
    map.put("result", result) catch {};
    return .{ .object = map };
}

fn buildError(
    arena: Allocator,
    id: json.Value,
    code: []const u8,
    message: []const u8,
    data: ?json.Value,
) json.Value {
    var err_obj = json.ObjectMap.init(arena);
    err_obj.put("code", .{ .string = code }) catch {};
    err_obj.put("message", .{ .string = message }) catch {};
    if (data) |d| {
        err_obj.put("data", d) catch {};
    }

    var map = json.ObjectMap.init(arena);
    map.put("id", id) catch {};
    map.put("ok", .{ .bool = false }) catch {};
    map.put("error", .{ .object = err_obj }) catch {};
    return .{ .object = map };
}

/// Serialize a JSON value to a single line (newlines escaped) and write it
/// followed by \n. Matches macOS v2Encode (line 2955).
fn writeJsonLine(writer: anytype, arena: Allocator, value: json.Value) !void {
    // Serialize JSON to a string using std.json.fmt (the Zig 0.15 pattern).
    const encoded = std.fmt.allocPrint(arena, "{f}", .{
        json.fmt(value, .{ .whitespace = .minified }),
    }) catch {
        // Fallback: write a static encode_error response.
        try writer.writeAll("{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}\n");
        return;
    };

    // Escape literal newlines for the line protocol.
    var start: usize = 0;
    for (encoded, 0..) |ch, i| {
        if (ch == '\n') {
            try writer.writeAll(encoded[start..i]);
            try writer.writeAll("\\n");
            start = i + 1;
        }
    }
    try writer.writeAll(encoded[start..]);
    try writer.writeByte('\n');
}

// --- Tests ---

test "parseRequest valid" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const req = try parseRequest(arena,
        \\{"id":1,"method":"system.ping","params":{}}
    );
    try std.testing.expectEqualStrings("system.ping", req.method);
    try std.testing.expectEqual(json.Value{ .integer = 1 }, req.id);
}

test "parseRequest minimal (no id, no params)" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const req = try parseRequest(arena,
        \\{"method":"system.ping"}
    );
    try std.testing.expectEqualStrings("system.ping", req.method);
    try std.testing.expectEqual(json.Value.null, req.id);
}

test "parseRequest invalid JSON" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    try std.testing.expectError(error.ParseError, parseRequest(arena, "not json"));
}

test "parseRequest missing method" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    try std.testing.expectError(error.ParseError, parseRequest(arena,
        \\{"id":1}
    ));
}

test "writeOk format" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var result_map = json.ObjectMap.init(arena);
    try result_map.put("pong", .{ .bool = true });

    try writeOk(fbs.writer(), arena, .{ .integer = 1 }, .{ .object = result_map });
    const output = fbs.getWritten();

    // Response must end with \n and be valid JSON before the newline.
    try std.testing.expect(output.len > 0 and output[output.len - 1] == '\n');

    // Parse the JSON to verify structure.
    const parsed = try json.parseFromSliceLeaky(json.Value, arena, output[0 .. output.len - 1], .{
        .allocate = .alloc_if_needed,
    });
    const obj = parsed.object;
    try std.testing.expectEqual(json.Value{ .bool = true }, obj.get("ok").?);
}

test "writeError format" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try writeError(fbs.writer(), arena, .null, ErrorCode.method_not_found, "Unknown method");
    const output = fbs.getWritten();

    try std.testing.expect(output.len > 0 and output[output.len - 1] == '\n');

    const parsed = try json.parseFromSliceLeaky(json.Value, arena, output[0 .. output.len - 1], .{
        .allocate = .alloc_if_needed,
    });
    const obj = parsed.object;
    try std.testing.expectEqual(json.Value{ .bool = false }, obj.get("ok").?);
    const err_obj = obj.get("error").?.object;
    try std.testing.expectEqualStrings("method_not_found", err_obj.get("code").?.string);
}
