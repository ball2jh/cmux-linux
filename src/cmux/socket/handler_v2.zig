// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2025 cmux-linux contributors
//
// V2 JSON-RPC protocol handler for the cmux socket API.
// Requests are newline-delimited JSON:
//   {"id":"1","method":"system.capabilities","params":{}}
// Responses:
//   {"id":"1","ok":true,"result":{...}}
//   {"id":"1","ok":false,"error":{"code":"...","message":"..."}}

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const gtk = @import("gtk");

const Server = @import("server.zig").Server;
const handler_v1 = @import("handler_v1.zig");

const log = std.log.scoped(.cmux_v2);

/// Handle a JSON-RPC request line. Parses the JSON, dispatches to
/// the appropriate handler, and writes the JSON response.
pub fn handleJsonRpc(
    ctx: *anyopaque,
    alloc: Allocator,
    line: []const u8,
    client_fd: posix.fd_t,
) void {
    // Parse the JSON request
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        line,
        .{ .allocate = .alloc_always },
    ) catch {
        respondError(alloc, client_fd, null, "parse_error", "invalid JSON");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        respondError(alloc, client_fd, null, "parse_error", "expected object");
        return;
    }

    // Extract id
    const id_val = root.object.get("id");

    // Extract method
    const method_val = root.object.get("method") orelse {
        respondError(alloc, client_fd, id_val, "invalid_request", "missing method");
        return;
    };
    const method = switch (method_val) {
        .string => |s| s,
        else => {
            respondError(alloc, client_fd, id_val, "invalid_request", "method must be string");
            return;
        },
    };

    // Dispatch based on method
    const app: *gtk.Application = @ptrCast(@alignCast(ctx));
    dispatch(app, alloc, method, root.object.get("params"), id_val, client_fd);
}

fn dispatch(
    app: *gtk.Application,
    alloc: Allocator,
    method: []const u8,
    params: ?std.json.Value,
    id: ?std.json.Value,
    client_fd: posix.fd_t,
) void {
    _ = params; // TODO: use params for parameterized methods

    if (std.mem.eql(u8, method, "system.capabilities")) {
        respondOkRaw(alloc, client_fd, id, "{\"v1\":true,\"v2\":true,\"send\":true,\"read_screen\":true,\"notifications\":true}");
    } else if (std.mem.eql(u8, method, "system.ping")) {
        respondOkString(alloc, client_fd, id, "pong");
    } else if (std.mem.eql(u8, method, "system.version")) {
        const build_config = @import("../../build_config.zig");
        respondOkString(alloc, client_fd, id, build_config.version_string);
    } else if (std.mem.eql(u8, method, "window.list")) {
        v2ListWindows(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "window.create")) {
        handler_v1.handleCommand(@ptrCast(app), alloc, "new-window", "", client_fd);
        // Override the V1 response with JSON
        respondOkString(alloc, client_fd, id, "created");
    } else if (std.mem.eql(u8, method, "surface.send_text")) {
        // Delegate to V1 send handler but we need the text from params
        // For now, respond with guidance
        respondError(alloc, client_fd, id, "not_implemented", "use V1 'send' command for now");
    } else if (std.mem.eql(u8, method, "surface.read_text")) {
        v2ReadScreen(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "notification.list")) {
        v2ListNotifications(alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "notification.clear")) {
        const notification_store = @import("../notification/store.zig");
        if (notification_store.getGlobal()) |store| store.clear(null);
        respondOkString(alloc, client_fd, id, "cleared");
    } else {
        respondError(alloc, client_fd, id, "method_not_found", method);
    }
}

fn v2ListWindows(app: *gtk.Application, alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const glib = @import("glib");
    const windows = app.getWindows();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    writer.writeAll("[") catch return;
    var count: usize = 0;
    var node: ?*glib.List = windows;
    while (node) |n| {
        if (n.f_data) |data| {
            if (count > 0) writer.writeAll(",") catch return;
            writer.print("{d}", .{@intFromPtr(data)}) catch return;
            count += 1;
        }
        node = n.f_next;
    }
    writer.writeAll("]") catch return;

    // Build result JSON manually
    respondOkRaw(alloc, client_fd, id, buf.items);
}

fn v2ReadScreen(app: *gtk.Application, alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const surface = handler_v1.getActiveSurface(app) orelse {
        respondError(alloc, client_fd, id, "no_surface", "no active surface");
        return;
    };

    surface.renderer_state.mutex.lock();
    defer surface.renderer_state.mutex.unlock();

    const text = surface.io.terminal.plainString(alloc) catch {
        respondError(alloc, client_fd, id, "read_error", "failed to read screen");
        return;
    };
    defer alloc.free(text);

    respondOkString(alloc, client_fd, id, text);
}

fn v2ListNotifications(alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const notification_store = @import("../notification/store.zig");
    const store = notification_store.getGlobal() orelse {
        respondOkRaw(alloc, client_fd, id, "[]");
        return;
    };

    store.mutex.lock();
    defer store.mutex.unlock();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    writer.writeAll("[") catch return;
    for (store.entries.items, 0..) |entry, i| {
        if (i > 0) writer.writeAll(",") catch return;
        writer.print(
            \\{{"id":{d},"title":"{s}","body":"{s}","timestamp":{d},"read":{s}}}
        , .{
            entry.id,
            entry.title,
            entry.body,
            entry.timestamp,
            if (entry.read) "true" else "false",
        }) catch return;
    }
    writer.writeAll("]") catch return;

    respondOkRaw(alloc, client_fd, id, buf.items);
}

// --- Response helpers ---

fn respondOkString(alloc: Allocator, fd: posix.fd_t, id: ?std.json.Value, result: []const u8) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    writeId(writer, id);
    // Escape the string value for JSON
    writer.writeAll(",\"ok\":true,\"result\":\"") catch return;
    writeJsonEscaped(writer, result);
    writer.writeAll("\"}\n") catch return;

    _ = posix.write(fd, buf.items) catch {};
}

fn respondOkRaw(alloc: Allocator, fd: posix.fd_t, id: ?std.json.Value, raw_json: []const u8) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    writeId(writer, id);
    writer.writeAll(",\"ok\":true,\"result\":") catch return;
    writer.writeAll(raw_json) catch return;
    writer.writeAll("}\n") catch return;

    _ = posix.write(fd, buf.items) catch {};
}

fn respondOk(alloc: Allocator, fd: posix.fd_t, id: ?std.json.Value, result: std.json.Value) void {
    _ = result;
    respondOkRaw(alloc, fd, id, "{}");
}

fn respondError(alloc: Allocator, fd: posix.fd_t, id: ?std.json.Value, code: []const u8, message: []const u8) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    writeId(writer, id);
    writer.writeAll(",\"ok\":false,\"error\":{\"code\":\"") catch return;
    writer.writeAll(code) catch return;
    writer.writeAll("\",\"message\":\"") catch return;
    writeJsonEscaped(writer, message);
    writer.writeAll("\"}}\n") catch return;

    _ = posix.write(fd, buf.items) catch {};
}

fn writeId(writer: anytype, id: ?std.json.Value) void {
    writer.writeAll("{\"id\":") catch return;
    if (id) |v| {
        switch (v) {
            .string => |s| {
                writer.writeAll("\"") catch return;
                writer.writeAll(s) catch return;
                writer.writeAll("\"") catch return;
            },
            .integer => |n| {
                writer.print("{d}", .{n}) catch return;
            },
            else => writer.writeAll("null") catch return,
        }
    } else {
        writer.writeAll("null") catch return;
    }
}

fn writeJsonEscaped(writer: anytype, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => writer.writeAll("\\\"") catch return,
            '\\' => writer.writeAll("\\\\") catch return,
            '\n' => writer.writeAll("\\n") catch return,
            '\r' => writer.writeAll("\\r") catch return,
            '\t' => writer.writeAll("\\t") catch return,
            else => {
                if (c < 0x20) {
                    writer.print("\\u{x:0>4}", .{c}) catch return;
                } else {
                    writer.writeByte(c) catch return;
                }
            },
        }
    }
}
