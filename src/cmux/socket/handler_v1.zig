// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
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
const Binding = @import("../../input/Binding.zig");
const port_scanner = @import("../workspace/port_scanner.zig");
const markdown = @import("../markdown/panel.zig");
const ssh_detector = @import("../workspace/ssh_detector.zig");
const tmux_compat = @import("tmux_compat.zig");
const agent_session = @import("../agent/session.zig");

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
        cmdClearNotifications(args);
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
    } else if (std.mem.eql(u8, command, "new-tab")) {
        cmdNewTab(app);
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, command, "close-tab")) {
        cmdCloseTab(app);
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, command, "new-split")) {
        cmdNewSplit(app, args, client_fd);
    } else if (std.mem.eql(u8, command, "list-panes")) {
        cmdListPanes(app, alloc, client_fd);
    } else if (std.mem.eql(u8, command, "rename-tab")) {
        // Alias for rename-workspace (macOS cmux uses tab = workspace)
        cmdRenameWorkspace(alloc, args, client_fd);
    } else if (std.mem.eql(u8, command, "tree")) {
        cmdTree(app, alloc, client_fd);
    } else if (std.mem.eql(u8, command, "new-pane")) {
        // Alias for new-split (macOS: pane = split direction)
        cmdNewSplit(app, args, client_fd);
    } else if (std.mem.eql(u8, command, "focus-pane")) {
        // Navigate to next/previous pane
        cmdFocusPane(app, args, client_fd);
    } else if (std.mem.eql(u8, command, "close-surface")) {
        cmdCloseSurface(app, client_fd);
    } else if (std.mem.eql(u8, command, "send-key")) {
        cmdSendKey(app, args, client_fd);
    } else if (std.mem.eql(u8, command, "current-window")) {
        cmdCurrentWindow(app, client_fd);
    } else if (std.mem.eql(u8, command, "focus-window")) {
        cmdFocusWindow(app, args, client_fd);
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
    } else if (std.mem.eql(u8, command, "list-ports")) {
        cmdListPorts(alloc, client_fd);
    } else if (std.mem.eql(u8, command, "open-browser")) {
        cmdOpenBrowser(args, client_fd);
    } else if (std.mem.eql(u8, command, "navigate")) {
        cmdNavigate(args, client_fd);
    } else if (std.mem.eql(u8, command, "get-url")) {
        cmdGetUrl(args, client_fd);
    } else if (std.mem.eql(u8, command, "identify")) {
        cmdIdentify(client_fd);
    } else if (std.mem.eql(u8, command, "capabilities")) {
        Server.respond(client_fd, "v1 v2 send read-screen notifications workspaces browser status progress log ports splits agent");
    } else if (std.mem.eql(u8, command, "sidebar-state")) {
        cmdSidebarState(alloc, client_fd);
    } else if (std.mem.eql(u8, command, "browser-back")) {
        cmdBrowserBack(args, client_fd);
    } else if (std.mem.eql(u8, command, "browser-forward")) {
        cmdBrowserForward(args, client_fd);
    } else if (std.mem.eql(u8, command, "browser-reload")) {
        cmdBrowserReload(args, client_fd);
    } else if (std.mem.eql(u8, command, "markdown")) {
        cmdMarkdown(alloc, args, client_fd);
    } else if (std.mem.eql(u8, command, "reorder-workspace")) {
        cmdReorderWorkspace(args, client_fd);
    } else if (std.mem.eql(u8, command, "move-workspace-to-window")) {
        Server.respond(client_fd, "error: single window mode — multi-window not yet supported");
    } else if (std.mem.eql(u8, command, "move-surface")) {
        Server.respond(client_fd, "error: move-surface not yet supported on Linux");
    } else if (std.mem.eql(u8, command, "reorder-surface")) {
        Server.respond(client_fd, "error: reorder-surface not yet supported on Linux");
    } else if (std.mem.eql(u8, command, "drag-surface-to-split")) {
        // Treat as a new-split request
        cmdNewSplit(app, args, client_fd);
    } else if (std.mem.eql(u8, command, "set-app-focus")) {
        Server.respond(client_fd, "ok"); // no-op on Wayland — can't force focus
    } else if (std.mem.eql(u8, command, "simulate-app-active")) {
        Server.respond(client_fd, "ok"); // no-op on Wayland
    } else if (std.mem.eql(u8, command, "trigger-flash")) {
        Server.respond(client_fd, "ok"); // visual flash — minimal no-op for compatibility
    } else if (std.mem.eql(u8, command, "refresh-surfaces")) {
        cmdRefreshSurfaces(app);
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, command, "send-panel")) {
        cmdSendPanel(app, alloc, args, client_fd);
    } else if (std.mem.eql(u8, command, "send-key-panel")) {
        cmdSendKeyPanel(app, args, client_fd);
    } else if (std.mem.eql(u8, command, "focus-panel")) {
        cmdFocusPanel(app, args, client_fd);
    } else if (std.mem.eql(u8, command, "new-surface")) {
        cmdNewTab(app);
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, command, "surface-health")) {
        cmdSurfaceHealth(app, client_fd);
    } else if (std.mem.eql(u8, command, "list-pane-surfaces")) {
        cmdListPaneSurfaces(app, alloc, client_fd);
    } else if (std.mem.eql(u8, command, "workspace-action")) {
        cmdWorkspaceAction(args, client_fd);
    } else if (std.mem.eql(u8, command, "tab-action")) {
        cmdTabAction(app, args, client_fd);
    } else if (std.mem.eql(u8, command, "rename-window")) {
        // Alias for rename-workspace
        cmdRenameWorkspace(alloc, args, client_fd);
    } else if (std.mem.eql(u8, command, "focus-webview")) {
        Server.respond(client_fd, "ok"); // browser focus — best effort
    } else if (std.mem.eql(u8, command, "is-webview-focused")) {
        Server.respond(client_fd, "false");
    } else if (std.mem.eql(u8, command, "ssh-session-end")) {
        Server.respond(client_fd, "ok"); // SSH session cleanup — no persistent state on Linux
    } else if (std.mem.eql(u8, command, "debug-terminals")) {
        cmdDebugTerminals(app, alloc, client_fd);
    } else if (std.mem.eql(u8, command, "unread-count")) {
        cmdUnreadCount(client_fd);
    } else if (std.mem.eql(u8, command, "__tmux-compat")) {
        if (args.len > 0) {
            var tmux_cmd: []const u8 = args;
            var tmux_args: []const u8 = "";
            if (std.mem.indexOf(u8, args, " ")) |sp| {
                tmux_cmd = args[0..sp];
                tmux_args = std.mem.trim(u8, args[sp + 1 ..], &[_]u8{ ' ', '\t' });
            }
            tmux_compat.handleTmuxCommand(ctx, alloc, tmux_cmd, tmux_args, client_fd);
        } else {
            Server.respond(client_fd, "error: usage: __tmux-compat <command> [args]");
        }
    } else if (std.mem.eql(u8, command, "ssh")) {
        cmdSshDetect(alloc, client_fd);
    } else if (std.mem.eql(u8, command, "quit")) {
        cmdQuit(app);
        Server.respond(client_fd, "ok");
    } else if (std.mem.eql(u8, command, "claude-hook")) {
        cmdClaudeHook(alloc, args, client_fd);
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

fn cmdClearNotifications(args: []const u8) void {
    const store = notification_store.getGlobal() orelse return;

    // Support --workspace=ID
    if (std.mem.indexOf(u8, args, "--workspace=")) |pos| {
        const start = pos + "--workspace=".len;
        const end = std.mem.indexOfPos(u8, args, start, " ") orelse args.len;
        const ws_id = std.fmt.parseInt(u64, args[start..end], 10) catch {
            store.clear(null);
            return;
        };
        store.clearByWorkspace(ws_id);
        return;
    }

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
    // Format: notify [--subtitle=X] <title> [body]
    if (args.len == 0) {
        Server.respond(client_fd, "error: notify requires a title");
        return;
    }

    var subtitle: []const u8 = "";
    var remaining: []const u8 = args;

    // Extract --subtitle=X flag
    if (std.mem.indexOf(u8, args, "--subtitle=")) |pos| {
        const start = pos + "--subtitle=".len;
        const end = std.mem.indexOfPos(u8, args, start, " ") orelse args.len;
        subtitle = args[start..end];
        // Remove the flag from remaining args
        if (end < args.len) {
            remaining = std.mem.trim(u8, args[end + 1 ..], &[_]u8{ ' ', '\t' });
        } else if (pos > 0) {
            remaining = std.mem.trim(u8, args[0 .. pos - 1], &[_]u8{ ' ', '\t' });
        } else {
            remaining = "";
        }
    }

    if (remaining.len == 0) {
        Server.respond(client_fd, "error: notify requires a title");
        return;
    }

    var title: []const u8 = remaining;
    var body: []const u8 = "";
    if (std.mem.indexOf(u8, remaining, " ")) |space_pos| {
        title = remaining[0..space_pos];
        body = std.mem.trim(u8, remaining[space_pos + 1 ..], &[_]u8{ ' ', '\t' });
    }

    const store = notification_store.getGlobal() orelse {
        Server.respond(client_fd, "error: notification store not initialized");
        return;
    };
    store.addFull(title, subtitle, body, 0, 0);
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

// --- Pane/Split commands ---

fn cmdNewSplit(app: *gtk.Application, args: []const u8, client_fd: posix.fd_t) void {
    const surface = getActiveSurface(app) orelse {
        Server.respond(client_fd, "error: no active surface");
        return;
    };

    // Parse direction: right (default), left, up, down
    const direction: Binding.Action.SplitDirection = if (args.len == 0)
        .right
    else if (std.mem.eql(u8, args, "right"))
        .right
    else if (std.mem.eql(u8, args, "left"))
        .left
    else if (std.mem.eql(u8, args, "up"))
        .up
    else if (std.mem.eql(u8, args, "down"))
        .down
    else {
        Server.respond(client_fd, "error: direction must be right, left, up, or down");
        return;
    };

    _ = surface.performBindingAction(.{ .new_split = direction }) catch {
        Server.respond(client_fd, "error: failed to create split");
        return;
    };
    Server.respond(client_fd, "ok");
}

fn cmdListPanes(app: *gtk.Application, alloc: Allocator, client_fd: posix.fd_t) void {
    // List all surfaces in the active window's tab
    const active_gtk_window = app.getActiveWindow() orelse {
        Server.respond(client_fd, "");
        return;
    };

    const window = gobject.ext.cast(Window, active_gtk_window) orelse {
        Server.respond(client_fd, "");
        return;
    };

    // Get all tabs and their surfaces
    const tab_view = window.getTabView();
    const n_pages = tab_view.getNPages();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    var i: c_int = 0;
    while (i < n_pages) : (i += 1) {
        const page = tab_view.getNthPage(i);
        if (i > 0) writer.writeAll("\n") catch return;
        writer.print("tab:{d} page:{d}", .{ i, @intFromPtr(page) }) catch return;
    }

    if (buf.items.len > 0) {
        _ = posix.write(client_fd, buf.items) catch {};
        _ = posix.write(client_fd, "\n") catch {};
    } else {
        Server.respond(client_fd, "");
    }
}

fn cmdSendKey(app: *gtk.Application, args: []const u8, client_fd: posix.fd_t) void {
    if (args.len == 0) {
        Server.respond(client_fd, "error: no key specified");
        return;
    }

    const surface = getActiveSurface(app) orelse {
        Server.respond(client_fd, "error: no active surface");
        return;
    };

    // Handle common key names
    const text: []const u8 = if (std.mem.eql(u8, args, "enter") or std.mem.eql(u8, args, "return"))
        "\r"
    else if (std.mem.eql(u8, args, "tab"))
        "\t"
    else if (std.mem.eql(u8, args, "escape") or std.mem.eql(u8, args, "esc"))
        "\x1b"
    else if (std.mem.eql(u8, args, "backspace"))
        "\x7f"
    else if (std.mem.eql(u8, args, "space"))
        " "
    else if (std.mem.eql(u8, args, "ctrl-c"))
        "\x03"
    else if (std.mem.eql(u8, args, "ctrl-d"))
        "\x04"
    else if (std.mem.eql(u8, args, "ctrl-z"))
        "\x1a"
    else if (std.mem.eql(u8, args, "ctrl-l"))
        "\x0c"
    else if (std.mem.eql(u8, args, "up"))
        "\x1b[A"
    else if (std.mem.eql(u8, args, "down"))
        "\x1b[B"
    else if (std.mem.eql(u8, args, "right"))
        "\x1b[C"
    else if (std.mem.eql(u8, args, "left"))
        "\x1b[D"
    else
        args;

    surface.textCallback(text) catch {
        Server.respond(client_fd, "error: send-key failed");
        return;
    };
    Server.respond(client_fd, "ok");
}

fn cmdCurrentWindow(app: *gtk.Application, client_fd: posix.fd_t) void {
    if (app.getActiveWindow()) |win| {
        var buf: [64]u8 = undefined;
        Server.respond(client_fd, std.fmt.bufPrint(&buf, "{d}", .{@intFromPtr(win)}) catch "0");
    } else {
        Server.respond(client_fd, "error: no active window");
    }
}

fn cmdFocusWindow(app: *gtk.Application, args: []const u8, client_fd: posix.fd_t) void {
    _ = args; // TODO: parse window ID and focus specific window
    if (app.getActiveWindow()) |win| {
        win.present();
        Server.respond(client_fd, "ok");
    } else {
        Server.respond(client_fd, "error: no window to focus");
    }
}

fn cmdNewTab(app: *gtk.Application) void {
    // Create a new tab by getting the active window and calling newTab
    if (app.getActiveWindow()) |gtk_win| {
        if (gobject.ext.cast(Window, gtk_win)) |window| {
            window.newTab(null);
        }
    }
}

fn cmdCloseTab(app: *gtk.Application) void {
    // Close the active tab's surface
    const surface = getActiveSurface(app) orelse return;
    _ = surface.performBindingAction(.close_surface) catch {};
}

fn cmdTree(app: *gtk.Application, alloc: Allocator, client_fd: posix.fd_t) void {
    // Dump workspace + tab tree structure as text
    const mgr = workspace_mgr.getGlobal() orelse {
        Server.respond(client_fd, "");
        return;
    };
    mgr.mutex.lock();
    defer mgr.mutex.unlock();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    // Get tab count from active window
    var tab_count: c_int = 0;
    if (app.getActiveWindow()) |gtk_win| {
        if (gobject.ext.cast(Window, gtk_win)) |window| {
            tab_count = window.getTabView().getNPages();
        }
    }

    writer.print("cmux ({d} tabs, {d} workspaces)\n", .{ tab_count, mgr.workspaces.items.len }) catch return;
    for (mgr.workspaces.items) |ws| {
        const marker: []const u8 = if (ws.id == mgr.active_id) " *" else "";
        writer.print("  workspace {d}: \"{s}\"{s}\n", .{ ws.id, ws.name, marker }) catch return;
        // Status entries
        for (ws.status.statuses.items) |s| {
            writer.print("    {s}: {s}\n", .{ s.key, s.value }) catch continue;
        }
        // Progress
        for (ws.status.progress.items) |p| {
            writer.print("    [{s}: {d:.0}%]\n", .{ p.key, p.value * 100 }) catch continue;
        }
    }

    if (buf.items.len > 0) {
        _ = posix.write(client_fd, buf.items) catch {};
    } else {
        Server.respond(client_fd, "");
    }
}

fn cmdFocusPane(app: *gtk.Application, args: []const u8, client_fd: posix.fd_t) void {
    const surface = getActiveSurface(app) orelse {
        Server.respond(client_fd, "error: no active surface");
        return;
    };

    // Parse direction: next (default), previous, right, left, up, down
    if (args.len == 0 or std.mem.eql(u8, args, "next")) {
        _ = surface.performBindingAction(.{ .goto_split = .next }) catch {};
    } else if (std.mem.eql(u8, args, "previous") or std.mem.eql(u8, args, "prev")) {
        _ = surface.performBindingAction(.{ .goto_split = .previous }) catch {};
    } else {
        Server.respond(client_fd, "error: direction must be next or previous");
        return;
    }
    Server.respond(client_fd, "ok");
}

fn cmdCloseSurface(app: *gtk.Application, client_fd: posix.fd_t) void {
    const surface = getActiveSurface(app) orelse {
        Server.respond(client_fd, "error: no active surface");
        return;
    };
    _ = surface.performBindingAction(.close_surface) catch {
        Server.respond(client_fd, "error: failed to close surface");
        return;
    };
    Server.respond(client_fd, "ok");
}

// --- Status/Progress/Log commands ---

/// Get the active workspace's status store.
/// Safe because all socket handler callbacks run on the GTK main thread
/// (GLib main loop), same thread that modifies workspace state.
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

fn cmdIdentify(client_fd: posix.fd_t) void {
    const build_config = @import("../../build_config.zig");
    var buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "cmux-linux {s} gtk", .{build_config.version_string}) catch "cmux-linux";
    Server.respond(client_fd, resp);
}

fn cmdSidebarState(alloc: Allocator, client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        Server.respond(client_fd, "{}");
        return;
    };

    // formatJson acquires its own lock, so don't hold mutex here
    const ws_json = mgr.formatJson(alloc) catch {
        Server.respond(client_fd, "{}");
        return;
    };
    defer alloc.free(ws_json);

    const ports_json = port_scanner.formatJson(alloc) catch blk: {
        break :blk alloc.dupe(u8, "[]") catch {
            Server.respond(client_fd, "{}");
            return;
        };
    };
    defer alloc.free(ports_json);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    writer.writeAll("{\"workspaces\":") catch return;
    writer.writeAll(ws_json) catch return;
    // Add notification unread count
    const notif_store = notification_store.getGlobal();
    const unread = if (notif_store) |s| s.unreadCount() else 0;
    writer.print(",\"unread_notifications\":{d}", .{unread}) catch return;

    writer.writeAll(",\"ports\":") catch return;
    writer.writeAll(ports_json) catch return;
    writer.writeAll("}") catch return;

    Server.respond(client_fd, buf.items);
}

fn cmdListPorts(alloc: Allocator, client_fd: posix.fd_t) void {
    const text = port_scanner.formatText(alloc) catch {
        Server.respond(client_fd, "error: failed to scan ports");
        return;
    };
    defer alloc.free(text);
    Server.respond(client_fd, if (text.len > 0) text else "");
}

fn cmdOpenBrowser(args: []const u8, client_fd: posix.fd_t) void {
    const url = if (args.len > 0) args else "about:blank";
    const id = browser.open(url) catch {
        Server.respond(client_fd, "error: failed to open browser");
        return;
    };

    // Embed the browser widget in the active window's tab as a Paned split
    if (browser.getWidget(id)) |browser_widget| {
        browser_widget.setSizeRequest(400, -1);
        browser_widget.setVisible(1);

        // Get the active window from the default GIO application
        const gio_app = gio.Application.getDefault() orelse {
            var buf2: [64]u8 = undefined;
            Server.respond(client_fd, std.fmt.bufPrint(&buf2, "{d}", .{id}) catch "0");
            return;
        };
        const gtk_app = gobject.ext.cast(gtk.Application, gio_app) orelse {
            var buf2: [64]u8 = undefined;
            Server.respond(client_fd, std.fmt.bufPrint(&buf2, "{d}", .{id}) catch "0");
            return;
        };
        const active_win = gtk_app.getActiveWindow() orelse {
            var buf: [64]u8 = undefined;
            Server.respond(client_fd, std.fmt.bufPrint(&buf, "{d}", .{id}) catch "0");
            return;
        };
        const window = gobject.ext.cast(Window, active_win) orelse {
            var buf: [64]u8 = undefined;
            Server.respond(client_fd, std.fmt.bufPrint(&buf, "{d}", .{id}) catch "0");
            return;
        };

        // Get the active tab's split tree widget
        const tab_view = window.getTabView();
        const selected_page = tab_view.getSelectedPage() orelse {
            var buf: [64]u8 = undefined;
            Server.respond(client_fd, std.fmt.bufPrint(&buf, "{d}", .{id}) catch "0");
            return;
        };
        const tab_child = selected_page.getChild();

        // The tab_child is a GhosttyTab (gtk.Box). Its first child is
        // the GhosttySplitTree. We insert a Paned wrapping both.
        const first_child = tab_child.getFirstChild() orelse {
            var buf: [64]u8 = undefined;
            Server.respond(client_fd, std.fmt.bufPrint(&buf, "{d}", .{id}) catch "0");
            return;
        };

        // Create a scrolled window for the browser
        const browser_scroll = gtk.ScrolledWindow.new();
        browser_scroll.setChild(browser_widget);

        // Create a Paned: terminal | browser
        const paned = gtk.Paned.new(.horizontal);
        paned.as(gtk.Widget).setHexpand(1);
        paned.as(gtk.Widget).setVexpand(1);

        // Reparent: remove split_tree from tab, put in paned
        first_child.unparent();
        paned.setStartChild(first_child);
        paned.setEndChild(browser_scroll.as(gtk.Widget));

        // Set initial position (60/40 split)
        paned.setPosition(600);

        // Add paned to the tab box
        const tab_box: *gtk.Box = @ptrCast(@alignCast(tab_child));
        tab_box.prepend(paned.as(gtk.Widget));

        log.debug("browser panel embedded in active tab as horizontal split", .{});
    }

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

fn cmdBrowserBack(args: []const u8, client_fd: posix.fd_t) void {
    const id = std.fmt.parseInt(usize, if (args.len > 0) args else "0", 10) catch 0;
    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (browser.getWidget(id)) |w| {
            webkit.goBack(w);
            Server.respond(client_fd, "ok");
            return;
        }
    }
    Server.respond(client_fd, "error: no browser widget");
}

fn cmdBrowserForward(args: []const u8, client_fd: posix.fd_t) void {
    const id = std.fmt.parseInt(usize, if (args.len > 0) args else "0", 10) catch 0;
    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (browser.getWidget(id)) |w| {
            webkit.goForward(w);
            Server.respond(client_fd, "ok");
            return;
        }
    }
    Server.respond(client_fd, "error: no browser widget");
}

fn cmdBrowserReload(args: []const u8, client_fd: posix.fd_t) void {
    const id = std.fmt.parseInt(usize, if (args.len > 0) args else "0", 10) catch 0;
    const build_config = @import("../../build_config.zig");
    if (comptime build_config.cmux) {
        const webkit = @import("../browser/webkit.zig");
        if (browser.getWidget(id)) |w| {
            webkit.reload(w);
            Server.respond(client_fd, "ok");
            return;
        }
    }
    Server.respond(client_fd, "error: no browser widget");
}

fn cmdSshDetect(alloc: Allocator, client_fd: posix.fd_t) void {
    const json = ssh_detector.formatJson(alloc) catch {
        Server.respond(client_fd, "[]");
        return;
    };
    defer alloc.free(json);
    Server.respond(client_fd, json);
}

fn cmdMarkdown(alloc: Allocator, args: []const u8, client_fd: posix.fd_t) void {
    if (args.len == 0) {
        Server.respond(client_fd, "error: usage: markdown <path>");
        return;
    }
    const id = markdown.open(args) catch {
        Server.respond(client_fd, "error: failed to open markdown");
        return;
    };
    var buf: [64]u8 = undefined;
    Server.respond(client_fd, std.fmt.bufPrint(&buf, "{d}", .{id}) catch "0");
    _ = alloc;
}

// --- Phase 2: Previously stubbed and missing commands ---

fn cmdReorderWorkspace(args: []const u8, client_fd: posix.fd_t) void {
    // Format: reorder-workspace <id> <new_index>
    const space = std.mem.indexOf(u8, args, " ") orelse {
        Server.respond(client_fd, "error: usage: reorder-workspace <id> <index>");
        return;
    };
    const id = std.fmt.parseInt(u64, args[0..space], 10) catch {
        Server.respond(client_fd, "error: invalid workspace id");
        return;
    };
    const new_index = std.fmt.parseInt(usize, std.mem.trim(u8, args[space + 1 ..], &[_]u8{ ' ', '\t' }), 10) catch {
        Server.respond(client_fd, "error: invalid index");
        return;
    };
    const mgr = workspace_mgr.getGlobal() orelse {
        Server.respond(client_fd, "error: no workspace manager");
        return;
    };
    if (mgr.reorder(id, new_index)) {
        Server.respond(client_fd, "ok");
    } else {
        Server.respond(client_fd, "error: workspace not found");
    }
}

fn cmdRefreshSurfaces(app: *gtk.Application) void {
    const windows = app.getWindows();
    var node: ?*glib.List = windows;
    while (node) |n| {
        if (n.f_data) |data| {
            const widget: *gtk.Widget = @ptrCast(@alignCast(data));
            widget.queueDraw();
        }
        node = n.f_next;
    }
}

fn cmdSendPanel(_: *gtk.Application, _: Allocator, args: []const u8, client_fd: posix.fd_t) void {
    // Format: send-panel --id=ID text
    // For now, equivalent to send (targets active surface)
    // TODO: look up specific surface by ID
    const text_start = std.mem.indexOf(u8, args, " ") orelse {
        Server.respond(client_fd, "error: usage: send-panel --id=ID text");
        return;
    };
    _ = args[0..text_start]; // skip --id=X
    const text = std.mem.trim(u8, args[text_start + 1 ..], &[_]u8{ ' ', '\t' });
    if (text.len == 0) {
        Server.respond(client_fd, "error: no text to send");
        return;
    }
    // Fall back to active surface for now
    Server.respond(client_fd, "error: send-panel by ID not yet supported — use send");
}

fn cmdSendKeyPanel(_: *gtk.Application, args: []const u8, client_fd: posix.fd_t) void {
    _ = args;
    Server.respond(client_fd, "error: send-key-panel by ID not yet supported — use send-key");
}

fn cmdFocusPanel(_: *gtk.Application, args: []const u8, client_fd: posix.fd_t) void {
    _ = args;
    // TODO: implement panel lookup by ID and focus
    Server.respond(client_fd, "error: focus-panel by ID not yet supported");
}

fn cmdSurfaceHealth(app: *gtk.Application, client_fd: posix.fd_t) void {
    const surface = getActiveSurface(app) orelse {
        Server.respond(client_fd, "dead");
        return;
    };
    _ = surface;
    Server.respond(client_fd, "alive");
}

fn cmdListPaneSurfaces(app: *gtk.Application, alloc: Allocator, client_fd: posix.fd_t) void {
    // List tab pages in the active window's tab view
    const active_gtk_window = app.getActiveWindow() orelse {
        Server.respond(client_fd, "");
        return;
    };
    const window = gobject.ext.cast(Window, active_gtk_window) orelse {
        Server.respond(client_fd, "");
        return;
    };
    const tab_view = window.getTabView();
    const n: usize = @intCast(@max(0, tab_view.getNPages()));

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const page = tab_view.getNthPage(@intCast(i));
        if (i > 0) writer.writeAll("\n") catch return;
        writer.print("{d}\t{s}", .{ i, std.mem.sliceTo(page.getTitle(), 0) }) catch return;
    }

    if (buf.items.len == 0) {
        Server.respond(client_fd, "");
    } else {
        _ = posix.write(client_fd, buf.items) catch {};
    }
}

fn cmdWorkspaceAction(args: []const u8, client_fd: posix.fd_t) void {
    const mgr = workspace_mgr.getGlobal() orelse {
        Server.respond(client_fd, "error: no workspace manager");
        return;
    };
    mgr.mutex.lock();
    defer mgr.mutex.unlock();

    if (mgr.workspaces.items.len == 0) {
        Server.respond(client_fd, "error: no workspaces");
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

    const total = mgr.workspaces.items.len;
    var target_idx: usize = current_idx;

    if (std.mem.eql(u8, args, "next")) {
        target_idx = (current_idx + 1) % total;
    } else if (std.mem.eql(u8, args, "previous") or std.mem.eql(u8, args, "prev")) {
        target_idx = if (current_idx == 0) total - 1 else current_idx - 1;
    } else if (std.mem.eql(u8, args, "last")) {
        target_idx = total - 1;
    } else {
        Server.respond(client_fd, "error: usage: workspace-action next|previous|last");
        return;
    }

    mgr.active_id = mgr.workspaces.items[target_idx].id;
    Server.respond(client_fd, "ok");
}

fn cmdTabAction(app: *gtk.Application, args: []const u8, client_fd: posix.fd_t) void {
    const active_gtk_window = app.getActiveWindow() orelse {
        Server.respond(client_fd, "error: no active window");
        return;
    };
    const window = gobject.ext.cast(Window, active_gtk_window) orelse {
        Server.respond(client_fd, "error: no cmux window");
        return;
    };
    const tab_view = window.getTabView();
    const n = tab_view.getNPages();
    if (n <= 0) {
        Server.respond(client_fd, "error: no tabs");
        return;
    }

    const current_page = tab_view.getSelectedPage() orelse {
        Server.respond(client_fd, "error: no selected page");
        return;
    };
    const current_pos = tab_view.getPagePosition(current_page);

    if (std.mem.eql(u8, args, "next")) {
        const next_pos = @mod(current_pos + 1, n);
        const next_page = tab_view.getNthPage(next_pos);
        tab_view.setSelectedPage(next_page);
    } else if (std.mem.eql(u8, args, "previous") or std.mem.eql(u8, args, "prev")) {
        const prev_pos = if (current_pos == 0) n - 1 else current_pos - 1;
        const prev_page = tab_view.getNthPage(prev_pos);
        tab_view.setSelectedPage(prev_page);
    } else if (std.mem.eql(u8, args, "last")) {
        const last_page = tab_view.getNthPage(n - 1);
        tab_view.setSelectedPage(last_page);
    } else {
        Server.respond(client_fd, "error: usage: tab-action next|previous|last");
        return;
    }

    Server.respond(client_fd, "ok");
}

fn cmdDebugTerminals(app: *gtk.Application, alloc: Allocator, client_fd: posix.fd_t) void {
    const windows = app.getWindows();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = buf.writer(alloc);

    writer.writeAll("--- cmux debug: terminal tree ---\n") catch return;

    var win_count: usize = 0;
    var node: ?*glib.List = windows;
    while (node) |n| {
        if (n.f_data) |data| {
            writer.print("Window {d}: {x}\n", .{ win_count, @intFromPtr(data) }) catch return;
            if (gobject.ext.cast(Window, @as(*gtk.Window, @ptrCast(@alignCast(data))))) |window| {
                const tab_view = window.getTabView();
                const pages: usize = @intCast(@max(0, tab_view.getNPages()));
                writer.print("  Tabs: {d}\n", .{pages}) catch return;
                var t: usize = 0;
                while (t < pages) : (t += 1) {
                    const page = tab_view.getNthPage(@intCast(t));
                    writer.print("    Tab {d}: {s}\n", .{ t, std.mem.sliceTo(page.getTitle(), 0) }) catch return;
                }
            }
            win_count += 1;
        }
        node = n.f_next;
    }

    if (buf.items.len == 0) {
        Server.respond(client_fd, "(no windows)");
    } else {
        _ = posix.write(client_fd, buf.items) catch {};
    }
}

fn cmdUnreadCount(client_fd: posix.fd_t) void {
    const store = notification_store.getGlobal() orelse {
        Server.respond(client_fd, "0");
        return;
    };
    var count_buf: [20]u8 = undefined;
    Server.respond(client_fd, std.fmt.bufPrint(&count_buf, "{d}", .{store.unreadCount()}) catch "0");
}

// --- Claude Hook / Agent Session Commands ---

fn cmdClaudeHook(alloc: Allocator, args: []const u8, client_fd: posix.fd_t) void {
    if (args.len == 0) {
        Server.respond(client_fd, "error: usage: claude-hook <subcommand> [json]");
        return;
    }

    // Split subcommand from the rest (which is JSON input or flags)
    var subcmd: []const u8 = args;
    var json_input: []const u8 = "";
    if (std.mem.indexOf(u8, args, " ")) |sp| {
        subcmd = args[0..sp];
        json_input = std.mem.trim(u8, args[sp + 1 ..], &[_]u8{ ' ', '\t' });
    }

    // Parse workspace/surface from flags if present, then strip flags from JSON
    var workspace_id: ?[]const u8 = null;
    var surface_id: ?[]const u8 = null;
    var clean_json: []const u8 = json_input;

    // Extract --workspace=X and --surface=X flags
    if (std.mem.indexOf(u8, json_input, "--workspace=")) |pos| {
        const start = pos + "--workspace=".len;
        const end = std.mem.indexOfPos(u8, json_input, start, " ") orelse json_input.len;
        workspace_id = json_input[start..end];
    }
    if (std.mem.indexOf(u8, json_input, "--surface=")) |pos| {
        const start = pos + "--surface=".len;
        const end = std.mem.indexOfPos(u8, json_input, start, " ") orelse json_input.len;
        surface_id = json_input[start..end];
    }

    // Find the JSON part (starts with '{')
    if (std.mem.indexOf(u8, json_input, "{")) |json_start| {
        clean_json = json_input[json_start..];
    }

    // Parse the JSON input
    const input = agent_session.parseClaudeHookInput(alloc, clean_json);

    // Resolve workspace/surface from input or env
    const ws_id = workspace_id orelse input.cwd orelse std.posix.getenv("CMUX_WORKSPACE_ID") orelse "default";
    const sf_id = surface_id orelse std.posix.getenv("CMUX_SURFACE_ID") orelse "";

    if (std.mem.eql(u8, subcmd, "session-start") or std.mem.eql(u8, subcmd, "active")) {
        claudeHookSessionStart(input, ws_id, sf_id, client_fd);
    } else if (std.mem.eql(u8, subcmd, "stop") or std.mem.eql(u8, subcmd, "idle") or std.mem.eql(u8, subcmd, "session-idle")) {
        claudeHookStop(input, ws_id, client_fd);
    } else if (std.mem.eql(u8, subcmd, "session-end")) {
        claudeHookSessionEnd(input, ws_id, sf_id, client_fd);
    } else if (std.mem.eql(u8, subcmd, "prompt-submit")) {
        claudeHookPromptSubmit(input, ws_id, client_fd);
    } else if (std.mem.eql(u8, subcmd, "pre-tool-use")) {
        claudeHookPreToolUse(input, ws_id, client_fd);
    } else if (std.mem.eql(u8, subcmd, "notification") or std.mem.eql(u8, subcmd, "notify")) {
        claudeHookNotification(input, ws_id, sf_id, client_fd);
    } else {
        Server.respond(client_fd, "error: unknown claude-hook subcommand");
    }
}

fn claudeHookSessionStart(
    input: agent_session.ParsedInput,
    workspace_id: []const u8,
    surface_id: []const u8,
    client_fd: posix.fd_t,
) void {
    const store = agent_session.getGlobal() orelse {
        Server.respond(client_fd, "OK");
        return;
    };

    const session_id = input.session_id orelse "";

    // Get Claude PID from env
    const pid: ?i32 = blk: {
        const pid_str = std.posix.getenv("CMUX_CLAUDE_PID") orelse break :blk null;
        break :blk std.fmt.parseInt(i32, pid_str, 10) catch null;
    };

    // Upsert session
    store.upsert(
        session_id,
        workspace_id,
        surface_id,
        input.cwd,
        pid,
        null, // no subtitle on start
        null, // no body on start
    );

    // Set status: "Running" with bolt icon, blue color
    setAgentStatus(workspace_id, "Running", "bolt.fill", "#4C8DFF");

    Server.respond(client_fd, "OK");
}

fn claudeHookStop(
    input: agent_session.ParsedInput,
    workspace_id: []const u8,
    client_fd: posix.fd_t,
) void {
    const store = agent_session.getGlobal() orelse {
        Server.respond(client_fd, "OK");
        return;
    };

    // Lookup session (don't consume — Claude is still running)
    var resolved_ws = workspace_id;
    if (input.session_id) |sid| {
        if (store.lookup(sid)) |record| {
            resolved_ws = record.workspace_id;

            // Save completion info to session
            const subtitle = "Completed";
            const body = input.message;
            store.upsert(sid, resolved_ws, "", null, null, subtitle, body);
        }
    }

    // Set status: "Idle" with pause icon, gray color
    setAgentStatus(resolved_ws, "Idle", "pause.circle.fill", "#8E8E93");

    Server.respond(client_fd, "OK");
}

fn claudeHookSessionEnd(
    input: agent_session.ParsedInput,
    workspace_id: []const u8,
    surface_id: []const u8,
    client_fd: posix.fd_t,
) void {
    const store = agent_session.getGlobal() orelse {
        Server.respond(client_fd, "OK");
        return;
    };

    // Consume the session (final cleanup)
    var record = store.consume(input.session_id, workspace_id, surface_id) orelse {
        Server.respond(client_fd, "OK");
        return;
    };
    defer store.freeConsumed(&record);

    // Clear status for this workspace
    clearAgentStatus(record.workspace_id);

    // Clear notifications for this workspace
    const notif_store = notification_store.getGlobal() orelse {
        Server.respond(client_fd, "OK");
        return;
    };
    notif_store.clear(null); // TODO: clear by workspace when supported

    Server.respond(client_fd, "OK");
}

fn claudeHookPromptSubmit(
    input: agent_session.ParsedInput,
    workspace_id: []const u8,
    client_fd: posix.fd_t,
) void {
    const store = agent_session.getGlobal() orelse {
        Server.respond(client_fd, "OK");
        return;
    };

    // Lookup session to resolve workspace
    var resolved_ws = workspace_id;
    if (input.session_id) |sid| {
        if (store.lookup(sid)) |record| {
            resolved_ws = record.workspace_id;
        }
    }

    // Clear notifications
    if (notification_store.getGlobal()) |notif_store| {
        notif_store.clear(null); // TODO: clear by workspace
    }

    // Set status: "Running"
    setAgentStatus(resolved_ws, "Running", "bolt.fill", "#4C8DFF");

    Server.respond(client_fd, "OK");
}

fn claudeHookPreToolUse(
    input: agent_session.ParsedInput,
    workspace_id: []const u8,
    client_fd: posix.fd_t,
) void {
    const store = agent_session.getGlobal() orelse {
        Server.respond(client_fd, "OK");
        return;
    };

    var resolved_ws = workspace_id;
    if (input.session_id) |sid| {
        if (store.lookup(sid)) |record| {
            resolved_ws = record.workspace_id;
        }
    }

    // If tool is AskUserQuestion, save the question to lastBody
    if (input.tool_name) |tool| {
        if (std.mem.eql(u8, tool, "AskUserQuestion")) {
            if (input.session_id) |sid| {
                store.upsert(sid, resolved_ws, "", null, null, null, input.message);
            }
        }
    }

    // Clear notifications
    if (notification_store.getGlobal()) |notif_store| {
        notif_store.clear(null);
    }

    // Set status with tool description or "Running"
    const status_text = input.tool_description orelse "Running";
    setAgentStatus(resolved_ws, status_text, "bolt.fill", "#4C8DFF");

    Server.respond(client_fd, "OK");
}

fn claudeHookNotification(
    input: agent_session.ParsedInput,
    workspace_id: []const u8,
    surface_id: []const u8,
    client_fd: posix.fd_t,
) void {
    const store = agent_session.getGlobal() orelse {
        Server.respond(client_fd, "OK");
        return;
    };

    // Resolve workspace from session
    var resolved_ws = workspace_id;
    if (input.session_id) |sid| {
        if (store.lookup(sid)) |record| {
            resolved_ws = record.workspace_id;
        }
    }

    // Classify the event
    const class = agent_session.classifyEvent(input.event_type, input.message);

    // Build notification subtitle based on classification
    const subtitle = switch (class) {
        .permission => "Permission requested",
        .@"error" => "Error occurred",
        .completed => "Task completed",
        .waiting => "Waiting for input",
        .attention => "Needs attention",
    };

    const body = input.message orelse "";

    // Update session with notification info
    if (input.session_id) |sid| {
        store.upsert(sid, resolved_ws, surface_id, null, null, subtitle, body);
    }

    // Store the notification
    if (notification_store.getGlobal()) |notif_store| {
        notif_store.add(subtitle, body, 0);
    }

    // Set status: "Needs input" with bell icon
    setAgentStatus(resolved_ws, "Needs input", "bell.fill", "#4C8DFF");

    Server.respond(client_fd, "OK");
}

/// Set agent status on a workspace using the workspace status store.
pub fn setAgentStatus(workspace_id: []const u8, value: []const u8, icon: []const u8, color: []const u8) void {
    const mgr = workspace_mgr.getGlobal() orelse return;
    // Find workspace by name or use active
    const ws_id = findWorkspaceByNameOrActive(mgr, workspace_id);
    mgr.mutex.lock();
    defer mgr.mutex.unlock();
    const status = mgr.getStatus(ws_id) orelse return;

    // Set the status entry with icon and color
    status.setStatus("claude_code", value) catch return;

    // Update icon and color on the status entry
    for (status.statuses.items) |*s| {
        if (std.mem.eql(u8, s.key, "claude_code")) {
            if (s.icon) |ic| status.alloc.free(ic);
            s.icon = status.alloc.dupe(u8, icon) catch null;
            if (s.color) |c| status.alloc.free(c);
            s.color = status.alloc.dupe(u8, color) catch null;
            break;
        }
    }
}

/// Clear agent status from a workspace.
pub fn clearAgentStatus(workspace_id: []const u8) void {
    const mgr = workspace_mgr.getGlobal() orelse return;
    const ws_id = findWorkspaceByNameOrActive(mgr, workspace_id);
    mgr.mutex.lock();
    defer mgr.mutex.unlock();
    if (mgr.getStatus(ws_id)) |status| {
        status.clearStatus("claude_code");
    }
}

/// Find a workspace ID by name, or return the active workspace ID.
fn findWorkspaceByNameOrActive(mgr: *workspace_mgr.Manager, name: []const u8) u64 {
    // Try to parse as numeric ID first
    if (std.fmt.parseInt(u64, name, 10) catch null) |id| {
        for (mgr.workspaces.items) |ws| {
            if (ws.id == id) return id;
        }
    }
    // Try name match
    for (mgr.workspaces.items) |ws| {
        if (std.mem.eql(u8, ws.name, name)) return ws.id;
    }
    // Fall back to active
    return mgr.active_id;
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
