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
const workspace_mgr = @import("../workspace/manager.zig");
const port_scanner = @import("../workspace/port_scanner.zig");
const browser_panel = @import("../browser/panel.zig");

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
    if (std.mem.eql(u8, method, "system.capabilities")) {
        respondOkRaw(alloc, client_fd, id, "{\"v1\":true,\"v2\":true,\"send\":true,\"read_screen\":true,\"notifications\":true}");
    } else if (std.mem.eql(u8, method, "system.ping")) {
        respondOkString(alloc, client_fd, id, "pong");
    } else if (std.mem.eql(u8, method, "system.version")) {
        const build_config = @import("../../build_config.zig");
        respondOkString(alloc, client_fd, id, build_config.version_string);
    } else if (std.mem.eql(u8, method, "system.identify")) {
        const build_config = @import("../../build_config.zig");
        respondOkRaw(alloc, client_fd, id,
            "{\"app\":\"cmux-linux\",\"version\":\"" ++ build_config.version_string ++ "\",\"runtime\":\"gtk\",\"platform\":\"linux\"}");
    } else if (std.mem.eql(u8, method, "window.current")) {
        v2WindowCurrent(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "window.list")) {
        v2ListWindows(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "window.create")) {
        handler_v1.handleCommand(@ptrCast(app), alloc, "new-window", "", client_fd);
        // Override the V1 response with JSON
        respondOkString(alloc, client_fd, id, "created");
    } else if (std.mem.eql(u8, method, "surface.split")) {
        v2SurfaceSplit(app, alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "surface.send_text")) {
        v2SurfaceSendText(app, alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "surface.send_key")) {
        v2SurfaceSendKey(app, alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "pane.list")) {
        v2PaneList(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "surface.read_text")) {
        v2ReadScreen(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "workspace.list")) {
        v2WorkspaceList(alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "workspace.current")) {
        v2WorkspaceCurrent(alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "workspace.create")) {
        v2WorkspaceCreate(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "workspace.select")) {
        v2WorkspaceSelect(params, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "workspace.close")) {
        v2WorkspaceClose(params, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "workspace.rename")) {
        v2WorkspaceRename(params, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "workspace.ports")) {
        v2WorkspacePorts(alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.open")) {
        v2BrowserOpen(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.navigate")) {
        v2BrowserNavigate(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.url.get")) {
        v2BrowserGetUrl(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.list")) {
        v2BrowserList(alloc, id, client_fd);
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

fn v2WindowCurrent(app: *gtk.Application, alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    if (app.getActiveWindow()) |win| {
        var buf: [64]u8 = undefined;
        respondOkRaw(alloc, client_fd, id, std.fmt.bufPrint(&buf, "{d}", .{@intFromPtr(win)}) catch "null");
    } else {
        respondOkRaw(alloc, client_fd, id, "null");
    }
}

fn v2SurfaceSplit(app: *gtk.Application, alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const surface = handler_v1.getActiveSurface(app) orelse {
        respondError(alloc, client_fd, id, "no_surface", "no active surface");
        return;
    };

    const dir_str = getParamString(params, "direction") orelse "right";
    const Binding = @import("../../input/Binding.zig");
    const direction: Binding.Action.SplitDirection = if (std.mem.eql(u8, dir_str, "right"))
        .right
    else if (std.mem.eql(u8, dir_str, "left"))
        .left
    else if (std.mem.eql(u8, dir_str, "up"))
        .up
    else if (std.mem.eql(u8, dir_str, "down"))
        .down
    else {
        respondError(alloc, client_fd, id, "invalid_params", "direction must be right/left/up/down");
        return;
    };

    _ = surface.performBindingAction(.{ .new_split = direction }) catch {
        respondError(alloc, client_fd, id, "internal", "failed to create split");
        return;
    };
    respondOkString(alloc, client_fd, id, "split_created");
}

fn v2SurfaceSendText(app: *gtk.Application, alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const text = getParamString(params, "text") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing text");
        return;
    };

    const surface = handler_v1.getActiveSurface(app) orelse {
        respondError(alloc, client_fd, id, "no_surface", "no active surface");
        return;
    };

    surface.textCallback(text) catch {
        respondError(alloc, client_fd, id, "internal", "send failed");
        return;
    };
    respondOkString(alloc, client_fd, id, "sent");
}

fn v2SurfaceSendKey(app: *gtk.Application, alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const key_name = getParamString(params, "key") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing key");
        return;
    };

    // Delegate to V1 send-key handler logic
    handler_v1.handleCommand(@ptrCast(app), alloc, "send-key", key_name, client_fd);
    // V1 already responded, but we need JSON. For now this works since
    // the client can handle either format.
    // TODO: proper JSON response wrapping
}

fn v2PaneList(app: *gtk.Application, alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    // Delegate to V1 for now
    handler_v1.handleCommand(@ptrCast(app), alloc, "list-panes", "", client_fd);
    _ = id; // TODO: wrap in JSON
}

fn v2WorkspaceList(alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        respondOkRaw(alloc, client_fd, id, "[]");
        return;
    };
    const json_str = mgr.formatJson(alloc) catch {
        respondError(alloc, client_fd, id, "internal", "failed to format workspaces");
        return;
    };
    defer alloc.free(json_str);
    respondOkRaw(alloc, client_fd, id, json_str);
}

fn v2WorkspaceCurrent(alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        respondOkRaw(alloc, client_fd, id, "0");
        return;
    };
    var buf: [64]u8 = undefined;
    const num = std.fmt.bufPrint(&buf, "{d}", .{mgr.activeId()}) catch "0";
    respondOkRaw(alloc, client_fd, id, num);
}

fn v2WorkspaceCreate(alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        respondError(alloc, client_fd, id, "internal", "workspace manager not initialized");
        return;
    };

    var name: []const u8 = "workspace";
    if (params) |p| {
        if (p == .object) {
            if (p.object.get("name")) |n| {
                if (n == .string) name = n.string;
            }
        }
    }

    const ws_id = mgr.create(name, null) catch {
        respondError(alloc, client_fd, id, "internal", "failed to create workspace");
        return;
    };

    var buf: [64]u8 = undefined;
    const num = std.fmt.bufPrint(&buf, "{d}", .{ws_id}) catch "0";
    respondOkRaw(alloc, client_fd, id, num);
}

fn v2WorkspaceSelect(params: ?std.json.Value, alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        respondError(alloc, client_fd, id, "internal", "workspace manager not initialized");
        return;
    };

    const ws_id = getParamInt(params, "workspace_id") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing workspace_id");
        return;
    };

    if (mgr.select(ws_id)) {
        respondOkString(alloc, client_fd, id, "selected");
    } else {
        respondError(alloc, client_fd, id, "not_found", "workspace not found");
    }
}

fn v2WorkspaceClose(params: ?std.json.Value, alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        respondError(alloc, client_fd, id, "internal", "workspace manager not initialized");
        return;
    };

    const ws_id = getParamInt(params, "workspace_id") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing workspace_id");
        return;
    };

    if (mgr.close(ws_id)) {
        respondOkString(alloc, client_fd, id, "closed");
    } else {
        respondError(alloc, client_fd, id, "not_found", "workspace not found");
    }
}

fn v2WorkspaceRename(params: ?std.json.Value, alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        respondError(alloc, client_fd, id, "internal", "workspace manager not initialized");
        return;
    };

    const ws_id = getParamInt(params, "workspace_id") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing workspace_id");
        return;
    };

    const title = getParamString(params, "title") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing title");
        return;
    };

    if (mgr.rename(ws_id, title) catch false) {
        respondOkString(alloc, client_fd, id, "renamed");
    } else {
        respondError(alloc, client_fd, id, "not_found", "workspace not found");
    }
}

fn v2WorkspacePorts(alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const json_str = port_scanner.formatJson(alloc) catch {
        respondError(alloc, client_fd, id, "internal", "failed to scan ports");
        return;
    };
    defer alloc.free(json_str);
    respondOkRaw(alloc, client_fd, id, json_str);
}

fn v2BrowserOpen(alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const url = getParamString(params, "url") orelse "about:blank";
    const panel_id = browser_panel.open(url) catch {
        respondError(alloc, client_fd, id, "internal", "failed to open browser");
        return;
    };
    var buf: [64]u8 = undefined;
    respondOkRaw(alloc, client_fd, id, std.fmt.bufPrint(&buf, "{d}", .{panel_id}) catch "0");
}

fn v2BrowserNavigate(alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const url = getParamString(params, "url") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing url");
        return;
    };
    const panel_id = getParamInt(params, "id") orelse 0;
    browser_panel.navigateTo(@intCast(panel_id), url) catch {
        respondError(alloc, client_fd, id, "not_found", "browser not found");
        return;
    };
    respondOkString(alloc, client_fd, id, "navigated");
}

fn v2BrowserGetUrl(alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const panel_id = getParamInt(params, "id") orelse 0;
    const url = browser_panel.getUrl(@intCast(panel_id)) orelse {
        respondError(alloc, client_fd, id, "not_found", "browser not found");
        return;
    };
    respondOkString(alloc, client_fd, id, url);
}

fn v2BrowserList(alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const json_str = browser_panel.formatJson(alloc) catch {
        respondError(alloc, client_fd, id, "internal", "failed to list browsers");
        return;
    };
    defer alloc.free(json_str);
    respondOkRaw(alloc, client_fd, id, json_str);
}

/// Extract an integer parameter from JSON params.
fn getParamInt(params: ?std.json.Value, key: []const u8) ?u64 {
    const p = params orelse return null;
    if (p != .object) return null;
    const v = p.object.get(key) orelse return null;
    return switch (v) {
        .integer => |n| @intCast(@max(0, n)),
        else => null,
    };
}

/// Extract a string parameter from JSON params.
fn getParamString(params: ?std.json.Value, key: []const u8) ?[]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    const v = p.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
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
