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
const gtk = @import("gtk");

const Server = @import("server.zig").Server;

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
    // Activate the "new-window" action on the GTK application
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
    _ = args; // TODO: parse window ID from args
    // Close the most recent active window
    const windows = app.getWindows();
    if (windows.f_data) |data| {
        const window: *gtk.Window = @ptrCast(@alignCast(data));
        window.close();
    }
}

fn cmdQuit(app: *gtk.Application) void {
    const action_group = app.as(gio.ActionGroup);
    action_group.activateAction("quit", null);
}
