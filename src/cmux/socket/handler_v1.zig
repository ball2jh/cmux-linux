// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2025 cmux-linux contributors
//
// V1 text protocol handler for the cmux socket API.
// Commands are newline-delimited text. Compatible with the macOS cmux
// socket protocol for agent interoperability.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Server = @import("server.zig").Server;
const Window = @import("../../apprt/gtk/class/window.zig").Window;
const GtkSurface = @import("../../apprt/gtk/class/surface.zig").Surface;
const CoreSurface = @import("../../Surface.zig");
const notification_store = @import("../notification/store.zig");
const workspace_mgr = @import("../workspace/manager.zig");
const browser = @import("../browser/panel.zig");
const WorkspaceStatus = @import("../workspace/status.zig").WorkspaceStatus;

const log = std.log.scoped(.cmux_v1);

/// V1 command handler. ctx must be a *gtk.Application.
pub fn handleCommand(
    ctx: *anyopaque,
    alloc: Allocator,
    command: []const u8,
    args: []const u8,
    client_fd: posix.fd_t,
) void {
    const app: *gtk.Application = @ptrCast(@alignCast(ctx));

    if (std.mem.eql(u8, command, "ping")) {
        Server.respond(client_fd, "pong");
    } else if (std.mem.eql(u8, command, "new-window")) {
        cmdNewWindow(app);
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, command, "list-windows")) {
        cmdListWindows(app, alloc, client_fd);
    } else if (std.mem.eql(u8, command, "close-window")) {
        cmdCloseWindow(app, args);
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, command, "send")) {
        cmdSend(app, alloc, args, client_fd);
    } else if (std.mem.eql(u8, command, "list-notifications")) {
        cmdListNotifications(alloc, client_fd);
    } else if (std.mem.eql(u8, command, "clear-notifications")) {
        cmdClearNotifications();
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, command, "notify")) {
        cmdNotify(args, client_fd);
    } else if (std.mem.eql(u8, command, "read-screen")) {
        cmdReadScreen(app, alloc, client_fd);
    } else if (std.mem.eql(u8, command, "list-workspaces")) {
        cmdListWorkspaces(alloc, client_fd);
    } else if (std.mem.eql(u8, command, "new-workspace")) {
        cmdNewWorkspace(alloc, args, client_fd);
    } else if (std.mem.eql(u8, command, "select-workspace")) {
        cmdSelectWorkspace(args, client_fd);
    } else if (std.mem.eql(u8, command, "close-workspace")) {
        cmdCloseWorkspace(args, client_fd);
    } else if (std.mem.eql(u8, command, "rename-workspace")) {
        cmdRenameWorkspace(alloc, args, client_fd);
    } else if (std.mem.eql(u8, command, "current-workspace")) {
        cmdCurrentWorkspace(client_fd);
    } else if (std.mem.eql(u8, command, "set-status")) {
        cmdSetStatus(alloc, args, client_fd);
    } else if (std.mem.eql(u8, command, "list-status")) {
        cmdListStatus(alloc, client_fd);
    } else if (std.mem.eql(u8, command, "clear-status")) {
        cmdClearStatus(args, client_fd);
    } else if (std.mem.eql(u8, command, "set-progress")) {
        cmdSetProgress(args, client_fd);
    } else if (std.mem.eql(u8, command, "clear-progress")) {
        cmdClearProgress(args, client_fd);
    } else if (std.mem.eql(u8, command, "log")) {
        cmdLog(alloc, args, client_fd);
    } else if (std.mem.eql(u8, command, "clear-log")) {
        cmdClearLog(client_fd);
    } else if (std.mem.eql(u8, command, "list-log")) {
        cmdListLog(alloc, client_fd);
    } else if (std.mem.eql(u8, command, "open-browser")) {
        cmdOpenBrowser(args, client_fd);
    } else if (std.mem.eql(u8, command, "navigate")) {
        cmdNavigate(args, client_fd);
    } else if (std.mem.eql(u8, command, "get-url")) {
        cmdGetUrl(args, client_fd);
    } else if (std.mem.eql(u8, command, "quit")) {
        cmdQuit(app);
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, command, "version")) {
        const build_config = @import("../../build_config.zig");
        Server.respond(client_fd, build_config.version_string);
    } else {
        Server.respond(client_fd, "error: unknown command");
    }
}

fn cmdNewWindow(app: *gtk.Application) void {
    const action_group = app.as(gio.ActionGroup);
    action_group.activateAction("new-window", null);
}

fn cmdListWindows(app: *gtk.Application, alloc: Allocator, client_fd: posix.fd_t) void {
    const windows = app.getWindows();
    if (windows.f_data == null) {
        Server.respond(client_fd, "");
        return;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    var writer = buf.writer(alloc);
    var count: usize = 0;
    var node: ?*glib.List = windows;
    while (node) |n| {
        if (n.f_data) |data| {
            if (count > 0) writer.writeAll(", ") catch return;
            writer.print("{d}", .{@intFromPtr(data)}) catch return;
            count += 1;
        }
        node = n.f_next;
    }

    Server.respond(client_fd, buf.items);
}

fn cmdCloseWindow(app: *gtk.Application, args: []const u8) void {
    _ = args;
    const windows = app.getWindows();
    if (windows.f_data) |data| {
        const window: *gtk.Window = @ptrCast(@alignCast(data));
        window.close();
    }
}

fn cmdSend(app: *gtk.Application, alloc: Allocator, text: []const u8, client_fd: posix.fd_t) void {
    if (text.len == 0) {
        Server.respond(client_fd, "error: no text to send");
        return;
    }

    // Get the active surface from the active window
    const surface = getActiveSurface(app) orelse {
        Server.respond(client_fd, "error: no active surface");
        return;
    };

    // Write the text to the terminal's PTY via textCallback.
    _ = alloc;
    surface.textCallback(text) catch {
        Server.respond(client_fd, "error: send failed");
        return;
    };

    Server.respond(client_fd, "ok");
}

fn cmdListNotifications(alloc: Allocator, client_fd: posix.fd_t) void {
    const store = notification_store.getGlobal() orelse {
        Server.respond(client_fd, "");
        return;
    };
    const list = store.formatList(alloc) catch {
        Server.respond(client_fd, "error: failed to format notifications");
        return;
    };
    defer alloc.free(list);
    if (list.len == 0) {
        Server.respond(client_fd, "");
    } else {
        // formatList already has newlines, send without extra newline
        _ = posix.write(client_fd, list) catch {};
    }
}

fn cmdClearNotifications() void {
    const store = notification_store.getGlobal() orelse return;
    store.clear(null);
}

fn cmdReadScreen(app: *gtk.Application, alloc: Allocator, client_fd: posix.fd_t) void {
    const surface = getActiveSurface(app) orelse {
        Server.respond(client_fd, "error: no active surface");
        return;
    };

    // Lock the renderer state and read the viewport text
    surface.renderer_state.mutex.lock();
    defer surface.renderer_state.mutex.unlock();

    const text = surface.io.terminal.plainString(alloc) catch {
        Server.respond(client_fd, "error: failed to read screen");
        return;
    };
    defer alloc.free(text);

    if (text.len == 0) {
        Server.respond(client_fd, "");
    } else {
        _ = posix.write(client_fd, text) catch {};
        _ = posix.write(client_fd, "\n") catch {};
    }
}

fn cmdNotify(args: []const u8, client_fd: posix.fd_t) void {
    // Format: notify <title> [body]
    // Title and body are separated by first space
    if (args.len == 0) {
        Server.respond(client_fd, "error: notify requires a title");
        return;
    }

    var title: []const u8 = args;
    var body: []const u8 = "";
    if (std.mem.indexOf(u8, args, " ")) |space_pos| {
        title = args[0..space_pos];
        body = std.mem.trim(u8, args[space_pos + 1 ..], &[_]u8{ ' ', '\t' });
    }

    const store = notification_store.getGlobal() orelse {
        Server.respond(client_fd, "error: notification store not initialized");
        return;
    };
    store.add(title, body, 0); // surface_id 0 = manual notification
    Server.respond(client_fd, "ok");
}

fn cmdQuit(app: *gtk.Application) void {
    const action_group = app.as(gio.ActionGroup);
    action_group.activateAction("quit", null);
}

fn cmdListWorkspaces(alloc: Allocator, client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        Server.respond(client_fd, "");
        return;
    };
    const text = mgr.formatText(alloc) catch {
        Server.respond(client_fd, "error: failed to format workspaces");
        return;
    };
    defer alloc.free(text);
    if (text.len == 0) {
        Server.respond(client_fd, "");
    } else {
        _ = posix.write(client_fd, text) catch {};
    }
}

fn cmdNewWorkspace(_: Allocator, args: []const u8, client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        Server.respond(client_fd, "error: workspace manager not initialized");
        return;
    };
    const name = if (args.len > 0) args else "workspace";
    const id = mgr.create(name, null) catch {
        Server.respond(client_fd, "error: failed to create workspace");
        return;
    };

    var buf: [64]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "{d}", .{id}) catch "error";
    Server.respond(client_fd, resp);
}

fn cmdSelectWorkspace(args: []const u8, client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        Server.respond(client_fd, "error: workspace manager not initialized");
        return;
    };
    const id = std.fmt.parseInt(u64, args, 10) catch {
        Server.respond(client_fd, "error: invalid workspace id");
        return;
    };
    if (mgr.select(id)) {
        Server.respond(client_fd, "ok");
    } else {
        Server.respond(client_fd, "error: workspace not found");
    }
}

fn cmdCloseWorkspace(args: []const u8, client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        Server.respond(client_fd, "error: workspace manager not initialized");
        return;
    };
    const id = std.fmt.parseInt(u64, args, 10) catch {
        Server.respond(client_fd, "error: invalid workspace id");
        return;
    };
    if (mgr.close(id)) {
        Server.respond(client_fd, "ok");
    } else {
        Server.respond(client_fd, "error: workspace not found");
    }
}

fn cmdRenameWorkspace(alloc: Allocator, args: []const u8, client_fd: posix.fd_t) void {
    _ = alloc;
    const mgr = workspace_mgr.getGlobal() orelse {
        Server.respond(client_fd, "error: workspace manager not initialized");
        return;
    };
    // Format: rename-workspace <id> <new-name>
    const space_pos = std.mem.indexOf(u8, args, " ") orelse {
        Server.respond(client_fd, "error: usage: rename-workspace <id> <name>");
        return;
    };
    const id = std.fmt.parseInt(u64, args[0..space_pos], 10) catch {
        Server.respond(client_fd, "error: invalid workspace id");
        return;
    };
    const new_name = std.mem.trim(u8, args[space_pos + 1 ..], &[_]u8{ ' ', '\t' });
    if (mgr.rename(id, new_name) catch false) {
        Server.respond(client_fd, "ok");
    } else {
        Server.respond(client_fd, "error: workspace not found");
    }
}

fn cmdCurrentWorkspace(client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        Server.respond(client_fd, "0");
        return;
    };
    var buf: [64]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "{d}", .{mgr.activeId()}) catch "0";
    Server.respond(client_fd, resp);
}

// --- Status/Progress/Log commands ---

fn getActiveWsStatus() ?*WorkspaceStatus {
    const mgr = workspace_mgr.getGlobal() orelse return null;
    mgr.mutex.lock();
    defer mgr.mutex.unlock();
    return mgr.getActiveStatus();
}

fn cmdSetStatus(_: Allocator, args: []const u8, client_fd: posix.fd_t) void {
    // Format: set-status <key> <value>
    const space = std.mem.indexOf(u8, args, " ") orelse {
        Server.respond(client_fd, "error: usage: set-status <key> <value>");
        return;
    };
    const key = args[0..space];
    const value = std.mem.trim(u8, args[space + 1 ..], &[_]u8{ ' ', '\t' });
    const status = getActiveWsStatus() orelse {
        Server.respond(client_fd, "error: no active workspace");
        return;
    };
    status.setStatus(key, value) catch {
        Server.respond(client_fd, "error: failed to set status");
        return;
    };
    Server.respond(client_fd, "ok");
}

fn cmdListStatus(alloc: Allocator, client_fd: posix.fd_t) void {
    const status = getActiveWsStatus() orelse {
        Server.respond(client_fd, "");
        return;
    };
    const text = status.formatStatusText(alloc) catch {
        Server.respond(client_fd, "error: failed to format status");
        return;
    };
    defer alloc.free(text);
    if (text.len == 0) {
        Server.respond(client_fd, "");
    } else {
        _ = posix.write(client_fd, text) catch {};
    }
}

fn cmdClearStatus(args: []const u8, client_fd: posix.fd_t) void {
    const status = getActiveWsStatus() orelse {
        Server.respond(client_fd, "ok");
        return;
    };
    if (args.len > 0) {
        status.clearStatus(args);
    } else {
        status.clearAllStatuses();
    }
    Server.respond(client_fd, "ok");
}

fn cmdSetProgress(args: []const u8, client_fd: posix.fd_t) void {
    // Format: set-progress <key> <value 0-100>
    const space = std.mem.indexOf(u8, args, " ") orelse {
        Server.respond(client_fd, "error: usage: set-progress <key> <percent>");
        return;
    };
    const key = args[0..space];
    const pct_str = std.mem.trim(u8, args[space + 1 ..], &[_]u8{ ' ', '\t' });
    const pct = std.fmt.parseFloat(f64, pct_str) catch {
        Server.respond(client_fd, "error: invalid percentage");
        return;
    };
    const status = getActiveWsStatus() orelse {
        Server.respond(client_fd, "error: no active workspace");
        return;
    };
    status.setProgress(key, pct / 100.0) catch {
        Server.respond(client_fd, "error: failed to set progress");
        return;
    };
    Server.respond(client_fd, "ok");
}

fn cmdClearProgress(args: []const u8, client_fd: posix.fd_t) void {
    const status = getActiveWsStatus() orelse {
        Server.respond(client_fd, "ok");
        return;
    };
    if (args.len > 0) {
        status.clearProgress(args);
    }
    Server.respond(client_fd, "ok");
}

fn cmdLog(_: Allocator, args: []const u8, client_fd: posix.fd_t) void {
    if (args.len == 0) {
        Server.respond(client_fd, "error: usage: log <message>");
        return;
    }
    const status = getActiveWsStatus() orelse {
        Server.respond(client_fd, "error: no active workspace");
        return;
    };
    status.addLog(args) catch {
        Server.respond(client_fd, "error: failed to add log");
        return;
    };
    Server.respond(client_fd, "ok");
}

fn cmdClearLog(client_fd: posix.fd_t) void {
    const status = getActiveWsStatus() orelse {
        Server.respond(client_fd, "ok");
        return;
    };
    status.clearLogs();
    Server.respond(client_fd, "ok");
}

fn cmdListLog(alloc: Allocator, client_fd: posix.fd_t) void {
    const status = getActiveWsStatus() orelse {
        Server.respond(client_fd, "");
        return;
    };
    const text = status.formatLogText(alloc) catch {
        Server.respond(client_fd, "error: failed to format log");
        return;
    };
    defer alloc.free(text);
    if (text.len == 0) {
        Server.respond(client_fd, "");
    } else {
        _ = posix.write(client_fd, text) catch {};
    }
}

fn cmdOpenBrowser(args: []const u8, client_fd: posix.fd_t) void {
    const url = if (args.len > 0) args else "about:blank";
    const id = browser.open(url) catch {
        Server.respond(client_fd, "error: failed to open browser");
        return;
    };
    var buf: [64]u8 = undefined;
    Server.respond(client_fd, std.fmt.bufPrint(&buf, "{d}", .{id}) catch "0");
}

fn cmdNavigate(args: []const u8, client_fd: posix.fd_t) void {
    // Format: navigate <id> <url>
    const space = std.mem.indexOf(u8, args, " ") orelse {
        Server.respond(client_fd, "error: usage: navigate <id> <url>");
        return;
    };
    const id = std.fmt.parseInt(usize, args[0..space], 10) catch {
        Server.respond(client_fd, "error: invalid browser id");
        return;
    };
    const url = std.mem.trim(u8, args[space + 1 ..], &[_]u8{ ' ', '\t' });
    browser.navigateTo(id, url) catch {
        Server.respond(client_fd, "error: browser not found");
        return;
    };
    Server.respond(client_fd, "ok");
}

fn cmdGetUrl(args: []const u8, client_fd: posix.fd_t) void {
    const id = std.fmt.parseInt(usize, args, 10) catch {
        Server.respond(client_fd, "error: invalid browser id");
        return;
    };
    Server.respond(client_fd, browser.getUrl(id) orelse "error: browser not found");
}

/// Get the active core Surface from the GTK Application.
/// Walks: Application → active Window → active Tab → active Surface → core Surface
pub fn getActiveSurface(app: *gtk.Application) ?*CoreSurface {
    // Get the active window from the app
    const active_gtk_window = app.getActiveWindow() orelse return null;

    // Cast to our Window type
    const window = gobject.ext.cast(Window, active_gtk_window) orelse return null;

    // Get the active GTK surface from the window
    const gtk_surface = window.getActiveSurface() orelse return null;

    // Get the core surface
    return gtk_surface.core();
}
