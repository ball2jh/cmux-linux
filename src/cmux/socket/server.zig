// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2025 cmux-linux contributors
//
// Unix domain socket server for the cmux control API.
// AI coding agents connect to this socket to control the terminal:
// create workspaces, send keystrokes, trigger notifications, etc.
//
// The server integrates with the GLib main loop so all commands
// execute on the GTK main thread where widget manipulation is safe.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gio = @import("gio");
const gtk = @import("gtk");

const handler_v2 = @import("handler_v2.zig");
const auth = @import("auth.zig");

const log = std.log.scoped(.cmux_socket);

/// Maximum number of concurrent client connections.
const max_clients = 32;

/// Maximum line length for a single command (16 KiB).
const max_line_len = 16 * 1024;

/// A connected client with its read buffer.
const Client = struct {
    fd: posix.fd_t,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    watch_id: c_uint = 0,

    fn deinit(self: *Client, alloc: Allocator) void {
        self.buf.deinit(alloc);
        posix.close(self.fd);
    }
};

/// The socket server state.
pub const Server = struct {
    /// Callback type for dispatching parsed commands.
    /// The handler writes the response directly to the client fd.
    pub const CommandHandler = *const fn (
        ctx: *anyopaque,
        alloc: Allocator,
        command: []const u8,
        args: []const u8,
        client_fd: posix.fd_t,
    ) void;

    alloc: Allocator,
    socket_path: []const u8,
    listen_fd: posix.fd_t = -1,
    listen_watch_id: c_uint = 0,
    clients: std.ArrayListUnmanaged(Client) = .empty,
    handler: CommandHandler,
    handler_ctx: *anyopaque,

    pub fn init(
        alloc: Allocator,
        handler: CommandHandler,
        handler_ctx: *anyopaque,
    ) !Server {
        const uid = std.os.linux.getuid();
        const path = try std.fmt.allocPrint(alloc, "/tmp/cmux-{d}.sock", .{uid});

        return .{
            .alloc = alloc,
            .socket_path = path,
            .handler = handler,
            .handler_ctx = handler_ctx,
        };
    }

    pub fn deinit(self: *Server) void {
        // Remove GLib watches
        if (self.listen_watch_id != 0) {
            _ = glib.Source.remove(self.listen_watch_id);
            self.listen_watch_id = 0;
        }

        // Close all client connections
        for (self.clients.items) |*client| {
            if (client.watch_id != 0) {
                _ = glib.Source.remove(client.watch_id);
            }
            client.deinit(self.alloc);
        }
        self.clients.deinit(self.alloc);

        // Close listen socket
        if (self.listen_fd != -1) {
            posix.close(self.listen_fd);
            self.listen_fd = -1;
        }

        // Remove socket file
        std.fs.deleteFileAbsolute(self.socket_path) catch {};

        self.alloc.free(self.socket_path);
    }

    /// Start listening on the Unix socket.
    pub fn start(self: *Server) !void {
        // Remove stale socket file if it exists
        std.fs.deleteFileAbsolute(self.socket_path) catch {};

        // Create Unix domain socket
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        // Bind to the path
        var addr: posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        const path_bytes = self.socket_path;
        if (path_bytes.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path_bytes.len], path_bytes);

        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        // Set permissions to owner-only (0600) via fchmod on the fd
        const rc = std.os.linux.fchmod(fd, 0o600);
        if (rc != 0) {
            log.warn("failed to fchmod socket", .{});
        }

        // Listen for connections
        try posix.listen(fd, 5);

        self.listen_fd = fd;

        // Register with GLib main loop for incoming connections
        const channel = glib.IOChannel.unixNew(fd);
        defer channel.unref();
        self.listen_watch_id = glib.ioAddWatch(
            channel,
            glib.IOCondition{ .in = true, .hup = true },
            &acceptCallback,
            @ptrCast(self),
        );

        log.info("cmux socket server listening on {s}", .{self.socket_path});
    }

    /// GLib callback for accepting new connections.
    fn acceptCallback(
        _: *glib.IOChannel,
        condition: glib.IOCondition,
        user_data: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Server = @ptrCast(@alignCast(user_data.?));

        if (condition.hup) {
            log.warn("listen socket hung up", .{});
            return 0;
        }

        const client_fd = posix.accept(self.listen_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch |err| {
            log.warn("accept failed: {}", .{err});
            return 1;
        };

        // Check authentication
        if (!auth.checkClient(client_fd)) {
            log.warn("auth rejected client connection", .{});
            _ = posix.write(client_fd, "error: unauthorized\n") catch {};
            posix.close(client_fd);
            return 1;
        }

        if (self.clients.items.len >= max_clients) {
            log.warn("max clients reached, rejecting connection", .{});
            posix.close(client_fd);
            return 1;
        }

        var client: Client = .{ .fd = client_fd };

        // Register client fd with GLib main loop
        const ch = glib.IOChannel.unixNew(client_fd);
        defer ch.unref();
        client.watch_id = glib.ioAddWatch(
            ch,
            glib.IOCondition{ .in = true, .hup = true },
            &clientCallback,
            @ptrCast(self),
        );

        self.clients.append(self.alloc, client) catch {
            log.warn("failed to track client", .{});
            posix.close(client_fd);
            return 1;
        };

        log.debug("accepted client connection (fd={})", .{client_fd});
        return 1;
    }

    /// GLib callback for data from a client.
    fn clientCallback(
        channel: *glib.IOChannel,
        condition: glib.IOCondition,
        user_data: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Server = @ptrCast(@alignCast(user_data.?));
        const client_fd = glib.IOChannel.unixGetFd(channel);

        if (condition.hup) {
            self.removeClient(client_fd);
            return 0;
        }

        const client = self.findClient(client_fd) orelse {
            return 0;
        };

        // Read available data
        var buf: [4096]u8 = undefined;
        const n = posix.read(client_fd, &buf) catch |err| {
            log.debug("read error on fd={}: {}", .{ client_fd, err });
            self.removeClient(client_fd);
            return 0;
        };

        if (n == 0) {
            self.removeClient(client_fd);
            return 0;
        }

        client.buf.appendSlice(self.alloc, buf[0..n]) catch {
            log.warn("client buffer overflow, dropping connection", .{});
            self.removeClient(client_fd);
            return 0;
        };

        self.processClientBuffer(client) catch {
            self.removeClient(client_fd);
            return 0;
        };

        return 1;
    }

    fn processClientBuffer(self: *Server, client: *Client) !void {
        while (true) {
            const newline_pos = std.mem.indexOf(u8, client.buf.items, "\n") orelse break;

            if (newline_pos > max_line_len) {
                return error.LineTooLong;
            }

            const line = client.buf.items[0..newline_pos];
            const trimmed = std.mem.trim(u8, line, &[_]u8{ '\r', ' ', '\t' });

            if (trimmed.len > 0) {
                // Auto-detect V1 (text) vs V2 (JSON) by first character
                if (trimmed[0] == '{') {
                    // V2 JSON-RPC
                    handler_v2.handleJsonRpc(self.handler_ctx, self.alloc, trimmed, client.fd);
                } else {
                    // V1 text protocol
                    var command: []const u8 = trimmed;
                    var args: []const u8 = "";
                    if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
                        command = trimmed[0..space_pos];
                        args = std.mem.trim(u8, trimmed[space_pos + 1 ..], &[_]u8{ ' ', '\t' });
                    }

                    self.handler(self.handler_ctx, self.alloc, command, args, client.fd);
                }
            }

            // Remove processed data from buffer
            const remaining = client.buf.items.len - newline_pos - 1;
            if (remaining > 0) {
                std.mem.copyForwards(u8, client.buf.items[0..remaining], client.buf.items[newline_pos + 1 ..]);
            }
            client.buf.shrinkRetainingCapacity(remaining);
        }
    }

    fn findClient(self: *Server, fd: posix.fd_t) ?*Client {
        for (self.clients.items) |*client| {
            if (client.fd == fd) return client;
        }
        return null;
    }

    fn removeClient(self: *Server, fd: posix.fd_t) void {
        for (self.clients.items, 0..) |*client, i| {
            if (client.fd == fd) {
                log.debug("removing client (fd={})", .{fd});
                client.deinit(self.alloc);
                _ = self.clients.swapRemove(i);
                return;
            }
        }
    }

    /// Write a response line to a client fd.
    pub fn respond(fd: posix.fd_t, msg: []const u8) void {
        _ = posix.write(fd, msg) catch {};
        _ = posix.write(fd, "\n") catch {};
    }
};
