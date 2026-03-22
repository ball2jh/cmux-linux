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
