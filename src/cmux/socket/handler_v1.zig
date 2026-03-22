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
const termio = @import("../../termio.zig");

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

fn cmdQuit(app: *gtk.Application) void {
    const action_group = app.as(gio.ActionGroup);
    action_group.activateAction("quit", null);
}

/// Get the active core Surface from the GTK Application.
/// Walks: Application → active Window → active Tab → active Surface → core Surface
fn getActiveSurface(app: *gtk.Application) ?*CoreSurface {
    // Get the active window from the app
    const active_gtk_window = app.getActiveWindow() orelse return null;

    // Cast to our Window type
    const window = gobject.ext.cast(Window, active_gtk_window) orelse return null;

    // Get the active GTK surface from the window
    const gtk_surface = window.getActiveSurface() orelse return null;

    // Get the core surface
    return gtk_surface.core();
}
