// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
//
// tmux compatibility layer for cmux.
// Translates common tmux commands to cmux socket API calls.
// Accessed via: cmux +ctl __tmux-compat <tmux-command> [args...]

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const Server = @import("server.zig").Server;
const handler_v1 = @import("handler_v1.zig");

const log = std.log.scoped(.cmux_tmux);

/// Handle a tmux-compat command by translating to cmux equivalents.
pub fn handleTmuxCommand(
    ctx: *anyopaque,
    alloc: Allocator,
    tmux_cmd: []const u8,
    args: []const u8,
    client_fd: posix.fd_t,
) void {
    if (std.mem.eql(u8, tmux_cmd, "capture-pane")) {
        // Translate to read-screen
        handler_v1.handleCommand(ctx, alloc, "read-screen", args, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "send-keys")) {
        // Translate to send
        handler_v1.handleCommand(ctx, alloc, "send", args, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "split-window")) {
        // Parse -h (horizontal) or -v (vertical)
        const dir = if (std.mem.indexOf(u8, args, "-h") != null) "right" else "down";
        handler_v1.handleCommand(ctx, alloc, "new-split", dir, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "new-window")) {
        handler_v1.handleCommand(ctx, alloc, "new-tab", args, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "kill-pane")) {
        handler_v1.handleCommand(ctx, alloc, "close-surface", args, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "kill-window")) {
        handler_v1.handleCommand(ctx, alloc, "close-window", args, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "select-pane")) {
        // Parse -t direction
        const dir = if (std.mem.indexOf(u8, args, "-U") != null)
            "previous"
        else if (std.mem.indexOf(u8, args, "-D") != null)
            "next"
        else
            "next";
        handler_v1.handleCommand(ctx, alloc, "focus-pane", dir, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "select-window")) {
        handler_v1.handleCommand(ctx, alloc, "select-workspace", args, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "next-window")) {
        handler_v1.handleCommand(ctx, alloc, "select-workspace", "next", client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "previous-window")) {
        handler_v1.handleCommand(ctx, alloc, "select-workspace", "prev", client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "last-window") or std.mem.eql(u8, tmux_cmd, "last-pane")) {
        handler_v1.handleCommand(ctx, alloc, "focus-pane", "previous", client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "list-windows")) {
        handler_v1.handleCommand(ctx, alloc, "list-workspaces", args, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "list-panes")) {
        handler_v1.handleCommand(ctx, alloc, "list-panes", args, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "resize-pane")) {
        // Resize not directly supported — acknowledge
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, tmux_cmd, "display-message")) {
        // Display as notification
        handler_v1.handleCommand(ctx, alloc, "notify", args, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "clear-history")) {
        handler_v1.handleCommand(ctx, alloc, "clear-log", args, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "rename-window")) {
        handler_v1.handleCommand(ctx, alloc, "rename-tab", args, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "swap-pane")) {
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, tmux_cmd, "break-pane")) {
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, tmux_cmd, "join-pane")) {
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, tmux_cmd, "pipe-pane")) {
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, tmux_cmd, "wait-for")) {
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, tmux_cmd, "find-window")) {
        handler_v1.handleCommand(ctx, alloc, "list-windows", args, client_fd);
    } else if (std.mem.eql(u8, tmux_cmd, "respawn-pane")) {
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, tmux_cmd, "set-hook") or
        std.mem.eql(u8, tmux_cmd, "bind-key") or
        std.mem.eql(u8, tmux_cmd, "unbind-key") or
        std.mem.eql(u8, tmux_cmd, "copy-mode") or
        std.mem.eql(u8, tmux_cmd, "set-buffer") or
        std.mem.eql(u8, tmux_cmd, "paste-buffer") or
        std.mem.eql(u8, tmux_cmd, "list-buffers") or
        std.mem.eql(u8, tmux_cmd, "popup"))
    {
        Server.respond(client_fd, "ok");
    } else {
        Server.respond(client_fd, "error: unknown tmux command");
    }
}
