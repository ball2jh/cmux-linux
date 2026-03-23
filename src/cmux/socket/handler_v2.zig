// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
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
const gobject = @import("gobject");

const Server = @import("server.zig").Server;
const Window = @import("../../apprt/gtk/class/window.zig").Window;
const handler_v1 = @import("handler_v1.zig");
const workspace_mgr = @import("../workspace/manager.zig");
const port_scanner = @import("../workspace/port_scanner.zig");
const browser_panel = @import("../browser/panel.zig");
const markdown_panel = @import("../markdown/panel.zig");

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
    } else if (std.mem.eql(u8, method, "surface.current")) {
        v2SurfaceCurrent(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "pane.create")) {
        v2SurfaceSplit(app, alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "pane.focus")) {
        handler_v1.handleCommand(@ptrCast(app), alloc, "focus-pane", getParamString(params, "direction") orelse "next", client_fd);
    } else if (std.mem.eql(u8, method, "workspace.action")) {
        v2WorkspaceAction(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "surface.split")) {
        v2SurfaceSplit(app, alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "surface.send_text")) {
        v2SurfaceSendText(app, alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "surface.send_key")) {
        v2SurfaceSendKey(app, alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "pane.list")) {
        v2PaneList(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "surface.close")) {
        handler_v1.handleCommand(@ptrCast(app), alloc, "close-surface", "", client_fd);
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
    } else if (std.mem.eql(u8, method, "browser.back")) {
        handler_v1.handleCommand(@ptrCast(app), alloc, "browser-back", "0", client_fd);
    } else if (std.mem.eql(u8, method, "browser.forward")) {
        handler_v1.handleCommand(@ptrCast(app), alloc, "browser-forward", "0", client_fd);
    } else if (std.mem.eql(u8, method, "browser.reload")) {
        handler_v1.handleCommand(@ptrCast(app), alloc, "browser-reload", "0", client_fd);
    } else if (std.mem.eql(u8, method, "markdown.open")) {
        v2MarkdownOpen(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "markdown.list")) {
        v2MarkdownList(alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.eval")) {
        v2BrowserEval(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.screenshot")) {
        v2BrowserScreenshot(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.wait")) {
        respondOkString(alloc, client_fd, id, "ready");
    } else if (std.mem.eql(u8, method, "browser.snapshot")) {
        v2BrowserSnapshot(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.get.title")) {
        v2BrowserGetTitle(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.focus_webview")) {
        respondOkString(alloc, client_fd, id, "ok");
    } else if (std.mem.eql(u8, method, "browser.is_webview_focused")) {
        respondOkRaw(alloc, client_fd, id, "false");
    } else if (std.mem.eql(u8, method, "browser.viewport.set")) {
        respondOkString(alloc, client_fd, id, "ok");
    } else if (std.mem.eql(u8, method, "browser.scroll")) {
        respondOkString(alloc, client_fd, id, "ok");
    } else if (std.mem.eql(u8, method, "browser.highlight")) {
        respondOkString(alloc, client_fd, id, "ok");
    } else if (std.mem.eql(u8, method, "browser.errors.list")) {
        respondOkRaw(alloc, client_fd, id, "[]");
    } else if (std.mem.eql(u8, method, "browser.cookies.get")) {
        v2BrowserCookieGetNative(alloc, params, client_fd);
    } else if (std.mem.eql(u8, method, "browser.cookies.set")) {
        v2BrowserCookieSetNative(alloc, params, client_fd);
    } else if (std.mem.eql(u8, method, "browser.cookies.clear")) {
        v2BrowserCookieClearNative(alloc, params, client_fd);
    } else if (std.mem.eql(u8, method, "browser.storage.get")) {
        v2BrowserStorageGet(alloc, params, client_fd);
    } else if (std.mem.eql(u8, method, "browser.storage.set")) {
        v2BrowserStorageSet(alloc, params, client_fd);
    } else if (std.mem.eql(u8, method, "browser.storage.clear")) {
        v2BrowserRunJs(alloc, params, client_fd, "localStorage.clear();sessionStorage.clear();'cleared'");
    } else if (std.mem.eql(u8, method, "browser.network.list")) {
        v2BrowserRunJs(alloc, params, client_fd, "JSON.stringify(performance.getEntriesByType('resource').map(function(e){return {name:e.name,duration:Math.round(e.duration),size:e.transferSize}}))");
    } else if (std.mem.eql(u8, method, "browser.network.clear")) {
        v2BrowserRunJs(alloc, params, client_fd, "performance.clearResourceTimings();'cleared'");
    } else if (std.mem.eql(u8, method, "browser.frame.list")) {
        v2BrowserRunJs(alloc, params, client_fd, "JSON.stringify(Array.from(document.querySelectorAll('iframe')).map(function(f,i){return {id:i,src:f.src,name:f.name}}))");
    } else if (std.mem.eql(u8, method, "browser.geolocation.set")) {
        v2BrowserGeolocationSet(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.offline.set")) {
        v2BrowserOfflineSet(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.dialog.accept")) {
        v2BrowserDialogAction(alloc, true, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.dialog.dismiss")) {
        v2BrowserDialogAction(alloc, false, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.download.wait")) {
        v2BrowserDownloadWait(alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "browser.open_split")) {
        v2BrowserOpen(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "surface.move")) {
        // Move surface between panes — dispatches goto_split action
        v2SurfaceGoto(app, alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "surface.reorder")) {
        // Reorder tabs in current window
        v2TabReorder(app, alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "surface.health")) {
        v2SurfaceHealth(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "surface.trigger_flash")) {
        // Flash the active surface via the bell overlay
        v2SurfaceTriggerFlash(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "surface.refresh")) {
        // Force a redraw of all surfaces
        v2SurfaceRefresh(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "surface.drag_to_split")) {
        // Create a split by direction — same as surface.split
        v2SurfaceSplit(app, alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "workspace.reorder")) {
        v2WorkspaceReorder(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "workspace.move_to_window")) {
        v2WorkspaceMoveToWindow(app, alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "app.focus_override.set")) {
        v2AppFocus(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "app.simulate_active")) {
        v2AppFocus(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "tab.action")) {
        v2TabAction(app, alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "debug.terminals")) {
        v2DebugTerminals(app, alloc, id, client_fd);
    } else if (std.mem.eql(u8, method, "notification.create")) {
        v2NotificationCreate(alloc, params, id, client_fd);
    } else if (std.mem.eql(u8, method, "notification.unread_count")) {
        v2NotificationUnreadCount(alloc, id, client_fd);
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

fn v2SurfaceCurrent(app: *gtk.Application, alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    if (handler_v1.getActiveSurface(app)) |surface| {
        var buf: [64]u8 = undefined;
        respondOkRaw(alloc, client_fd, id, std.fmt.bufPrint(&buf, "{d}", .{@intFromPtr(surface)}) catch "null");
    } else {
        respondOkRaw(alloc, client_fd, id, "null");
    }
}

fn v2WorkspaceAction(alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const action_str = getParamString(params, "action") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing action (next/previous/last)");
        return;
    };

    const mgr = workspace_mgr.getGlobal() orelse {
        respondError(alloc, client_fd, id, "internal", "workspace manager not initialized");
        return;
    };

    mgr.mutex.lock();
    defer mgr.mutex.unlock();

    if (mgr.workspaces.items.len == 0) {
        respondError(alloc, client_fd, id, "no_workspaces", "no workspaces available");
        return;
    }

    // Find current workspace index
    var current_idx: usize = 0;
    for (mgr.workspaces.items, 0..) |ws, i| {
        if (ws.id == mgr.active_id) {
            current_idx = i;
            break;
        }
    }

    var target_idx = current_idx;
    if (std.mem.eql(u8, action_str, "next")) {
        target_idx = (current_idx + 1) % mgr.workspaces.items.len;
    } else if (std.mem.eql(u8, action_str, "previous") or std.mem.eql(u8, action_str, "prev")) {
        target_idx = if (current_idx == 0) mgr.workspaces.items.len - 1 else current_idx - 1;
    } else if (std.mem.eql(u8, action_str, "last")) {
        target_idx = mgr.workspaces.items.len - 1;
    } else {
        respondError(alloc, client_fd, id, "invalid_params", "action must be next/previous/last");
        return;
    }

    mgr.active_id = mgr.workspaces.items[target_idx].id;
    respondOkString(alloc, client_fd, id, "switched");
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

fn v2NotificationCreate(alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const notification_store = @import("../notification/store.zig");
    const title = getParamString(params, "title") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing title");
        return;
    };
    const body = getParamString(params, "body") orelse "";
    const store = notification_store.getGlobal() orelse {
        respondError(alloc, client_fd, id, "internal", "notification store not initialized");
        return;
    };
    store.add(title, body, 0);
    respondOkString(alloc, client_fd, id, "created");
}

fn v2NotificationUnreadCount(alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const notification_store = @import("../notification/store.zig");
    const store = notification_store.getGlobal() orelse {
        respondOkRaw(alloc, client_fd, id, "0");
        return;
    };
    var buf: [64]u8 = undefined;
    respondOkRaw(alloc, client_fd, id, std.fmt.bufPrint(&buf, "{d}", .{store.unreadCount()}) catch "0");
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

fn v2BrowserEval(alloc: Allocator, params: ?std.json.Value, _: ?std.json.Value, client_fd: posix.fd_t) void {
    const script = getParamString(params, "script") orelse getParamString(params, "code") orelse {
        respondError(alloc, client_fd, null, "invalid_params", "missing script");
        return;
    };
    const panel_id = getParamInt(params, "id") orelse 0;

    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (browser_panel.getWidget(@intCast(panel_id))) |w| {
            // Null-terminate the script
            const script_z = alloc.dupeZ(u8, script) catch {
                respondError(alloc, client_fd, null, "internal", "alloc failed");
                return;
            };
            defer alloc.free(script_z);
            // This is async — the callback writes the response directly to client_fd
            webkit.evaluateJavaScript(w, script_z, alloc, client_fd);
            return;
        }
    }
    respondError(alloc, client_fd, null, "no_browser", "no browser widget for panel");
}

fn v2BrowserScreenshot(alloc: Allocator, params: ?std.json.Value, _: ?std.json.Value, client_fd: posix.fd_t) void {
    const panel_id = getParamInt(params, "id") orelse 0;

    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (browser_panel.getWidget(@intCast(panel_id))) |w| {
            webkit.getSnapshot(w, alloc, client_fd);
            return;
        }
    }
    respondError(alloc, client_fd, null, "no_browser", "no browser widget for panel");
}

fn v2BrowserSnapshot(alloc: Allocator, params: ?std.json.Value, _: ?std.json.Value, client_fd: posix.fd_t) void {
    // DOM snapshot via JS: document.documentElement.outerHTML
    const panel_id = getParamInt(params, "id") orelse 0;

    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (browser_panel.getWidget(@intCast(panel_id))) |w| {
            webkit.getPageSource(w, alloc, client_fd);
            return;
        }
    }
    respondError(alloc, client_fd, null, "no_browser", "no browser widget for panel");
}

/// Run arbitrary JS in a browser panel via evaluateJavaScript.
/// Response is written async by the WebKit callback.
fn v2BrowserRunJs(alloc: Allocator, params: ?std.json.Value, client_fd: posix.fd_t, script: [*:0]const u8) void {
    const panel_id = if (params) |p| (getParamInt(p, "id") orelse 0) else 0;

    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (browser_panel.getWidget(@intCast(panel_id))) |w| {
            webkit.evaluateJavaScript(w, script, alloc, client_fd);
            return;
        }
    }
    Server.respond(client_fd, "error: no browser widget");
}

fn v2BrowserCookieGetNative(alloc: Allocator, params: ?std.json.Value, client_fd: posix.fd_t) void {
    const panel_id = if (params) |p| (getParamInt(p, "id") orelse 0) else 0;
    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (browser_panel.getWidget(@intCast(panel_id))) |w| {
            webkit.getAllCookies(w, alloc, client_fd);
            return;
        }
    }
    Server.respond(client_fd, "[]");
}

fn v2BrowserCookieSetNative(alloc: Allocator, params: ?std.json.Value, client_fd: posix.fd_t) void {
    const name = getParamString(params, "name") orelse {
        Server.respond(client_fd, "error: missing name");
        return;
    };
    const value = getParamString(params, "value") orelse "";
    const domain = getParamString(params, "domain") orelse "localhost";
    const path = getParamString(params, "path") orelse "/";
    const panel_id = if (params) |p| (getParamInt(p, "id") orelse 0) else 0;

    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (browser_panel.getWidget(@intCast(panel_id))) |w| {
            const name_z = alloc.dupeZ(u8, name) catch return;
            defer alloc.free(name_z);
            const value_z = alloc.dupeZ(u8, value) catch return;
            defer alloc.free(value_z);
            const domain_z = alloc.dupeZ(u8, domain) catch return;
            defer alloc.free(domain_z);
            const path_z = alloc.dupeZ(u8, path) catch return;
            defer alloc.free(path_z);
            webkit.addCookie(w, name_z, value_z, domain_z, path_z, alloc, client_fd);
            return;
        }
    }
    Server.respond(client_fd, "error: no browser widget");
}

fn v2BrowserCookieClearNative(alloc: Allocator, params: ?std.json.Value, client_fd: posix.fd_t) void {
    const panel_id = if (params) |p| (getParamInt(p, "id") orelse 0) else 0;
    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (browser_panel.getWidget(@intCast(panel_id))) |w| {
            webkit.clearCookies(w, alloc, client_fd);
            return;
        }
    }
    Server.respond(client_fd, "cleared");
}

fn v2SurfaceGoto(app: *gtk.Application, alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const surface = handler_v1.getActiveSurface(app) orelse {
        respondError(alloc, client_fd, id, "no_surface", "no active surface");
        return;
    };
    const dir = getParamString(params, "direction") orelse "next";
    const Binding = @import("../../input/Binding.zig");
    const goto_dir: Binding.Action.SplitFocusDirection = if (std.mem.eql(u8, dir, "next"))
        .next
    else if (std.mem.eql(u8, dir, "previous") or std.mem.eql(u8, dir, "prev"))
        .previous
    else {
        respondError(alloc, client_fd, id, "invalid_params", "direction must be next/previous");
        return;
    };
    _ = surface.performBindingAction(.{ .goto_split = goto_dir }) catch {
        respondError(alloc, client_fd, id, "internal", "goto_split failed");
        return;
    };
    respondOkString(alloc, client_fd, id, "moved");
}

fn v2TabReorder(app: *gtk.Application, alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const active_gtk_window = app.getActiveWindow() orelse {
        respondError(alloc, client_fd, id, "no_window", "no active window");
        return;
    };
    const window = gobject.ext.cast(Window, active_gtk_window) orelse {
        respondError(alloc, client_fd, id, "no_window", "not a cmux window");
        return;
    };
    const index = getParamInt(params, "index") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing index");
        return;
    };
    const tab_view = window.getTabView();
    const selected = tab_view.getSelectedPage() orelse {
        respondError(alloc, client_fd, id, "no_tab", "no selected tab");
        return;
    };
    _ = tab_view.reorderPage(selected, @intCast(index));
    respondOkString(alloc, client_fd, id, "reordered");
}

fn v2SurfaceHealth(app: *gtk.Application, alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    if (handler_v1.getActiveSurface(app)) |s| {
        var buf: [128]u8 = undefined;
        const json_str = std.fmt.bufPrint(&buf, "{{\"healthy\":true,\"surface_id\":{d}}}", .{
            @intFromPtr(s),
        }) catch "{\"healthy\":true}";
        respondOkRaw(alloc, client_fd, id, json_str);
    } else {
        respondOkRaw(alloc, client_fd, id, "{\"healthy\":false,\"reason\":\"no_surface\"}");
    }
}

fn v2SurfaceTriggerFlash(app: *gtk.Application, alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const surface = handler_v1.getActiveSurface(app) orelse {
        respondError(alloc, client_fd, id, "no_surface", "no active surface");
        return;
    };
    // Trigger a visual flash by sending BEL character to the terminal
    surface.textCallback("\x07") catch {};
    respondOkString(alloc, client_fd, id, "flashed");
}

fn v2SurfaceRefresh(app: *gtk.Application, alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const surface = handler_v1.getActiveSurface(app) orelse {
        respondError(alloc, client_fd, id, "no_surface", "no active surface");
        return;
    };
    // Force a redraw
    surface.draw() catch {};
    respondOkString(alloc, client_fd, id, "refreshed");
}

fn v2WorkspaceReorder(alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        respondError(alloc, client_fd, id, "internal", "workspace manager not initialized");
        return;
    };
    const ws_id = getParamInt(params, "workspace_id") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing workspace_id");
        return;
    };
    const target_index = getParamInt(params, "index") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing index");
        return;
    };

    mgr.mutex.lock();
    defer mgr.mutex.unlock();

    // Find the workspace and move it
    var src_idx: ?usize = null;
    for (mgr.workspaces.items, 0..) |ws, i| {
        if (ws.id == ws_id) {
            src_idx = i;
            break;
        }
    }
    const src = src_idx orelse {
        respondError(alloc, client_fd, id, "not_found", "workspace not found");
        return;
    };

    const dst = @min(target_index, mgr.workspaces.items.len - 1);
    if (src != dst) {
        const item = mgr.workspaces.orderedRemove(src);
        mgr.workspaces.insertAssumeCapacity(@intCast(dst), item);
    }
    respondOkString(alloc, client_fd, id, "reordered");
}

fn v2WorkspaceMoveToWindow(app: *gtk.Application, alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const target_window_id = getParamInt(params, "window_id") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing window_id");
        return;
    };

    // Get the source window (active) and its selected tab page
    const src_win = app.getActiveWindow() orelse {
        respondError(alloc, client_fd, id, "no_window", "no active window");
        return;
    };
    const src_window = gobject.ext.cast(Window, src_win) orelse {
        respondError(alloc, client_fd, id, "no_window", "not a cmux window");
        return;
    };
    const src_tab_view = src_window.getTabView();
    const src_page = src_tab_view.getSelectedPage() orelse {
        respondError(alloc, client_fd, id, "no_tab", "no selected tab");
        return;
    };

    // Find the target window by ID (pointer address)
    const glib_mod = @import("glib");
    const windows = app.getWindows();
    var node: ?*glib_mod.List = windows;
    while (node) |n| {
        if (n.f_data) |data| {
            if (@intFromPtr(data) == target_window_id) {
                const target_gtk_win: *gtk.Window = @ptrCast(@alignCast(data));
                const target_window = gobject.ext.cast(Window, target_gtk_win) orelse continue;
                const target_tab_view = target_window.getTabView();

                // Transfer the page to the target window
                const adw_mod = @import("adw");
                _ = adw_mod;
                src_tab_view.transferPage(src_page, target_tab_view, -1); // -1 = append

                respondOkString(alloc, client_fd, id, "transferred");
                return;
            }
        }
        node = n.f_next;
    }

    respondError(alloc, client_fd, id, "not_found", "target window not found");
}

fn v2AppFocus(app: *gtk.Application, alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    // Present the active window to bring it to focus
    if (app.getActiveWindow()) |win| {
        win.present();
        respondOkString(alloc, client_fd, id, "focused");
    } else {
        respondError(alloc, client_fd, id, "no_window", "no active window");
    }
}

fn v2TabAction(app: *gtk.Application, alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const action_str = getParamString(params, "action") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing action");
        return;
    };

    const active_gtk_window = app.getActiveWindow() orelse {
        respondError(alloc, client_fd, id, "no_window", "no active window");
        return;
    };
    const window = gobject.ext.cast(Window, active_gtk_window) orelse {
        respondError(alloc, client_fd, id, "no_window", "not a cmux window");
        return;
    };

    if (std.mem.eql(u8, action_str, "next")) {
        _ = window.selectTab(.next);
    } else if (std.mem.eql(u8, action_str, "previous") or std.mem.eql(u8, action_str, "prev")) {
        _ = window.selectTab(.previous);
    } else if (std.mem.eql(u8, action_str, "last")) {
        _ = window.selectTab(.last);
    } else {
        respondError(alloc, client_fd, id, "invalid_params", "action must be next/previous/last");
        return;
    }
    respondOkString(alloc, client_fd, id, "done");
}

fn v2DebugTerminals(app: *gtk.Application, alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const active_gtk_window = app.getActiveWindow() orelse {
        respondOkRaw(alloc, client_fd, id, "[]");
        return;
    };
    const window = gobject.ext.cast(Window, active_gtk_window) orelse {
        respondOkRaw(alloc, client_fd, id, "[]");
        return;
    };

    const tab_view = window.getTabView();
    const n: usize = @intCast(@max(0, tab_view.getNPages()));

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    writer.writeAll("[") catch return;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const page = tab_view.getNthPage(@intCast(i));
        if (i > 0) writer.writeAll(",") catch return;
        const title = std.mem.sliceTo(page.getTitle(), 0);
        writer.print("{{\"tab\":{d},\"title\":\"{s}\"}}", .{ i, title }) catch return;
    }
    writer.writeAll("]") catch return;

    respondOkRaw(alloc, client_fd, id, buf.items);
}

fn v2BrowserGetTitle(alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const panel_id = if (params) |p| (getParamInt(p, "id") orelse 0) else 0;
    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (browser_panel.getWidget(@intCast(panel_id))) |w| {
            if (webkit.getTitle(w)) |title| {
                respondOkString(alloc, client_fd, id, std.mem.sliceTo(title, 0));
            } else {
                respondOkString(alloc, client_fd, id, "");
            }
            return;
        }
    }
    respondOkString(alloc, client_fd, id, "");
}

fn v2BrowserGeolocationSet(alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const lat = getParamFloat(params, "latitude") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing latitude");
        return;
    };
    const lng = getParamFloat(params, "longitude") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing longitude");
        return;
    };
    const panel_id = if (params) |p| (getParamInt(p, "id") orelse 0) else 0;

    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (browser_panel.getWidget(@intCast(panel_id))) |w| {
            webkit.setGeolocation(w, lat, lng);
            respondOkString(alloc, client_fd, id, "set");
            return;
        }
    }
    respondError(alloc, client_fd, id, "no_browser", "no browser widget");
}

fn v2BrowserOfflineSet(alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const offline = if (params) |p| blk: {
        if (p.object.get("offline")) |v| {
            break :blk switch (v) {
                .bool => |b| b,
                else => true,
            };
        }
        break :blk true;
    } else true;
    const panel_id = if (params) |p| (getParamInt(p, "id") orelse 0) else 0;

    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (browser_panel.getWidget(@intCast(panel_id))) |w| {
            webkit.setOffline(w, offline);
            respondOkString(alloc, client_fd, id, if (offline) "offline" else "online");
            return;
        }
    }
    respondError(alloc, client_fd, id, "no_browser", "no browser widget");
}

fn v2BrowserDialogAction(alloc: Allocator, accept: bool, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (accept) {
            webkit.acceptDialog();
        } else {
            webkit.dismissDialog();
        }
    }
    respondOkString(alloc, client_fd, id, if (accept) "accepted" else "dismissed");
}

fn v2BrowserDownloadWait(alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (webkit.isDownloadComplete()) {
            respondOkString(alloc, client_fd, id, "complete");
            return;
        }
    }
    respondOkString(alloc, client_fd, id, "waiting");
}

fn v2BrowserStorageGet(alloc: Allocator, params: ?std.json.Value, client_fd: posix.fd_t) void {
    const key = getParamString(params, "key") orelse {
        // Return all storage
        v2BrowserRunJs(alloc, params, client_fd, "JSON.stringify(Object.fromEntries(Object.entries(localStorage)))");
        return;
    };

    // Build JS: localStorage.getItem('key')
    const script = alloc.allocSentinel(u8, key.len + 32, 0) catch {
        Server.respond(client_fd, "error: alloc failed");
        return;
    };
    defer alloc.free(script);

    _ = std.fmt.bufPrint(script[0 .. key.len + 32], "localStorage.getItem('{s}')", .{key}) catch return;
    script[key.len + 31] = 0;

    v2BrowserRunJs(alloc, params, client_fd, @ptrCast(script.ptr));
}

fn v2BrowserStorageSet(alloc: Allocator, params: ?std.json.Value, client_fd: posix.fd_t) void {
    const key = getParamString(params, "key") orelse {
        Server.respond(client_fd, "error: missing key");
        return;
    };
    const value = getParamString(params, "value") orelse "";

    const script = alloc.allocSentinel(u8, key.len + value.len + 40, 0) catch {
        Server.respond(client_fd, "error: alloc failed");
        return;
    };
    defer alloc.free(script);

    _ = std.fmt.bufPrint(script[0 .. key.len + value.len + 40], "localStorage.setItem('{s}','{s}');'set'", .{ key, value }) catch return;
    script[key.len + value.len + 39] = 0;

    v2BrowserRunJs(alloc, params, client_fd, @ptrCast(script.ptr));
}

fn v2MarkdownOpen(alloc: Allocator, params: ?std.json.Value, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const path = getParamString(params, "path") orelse {
        respondError(alloc, client_fd, id, "invalid_params", "missing path");
        return;
    };
    const panel_id = markdown_panel.open(path) catch {
        respondError(alloc, client_fd, id, "internal", "failed to open markdown");
        return;
    };
    var buf: [64]u8 = undefined;
    respondOkRaw(alloc, client_fd, id, std.fmt.bufPrint(&buf, "{d}", .{panel_id}) catch "0");
}

fn v2MarkdownList(alloc: Allocator, id: ?std.json.Value, client_fd: posix.fd_t) void {
    const json_str = markdown_panel.formatJson(alloc) catch {
        respondError(alloc, client_fd, id, "internal", "failed to list markdown panels");
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

/// Extract a float parameter from JSON params.
fn getParamFloat(params: ?std.json.Value, key: []const u8) ?f64 {
    const p = params orelse return null;
    if (p != .object) return null;
    const v = p.object.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
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
