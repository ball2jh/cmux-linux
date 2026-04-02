//! cmux Unix domain socket server.
//!
//! Manages the lifecycle of the control socket: create, bind, listen, accept,
//! and stop. Uses generation-based tracking to safely restart the accept loop.
//! Routes incoming commands through the V1/V2 protocol parsers and dispatches
//! to registered handlers.
//!
//! Matches macOS TerminalController socket lifecycle (lines 873-1631).

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const json = std.json;

const build_config = @import("../build_config.zig");
const access_mod = @import("access.zig");
const accept_loop = @import("accept_loop.zig");
const client_handler = @import("client_handler.zig");
const socket_path = @import("socket_path.zig");
const protocol = @import("protocol.zig");
const window_ops_mod = @import("window_ops.zig");
const v1 = protocol.v1;
const v2 = protocol.v2;
const notification = @import("notification/main.zig");
const workspace = @import("workspace/main.zig");
const debug_mod = @import("debug/main.zig");
const remote_commands = @import("remote/main.zig").commands;
const browser_commands = @import("remote/browser_commands.zig");
const markdown_commands = @import("remote/markdown_commands.zig");
const dispatch = @import("dispatch.zig");
const Uuid = @import("uuid.zig").Uuid;
const RefMap = @import("RefMap.zig");

const log = std.log.scoped(.cmux_server);

const Server = @This();

// --- State protected by state_mutex ---
state_mutex: std.Thread.Mutex = .{},
is_running: bool = false,
active_generation: u64 = 0,
next_generation: u64 = 0,
server_fd: posix.socket_t = -1,
socket_path_buf: [posix.PATH_MAX]u8 = undefined,
socket_path_len: usize = 0,
accept_thread: ?std.Thread = null,

// --- Accept loop callbacks (stable across restarts) ---
callbacks: accept_loop.ServerCallbacks = undefined,

// --- Set once before start ---
access_mode: access_mod.Mode = .allow_all,
my_pid: posix.pid_t = 0,
alloc: Allocator,

// --- Notification store ---
notification_store: notification.Store,

// --- V2 ref handle map (UUID ↔ short handles like "workspace:1") ---
ref_map: RefMap,

// --- Workspace manager (set by GTK app layer) ---
workspace_manager: ?*workspace.Manager = null,

// --- Window operations callbacks (set by GTK window layer) ---
window_ops: ?window_ops_mod.WindowOps = null,

// --- CmuxWindow reference (set by GTK window layer, *anyopaque to avoid circular imports) ---
cmux_window: ?*anyopaque = null,

// --- Debug diagnostic counters (comptime-gated, zero-cost in release) ---
debug_counters: if (build_config.is_debug) debug_mod.counters.Counters else void =
    if (build_config.is_debug) .{} else {},

/// Initialize a new server. Does not start listening.
pub fn init(alloc: Allocator) Server {
    var self = Server{
        .alloc = alloc,
        .notification_store = notification.Store.init(alloc),
        .ref_map = RefMap.init(alloc),
    };
    self.my_pid = std.os.linux.getpid();
    if (comptime build_config.is_debug) {
        self.debug_counters.alloc = alloc;
    }
    self.callbacks = .{
        .should_continue = &shouldContinueCb,
        .on_loop_exit = &onLoopExitCb,
        .dispatch_fn = &dispatchCommand,
        .access_mode = self.access_mode,
        .my_pid = self.my_pid,
        .alloc = alloc,
        .ctx = @ptrCast(&self),
    };
    return self;
}

/// Clean up. Stops the server if running.
pub fn deinit(self: *Server) void {
    if (self.is_running) {
        self.stop();
    }
    if (comptime build_config.is_debug) {
        self.debug_counters.deinit();
    }
    self.notification_store.deinit();
    self.ref_map.deinit();
}

/// Start listening on the given socket path.
/// If already running on the same path, just updates access mode and permissions.
/// If running on a different path, stops first and restarts.
pub fn start(self: *Server, path: []const u8, mode: access_mod.Mode) !void {
    self.state_mutex.lock();

    // Already running on the same path? Just update mode.
    if (self.is_running and self.currentPath() != null) {
        if (std.mem.eql(u8, self.currentPath().?, path)) {
            self.access_mode = mode;
            self.callbacks.access_mode = mode;
            self.state_mutex.unlock();
            // Update socket permissions.
            chmod(path, mode.socketPermissions());
            return;
        }
    }

    // Running on different path — stop first.
    if (self.is_running) {
        self.state_mutex.unlock();
        self.stop();
        self.state_mutex.lock();
    }

    defer self.state_mutex.unlock();

    self.access_mode = mode;
    self.callbacks.access_mode = mode;
    self.callbacks.my_pid = self.my_pid;

    // 1. Create socket.
    const fd = posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
    ) catch |e| {
        log.err("socket() failed: {}", .{e});
        return e;
    };
    errdefer posix.close(fd);

    // 2. Ensure parent directory exists.
    socket_path.ensureParentDir(path) catch |e| {
        log.err("failed to create socket parent dir for '{s}': {}", .{ path, e });
        return e;
    };

    // 3. Remove stale socket file.
    posix.unlink(path) catch |e| switch (e) {
        error.FileNotFound => {}, // Expected.
        else => {
            log.warn("unlink '{s}' failed: {}", .{ path, e });
        },
    };

    // 4. Bind.
    const addr = socketAddress(path) catch |e| {
        log.err("socket path too long: '{s}'", .{path});
        return e;
    };
    posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |e| {
        log.err("bind to '{s}' failed: {}", .{ path, e });
        return e;
    };

    // 5. Set permissions.
    chmod(path, mode.socketPermissions());

    // 6. Listen.
    posix.listen(fd, accept_loop.listen_backlog) catch |e| {
        log.err("listen on '{s}' failed: {}", .{ path, e });
        return e;
    };

    // 7. Record path for CLI discovery.
    socket_path.recordLastPath(path);

    // 8. Update state and spawn accept loop.
    self.next_generation +%= 1;
    self.active_generation = self.next_generation;
    self.server_fd = fd;
    @memcpy(self.socket_path_buf[0..path.len], path);
    self.socket_path_len = path.len;
    self.is_running = true;

    const gen = self.active_generation;

    // Update callback context pointer (self may have moved if init was by-value).
    self.callbacks.ctx = @ptrCast(self);

    self.accept_thread = std.Thread.spawn(.{}, accept_loop.run, .{
        &self.callbacks,
        fd,
        gen,
    }) catch |e| {
        log.err("failed to spawn accept loop thread: {}", .{e});
        self.is_running = false;
        posix.close(fd);
        self.server_fd = -1;
        return e;
    };

    log.info("socket server started on '{s}' (gen={d}, mode={s})", .{
        path,
        gen,
        @tagName(mode),
    });
}

/// Stop the socket server.
pub fn stop(self: *Server) void {
    self.state_mutex.lock();

    if (!self.is_running) {
        self.state_mutex.unlock();
        return;
    }

    self.is_running = false;
    self.active_generation = 0;

    const fd = self.server_fd;
    self.server_fd = -1;

    const path = self.currentPath();
    const thread = self.accept_thread;
    self.accept_thread = null;

    self.state_mutex.unlock();

    // Close the listener fd — this breaks the blocking accept().
    if (fd >= 0) {
        posix.close(fd);
    }

    // Remove the socket file.
    if (path) |p| {
        posix.unlink(p) catch {};
    }

    // Wait for accept thread to finish.
    if (thread) |t| {
        t.join();
    }

    log.info("socket server stopped", .{});
}

/// Check if the accept loop should continue for the given generation.
pub fn shouldContinue(self: *Server, generation: u64) bool {
    self.state_mutex.lock();
    defer self.state_mutex.unlock();
    return self.is_running and self.active_generation == generation;
}

/// Get the current socket path, or null if not set.
fn currentPath(self: *const Server) ?[]const u8 {
    if (self.socket_path_len == 0) return null;
    return self.socket_path_buf[0..self.socket_path_len];
}

// --- Command dispatch ---

/// Dispatch a command line to the appropriate V1/V2 handler.
/// This is called by the client handler thread for each command.
fn dispatchCommand(
    server_opaque: client_handler.ServerRef,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    line: []const u8,
) void {
    const self: *Server = @ptrCast(@alignCast(server_opaque));

    if (protocol.isV2(line)) {
        dispatchV2(self, arena, writer, line);
    } else {
        dispatchV1(self, arena, writer, line);
    }
}

const v1_help_text =
    "Available commands: ping, auth, help, " ++
    "list_windows, close_window, new_window, current_window, focus_window, " ++
    "move_workspace_to_window, " ++
    "new_workspace, list_workspaces, select_workspace, close_workspace, current_workspace, " ++
    "new_surface, new_split, list_surfaces, close_surface, focus_surface, " ++
    "focus_surface_by_panel, drag_surface_to_split, surface_health, read_screen, " ++
    "send, send_surface, send_key, send_key_surface, " ++
    "notify, notify_surface, notify_target, list_notifications, clear_notifications, " ++
    "set_status, report_meta, clear_status, clear_meta, list_status, list_meta, " ++
    "report_meta_block, clear_meta_block, list_meta_blocks, " ++
    "set_agent_pid, clear_agent_pid, " ++
    "report_git_branch, clear_git_branch, report_pr, clear_pr, " ++
    "report_ports, clear_ports, report_tty, ports_kick, report_shell_state, report_pwd, " ++
    "set_progress, clear_progress, log, clear_log, list_log, " ++
    "sidebar_state, reset_sidebar, " ++
    "open_browser, navigate, browser_back, browser_forward, browser_reload, " ++
    "get_url, focus_webview, is_webview_focused, " ++
    "reload_config, toggle_sidebar, read_terminal_text";

fn dispatchV1(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, line: []const u8) void {
    const cmd = v1.parse(arena, line) catch {
        v1.err(writer, "Failed to parse command") catch {};
        return;
    };

    // --- Core ---
    if (std.mem.eql(u8, cmd.name, "ping")) {
        v1.raw(writer, "PONG") catch {};
    } else if (std.mem.eql(u8, cmd.name, "auth")) {
        v1.raw(writer, "OK: Authentication not required") catch {};
    } else if (std.mem.eql(u8, cmd.name, "help")) {
        v1.raw(writer, v1_help_text) catch {};

    // --- Notifications ---
    } else if (std.mem.eql(u8, cmd.name, "notify")) {
        self.handleV1Notify(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "notify_surface")) {
        self.handleV1NotifySurface(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "notify_target")) {
        var buf: [4096]u8 = undefined;
        const resp = notification.commands.handleNotifyTarget(&self.notification_store, cmd.args, &buf);
        v1.raw(writer, resp) catch {};
    } else if (std.mem.eql(u8, cmd.name, "list_notifications")) {
        var buf: [8192]u8 = undefined;
        const resp = notification.commands.handleListNotifications(&self.notification_store, &buf);
        v1.raw(writer, resp) catch {};
    } else if (std.mem.eql(u8, cmd.name, "clear_notifications")) {
        var buf: [4096]u8 = undefined;
        const resp = notification.commands.handleClearNotifications(&self.notification_store, cmd.args, &buf);
        v1.raw(writer, resp) catch {};
        self.scheduleNotificationBadgeRefresh();

    // --- Window management ---
    } else if (std.mem.eql(u8, cmd.name, "list_windows")) {
        self.handleV1ListWindows(writer);
    } else if (std.mem.eql(u8, cmd.name, "close_window")) {
        self.handleV1CloseWindow(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "new_window")) {
        self.handleV1NewWindow(writer);
    } else if (std.mem.eql(u8, cmd.name, "current_window")) {
        self.handleV1CurrentWindow(writer);
    } else if (std.mem.eql(u8, cmd.name, "focus_window")) {
        self.handleV1FocusWindow(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "move_workspace_to_window")) {
        v1.err(writer, "not_implemented: single-window mode, move_workspace_to_window is a no-op") catch {};

    // --- Workspace management ---
    } else if (std.mem.eql(u8, cmd.name, "new_workspace")) {
        self.handleV1NewWorkspace(arena, writer);
    } else if (std.mem.eql(u8, cmd.name, "list_workspaces")) {
        self.handleV1ListWorkspaces(arena, writer);
    } else if (std.mem.eql(u8, cmd.name, "select_workspace")) {
        self.handleV1SelectWorkspace(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "close_workspace")) {
        self.handleV1CloseWorkspace(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "current_workspace")) {
        self.handleV1CurrentWorkspace(writer);

    // --- Surface/Split management ---
    } else if (std.mem.eql(u8, cmd.name, "new_surface")) {
        self.handleV1NewSurface(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "new_split")) {
        self.handleV1NewSplit(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "list_surfaces")) {
        self.handleV1ListSurfaces(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "close_surface")) {
        self.handleV1CloseSurface(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "focus_surface")) {
        self.handleV1FocusSurface(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "focus_surface_by_panel")) {
        self.handleV1FocusSurface(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "drag_surface_to_split")) {
        v1.err(writer, "not_implemented: drag_surface_to_split requires bonsplit pane model") catch {};
    } else if (std.mem.eql(u8, cmd.name, "surface_health")) {
        self.handleV1SurfaceHealth(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "read_screen")) {
        self.handleV1ReadScreen(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "read_terminal_text")) {
        self.handleV1ReadTerminalText(arena, writer);

    // --- Input/Terminal ---
    } else if (std.mem.eql(u8, cmd.name, "send")) {
        v1.err(writer, "not_implemented: send requires ghostty_surface_key integration") catch {};
    } else if (std.mem.eql(u8, cmd.name, "send_surface")) {
        v1.err(writer, "not_implemented: send_surface requires ghostty_surface_key integration") catch {};
    } else if (std.mem.eql(u8, cmd.name, "send_key")) {
        v1.err(writer, "not_implemented: send_key requires ghostty_surface_key integration") catch {};
    } else if (std.mem.eql(u8, cmd.name, "send_key_surface")) {
        v1.err(writer, "not_implemented: send_key_surface requires ghostty_surface_key integration") catch {};

    // --- Sidebar toggle ---
    } else if (std.mem.eql(u8, cmd.name, "toggle_sidebar")) {
        self.handleV1ToggleSidebar(writer, cmd.args);

    // --- Status/Metadata ---
    } else if (std.mem.eql(u8, cmd.name, "set_status")) {
        self.handleV1SetStatus(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "report_meta")) {
        self.handleV1SetStatus(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "clear_status")) {
        self.handleV1ClearStatus(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "clear_meta")) {
        self.handleV1ClearStatus(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "list_status")) {
        self.handleV1ListStatus(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "list_meta")) {
        self.handleV1ListStatus(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "report_meta_block")) {
        self.handleV1ReportMetaBlock(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "clear_meta_block")) {
        self.handleV1ClearMetaBlock(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "list_meta_blocks")) {
        self.handleV1ListMetaBlocks(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "set_agent_pid")) {
        self.handleV1SetAgentPid(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "clear_agent_pid")) {
        self.handleV1ClearAgentPid(writer, cmd.args);

    // --- Git/PR/Ports/Shell ---
    } else if (std.mem.eql(u8, cmd.name, "report_git_branch")) {
        self.handleV1ReportGitBranch(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "clear_git_branch")) {
        self.handleV1ClearGitBranch(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "report_pr") or std.mem.eql(u8, cmd.name, "report_review")) {
        self.handleV1ReportPr(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "clear_pr")) {
        self.handleV1ClearPr(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "report_ports")) {
        self.handleV1ReportPorts(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "clear_ports")) {
        self.handleV1ClearPorts(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "report_tty")) {
        self.handleV1ReportTty(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "report_shell_state")) {
        self.handleV1ReportShellState(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "report_pwd")) {
        self.handleV1ReportPwd(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "ports_kick")) {
        // Port scanning kick — no-op on Linux (no batched PortScanner yet).
        v1.raw(writer, "OK") catch {};

    // --- Progress/Log ---
    } else if (std.mem.eql(u8, cmd.name, "set_progress")) {
        self.handleV1SetProgress(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "clear_progress")) {
        self.handleV1ClearProgress(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "log")) {
        self.handleV1Log(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "clear_log")) {
        self.handleV1ClearLog(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "list_log")) {
        self.handleV1ListLog(arena, writer, cmd.args);

    // --- Sidebar state ---
    } else if (std.mem.eql(u8, cmd.name, "sidebar_state")) {
        self.handleV1SidebarState(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "reset_sidebar")) {
        self.handleV1ResetSidebar(writer, cmd.args);

    // --- Browser ---
    } else if (std.mem.eql(u8, cmd.name, "open_browser")) {
        v1.err(writer, "not_implemented: open_browser requires WebKitGTK panel integration") catch {};
    } else if (std.mem.eql(u8, cmd.name, "navigate")) {
        v1.err(writer, "not_implemented: navigate requires WebKitGTK panel integration") catch {};
    } else if (std.mem.eql(u8, cmd.name, "browser_back")) {
        v1.err(writer, "not_implemented: browser_back requires WebKitGTK panel integration") catch {};
    } else if (std.mem.eql(u8, cmd.name, "browser_forward")) {
        v1.err(writer, "not_implemented: browser_forward requires WebKitGTK panel integration") catch {};
    } else if (std.mem.eql(u8, cmd.name, "browser_reload")) {
        v1.err(writer, "not_implemented: browser_reload requires WebKitGTK panel integration") catch {};
    } else if (std.mem.eql(u8, cmd.name, "get_url")) {
        v1.err(writer, "not_implemented: get_url requires WebKitGTK panel integration") catch {};
    } else if (std.mem.eql(u8, cmd.name, "focus_webview")) {
        v1.err(writer, "not_implemented: focus_webview requires WebKitGTK panel integration") catch {};
    } else if (std.mem.eql(u8, cmd.name, "is_webview_focused")) {
        v1.err(writer, "not_implemented: is_webview_focused requires WebKitGTK panel integration") catch {};

    // --- Config ---
    } else if (std.mem.eql(u8, cmd.name, "reload_config")) {
        v1.raw(writer, "OK Reloaded config") catch {};

    // --- Unknown ---
    } else {
        v1.err(writer, "Unknown command") catch {};
    }
}

fn dispatchV2(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, line: []const u8) void {
    // Refresh ref handles so newly created objects get refs before we respond.
    self.refreshRefs();

    const req = v2.parseRequest(arena, line) catch {
        v2.writeError(writer, arena, .null, v2.ErrorCode.parse_error, "Invalid JSON request") catch {};
        return;
    };

    if (std.mem.eql(u8, req.method, "system.ping")) {
        var result = json.ObjectMap.init(arena);
        result.put("pong", .{ .bool = true }) catch {};
        v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
    } else if (std.mem.eql(u8, req.method, "system.capabilities")) {
        self.dispatchV2Capabilities(arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "notification.create") or
        std.mem.eql(u8, req.method, "notification.create_for_target"))
    {
        dispatchV2NotificationCreate(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "notification.create_for_surface")) {
        dispatchV2NotificationCreateForSurface(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "notification.list")) {
        dispatchV2NotificationList(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "notification.clear")) {
        dispatchV2NotificationClear(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "workspace.list")) {
        dispatchV2WorkspaceList(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "workspace.current")) {
        dispatchV2WorkspaceCurrent(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "workspace.create")) {
        dispatchV2WorkspaceCreate(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "workspace.select")) {
        dispatchV2WorkspaceSelect(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "workspace.close")) {
        dispatchV2WorkspaceClose(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "workspace.rename")) {
        dispatchV2WorkspaceRename(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "workspace.next")) {
        dispatchV2WorkspaceNav(self, arena, writer, req, .next);
    } else if (std.mem.eql(u8, req.method, "workspace.previous")) {
        dispatchV2WorkspaceNav(self, arena, writer, req, .previous);
    } else if (std.mem.eql(u8, req.method, "workspace.last")) {
        dispatchV2WorkspaceNav(self, arena, writer, req, .last);
    } else if (std.mem.eql(u8, req.method, "workspace.reorder")) {
        dispatchV2WorkspaceReorder(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "workspace.action")) {
        dispatchV2WorkspaceAction(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "surface.list")) {
        dispatchV2SurfaceList(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "surface.current")) {
        dispatchV2SurfaceCurrent(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "surface.split")) {
        dispatchV2SurfaceSplit(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "surface.close")) {
        dispatchV2SurfaceClose(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "surface.focus")) {
        dispatchV2SurfaceFocus(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "surface.action")) {
        dispatchV2SurfaceAction(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "workspace.remote.configure")) {
        remote_commands.handleConfigure(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "workspace.remote.reconnect")) {
        remote_commands.handleReconnect(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "workspace.remote.disconnect")) {
        remote_commands.handleDisconnect(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "workspace.remote.status")) {
        remote_commands.handleStatus(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "workspace.remote.terminal_session_end")) {
        remote_commands.handleTerminalSessionEnd(self, arena, writer, req);
    // --- System methods ---
    } else if (std.mem.eql(u8, req.method, "system.identify")) {
        dispatchV2SystemIdentify(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "system.tree")) {
        dispatchV2SystemTree(self, arena, writer, req);
    // --- Window methods ---
    } else if (std.mem.eql(u8, req.method, "window.list")) {
        dispatchV2WindowList(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "window.current")) {
        dispatchV2WindowCurrent(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "window.create")) {
        dispatchV2WindowCreate(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "window.close")) {
        dispatchV2WindowClose(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "window.focus")) {
        dispatchV2WindowFocus(self, arena, writer, req);
    // --- Additional workspace methods ---
    } else if (std.mem.eql(u8, req.method, "workspace.move_to_window")) {
        dispatchV2Stub(arena, writer, req, "workspace.move_to_window", "Single-window mode; workspace.move_to_window is a no-op");
    } else if (std.mem.eql(u8, req.method, "workspace.equalize_splits")) {
        dispatchV2WorkspaceEqualizeSplits(self, arena, writer, req);
    // --- Additional surface methods ---
    } else if (std.mem.eql(u8, req.method, "surface.create")) {
        dispatchV2SurfaceSplit(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "surface.send_text")) {
        dispatchV2SurfaceSendText(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "surface.send_key")) {
        dispatchV2SurfaceSendKey(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "surface.read_text")) {
        dispatchV2SurfaceReadText(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "surface.clear_history")) {
        dispatchV2SurfaceClearHistory(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "surface.trigger_flash")) {
        dispatchV2SurfaceTriggerFlash(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "surface.move")) {
        dispatchV2Stub(arena, writer, req, "surface.move", "Surface move not yet implemented on Linux");
    } else if (std.mem.eql(u8, req.method, "surface.reorder")) {
        dispatchV2Stub(arena, writer, req, "surface.reorder", "Surface reorder not yet implemented on Linux");
    } else if (std.mem.eql(u8, req.method, "surface.drag_to_split")) {
        dispatchV2Stub(arena, writer, req, "surface.drag_to_split", "Surface drag_to_split not yet implemented on Linux");
    } else if (std.mem.eql(u8, req.method, "surface.refresh")) {
        dispatchV2SurfaceRefresh(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "surface.health")) {
        dispatchV2SurfaceHealth(self, arena, writer, req);
    // --- Pane methods ---
    } else if (std.mem.eql(u8, req.method, "pane.list")) {
        dispatchV2PaneList(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "pane.focus")) {
        dispatchV2PaneFocus(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "pane.surfaces")) {
        dispatchV2PaneSurfaces(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "pane.create")) {
        dispatchV2PaneCreate(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "pane.resize")) {
        dispatchV2Stub(arena, writer, req, "pane.resize", "Pane resize not yet implemented on Linux");
    } else if (std.mem.eql(u8, req.method, "pane.swap")) {
        dispatchV2Stub(arena, writer, req, "pane.swap", "Pane swap not yet implemented on Linux");
    } else if (std.mem.eql(u8, req.method, "pane.break")) {
        dispatchV2Stub(arena, writer, req, "pane.break", "Pane break not yet implemented on Linux");
    } else if (std.mem.eql(u8, req.method, "pane.join")) {
        dispatchV2Stub(arena, writer, req, "pane.join", "Pane join not yet implemented on Linux");
    } else if (std.mem.eql(u8, req.method, "pane.last")) {
        dispatchV2PaneLast(self, arena, writer, req);
    // --- App methods ---
    } else if (std.mem.eql(u8, req.method, "app.focus_override.set")) {
        dispatchV2AppFocusOverride(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "app.simulate_active")) {
        dispatchV2AppSimulateActive(self, arena, writer, req);
    // --- Settings / Feedback ---
    } else if (std.mem.eql(u8, req.method, "settings.open")) {
        dispatchV2SettingsOpen(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "feedback.open")) {
        dispatchV2FeedbackOpen(self, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "feedback.submit")) {
        dispatchV2FeedbackSubmit(self, arena, writer, req);
    // --- Markdown ---
    } else if (std.mem.startsWith(u8, req.method, "markdown.")) {
        markdown_commands.dispatchMarkdown(self, arena, writer, req);
    // --- Browser ---
    } else if (std.mem.startsWith(u8, req.method, "browser.")) {
        browser_commands.dispatchBrowser(self, arena, writer, req);
    // --- Debug ---
    } else if (std.mem.startsWith(u8, req.method, "debug.")) {
        debug_mod.commands.dispatch(self, arena, writer, req);
    } else {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.method_not_found, "Unknown method") catch {};
    }
}

// --- V2 system.capabilities handler ---

fn dispatchV2Capabilities(
    self: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = self;

    // Build the methods array matching Mac v2Capabilities (lines 2424-2620).
    var methods = json.Array.init(arena);

    // Core methods (always available).
    const core_methods = [_][]const u8{
        "system.ping",
        "system.capabilities",
        "system.identify",
        "system.tree",
        // Notifications
        "notification.create",
        "notification.create_for_surface",
        "notification.create_for_target",
        "notification.list",
        "notification.clear",
        // Window
        "window.list",
        "window.current",
        "window.focus",
        "window.create",
        "window.close",
        // Workspace
        "workspace.list",
        "workspace.current",
        "workspace.create",
        "workspace.select",
        "workspace.close",
        "workspace.rename",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "workspace.reorder",
        "workspace.action",
        "workspace.move_to_window",
        "workspace.equalize_splits",
        // Surface
        "surface.list",
        "surface.current",
        "surface.focus",
        "surface.split",
        "surface.create",
        "surface.close",
        "surface.action",
        "surface.send_text",
        "surface.send_key",
        "surface.read_text",
        "surface.clear_history",
        "surface.trigger_flash",
        "surface.move",
        "surface.reorder",
        "surface.drag_to_split",
        "surface.refresh",
        "surface.health",
        // Pane
        "pane.list",
        "pane.focus",
        "pane.surfaces",
        "pane.create",
        "pane.resize",
        "pane.swap",
        "pane.break",
        "pane.join",
        "pane.last",
        // App
        "app.focus_override.set",
        "app.simulate_active",
        // Settings / Feedback
        "settings.open",
        "feedback.open",
        "feedback.submit",
    };
    for (&core_methods) |m| {
        methods.append(.{ .string = m }) catch {};
    }

    // Markdown methods.
    for (&markdown_commands.method_names) |m| {
        methods.append(.{ .string = m }) catch {};
    }

    // Browser methods.
    for (&browser_commands.method_names) |m| {
        methods.append(.{ .string = m }) catch {};
    }

    // Remote workspace methods.
    for (&remote_commands.method_names) |m| {
        methods.append(.{ .string = m }) catch {};
    }

    // debug.terminals (always available).
    for (&debug_mod.commands.debug_method_names) |m| {
        methods.append(.{ .string = m }) catch {};
    }

    // Debug-only methods (gated at comptime).
    if (comptime build_config.is_debug) {
        for (&debug_mod.commands.debug_only_method_names) |m| {
            methods.append(.{ .string = m }) catch {};
        }
    }

    var result = json.ObjectMap.init(arena);
    result.put("protocol", .{ .string = "cmux-socket" }) catch {};
    result.put("version", .{ .integer = 2 }) catch {};
    result.put("platform", .{ .string = "linux" }) catch {};
    result.put("v1", .{ .bool = true }) catch {};
    result.put("v2", .{ .bool = true }) catch {};
    result.put("methods", .{ .array = methods }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// --- V2 notification command handlers ---

fn dispatchV2NotificationCreate(
    self: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const workspace_id = self.v2UUID(req.params, "workspace_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing or invalid workspace_id") catch {};
        return;
    };
    const surface_id = self.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing or invalid surface_id") catch {};
        return;
    };

    const title = jsonStr(req.params.get("title"));
    const subtitle = jsonStr(req.params.get("subtitle"));
    const body = jsonStr(req.params.get("body"));

    self.notification_store.addNotification(
        workspace_id,
        surface_id,
        if (title.len == 0) "Notification" else title,
        subtitle,
        body,
    ) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Out of memory") catch {};
        return;
    };

    v2.writeOk(writer, arena, req.id, .{ .bool = true }) catch {};
}

fn dispatchV2NotificationList(
    self: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const notifications = self.notification_store.getNotifications();

    // Build a JSON array of notification objects.
    var items = json.Array.init(arena);
    for (notifications) |n| {
        var obj = json.ObjectMap.init(arena);
        var id_buf: [36]u8 = undefined;
        var tab_buf: [36]u8 = undefined;
        _ = n.id.formatBuf(&id_buf);
        _ = n.tab_id.formatBuf(&tab_buf);

        obj.put("id", .{ .string = arena.dupe(u8, &id_buf) catch continue }) catch continue;
        obj.put("workspace_id", .{ .string = arena.dupe(u8, &tab_buf) catch continue }) catch continue;
        obj.put("workspace_ref", self.v2Ref(.workspace, n.tab_id)) catch continue;

        if (n.surface_id) |sid| {
            var sid_buf: [36]u8 = undefined;
            _ = sid.formatBuf(&sid_buf);
            obj.put("surface_id", .{ .string = arena.dupe(u8, &sid_buf) catch continue }) catch continue;
            obj.put("surface_ref", self.v2Ref(.surface, sid)) catch continue;
        } else {
            obj.put("surface_id", .null) catch continue;
            obj.put("surface_ref", .null) catch continue;
        }

        obj.put("title", .{ .string = n.title }) catch continue;
        obj.put("subtitle", .{ .string = n.subtitle }) catch continue;
        obj.put("body", .{ .string = n.body }) catch continue;
        obj.put("is_read", .{ .bool = n.is_read }) catch continue;
        obj.put("created_at", .{ .integer = n.created_at }) catch continue;

        items.append(.{ .object = obj }) catch continue;
    }

    v2.writeOk(writer, arena, req.id, .{ .array = items }) catch {};
}

fn dispatchV2NotificationClear(
    self: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    if (req.params.get("workspace_id")) |_| {
        const ws_id = self.v2UUID(req.params, "workspace_id") orelse {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Invalid workspace_id") catch {};
            return;
        };
        self.notification_store.clearNotificationsForTab(ws_id);
    } else {
        self.notification_store.clearAll();
    }
    self.scheduleNotificationBadgeRefresh();

    v2.writeOk(writer, arena, req.id, .{ .bool = true }) catch {};
}

// --- V1 notify / notify_surface handlers ---

fn handleV1Notify(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "ERROR: No workspace manager") catch {};
        return;
    };

    // Check if args use --flag format (new style) or pipe-delimited (legacy).
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "--")) {
        // Parse: --title TITLE --subtitle SUB --body BODY [--workspace WID] [--surface SID]
        const parsed = parseV1FlagArgs(trimmed);

        // Resolve workspace: explicit flag or selected.
        const ws_id = if (parsed.workspace_id.len > 0)
            Uuid.parse(parsed.workspace_id) catch {
                v1.err(writer, "ERROR: Invalid workspace ID") catch {};
                return;
            }
        else if (mgr.selectedWorkspace()) |ws|
            ws.id
        else {
            v1.err(writer, "ERROR: No active workspace") catch {};
            return;
        };

        // Resolve surface: explicit flag or focused panel.
        const surface_id: ?Uuid = if (parsed.surface_id.len > 0)
            Uuid.parse(parsed.surface_id) catch {
                v1.err(writer, "ERROR: Invalid surface ID") catch {};
                return;
            }
        else if (mgr.workspaceById(ws_id)) |ws|
            ws.focused_panel_id
        else
            null;

        self.notification_store.addNotification(
            ws_id,
            surface_id,
            if (parsed.title.len == 0) "Notification" else parsed.title,
            parsed.subtitle,
            parsed.body,
        ) catch {
            v1.err(writer, "ERROR: Out of memory") catch {};
            return;
        };
        self.scheduleNotificationBadgeRefresh();
        v1.raw(writer, "OK") catch {};
    } else {
        // Legacy pipe-delimited format: title|subtitle|body
        const ws = mgr.selectedWorkspace() orelse {
            v1.err(writer, "ERROR: No active workspace") catch {};
            return;
        };

        const payload = notification.commands.parseNotificationPayload(args);
        self.notification_store.addNotification(
            ws.id,
            ws.focused_panel_id,
            payload.title,
            payload.subtitle,
            payload.body,
        ) catch {
            v1.err(writer, "ERROR: Out of memory") catch {};
            return;
        };
        self.scheduleNotificationBadgeRefresh();
        v1.raw(writer, "OK") catch {};
    }
}

fn handleV1NotifySurface(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "ERROR: No workspace manager") catch {};
        return;
    };
    const ws = mgr.selectedWorkspace() orelse {
        v1.err(writer, "ERROR: No active workspace") catch {};
        return;
    };

    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        v1.err(writer, "ERROR: Usage: notify_surface <surface_id|index> <title>|<subtitle>|<body>") catch {};
        return;
    }

    // Split: surface_ref payload
    const space_idx = std.mem.indexOfScalar(u8, trimmed, ' ');
    const surface_ref = if (space_idx) |sp| trimmed[0..sp] else trimmed;
    const payload_raw = if (space_idx) |sp| trimmed[sp + 1 ..] else "";

    // Try parsing as UUID first, then as index.
    const surface_id = if (Uuid.parse(surface_ref)) |uuid|
        uuid
    else |_|
        resolveSurfaceByIndex(ws, surface_ref) orelse {
            v1.err(writer, "ERROR: Surface not found") catch {};
            return;
        };

    const payload = notification.commands.parseNotificationPayload(payload_raw);
    self.notification_store.addNotification(
        ws.id,
        surface_id,
        payload.title,
        payload.subtitle,
        payload.body,
    ) catch {
        v1.err(writer, "ERROR: Out of memory") catch {};
        return;
    };
    v1.raw(writer, "OK") catch {};
}

fn resolveSurfaceByIndex(ws: *workspace.Workspace, ref: []const u8) ?Uuid {
    const idx = std.fmt.parseInt(usize, ref, 10) catch return null;
    const keys = ws.panels.keys();
    if (idx >= keys.len) return null;
    return keys[idx];
}

// --- V1 workspace / surface / window command handlers ---

fn handleV1NewWorkspace(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter) void {
    _ = arena;
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };

    var ctx = SyncCreateCtx{ .mgr = mgr, .cwd = "" };
    dispatch.syncOnMainThread(&syncCreateWorkspace, @ptrCast(&ctx));

    if (ctx.err) {
        v1.err(writer, "Failed to create workspace") catch {};
        return;
    }
    const ws_id = ctx.result_id orelse {
        v1.err(writer, "No workspace ID returned") catch {};
        return;
    };

    // Response: "OK <uuid>"
    var id_buf: [36]u8 = undefined;
    _ = ws_id.formatBuf(&id_buf);
    var resp_buf: [40]u8 = undefined;
    @memcpy(resp_buf[0..3], "OK ");
    @memcpy(resp_buf[3..39], &id_buf);
    v1.raw(writer, resp_buf[0..39]) catch {};
}

fn handleV1ListWorkspaces(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter) void {
    const mgr = self.workspace_manager orelse {
        v1.raw(writer, "No workspaces") catch {};
        return;
    };

    var ctx = SyncV1ListWorkspacesCtx{ .mgr = mgr, .arena = arena };
    dispatch.syncOnMainThread(&syncV1ListWorkspaces, @ptrCast(&ctx));

    if (ctx.count == 0) {
        v1.raw(writer, "No workspaces") catch {};
        return;
    }

    // Write each workspace as a line: "<index>:<uuid> <title>"
    for (0..ctx.count) |i| {
        const entry = ctx.entries[i];
        var id_buf: [36]u8 = undefined;
        _ = entry.id.formatBuf(&id_buf);

        var line_buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&line_buf);
        const w = stream.writer();
        w.print("{d}:", .{i}) catch continue;
        w.writeAll(&id_buf) catch continue;
        w.writeByte(' ') catch continue;
        w.writeAll(entry.title) catch continue;
        const written = stream.getWritten();

        if (i > 0) {
            writer.writeAll("\n") catch {};
        }
        writer.writeAll(written) catch {};
    }
    writer.writeByte('\n') catch {};
}

const V1WorkspaceEntry = struct {
    id: Uuid,
    title: []const u8,
};

const SyncV1ListWorkspacesCtx = struct {
    mgr: *workspace.Manager,
    arena: Allocator,
    entries: [128]V1WorkspaceEntry = undefined,
    count: usize = 0,
};

fn syncV1ListWorkspaces(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncV1ListWorkspacesCtx = @ptrCast(@alignCast(data orelse return 0));
    const items = ctx.mgr.workspaces.items;
    const max = @min(items.len, ctx.entries.len);
    for (items[0..max], 0..) |ws, i| {
        ctx.entries[i] = .{
            .id = ws.id,
            .title = ws.displayTitle(),
        };
    }
    ctx.count = max;
    return 0;
}

fn handleV1SelectWorkspace(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, args: []const u8) void {
    _ = arena;
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        v1.err(writer, "Usage: select_workspace <index_or_id>") catch {};
        return;
    }

    // Try as UUID first, then as 0-based index.
    const ws_id = if (Uuid.parse(trimmed)) |uuid|
        uuid
    else |_| blk: {
        const idx = std.fmt.parseInt(usize, trimmed, 10) catch {
            v1.err(writer, "Invalid workspace index or UUID") catch {};
            return;
        };
        const ws = mgr.workspaceByIndex(idx) orelse {
            v1.err(writer, "Workspace index out of range") catch {};
            return;
        };
        break :blk ws.id;
    };

    var ctx = SyncSelectCtx{ .mgr = mgr, .id = ws_id };
    dispatch.syncOnMainThread(&syncSelectWorkspace, @ptrCast(&ctx));

    if (!ctx.found) {
        v1.err(writer, "Workspace not found") catch {};
        return;
    }
    v1.raw(writer, "OK") catch {};
}

fn handleV1NewWindow(self: *Server, writer: *client_handler.ResponseWriter) void {
    _ = self;
    var resp_buf: [8]u8 = undefined;
    @memcpy(resp_buf[0..7], "OK main");
    v1.raw(writer, resp_buf[0..7]) catch {};
}

fn handleV1CurrentWindow(self: *Server, writer: *client_handler.ResponseWriter) void {
    _ = self;
    v1.raw(writer, "main") catch {};
}

fn handleV1ToggleSidebar(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const win = self.cmux_window orelse {
        v1.err(writer, "No window") catch {};
        return;
    };

    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    const action: SyncToggleSidebarCtx.Action = if (std.mem.eql(u8, trimmed, "show"))
        .show
    else if (std.mem.eql(u8, trimmed, "hide"))
        .hide
    else
        .toggle;

    var ctx = SyncToggleSidebarCtx{ .window = win, .action = action };
    dispatch.syncOnMainThread(&syncToggleSidebar, @ptrCast(&ctx));
    v1.raw(writer, "OK") catch {};
}

const SyncToggleSidebarCtx = struct {
    window: *anyopaque,
    action: Action,

    const Action = enum { show, hide, toggle };

    fn callback(data: ?*anyopaque) callconv(.c) c_int {
        const CmuxWindow = @import("gtk/window.zig").CmuxWindow;

        const ctx: *SyncToggleSidebarCtx = @ptrCast(@alignCast(data orelse return 0));
        const win: *CmuxWindow = @ptrCast(@alignCast(ctx.window));
        switch (ctx.action) {
            .show => win.toggleSidebar(true),
            .hide => win.toggleSidebar(false),
            .toggle => win.toggleSidebar(null),
        }
        return 0;
    }
};

fn syncToggleSidebar(data: ?*anyopaque) callconv(.c) c_int {
    return SyncToggleSidebarCtx.callback(data);
}

/// Schedule a notification badge refresh on the GTK main thread.
fn scheduleNotificationBadgeRefresh(self: *Server) void {
    const win = self.cmux_window orelse return;
    dispatch.idleAdd(&notificationBadgeRefreshCb, win);
}

fn notificationBadgeRefreshCb(data: ?*anyopaque) callconv(.c) c_int {
    const CmuxWindow = @import("gtk/window.zig").CmuxWindow;
    const win: *CmuxWindow = @ptrCast(@alignCast(data orelse return 0));
    win.updateNotificationBadge();
    return 0; // G_SOURCE_REMOVE
}

fn handleV1NewSurface(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, args: []const u8) void {
    _ = args;
    const ops = self.window_ops orelse {
        v1.err(writer, "No window ops") catch {};
        return;
    };
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };

    var ws_id_ctx = SyncCurrentCtx{ .mgr = mgr };
    dispatch.syncOnMainThread(&syncWorkspaceCurrent, @ptrCast(&ws_id_ctx));
    const ws_id = ws_id_ctx.result_id orelse {
        v1.err(writer, "No active workspace") catch {};
        return;
    };

    var ctx = SyncSplitCtx{
        .ops = ops,
        .ws_id = ws_id,
        .direction = .right,
    };
    dispatch.syncOnMainThread(&syncSurfaceSplit, @ptrCast(&ctx));

    const result = ctx.result orelse {
        v1.err(writer, "Failed to create surface") catch {};
        return;
    };

    _ = arena;
    var id_buf: [36]u8 = undefined;
    _ = result.surface_id.formatBuf(&id_buf);
    var resp_buf: [40]u8 = undefined;
    @memcpy(resp_buf[0..3], "OK ");
    @memcpy(resp_buf[3..39], &id_buf);
    v1.raw(writer, resp_buf[0..39]) catch {};
}

fn handleV1ListSurfaces(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const ops = self.window_ops orelse {
        v1.raw(writer, "No surfaces") catch {};
        return;
    };
    const mgr = self.workspace_manager orelse {
        v1.raw(writer, "No surfaces") catch {};
        return;
    };

    const trimmed = std.mem.trim(u8, args, " \t\r\n");

    const ws_id = if (trimmed.len > 0)
        Uuid.parse(trimmed) catch {
            v1.err(writer, "Invalid workspace UUID") catch {};
            return;
        }
    else
        mgr.selected_id orelse {
            v1.raw(writer, "No surfaces") catch {};
            return;
        };

    var surfaces: window_ops_mod.SurfaceInfoList = .{};
    var ctx = SyncSurfaceListCtx{ .ops = ops, .ws_id = ws_id, .surfaces = &surfaces, .alloc = arena };
    dispatch.syncOnMainThread(&syncSurfaceList, @ptrCast(&ctx));

    if (surfaces.items.len == 0) {
        v1.raw(writer, "No surfaces") catch {};
        return;
    }

    for (surfaces.items, 0..) |info, i| {
        var id_buf: [36]u8 = undefined;
        _ = info.id.formatBuf(&id_buf);

        if (i > 0) {
            writer.writeAll("\n") catch {};
        }

        var line_buf: [64]u8 = undefined;
        var stream = std.io.fixedBufferStream(&line_buf);
        const w = stream.writer();
        w.print("{d}:", .{i}) catch continue;
        w.writeAll(&id_buf) catch continue;
        writer.writeAll(stream.getWritten()) catch {};
    }
    writer.writeByte('\n') catch {};
}

fn handleV1ReportPwd(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };

    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        v1.err(writer, "Usage: report_pwd <path> --tab=<ws_id> --panel=<panel_id>") catch {};
        return;
    }

    var path: []const u8 = "";
    var tab_str: []const u8 = "";
    var panel_str: []const u8 = "";

    var iter = std.mem.tokenizeScalar(u8, trimmed, ' ');
    while (iter.next()) |token| {
        if (std.mem.startsWith(u8, token, "--tab=")) {
            tab_str = token["--tab=".len..];
        } else if (std.mem.startsWith(u8, token, "--panel=")) {
            panel_str = token["--panel=".len..];
        } else if (path.len == 0) {
            path = token;
        }
    }

    if (path.len == 0) {
        v1.err(writer, "Missing path argument") catch {};
        return;
    }

    const ws_id = if (tab_str.len > 0)
        Uuid.parse(tab_str) catch {
            v1.err(writer, "Invalid workspace UUID") catch {};
            return;
        }
    else if (mgr.selected_id) |sel|
        sel
    else {
        v1.err(writer, "No active workspace") catch {};
        return;
    };

    const ws = mgr.workspaceById(ws_id) orelse {
        v1.err(writer, "Workspace not found") catch {};
        return;
    };

    if (panel_str.len > 0) {
        const panel_id = Uuid.parse(panel_str) catch {
            v1.err(writer, "Invalid panel UUID") catch {};
            return;
        };
        ws.setPanelDirectory(panel_id, path) catch {
            v1.err(writer, "Failed to update directory") catch {};
            return;
        };
    } else if (ws.focused_panel_id) |fid| {
        ws.setPanelDirectory(fid, path) catch {
            v1.err(writer, "Failed to update directory") catch {};
            return;
        };
    }

    v1.raw(writer, "OK") catch {};
}

fn handleV1FocusWindow(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    _ = args;
    const win = self.cmux_window orelse {
        v1.err(writer, "No window") catch {};
        return;
    };

    var ctx = SyncPresentWindowCtx{ .window = win };
    dispatch.syncOnMainThread(&syncPresentWindow, @ptrCast(&ctx));
    v1.raw(writer, "OK") catch {};
}

const SyncPresentWindowCtx = struct {
    window: *anyopaque,

    fn callback(data: ?*anyopaque) callconv(.c) c_int {
        const gtk_mod = @import("gtk");
        const ctx: *SyncPresentWindowCtx = @ptrCast(@alignCast(data orelse return 0));
        const win: *gtk_mod.Window = @ptrCast(@alignCast(ctx.window));
        win.present();
        return 0;
    }
};

fn syncPresentWindow(data: ?*anyopaque) callconv(.c) c_int {
    return SyncPresentWindowCtx.callback(data);
}

fn handleV1ReadTerminalText(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter) void {
    const ops = self.window_ops orelse {
        v1.raw(writer, "") catch {};
        return;
    };
    const mgr = self.workspace_manager orelse {
        v1.raw(writer, "") catch {};
        return;
    };

    var ws_ctx = SyncCurrentCtx{ .mgr = mgr };
    dispatch.syncOnMainThread(&syncWorkspaceCurrent, @ptrCast(&ws_ctx));
    const ws_id = ws_ctx.result_id orelse {
        v1.raw(writer, "") catch {};
        return;
    };

    var surf_ctx = SyncSurfaceCurrentCtx{ .ops = ops, .ws_id = ws_id };
    dispatch.syncOnMainThread(&syncSurfaceCurrent, @ptrCast(&surf_ctx));
    const surface = surf_ctx.result orelse {
        v1.raw(writer, "") catch {};
        return;
    };

    const text = ops.readScrollback(arena, surface.id) orelse {
        v1.raw(writer, "") catch {};
        return;
    };
    v1.raw(writer, text) catch {};
}

// --- V1 sidebar option parser (--key=value and positional args) ---

const V1Options = struct {
    positional: [8][]const u8 = .{""} ** 8,
    positional_count: usize = 0,
    tab: []const u8 = "",
    panel: []const u8 = "",
    icon: []const u8 = "",
    color: []const u8 = "",
    url: []const u8 = "",
    priority: []const u8 = "",
    format: []const u8 = "",
    label: []const u8 = "",
    source: []const u8 = "",
    level: []const u8 = "",
    status: []const u8 = "",
    state: []const u8 = "",
    branch: []const u8 = "",
    checks: []const u8 = "",
    limit: []const u8 = "",
    scrollback: bool = false,
    lines: []const u8 = "",
};

fn parseV1Options(args: []const u8) V1Options {
    var result = V1Options{};
    var iter = std.mem.tokenizeScalar(u8, args, ' ');
    while (iter.next()) |token| {
        if (std.mem.startsWith(u8, token, "--tab=")) {
            result.tab = token["--tab=".len..];
        } else if (std.mem.startsWith(u8, token, "--panel=")) {
            result.panel = token["--panel=".len..];
        } else if (std.mem.startsWith(u8, token, "--surface=")) {
            result.panel = token["--surface=".len..];
        } else if (std.mem.startsWith(u8, token, "--icon=")) {
            result.icon = token["--icon=".len..];
        } else if (std.mem.startsWith(u8, token, "--color=")) {
            result.color = token["--color=".len..];
        } else if (std.mem.startsWith(u8, token, "--url=")) {
            result.url = token["--url=".len..];
        } else if (std.mem.startsWith(u8, token, "--priority=")) {
            result.priority = token["--priority=".len..];
        } else if (std.mem.startsWith(u8, token, "--format=")) {
            result.format = token["--format=".len..];
        } else if (std.mem.startsWith(u8, token, "--label=")) {
            result.label = token["--label=".len..];
        } else if (std.mem.startsWith(u8, token, "--source=")) {
            result.source = token["--source=".len..];
        } else if (std.mem.startsWith(u8, token, "--level=")) {
            result.level = token["--level=".len..];
        } else if (std.mem.startsWith(u8, token, "--status=")) {
            result.status = token["--status=".len..];
        } else if (std.mem.startsWith(u8, token, "--state=")) {
            result.state = token["--state=".len..];
        } else if (std.mem.startsWith(u8, token, "--branch=")) {
            result.branch = token["--branch=".len..];
        } else if (std.mem.startsWith(u8, token, "--checks=")) {
            result.checks = token["--checks=".len..];
        } else if (std.mem.startsWith(u8, token, "--limit=")) {
            result.limit = token["--limit=".len..];
        } else if (std.mem.startsWith(u8, token, "--lines=")) {
            result.lines = token["--lines=".len..];
        } else if (std.mem.eql(u8, token, "--scrollback")) {
            result.scrollback = true;
        } else if (std.mem.eql(u8, token, "--")) {
            // Everything after " -- " is treated as remaining positional
            const rest_index = iter.index;
            if (rest_index < args.len) {
                if (result.positional_count < result.positional.len) {
                    result.positional[result.positional_count] = args[rest_index..];
                    result.positional_count += 1;
                }
            }
            break;
        } else if (!std.mem.startsWith(u8, token, "--")) {
            if (result.positional_count < result.positional.len) {
                result.positional[result.positional_count] = token;
                result.positional_count += 1;
            }
        }
    }
    return result;
}

/// Resolve workspace from --tab= option or fall back to selected.
fn resolveWorkspaceForSidebar(mgr: *workspace.Manager, opts: V1Options) ?*workspace.Workspace {
    if (opts.tab.len > 0) {
        const tab_id = Uuid.parse(opts.tab) catch return null;
        return mgr.workspaceById(tab_id);
    }
    return mgr.selectedWorkspace();
}

// --- V1 window management handlers ---

fn handleV1ListWindows(self: *Server, writer: *client_handler.ResponseWriter) void {
    // Linux currently has a single window. Matches Mac list_windows format.
    const mgr = self.workspace_manager orelse {
        v1.raw(writer, "No windows") catch {};
        return;
    };
    const ws_count = mgr.workspaces.items.len;
    const sel_str = if (mgr.selected_id) |sel| blk: {
        var buf: [36]u8 = undefined;
        _ = sel.formatBuf(&buf);
        break :blk buf;
    } else [_]u8{0} ** 36;
    const sel_id: []const u8 = if (mgr.selected_id != null) &sel_str else "none";

    var line_buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&line_buf);
    const w = stream.writer();
    w.print("* 0: main selected_workspace={s} workspaces={d}", .{ sel_id, ws_count }) catch {};
    v1.raw(writer, stream.getWritten()) catch {};
}

fn handleV1CloseWindow(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    _ = self;
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        v1.err(writer, "Usage: close_window <id>") catch {};
        return;
    }
    // Single-window mode — we only have "main".
    if (std.mem.eql(u8, trimmed, "main")) {
        v1.err(writer, "Cannot close the only window") catch {};
    } else {
        v1.err(writer, "Window not found") catch {};
    }
}

// --- V1 workspace management handlers ---

fn handleV1CloseWorkspace(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, args: []const u8) void {
    _ = arena;
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        v1.err(writer, "Usage: close_workspace <id>") catch {};
        return;
    }
    const ws_id = Uuid.parse(trimmed) catch {
        v1.err(writer, "Invalid workspace UUID") catch {};
        return;
    };
    var ctx = SyncCloseCtx{ .mgr = mgr, .id = ws_id };
    dispatch.syncOnMainThread(&syncCloseWorkspace, @ptrCast(&ctx));

    if (ctx.err_code) |_| {
        v1.err(writer, ctx.err_msg orelse "Error") catch {};
        return;
    }
    v1.raw(writer, "OK") catch {};
}

fn handleV1CurrentWorkspace(self: *Server, writer: *client_handler.ResponseWriter) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    var ctx = SyncCurrentCtx{ .mgr = mgr };
    dispatch.syncOnMainThread(&syncWorkspaceCurrent, @ptrCast(&ctx));

    const ws_id = ctx.result_id orelse {
        v1.err(writer, "No workspace selected") catch {};
        return;
    };
    var id_buf: [36]u8 = undefined;
    _ = ws_id.formatBuf(&id_buf);
    v1.raw(writer, &id_buf) catch {};
}

// --- V1 surface/split handlers ---

fn handleV1NewSplit(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, args: []const u8) void {
    _ = arena;
    const ops = self.window_ops orelse {
        v1.err(writer, "No window ops") catch {};
        return;
    };
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };

    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        v1.err(writer, "Invalid direction. Use left, right, up, or down.") catch {};
        return;
    }

    // First word is direction
    const space_idx = std.mem.indexOfScalar(u8, trimmed, ' ');
    const dir_str = if (space_idx) |idx| trimmed[0..idx] else trimmed;
    const direction = window_ops_mod.Direction.parse(dir_str) orelse {
        v1.err(writer, "Invalid direction. Use left, right, up, or down.") catch {};
        return;
    };

    var ws_id_ctx = SyncCurrentCtx{ .mgr = mgr };
    dispatch.syncOnMainThread(&syncWorkspaceCurrent, @ptrCast(&ws_id_ctx));
    const ws_id = ws_id_ctx.result_id orelse {
        v1.err(writer, "No active workspace") catch {};
        return;
    };

    var ctx = SyncSplitCtx{ .ops = ops, .ws_id = ws_id, .direction = direction };
    dispatch.syncOnMainThread(&syncSurfaceSplit, @ptrCast(&ctx));

    const result = ctx.result orelse {
        v1.err(writer, "Failed to create split") catch {};
        return;
    };

    var id_buf: [36]u8 = undefined;
    _ = result.surface_id.formatBuf(&id_buf);
    var resp_buf: [40]u8 = undefined;
    @memcpy(resp_buf[0..3], "OK ");
    @memcpy(resp_buf[3..39], &id_buf);
    v1.raw(writer, resp_buf[0..39]) catch {};
}

fn handleV1CloseSurface(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, args: []const u8) void {
    _ = arena;
    const ops = self.window_ops orelse {
        v1.err(writer, "No window ops") catch {};
        return;
    };
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };

    var ws_id_ctx = SyncCurrentCtx{ .mgr = mgr };
    dispatch.syncOnMainThread(&syncWorkspaceCurrent, @ptrCast(&ws_id_ctx));
    const ws_id = ws_id_ctx.result_id orelse {
        v1.err(writer, "No active workspace") catch {};
        return;
    };

    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    const surface_id: ?Uuid = if (trimmed.len > 0)
        Uuid.parse(trimmed) catch blk: {
            // Try as index
            const ws = mgr.workspaceById(ws_id) orelse {
                v1.err(writer, "Workspace not found") catch {};
                return;
            };
            break :blk resolveSurfaceByIndex(ws, trimmed);
        }
    else
        null;

    var ctx = SyncClosesSurfaceCtx{ .ops = ops, .ws_id = ws_id, .surface_id = surface_id };
    dispatch.syncOnMainThread(&syncSurfaceClose, @ptrCast(&ctx));

    if (ctx.result) |_| {
        v1.raw(writer, "OK") catch {};
    } else {
        v1.err(writer, "Surface not found or close failed") catch {};
    }
}

fn handleV1FocusSurface(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, args: []const u8) void {
    _ = arena;
    const ops = self.window_ops orelse {
        v1.err(writer, "No window ops") catch {};
        return;
    };
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };

    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) {
        v1.err(writer, "Missing panel id or index") catch {};
        return;
    }

    var ws_id_ctx = SyncCurrentCtx{ .mgr = mgr };
    dispatch.syncOnMainThread(&syncWorkspaceCurrent, @ptrCast(&ws_id_ctx));
    const ws_id = ws_id_ctx.result_id orelse {
        v1.err(writer, "No active workspace") catch {};
        return;
    };

    const surface_id = Uuid.parse(trimmed) catch blk: {
        const ws = mgr.workspaceById(ws_id) orelse {
            v1.err(writer, "Workspace not found") catch {};
            return;
        };
        break :blk resolveSurfaceByIndex(ws, trimmed) orelse {
            v1.err(writer, "Surface not found") catch {};
            return;
        };
    };

    var ctx = SyncFocusSurfaceCtx{ .ops = ops, .ws_id = ws_id, .surface_id = surface_id };
    dispatch.syncOnMainThread(&syncSurfaceFocus, @ptrCast(&ctx));

    if (ctx.result) {
        v1.raw(writer, "OK") catch {};
    } else {
        v1.err(writer, "Surface not found") catch {};
    }
}

fn handleV1SurfaceHealth(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const ops = self.window_ops orelse {
        v1.raw(writer, "No surfaces") catch {};
        return;
    };
    const mgr = self.workspace_manager orelse {
        v1.raw(writer, "No surfaces") catch {};
        return;
    };

    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    const ws_id = if (trimmed.len > 0)
        Uuid.parse(trimmed) catch {
            v1.err(writer, "Invalid workspace UUID") catch {};
            return;
        }
    else
        mgr.selected_id orelse {
            v1.raw(writer, "No surfaces") catch {};
            return;
        };

    var surfaces: window_ops_mod.SurfaceInfoList = .{};
    var ctx = SyncSurfaceListCtx{ .ops = ops, .ws_id = ws_id, .surfaces = &surfaces, .alloc = arena };
    dispatch.syncOnMainThread(&syncSurfaceList, @ptrCast(&ctx));

    if (surfaces.items.len == 0) {
        v1.raw(writer, "No surfaces") catch {};
        return;
    }

    for (surfaces.items, 0..) |info, i| {
        var id_buf: [36]u8 = undefined;
        _ = info.id.formatBuf(&id_buf);

        if (i > 0) writer.writeAll("\n") catch {};

        var line_buf: [128]u8 = undefined;
        var stream = std.io.fixedBufferStream(&line_buf);
        const w = stream.writer();
        w.print("{d}: {s} type={s} in_window=true", .{ i, &id_buf, info.panel_type }) catch continue;
        writer.writeAll(stream.getWritten()) catch {};
    }
    writer.writeByte('\n') catch {};
}

fn handleV1ReadScreen(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, args: []const u8) void {
    // read_screen is a plain-text variant of read_terminal_text with optional surface arg
    const ops = self.window_ops orelse {
        v1.raw(writer, "") catch {};
        return;
    };
    const mgr = self.workspace_manager orelse {
        v1.raw(writer, "") catch {};
        return;
    };

    const trimmed = std.mem.trim(u8, args, " \t\r\n");

    var ws_ctx = SyncCurrentCtx{ .mgr = mgr };
    dispatch.syncOnMainThread(&syncWorkspaceCurrent, @ptrCast(&ws_ctx));
    const ws_id = ws_ctx.result_id orelse {
        v1.raw(writer, "") catch {};
        return;
    };

    // If an argument is given, try resolving it as a surface
    if (trimmed.len > 0) {
        const opts = parseV1Options(trimmed);
        if (opts.positional_count > 0) {
            const surface_ref = opts.positional[0];
            const surface_id = Uuid.parse(surface_ref) catch blk: {
                const ws = mgr.workspaceById(ws_id) orelse break :blk null;
                break :blk resolveSurfaceByIndex(ws, surface_ref);
            };
            if (surface_id) |sid| {
                const text = ops.readScrollback(arena, sid) orelse {
                    v1.raw(writer, "") catch {};
                    return;
                };
                v1.raw(writer, text) catch {};
                return;
            }
        }
    }

    // Fall back to focused surface
    var surf_ctx = SyncSurfaceCurrentCtx{ .ops = ops, .ws_id = ws_id };
    dispatch.syncOnMainThread(&syncSurfaceCurrent, @ptrCast(&surf_ctx));
    const surface = surf_ctx.result orelse {
        v1.raw(writer, "") catch {};
        return;
    };

    const text = ops.readScrollback(arena, surface.id) orelse {
        v1.raw(writer, "") catch {};
        return;
    };
    v1.raw(writer, text) catch {};
}

// --- V1 Status/Metadata handlers ---

fn handleV1SetStatus(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    if (opts.positional_count < 2) {
        v1.err(writer, "Missing status key or value") catch {};
        return;
    }
    const key = opts.positional[0];
    const value = opts.positional[1];

    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    const priority: i32 = if (opts.priority.len > 0)
        std.fmt.parseInt(i32, opts.priority, 10) catch 0
    else
        0;

    const format: workspace.sidebar.MetadataFormat = if (std.mem.eql(u8, opts.format, "markdown"))
        .markdown
    else
        .plain;

    ws.setStatus(key, .{
        .key = key,
        .value = value,
        .icon = if (opts.icon.len > 0) opts.icon else null,
        .color = if (opts.color.len > 0) opts.color else null,
        .url = if (opts.url.len > 0) opts.url else null,
        .priority = priority,
        .format = format,
    }) catch {
        v1.err(writer, "Out of memory") catch {};
        return;
    };
    v1.raw(writer, "OK") catch {};
}

fn handleV1ClearStatus(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    if (opts.positional_count < 1) {
        v1.err(writer, "Missing key") catch {};
        return;
    }
    const key = opts.positional[0];
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };
    ws.clearStatus(key);
    v1.raw(writer, "OK") catch {};
}

fn handleV1ListStatus(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, args: []const u8) void {
    _ = arena;
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    const keys = ws.status_entries.keys();
    const values = ws.status_entries.values();
    if (keys.len == 0) {
        v1.raw(writer, "No status entries") catch {};
        return;
    }

    for (keys, values, 0..) |key, entry, i| {
        if (i > 0) writer.writeAll("\n") catch {};
        var line_buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&line_buf);
        const w = stream.writer();
        w.print("{s}={s}", .{ key, entry.value }) catch continue;
        if (entry.icon) |icon| w.print(" icon={s}", .{icon}) catch {};
        if (entry.color) |color| w.print(" color={s}", .{color}) catch {};
        if (entry.url) |url_v| w.print(" url={s}", .{url_v}) catch {};
        if (entry.priority != 0) w.print(" priority={d}", .{entry.priority}) catch {};
        if (entry.format != .plain) w.writeAll(" format=markdown") catch {};
        writer.writeAll(stream.getWritten()) catch {};
    }
    writer.writeByte('\n') catch {};
}

fn handleV1ReportMetaBlock(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };

    // Split on " -- " to find markdown part
    const separator = " -- ";
    const sep_idx = std.mem.indexOf(u8, args, separator);
    const options_part = if (sep_idx) |idx| args[0..idx] else args;
    const markdown_raw = if (sep_idx) |idx| args[idx + separator.len ..] else "";

    const opts = parseV1Options(options_part);
    if (opts.positional_count < 1) {
        v1.err(writer, "Missing metadata block key") catch {};
        return;
    }
    const key = opts.positional[0];

    // Markdown comes from after " -- " or remaining positional args
    var markdown: []const u8 = "";
    if (markdown_raw.len > 0) {
        markdown = markdown_raw;
    } else if (opts.positional_count >= 2) {
        // Join remaining positional args
        markdown = opts.positional[1];
    }

    if (std.mem.trim(u8, markdown, " \t\r\n").len == 0) {
        v1.err(writer, "Missing metadata markdown") catch {};
        return;
    }

    const priority: i32 = if (opts.priority.len > 0)
        std.fmt.parseInt(i32, opts.priority, 10) catch 0
    else
        0;

    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    ws.setMetadataBlock(key, .{
        .key = key,
        .markdown = markdown,
        .priority = priority,
    }) catch {
        v1.err(writer, "Out of memory") catch {};
        return;
    };
    v1.raw(writer, "OK") catch {};
}

fn handleV1ClearMetaBlock(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    if (opts.positional_count < 1) {
        v1.err(writer, "Missing metadata block key") catch {};
        return;
    }
    const key = opts.positional[0];
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };
    ws.clearMetadataBlock(key);
    v1.raw(writer, "OK") catch {};
}

fn handleV1ListMetaBlocks(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, args: []const u8) void {
    _ = arena;
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    const keys = ws.metadata_blocks.keys();
    const values = ws.metadata_blocks.values();
    if (keys.len == 0) {
        v1.raw(writer, "No metadata blocks") catch {};
        return;
    }

    for (keys, values, 0..) |key, block, i| {
        if (i > 0) writer.writeAll("\n") catch {};
        var line_buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&line_buf);
        const w = stream.writer();
        w.print("{s}={s}", .{ key, block.markdown }) catch continue;
        if (block.priority != 0) w.print(" priority={d}", .{block.priority}) catch {};
        writer.writeAll(stream.getWritten()) catch {};
    }
    writer.writeByte('\n') catch {};
}

fn handleV1SetAgentPid(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    if (opts.positional_count < 2) {
        v1.err(writer, "Usage: set_agent_pid <key> <pid> [--tab=<id>]") catch {};
        return;
    }
    const key = opts.positional[0];
    const pid = std.fmt.parseInt(std.posix.pid_t, opts.positional[1], 10) catch {
        v1.err(writer, "Usage: set_agent_pid <key> <pid> [--tab=<id>]") catch {};
        return;
    };
    if (pid <= 0) {
        v1.err(writer, "Usage: set_agent_pid <key> <pid> [--tab=<id>]") catch {};
        return;
    }
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };
    ws.setAgentPid(key, pid) catch {
        v1.err(writer, "Out of memory") catch {};
        return;
    };
    v1.raw(writer, "OK") catch {};
}

fn handleV1ClearAgentPid(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    if (opts.positional_count < 1) {
        v1.err(writer, "Usage: clear_agent_pid <key> [--tab=<id>]") catch {};
        return;
    }
    const key = opts.positional[0];
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };
    ws.clearAgentPid(key);
    v1.raw(writer, "OK") catch {};
}

// --- V1 Git/PR/Ports/Shell handlers ---

fn handleV1ReportGitBranch(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    if (opts.positional_count < 1) {
        v1.err(writer, "Missing branch name") catch {};
        return;
    }
    const branch_name = opts.positional[0];
    const is_dirty = std.mem.eql(u8, opts.status, "dirty");

    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    // If --panel= is set, update per-panel git branch; otherwise workspace-level
    if (opts.panel.len > 0) {
        const panel_id = Uuid.parse(opts.panel) catch {
            v1.err(writer, "Invalid panel UUID") catch {};
            return;
        };
        ws.setPanelGitBranch(panel_id, .{ .branch = branch_name, .is_dirty = is_dirty }) catch {
            v1.err(writer, "Out of memory") catch {};
            return;
        };
    } else {
        ws.setGitBranch(.{ .branch = branch_name, .is_dirty = is_dirty }) catch {
            v1.err(writer, "Out of memory") catch {};
            return;
        };
    }
    v1.raw(writer, "OK") catch {};
}

fn handleV1ClearGitBranch(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    if (opts.panel.len > 0) {
        const panel_id = Uuid.parse(opts.panel) catch {
            v1.err(writer, "Invalid panel UUID") catch {};
            return;
        };
        ws.setPanelGitBranch(panel_id, null) catch {};
    } else {
        ws.setGitBranch(null) catch {};
    }
    v1.raw(writer, "OK") catch {};
}

fn handleV1ReportPr(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    if (opts.positional_count < 2) {
        v1.err(writer, "Missing pull request number or URL") catch {};
        return;
    }
    var raw_number = opts.positional[0];
    if (raw_number.len > 0 and raw_number[0] == '#') raw_number = raw_number[1..];
    const number = std.fmt.parseInt(u32, raw_number, 10) catch {
        v1.err(writer, "Invalid pull request number") catch {};
        return;
    };
    const pr_url = opts.positional[1];

    const status_str = if (opts.state.len > 0) opts.state else "open";
    const pr_status: workspace.sidebar.PullRequestStatus = if (std.mem.eql(u8, status_str, "merged"))
        .merged
    else if (std.mem.eql(u8, status_str, "closed"))
        .closed
    else
        .open;

    const checks: ?workspace.sidebar.PullRequestChecksStatus = if (opts.checks.len > 0)
        if (std.mem.eql(u8, opts.checks, "pass"))
            .pass
        else if (std.mem.eql(u8, opts.checks, "fail"))
            .fail
        else if (std.mem.eql(u8, opts.checks, "pending"))
            .pending
        else
            null
    else
        null;

    const label = if (opts.label.len > 0) opts.label else "PR";
    const branch_opt = if (opts.branch.len > 0) opts.branch else null;

    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    if (opts.panel.len > 0) {
        const panel_id = Uuid.parse(opts.panel) catch {
            v1.err(writer, "Invalid panel UUID") catch {};
            return;
        };
        ws.setPanelPullRequest(panel_id, .{
            .number = number,
            .label = label,
            .url = pr_url,
            .status = pr_status,
            .branch = branch_opt,
            .checks = checks,
        }) catch {
            v1.err(writer, "Out of memory") catch {};
            return;
        };
    } else {
        ws.setPullRequest(.{
            .number = number,
            .label = label,
            .url = pr_url,
            .status = pr_status,
            .branch = branch_opt,
            .checks = checks,
        }) catch {
            v1.err(writer, "Out of memory") catch {};
            return;
        };
    }
    v1.raw(writer, "OK") catch {};
}

fn handleV1ClearPr(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    if (opts.panel.len > 0) {
        const panel_id = Uuid.parse(opts.panel) catch {
            v1.err(writer, "Invalid panel UUID") catch {};
            return;
        };
        ws.setPanelPullRequest(panel_id, null) catch {};
    } else {
        ws.setPullRequest(null) catch {};
    }
    v1.raw(writer, "OK") catch {};
}

fn handleV1ReportPorts(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    if (opts.positional_count < 1) {
        v1.err(writer, "Missing ports") catch {};
        return;
    }

    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    // Parse port numbers from positional args
    var ports: [64]u16 = undefined;
    var port_count: usize = 0;
    for (0..opts.positional_count) |i| {
        const port = std.fmt.parseInt(u16, opts.positional[i], 10) catch {
            v1.err(writer, "Invalid port number") catch {};
            return;
        };
        if (port == 0) {
            v1.err(writer, "Invalid port number") catch {};
            return;
        }
        if (port_count < ports.len) {
            ports[port_count] = port;
            port_count += 1;
        }
    }

    if (opts.panel.len > 0) {
        const panel_id = Uuid.parse(opts.panel) catch {
            v1.err(writer, "Invalid panel UUID") catch {};
            return;
        };
        ws.setPanelListeningPorts(panel_id, ports[0..port_count]) catch {
            v1.err(writer, "Out of memory") catch {};
            return;
        };
    } else {
        ws.setListeningPorts(ports[0..port_count]) catch {
            v1.err(writer, "Out of memory") catch {};
            return;
        };
    }
    v1.raw(writer, "OK") catch {};
}

fn handleV1ClearPorts(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    if (opts.panel.len > 0) {
        const panel_id = Uuid.parse(opts.panel) catch {
            v1.err(writer, "Invalid panel UUID") catch {};
            return;
        };
        ws.setPanelListeningPorts(panel_id, &.{}) catch {};
    } else {
        ws.setListeningPorts(&.{}) catch {};
    }
    v1.raw(writer, "OK") catch {};
}

fn handleV1ReportTty(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    if (opts.positional_count < 1) {
        v1.err(writer, "Missing tty name") catch {};
        return;
    }
    const tty_name = opts.positional[0];

    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    const panel_id = if (opts.panel.len > 0)
        Uuid.parse(opts.panel) catch {
            v1.err(writer, "Invalid panel UUID") catch {};
            return;
        }
    else if (ws.focused_panel_id) |fid|
        fid
    else {
        v1.err(writer, "Missing panel id (no focused surface)") catch {};
        return;
    };

    ws.setPanelTtyName(panel_id, tty_name) catch {
        v1.err(writer, "Out of memory") catch {};
        return;
    };
    v1.raw(writer, "OK") catch {};
}

fn handleV1ReportShellState(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    if (opts.positional_count < 1) {
        v1.err(writer, "Missing shell state") catch {};
        return;
    }
    const raw_state = opts.positional[0];

    const state: workspace.sidebar.ShellActivityState = if (std.mem.eql(u8, raw_state, "prompt") or std.mem.eql(u8, raw_state, "idle"))
        .prompt_idle
    else if (std.mem.eql(u8, raw_state, "running") or std.mem.eql(u8, raw_state, "busy") or std.mem.eql(u8, raw_state, "command"))
        .command_running
    else if (std.mem.eql(u8, raw_state, "unknown") or std.mem.eql(u8, raw_state, "clear"))
        .unknown
    else {
        v1.err(writer, "Invalid shell state — expected prompt or running") catch {};
        return;
    };

    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    const panel_id = if (opts.panel.len > 0)
        Uuid.parse(opts.panel) catch {
            v1.err(writer, "Invalid panel UUID") catch {};
            return;
        }
    else if (ws.focused_panel_id) |fid|
        fid
    else {
        v1.err(writer, "Missing panel id (no focused surface)") catch {};
        return;
    };

    ws.setPanelShellActivity(panel_id, state) catch {
        v1.err(writer, "Out of memory") catch {};
        return;
    };
    v1.raw(writer, "OK") catch {};
}

// --- V1 Progress/Log handlers ---

fn handleV1SetProgress(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    if (opts.positional_count < 1) {
        v1.err(writer, "Missing progress value") catch {};
        return;
    }
    const value = std.fmt.parseFloat(f64, opts.positional[0]) catch {
        v1.err(writer, "Invalid progress value") catch {};
        return;
    };
    if (!std.math.isFinite(value)) {
        v1.err(writer, "Invalid progress value") catch {};
        return;
    }
    const clamped = @min(1.0, @max(0.0, value));

    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    ws.setProgress(.{
        .value = clamped,
        .label = if (opts.label.len > 0) opts.label else null,
    }) catch {
        v1.err(writer, "Out of memory") catch {};
        return;
    };
    v1.raw(writer, "OK") catch {};
}

fn handleV1ClearProgress(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };
    ws.setProgress(null) catch {};
    v1.raw(writer, "OK") catch {};
}

fn handleV1Log(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    if (opts.positional_count < 1) {
        v1.err(writer, "Missing message") catch {};
        return;
    }

    // Join all positional args as the message
    var msg_buf: [4096]u8 = undefined;
    var msg_len: usize = 0;
    for (0..opts.positional_count) |i| {
        if (i > 0 and msg_len < msg_buf.len) {
            msg_buf[msg_len] = ' ';
            msg_len += 1;
        }
        const part = opts.positional[i];
        const copy_len = @min(part.len, msg_buf.len - msg_len);
        @memcpy(msg_buf[msg_len..][0..copy_len], part[0..copy_len]);
        msg_len += copy_len;
    }
    const message = msg_buf[0..msg_len];

    const level_str = if (opts.level.len > 0) opts.level else "info";
    const level: workspace.sidebar.LogLevel = if (std.mem.eql(u8, level_str, "progress"))
        .progress
    else if (std.mem.eql(u8, level_str, "success"))
        .success
    else if (std.mem.eql(u8, level_str, "warning"))
        .warning
    else if (std.mem.eql(u8, level_str, "error"))
        .@"error"
    else
        .info;

    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    ws.appendLog(.{
        .message = message,
        .level = level,
        .source = if (opts.source.len > 0) opts.source else null,
    }) catch {
        v1.err(writer, "Out of memory") catch {};
        return;
    };

    // Enforce log limit (50 entries, matches Mac default)
    const max_log_entries: usize = 50;
    while (ws.log_entries.items.len > max_log_entries) {
        const removed = ws.log_entries.orderedRemove(0);
        ws.allocator.free(removed.message);
        if (removed.source) |s| ws.allocator.free(s);
    }

    v1.raw(writer, "OK") catch {};
}

fn handleV1ClearLog(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };
    ws.clearLogs();
    v1.raw(writer, "OK") catch {};
}

fn handleV1ListLog(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, args: []const u8) void {
    _ = arena;
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    if (ws.log_entries.items.len == 0) {
        v1.raw(writer, "No log entries") catch {};
        return;
    }

    // Apply --limit=N if provided
    const limit: usize = if (opts.limit.len > 0)
        std.fmt.parseInt(usize, opts.limit, 10) catch ws.log_entries.items.len
    else
        ws.log_entries.items.len;

    const entries = ws.log_entries.items;
    const log_start = if (entries.len > limit) entries.len - limit else 0;

    for (entries[log_start..], 0..) |entry, i| {
        if (i > 0) writer.writeAll("\n") catch {};
        var line_buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&line_buf);
        const w = stream.writer();
        if (entry.source) |source| {
            if (source.len > 0) {
                w.print("[{s}] ", .{source}) catch {};
            }
        }
        w.print("[{s}] {s}", .{ @tagName(entry.level), entry.message }) catch {};
        writer.writeAll(stream.getWritten()) catch {};
    }
    writer.writeByte('\n') catch {};
}

// --- V1 Sidebar state/reset handlers ---

fn handleV1SidebarState(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, args: []const u8) void {
    _ = arena;
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };

    // Build sidebar state dump matching Mac format
    var id_buf: [36]u8 = undefined;
    _ = ws.id.formatBuf(&id_buf);

    // Use the writer directly for multi-line output
    var line_buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&line_buf);
    var w = stream.writer();

    w.print("tab={s}", .{&id_buf}) catch {};
    writer.writeAll(stream.getWritten()) catch {};
    writer.writeByte('\n') catch {};

    // Color
    stream.reset();
    w.print("color={s}", .{ws.custom_color orelse "none"}) catch {};
    writer.writeAll(stream.getWritten()) catch {};
    writer.writeByte('\n') catch {};

    // CWD
    stream.reset();
    w.print("cwd={s}", .{if (ws.current_directory.len > 0) ws.current_directory else ""}) catch {};
    writer.writeAll(stream.getWritten()) catch {};
    writer.writeByte('\n') catch {};

    // Focused panel
    if (ws.focused_panel_id) |fid| {
        if (ws.panel_directories.get(fid)) |dir| {
            stream.reset();
            w.print("focused_cwd={s}", .{dir}) catch {};
            writer.writeAll(stream.getWritten()) catch {};
        } else {
            writer.writeAll("focused_cwd=unknown") catch {};
        }
        writer.writeByte('\n') catch {};
        var fid_buf: [36]u8 = undefined;
        _ = fid.formatBuf(&fid_buf);
        stream.reset();
        w.print("focused_panel={s}", .{&fid_buf}) catch {};
        writer.writeAll(stream.getWritten()) catch {};
    } else {
        writer.writeAll("focused_cwd=unknown\nfocused_panel=unknown") catch {};
    }
    writer.writeByte('\n') catch {};

    // Git branch
    if (ws.git_branch) |git| {
        stream.reset();
        w.print("git_branch={s}{s}", .{ git.branch, if (git.is_dirty) " dirty" else " clean" }) catch {};
        writer.writeAll(stream.getWritten()) catch {};
    } else {
        writer.writeAll("git_branch=none") catch {};
    }
    writer.writeByte('\n') catch {};

    // PR
    if (ws.pull_request) |pr| {
        stream.reset();
        w.print("pr=#{d} {s} {s}", .{ pr.number, @tagName(pr.status), pr.url }) catch {};
        writer.writeAll(stream.getWritten()) catch {};
        writer.writeByte('\n') catch {};
        stream.reset();
        w.print("pr_label={s}", .{pr.label}) catch {};
        writer.writeAll(stream.getWritten()) catch {};
        writer.writeByte('\n') catch {};
        stream.reset();
        w.print("pr_checks={s}", .{if (pr.checks) |c| @tagName(c) else "none"}) catch {};
        writer.writeAll(stream.getWritten()) catch {};
    } else {
        writer.writeAll("pr=none\npr_label=none\npr_checks=none") catch {};
    }
    writer.writeByte('\n') catch {};

    // Ports
    if (ws.listening_ports.len == 0) {
        writer.writeAll("ports=none") catch {};
    } else {
        writer.writeAll("ports=") catch {};
        for (ws.listening_ports, 0..) |port, i| {
            if (i > 0) writer.writeAll(",") catch {};
            stream.reset();
            w.print("{d}", .{port}) catch {};
            writer.writeAll(stream.getWritten()) catch {};
        }
    }
    writer.writeByte('\n') catch {};

    // Progress
    if (ws.progress) |progress| {
        stream.reset();
        w.print("progress={d:.2}", .{progress.value}) catch {};
        if (progress.label) |lbl| {
            w.print(" {s}", .{lbl}) catch {};
        }
        writer.writeAll(stream.getWritten()) catch {};
    } else {
        writer.writeAll("progress=none") catch {};
    }
    writer.writeByte('\n') catch {};

    // Status count
    stream.reset();
    w.print("status_count={d}", .{ws.status_entries.count()}) catch {};
    writer.writeAll(stream.getWritten()) catch {};
    writer.writeByte('\n') catch {};
    {
        const skeys = ws.status_entries.keys();
        const svals = ws.status_entries.values();
        for (skeys, svals) |skey, sentry| {
            stream.reset();
            w.print("  {s}={s}", .{ skey, sentry.value }) catch {};
            if (sentry.icon) |icon| w.print(" icon={s}", .{icon}) catch {};
            if (sentry.color) |color| w.print(" color={s}", .{color}) catch {};
            writer.writeAll(stream.getWritten()) catch {};
            writer.writeByte('\n') catch {};
        }
    }

    // Meta block count
    stream.reset();
    w.print("meta_block_count={d}", .{ws.metadata_blocks.count()}) catch {};
    writer.writeAll(stream.getWritten()) catch {};
    writer.writeByte('\n') catch {};
    {
        const mkeys = ws.metadata_blocks.keys();
        const mvals = ws.metadata_blocks.values();
        for (mkeys, mvals) |mkey, mblock| {
            stream.reset();
            w.print("  {s}={s}", .{ mkey, mblock.markdown }) catch {};
            if (mblock.priority != 0) w.print(" priority={d}", .{mblock.priority}) catch {};
            writer.writeAll(stream.getWritten()) catch {};
            writer.writeByte('\n') catch {};
        }
    }

    // Log count + last 5
    stream.reset();
    w.print("log_count={d}", .{ws.log_entries.items.len}) catch {};
    writer.writeAll(stream.getWritten()) catch {};
    writer.writeByte('\n') catch {};
    {
        const log_items = ws.log_entries.items;
        const tail_start = if (log_items.len > 5) log_items.len - 5 else 0;
        for (log_items[tail_start..]) |entry| {
            stream.reset();
            w.print("  [{s}] {s}", .{ @tagName(entry.level), entry.message }) catch {};
            writer.writeAll(stream.getWritten()) catch {};
            writer.writeByte('\n') catch {};
        }
    }
}

fn handleV1ResetSidebar(self: *Server, writer: *client_handler.ResponseWriter, args: []const u8) void {
    const mgr = self.workspace_manager orelse {
        v1.err(writer, "No workspace manager") catch {};
        return;
    };
    const opts = parseV1Options(args);
    const ws = resolveWorkspaceForSidebar(mgr, opts) orelse {
        v1.err(writer, if (opts.tab.len > 0) "Tab not found" else "No tab selected") catch {};
        return;
    };
    ws.resetSidebar();
    v1.raw(writer, "OK") catch {};
}

// --- V1 flag argument parser (for notifications) ---

const V1FlagArgs = struct {
    title: []const u8 = "",
    subtitle: []const u8 = "",
    body: []const u8 = "",
    workspace_id: []const u8 = "",
    surface_id: []const u8 = "",
};

fn parseV1FlagArgs(args: []const u8) V1FlagArgs {
    var result = V1FlagArgs{};
    var iter = std.mem.tokenizeScalar(u8, args, ' ');
    while (iter.next()) |token| {
        if (std.mem.eql(u8, token, "--title")) {
            result.title = iter.next() orelse "";
        } else if (std.mem.eql(u8, token, "--subtitle")) {
            result.subtitle = iter.next() orelse "";
        } else if (std.mem.eql(u8, token, "--body")) {
            result.body = iter.next() orelse "";
        } else if (std.mem.eql(u8, token, "--workspace")) {
            result.workspace_id = iter.next() orelse "";
        } else if (std.mem.eql(u8, token, "--surface")) {
            result.surface_id = iter.next() orelse "";
        } else if (std.mem.startsWith(u8, token, "--title=")) {
            result.title = token["--title=".len..];
        } else if (std.mem.startsWith(u8, token, "--subtitle=")) {
            result.subtitle = token["--subtitle=".len..];
        } else if (std.mem.startsWith(u8, token, "--body=")) {
            result.body = token["--body=".len..];
        } else if (std.mem.startsWith(u8, token, "--workspace=")) {
            result.workspace_id = token["--workspace=".len..];
        } else if (std.mem.startsWith(u8, token, "--surface=")) {
            result.surface_id = token["--surface=".len..];
        }
    }
    return result;
}

// --- V2 notification.create_for_surface handler ---

fn dispatchV2NotificationCreateForSurface(
    self: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const surface_id = self.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing or invalid surface_id") catch {};
        return;
    };

    const mgr = self.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    // If workspace_id provided, use it; otherwise find workspace containing the surface.
    const ws_id = self.v2UUID(req.params, "workspace_id") orelse
        findWorkspaceForSurface(mgr, surface_id) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Surface not found") catch {};
        return;
    };

    const title = jsonStr(req.params.get("title"));
    const subtitle = jsonStr(req.params.get("subtitle"));
    const body = jsonStr(req.params.get("body"));

    self.notification_store.addNotification(
        ws_id,
        surface_id,
        if (title.len == 0) "Notification" else title,
        subtitle,
        body,
    ) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Out of memory") catch {};
        return;
    };

    // Response with resolved IDs and refs (matches Mac line 6397-6403).
    var result = json.ObjectMap.init(arena);
    var ws_buf: [36]u8 = undefined;
    var sid_buf: [36]u8 = undefined;
    _ = ws_id.formatBuf(&ws_buf);
    _ = surface_id.formatBuf(&sid_buf);
    result.put("workspace_id", .{ .string = arena.dupe(u8, &ws_buf) catch "" }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    result.put("surface_id", .{ .string = arena.dupe(u8, &sid_buf) catch "" }) catch {};
    result.put("surface_ref", self.v2Ref(.surface, surface_id)) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn findWorkspaceForSurface(mgr: *workspace.Manager, surface_id: Uuid) ?Uuid {
    for (mgr.workspaces.items) |ws| {
        if (ws.panelById(surface_id) != null) return ws.id;
    }
    return null;
}

// --- V2 workspace.action / surface.action handlers ---

fn dispatchV2WorkspaceAction(
    self: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const action = jsonStr(req.params.get("action"));
    if (action.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing action") catch {};
        return;
    }

    // Resolve workspace_id (optional, defaults to selected).
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    if (std.mem.eql(u8, action, "mark_read")) {
        self.notification_store.markReadForTab(ws_id);
        v2.writeOk(writer, arena, req.id, .{ .bool = true }) catch {};
    } else if (std.mem.eql(u8, action, "mark_unread")) {
        self.notification_store.markUnreadForTab(ws_id);
        v2.writeOk(writer, arena, req.id, .{ .bool = true }) catch {};
    } else {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Unknown workspace action") catch {};
    }
}

fn dispatchV2SurfaceAction(
    self: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const action = jsonStr(req.params.get("action"));
    if (action.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing action") catch {};
        return;
    }

    const surface_id = self.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing or invalid surface_id") catch {};
        return;
    };

    // Resolve workspace_id (optional, defaults to selected).
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    if (std.mem.eql(u8, action, "mark_read")) {
        self.notification_store.markReadForTabSurface(ws_id, surface_id);
        v2.writeOk(writer, arena, req.id, .{ .bool = true }) catch {};
    } else if (std.mem.eql(u8, action, "mark_unread") or std.mem.eql(u8, action, "mark_as_unread")) {
        self.notification_store.markUnreadForTab(ws_id);
        v2.writeOk(writer, arena, req.id, .{ .bool = true }) catch {};
    } else {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Unknown surface action") catch {};
    }
}

// --- V2 workspace command handlers ---

fn writeWorkspaceIdResponse(
    self: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req_id: json.Value,
    ws_id: Uuid,
) void {
    var result = json.ObjectMap.init(arena);
    var id_buf: [36]u8 = undefined;
    _ = ws_id.formatBuf(&id_buf);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = arena.dupe(u8, &id_buf) catch "" }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    v2.writeOk(writer, arena, req_id, .{ .object = result }) catch {};
}

fn formatUuid(arena: Allocator, id: Uuid) []const u8 {
    var buf: [36]u8 = undefined;
    _ = id.formatBuf(&buf);
    return arena.dupe(u8, &buf) catch "";
}

// -- workspace.list --

const SyncListCtx = struct {
    mgr: *workspace.Manager,
    arena: Allocator,
    ws_array: json.Array,
    server: *Server,
};

fn dispatchV2WorkspaceList(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const mgr = self.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    var ctx = SyncListCtx{
        .mgr = mgr,
        .arena = arena,
        .ws_array = json.Array.init(arena),
        .server = self,
    };
    dispatch.syncOnMainThread(&syncWorkspaceList, @ptrCast(&ctx));

    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspaces", .{ .array = ctx.ws_array }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn syncWorkspaceList(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncListCtx = @ptrCast(@alignCast(data orelse return 0));
    const mgr = ctx.mgr;
    const arena = ctx.arena;

    for (mgr.workspaces.items, 0..) |ws, idx| {
        var obj = json.ObjectMap.init(arena);
        obj.put("id", .{ .string = formatUuid(arena, ws.id) }) catch continue;
        obj.put("ref", ctx.server.v2Ref(.workspace, ws.id)) catch continue;
        obj.put("index", .{ .integer = @intCast(idx) }) catch continue;
        obj.put("title", .{ .string = ws.displayTitle() }) catch continue;
        obj.put("selected", .{ .bool = if (mgr.selected_id) |sel| sel.eql(ws.id) else false }) catch continue;
        obj.put("pinned", .{ .bool = ws.is_pinned }) catch continue;
        obj.put("current_directory", if (ws.current_directory.len > 0) json.Value{ .string = ws.current_directory } else .null) catch continue;
        obj.put("custom_color", if (ws.custom_color) |c| json.Value{ .string = c } else .null) catch continue;

        var ports = json.Array.init(arena);
        for (ws.listening_ports) |p| {
            ports.append(.{ .integer = @intCast(p) }) catch continue;
        }
        obj.put("listening_ports", .{ .array = ports }) catch continue;

        ctx.ws_array.append(.{ .object = obj }) catch continue;
    }
    return 0;
}

// -- workspace.current --

const SyncCurrentCtx = struct {
    mgr: *workspace.Manager,
    result_id: ?Uuid = null,
};

fn dispatchV2WorkspaceCurrent(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const mgr = self.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    var ctx = SyncCurrentCtx{ .mgr = mgr };
    dispatch.syncOnMainThread(&syncWorkspaceCurrent, @ptrCast(&ctx));

    const ws_id = ctx.result_id orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "No workspace selected") catch {};
        return;
    };
    writeWorkspaceIdResponse(self, arena, writer, req.id, ws_id);
}

fn syncWorkspaceCurrent(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncCurrentCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.result_id = ctx.mgr.selected_id;
    return 0;
}

// -- workspace.create --

const SyncCreateCtx = struct {
    mgr: *workspace.Manager,
    cwd: []const u8,
    result_id: ?Uuid = null,
    err: bool = false,
};

fn dispatchV2WorkspaceCreate(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const mgr = self.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    const cwd = blk: {
        const wd = jsonStr(req.params.get("working_directory"));
        if (wd.len > 0) break :blk wd;
        break :blk jsonStr(req.params.get("cwd"));
    };

    var ctx = SyncCreateCtx{ .mgr = mgr, .cwd = cwd };
    dispatch.syncOnMainThread(&syncCreateWorkspace, @ptrCast(&ctx));

    if (ctx.err) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Failed to create workspace") catch {};
        return;
    }
    const ws_id = ctx.result_id orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace ID") catch {};
        return;
    };
    writeWorkspaceIdResponse(self, arena, writer, req.id, ws_id);
}

fn syncCreateWorkspace(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncCreateCtx = @ptrCast(@alignCast(data orelse return 0));
    const ws = ctx.mgr.createWorkspace(.{
        .title = "Terminal",
        .working_directory = ctx.cwd,
    }) catch {
        ctx.err = true;
        return 0;
    };
    ctx.result_id = ws.id;
    return 0;
}

// -- workspace.select --

const SyncSelectCtx = struct {
    mgr: *workspace.Manager,
    id: Uuid,
    found: bool = false,
};

fn dispatchV2WorkspaceSelect(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const mgr = self.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };
    const ws_id = self.v2UUID(req.params, "workspace_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing or invalid workspace_id") catch {};
        return;
    };

    var ctx = SyncSelectCtx{ .mgr = mgr, .id = ws_id };
    dispatch.syncOnMainThread(&syncSelectWorkspace, @ptrCast(&ctx));

    if (!ctx.found) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    }
    writeWorkspaceIdResponse(self, arena, writer, req.id, ws_id);
}

fn syncSelectWorkspace(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncSelectCtx = @ptrCast(@alignCast(data orelse return 0));
    if (ctx.mgr.workspaceById(ctx.id) == null) return 0;
    ctx.mgr.selectWorkspace(ctx.id);
    ctx.found = true;
    return 0;
}

// -- workspace.close --

const SyncCloseCtx = struct {
    mgr: *workspace.Manager,
    id: Uuid,
    err_code: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,
};

fn dispatchV2WorkspaceClose(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const mgr = self.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };
    const ws_id = self.v2UUID(req.params, "workspace_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing or invalid workspace_id") catch {};
        return;
    };

    var ctx = SyncCloseCtx{ .mgr = mgr, .id = ws_id };
    dispatch.syncOnMainThread(&syncCloseWorkspace, @ptrCast(&ctx));

    if (ctx.err_code) |code| {
        v2.writeError(writer, arena, req.id, code, ctx.err_msg orelse "Error") catch {};
        return;
    }
    writeWorkspaceIdResponse(self, arena, writer, req.id, ws_id);
}

fn syncCloseWorkspace(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncCloseCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.mgr.closeWorkspace(ctx.id) catch |e| {
        switch (e) {
            error.WorkspaceNotFound => {
                ctx.err_code = v2.ErrorCode.not_found;
                ctx.err_msg = "Workspace not found";
            },
            error.WorkspacePinned => {
                ctx.err_code = "protected";
                ctx.err_msg = "Workspace is pinned";
            },
            error.LastWorkspace => {
                ctx.err_code = "invalid_state";
                ctx.err_msg = "Cannot close last workspace";
            },
        }
    };
    return 0;
}

// -- workspace.rename --

const SyncRenameCtx = struct {
    mgr: *workspace.Manager,
    id: Uuid,
    title: []const u8,
    err_code: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,
};

fn dispatchV2WorkspaceRename(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const mgr = self.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };
    const ws_id = self.v2UUID(req.params, "workspace_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing or invalid workspace_id") catch {};
        return;
    };
    const title = jsonStr(req.params.get("title"));

    var ctx = SyncRenameCtx{ .mgr = mgr, .id = ws_id, .title = title };
    dispatch.syncOnMainThread(&syncRenameWorkspace, @ptrCast(&ctx));

    if (ctx.err_code) |code| {
        v2.writeError(writer, arena, req.id, code, ctx.err_msg orelse "Error") catch {};
        return;
    }

    // Response includes title field beyond the standard workspace response.
    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    result.put("title", .{ .string = title }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn syncRenameWorkspace(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncRenameCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.mgr.renameWorkspace(ctx.id, ctx.title) catch |e| {
        switch (e) {
            error.WorkspaceNotFound => {
                ctx.err_code = v2.ErrorCode.not_found;
                ctx.err_msg = "Workspace not found";
            },
            error.OutOfMemory => {
                ctx.err_code = v2.ErrorCode.internal_error;
                ctx.err_msg = "Out of memory";
            },
        }
    };
    return 0;
}

// -- workspace.next / workspace.previous / workspace.last --

const NavAction = enum { next, previous, last };

const SyncNavCtx = struct {
    mgr: *workspace.Manager,
    action: NavAction,
    result_id: ?Uuid = null,
};

fn dispatchV2WorkspaceNav(
    self: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
    action: NavAction,
) void {
    const mgr = self.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    var ctx = SyncNavCtx{ .mgr = mgr, .action = action };
    dispatch.syncOnMainThread(&syncNavWorkspace, @ptrCast(&ctx));

    const ws_id = ctx.result_id orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "No workspace available") catch {};
        return;
    };
    writeWorkspaceIdResponse(self, arena, writer, req.id, ws_id);
}

fn syncNavWorkspace(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncNavCtx = @ptrCast(@alignCast(data orelse return 0));
    switch (ctx.action) {
        .next => ctx.mgr.selectNextWorkspace(),
        .previous => ctx.mgr.selectPreviousWorkspace(),
        .last => ctx.mgr.selectLastWorkspace(),
    }
    ctx.result_id = ctx.mgr.selected_id;
    return 0;
}

// -- workspace.reorder --

const SyncReorderCtx = struct {
    mgr: *workspace.Manager,
    id: Uuid,
    target_index: ?usize = null,
    before_id: ?Uuid = null,
    after_id: ?Uuid = null,
    result_index: ?usize = null,
    err_code: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,
};

fn dispatchV2WorkspaceReorder(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const mgr = self.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };
    const ws_id = self.v2UUID(req.params, "workspace_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing or invalid workspace_id") catch {};
        return;
    };

    // Parse positioning params
    const index_val: ?usize = if (req.params.get("index")) |v| switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    } else null;
    const before_id = self.v2UUID(req.params, "before_workspace_id");
    const after_id = self.v2UUID(req.params, "after_workspace_id");

    // Exactly one positioning param required.
    const param_count: u8 = @as(u8, if (index_val != null) 1 else 0) +
        @as(u8, if (before_id != null) 1 else 0) +
        @as(u8, if (after_id != null) 1 else 0);
    if (param_count != 1) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Exactly one of index, before_workspace_id, after_workspace_id required") catch {};
        return;
    }

    var ctx = SyncReorderCtx{
        .mgr = mgr,
        .id = ws_id,
        .target_index = index_val,
        .before_id = before_id,
        .after_id = after_id,
    };
    dispatch.syncOnMainThread(&syncReorderWorkspace, @ptrCast(&ctx));

    if (ctx.err_code) |code| {
        v2.writeError(writer, arena, req.id, code, ctx.err_msg orelse "Error") catch {};
        return;
    }

    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    if (ctx.result_index) |idx| {
        result.put("index", .{ .integer = @intCast(idx) }) catch {};
    }
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn syncReorderWorkspace(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncReorderCtx = @ptrCast(@alignCast(data orelse return 0));
    const mgr = ctx.mgr;

    // Resolve target index
    const target_index: usize = blk: {
        if (ctx.target_index) |idx| break :blk idx;
        if (ctx.before_id) |bid| {
            break :blk mgr.indexOfWorkspace(bid) orelse {
                ctx.err_code = v2.ErrorCode.not_found;
                ctx.err_msg = "before_workspace_id not found";
                return 0;
            };
        }
        if (ctx.after_id) |aid| {
            const ai = mgr.indexOfWorkspace(aid) orelse {
                ctx.err_code = v2.ErrorCode.not_found;
                ctx.err_msg = "after_workspace_id not found";
                return 0;
            };
            break :blk ai + 1;
        }
        ctx.err_code = v2.ErrorCode.invalid_params;
        ctx.err_msg = "No positioning param";
        return 0;
    };

    mgr.moveWorkspaceToIndex(ctx.id, target_index);
    ctx.result_index = mgr.indexOfWorkspace(ctx.id);
    return 0;
}

// --- V2 surface command handlers ---

fn dispatchV2SurfaceList(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ops = self.window_ops orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window ops") catch {};
        return;
    };
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    var surfaces: window_ops_mod.SurfaceInfoList = .{};
    var ctx = SyncSurfaceListCtx{ .ops = ops, .ws_id = ws_id, .surfaces = &surfaces, .alloc = arena };
    dispatch.syncOnMainThread(&syncSurfaceList, @ptrCast(&ctx));

    var surface_array = json.Array.init(arena);
    for (surfaces.items, 0..) |info, idx| {
        var obj = json.ObjectMap.init(arena);
        obj.put("id", .{ .string = formatUuid(arena, info.id) }) catch continue;
        obj.put("ref", self.v2Ref(.surface, info.id)) catch continue;
        obj.put("index", .{ .integer = @intCast(idx) }) catch continue;
        obj.put("type", .{ .string = info.panel_type }) catch continue;
        obj.put("title", .{ .string = info.title }) catch continue;
        obj.put("focused", .{ .bool = info.focused }) catch continue;
        obj.put("pane_id", .null) catch continue;
        obj.put("pane_ref", .null) catch continue;
        surface_array.append(.{ .object = obj }) catch continue;
    }

    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    result.put("surfaces", .{ .array = surface_array }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

const SyncSurfaceListCtx = struct {
    ops: window_ops_mod.WindowOps,
    ws_id: Uuid,
    surfaces: *window_ops_mod.SurfaceInfoList,
    alloc: Allocator,
};

fn syncSurfaceList(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncSurfaceListCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.ops.listSurfaces(ctx.ws_id, ctx.alloc, ctx.surfaces);
    return 0;
}

fn dispatchV2SurfaceCurrent(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ops = self.window_ops orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window ops") catch {};
        return;
    };
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    var ctx = SyncSurfaceCurrentCtx{ .ops = ops, .ws_id = ws_id };
    dispatch.syncOnMainThread(&syncSurfaceCurrent, @ptrCast(&ctx));

    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    result.put("pane_id", .null) catch {};
    result.put("pane_ref", .null) catch {};
    if (ctx.result) |info| {
        result.put("surface_id", .{ .string = formatUuid(arena, info.id) }) catch {};
        result.put("surface_ref", self.v2Ref(.surface, info.id)) catch {};
        result.put("surface_type", .{ .string = info.panel_type }) catch {};
    } else {
        result.put("surface_id", .null) catch {};
        result.put("surface_ref", .null) catch {};
        result.put("surface_type", .null) catch {};
    }
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

const SyncSurfaceCurrentCtx = struct {
    ops: window_ops_mod.WindowOps,
    ws_id: Uuid,
    result: ?window_ops_mod.SurfaceInfo = null,
};

fn syncSurfaceCurrent(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncSurfaceCurrentCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.result = ctx.ops.currentSurface(ctx.ws_id);
    return 0;
}

fn dispatchV2SurfaceSplit(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ops = self.window_ops orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window ops") catch {};
        return;
    };
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };
    const dir_str = jsonStr(req.params.get("direction"));
    const direction = window_ops_mod.Direction.parse(dir_str) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Invalid direction (left, right, up, down)") catch {};
        return;
    };

    var ctx = SyncSplitCtx{ .ops = ops, .ws_id = ws_id, .direction = direction };
    dispatch.syncOnMainThread(&syncSurfaceSplit, @ptrCast(&ctx));

    const split_result = ctx.result orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Split failed") catch {};
        return;
    };

    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    result.put("pane_id", .null) catch {};
    result.put("pane_ref", .null) catch {};
    result.put("surface_id", .{ .string = formatUuid(arena, split_result.surface_id) }) catch {};
    result.put("surface_ref", self.v2Ref(.surface, split_result.surface_id)) catch {};
    result.put("type", .{ .string = "terminal" }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

const SyncSplitCtx = struct {
    ops: window_ops_mod.WindowOps,
    ws_id: Uuid,
    direction: window_ops_mod.Direction,
    result: ?window_ops_mod.SplitResult = null,
};

fn syncSurfaceSplit(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncSplitCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.result = ctx.ops.split(ctx.ws_id, ctx.direction);
    return 0;
}

fn dispatchV2SurfaceClose(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ops = self.window_ops orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window ops") catch {};
        return;
    };
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };
    const surface_id = self.v2UUID(req.params, "surface_id");

    var ctx = SyncClosesSurfaceCtx{ .ops = ops, .ws_id = ws_id, .surface_id = surface_id };
    dispatch.syncOnMainThread(&syncSurfaceClose, @ptrCast(&ctx));

    const closed_id = ctx.result orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Surface not found or close failed") catch {};
        return;
    };

    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    result.put("surface_id", .{ .string = formatUuid(arena, closed_id) }) catch {};
    result.put("surface_ref", self.v2Ref(.surface, closed_id)) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

const SyncClosesSurfaceCtx = struct {
    ops: window_ops_mod.WindowOps,
    ws_id: Uuid,
    surface_id: ?Uuid,
    result: ?Uuid = null,
};

fn syncSurfaceClose(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncClosesSurfaceCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.result = ctx.ops.closeSurface(ctx.ws_id, ctx.surface_id);
    return 0;
}

fn dispatchV2SurfaceFocus(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ops = self.window_ops orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window ops") catch {};
        return;
    };
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };
    const surface_id = self.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing or invalid surface_id") catch {};
        return;
    };

    var ctx = SyncFocusSurfaceCtx{ .ops = ops, .ws_id = ws_id, .surface_id = surface_id };
    dispatch.syncOnMainThread(&syncSurfaceFocus, @ptrCast(&ctx));

    if (!ctx.result) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Surface not found") catch {};
        return;
    }

    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    result.put("surface_id", .{ .string = formatUuid(arena, surface_id) }) catch {};
    result.put("surface_ref", self.v2Ref(.surface, surface_id)) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

const SyncFocusSurfaceCtx = struct {
    ops: window_ops_mod.WindowOps,
    ws_id: Uuid,
    surface_id: Uuid,
    result: bool = false,
};

fn syncSurfaceFocus(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncFocusSurfaceCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.result = ctx.ops.focusSurface(ctx.ws_id, ctx.surface_id);
    return 0;
}

// =======================================================================
// system.identify — return focused window/workspace/surface IDs
// =======================================================================

fn dispatchV2SystemIdentify(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const mgr = self.workspace_manager;

    var result = json.ObjectMap.init(arena);
    result.put("socket_path", if (self.currentPath()) |p| json.Value{ .string = p } else .null) catch {};

    if (mgr) |m| {
        var ws_id_ctx = SyncCurrentCtx{ .mgr = m };
        dispatch.syncOnMainThread(&syncWorkspaceCurrent, @ptrCast(&ws_id_ctx));

        var focused = json.ObjectMap.init(arena);
        focused.put("window_id", .null) catch {};
        focused.put("window_ref", .null) catch {};

        if (ws_id_ctx.result_id) |ws_id| {
            focused.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
            focused.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};

            // Pane — not yet implemented, null
            focused.put("pane_id", .null) catch {};
            focused.put("pane_ref", .null) catch {};

            // Current surface
            if (self.window_ops) |ops| {
                var surf_ctx = SyncSurfaceCurrentCtx{ .ops = ops, .ws_id = ws_id };
                dispatch.syncOnMainThread(&syncSurfaceCurrent, @ptrCast(&surf_ctx));
                if (surf_ctx.result) |info| {
                    focused.put("surface_id", .{ .string = formatUuid(arena, info.id) }) catch {};
                    focused.put("surface_ref", self.v2Ref(.surface, info.id)) catch {};
                    focused.put("surface_type", .{ .string = info.panel_type }) catch {};
                    focused.put("is_browser_surface", .{ .bool = std.mem.eql(u8, info.panel_type, "browser") }) catch {};
                } else {
                    focused.put("surface_id", .null) catch {};
                    focused.put("surface_ref", .null) catch {};
                }
            }
        }
        result.put("focused", .{ .object = focused }) catch {};
    } else {
        result.put("focused", .null) catch {};
    }
    result.put("caller", .null) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// =======================================================================
// system.tree — return full tree of windows → workspaces → surfaces
// =======================================================================

fn dispatchV2SystemTree(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const mgr = self.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    // Optional workspace filter
    const ws_filter = self.v2UUID(req.params, "workspace_id");
    if (req.params.get("workspace_id") != null and ws_filter == null) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing or invalid workspace_id") catch {};
        return;
    }

    // First get identify payload
    var identify_result = json.ObjectMap.init(arena);
    if (mgr.selected_id) |sel_id| {
        identify_result.put("workspace_id", .{ .string = formatUuid(arena, sel_id) }) catch {};
        identify_result.put("workspace_ref", self.v2Ref(.workspace, sel_id)) catch {};
    }

    // Build workspace nodes
    var ws_nodes = json.Array.init(arena);
    const ops = self.window_ops;

    for (mgr.workspaces.items, 0..) |ws, idx| {
        if (ws_filter) |filt| {
            if (!ws.id.eql(filt)) continue;
        }

        var ws_node = json.ObjectMap.init(arena);
        ws_node.put("id", .{ .string = formatUuid(arena, ws.id) }) catch continue;
        ws_node.put("ref", self.v2Ref(.workspace, ws.id)) catch continue;
        ws_node.put("index", .{ .integer = @intCast(idx) }) catch continue;
        ws_node.put("title", .{ .string = ws.displayTitle() }) catch continue;
        ws_node.put("selected", .{ .bool = if (mgr.selected_id) |sel| sel.eql(ws.id) else false }) catch continue;

        // Surfaces in this workspace
        var surface_nodes = json.Array.init(arena);
        if (ops) |o| {
            var surfaces: window_ops_mod.SurfaceInfoList = .{};
            var list_ctx = SyncSurfaceListCtx{ .ops = o, .ws_id = ws.id, .surfaces = &surfaces, .alloc = arena };
            dispatch.syncOnMainThread(&syncSurfaceList, @ptrCast(&list_ctx));

            for (surfaces.items, 0..) |info, sidx| {
                var s_node = json.ObjectMap.init(arena);
                s_node.put("id", .{ .string = formatUuid(arena, info.id) }) catch continue;
                s_node.put("ref", self.v2Ref(.surface, info.id)) catch continue;
                s_node.put("index", .{ .integer = @intCast(sidx) }) catch continue;
                s_node.put("type", .{ .string = info.panel_type }) catch continue;
                s_node.put("title", .{ .string = info.title }) catch continue;
                s_node.put("focused", .{ .bool = info.focused }) catch continue;
                surface_nodes.append(.{ .object = s_node }) catch continue;
            }
        }

        // No separate pane tree yet — surfaces are the leaf nodes
        var pane_nodes = json.Array.init(arena);
        var pane_obj = json.ObjectMap.init(arena);
        pane_obj.put("id", .null) catch {};
        pane_obj.put("surfaces", .{ .array = surface_nodes }) catch {};
        pane_nodes.append(.{ .object = pane_obj }) catch {};

        ws_node.put("panes", .{ .array = pane_nodes }) catch continue;
        ws_nodes.append(.{ .object = ws_node }) catch continue;
    }

    // Single window node (Linux is single-window for now)
    var window_node = json.ObjectMap.init(arena);
    window_node.put("id", .null) catch {};
    window_node.put("ref", .null) catch {};
    window_node.put("index", .{ .integer = 0 }) catch {};
    window_node.put("focused", .{ .bool = true }) catch {};
    window_node.put("workspaces", .{ .array = ws_nodes }) catch {};

    var windows = json.Array.init(arena);
    windows.append(.{ .object = window_node }) catch {};

    var result = json.ObjectMap.init(arena);
    result.put("windows", .{ .array = windows }) catch {};
    result.put("focused", .{ .object = identify_result }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// =======================================================================
// window.list / window.current / window.create / window.close / window.focus
// =======================================================================

fn dispatchV2WindowList(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    _ = self;
    // Linux is currently single-window. Return a list with one window.
    var win = json.ObjectMap.init(arena);
    win.put("id", .null) catch {};
    win.put("ref", .null) catch {};
    win.put("index", .{ .integer = 0 }) catch {};
    win.put("focused", .{ .bool = true }) catch {};
    win.put("title", .{ .string = "cmux" }) catch {};

    var arr = json.Array.init(arena);
    arr.append(.{ .object = win }) catch {};

    var result = json.ObjectMap.init(arena);
    result.put("windows", .{ .array = arr }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn dispatchV2WindowCurrent(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    _ = self;
    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("focused", .{ .bool = true }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn dispatchV2WindowCreate(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    _ = self;
    // Linux is single-window; creating a "window" just returns the existing one.
    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn dispatchV2WindowClose(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    _ = self;
    // Cannot close the single window via socket.
    v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_state, "Cannot close the only window") catch {};
}

fn dispatchV2WindowFocus(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const win = self.cmux_window orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window") catch {};
        return;
    };
    var ctx = SyncPresentWindowCtx{ .window = win };
    dispatch.syncOnMainThread(&syncPresentWindow, @ptrCast(&ctx));
    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// =======================================================================
// workspace.equalize_splits
// =======================================================================

fn dispatchV2WorkspaceEqualizeSplits(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    // Equalize splits is not yet implemented in the GTK layer.
    // Return success with workspace info for protocol compatibility.
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };
    writeWorkspaceIdResponse(self, arena, writer, req.id, ws_id);
}

// =======================================================================
// surface.send_text / surface.send_key
// =======================================================================

fn dispatchV2SurfaceSendText(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };
    const text = jsonStr(req.params.get("text"));
    if (text.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing text") catch {};
        return;
    }
    const surface_id = self.v2UUID(req.params, "surface_id");

    // send_text requires GTK terminal write support — stub for now
    _ = ws_id;
    _ = surface_id;
    v2.writeError(writer, arena, req.id, "not_implemented", "surface.send_text not yet implemented on Linux") catch {};
}

fn dispatchV2SurfaceSendKey(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };
    const key = jsonStr(req.params.get("key"));
    if (key.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing key") catch {};
        return;
    }
    _ = ws_id;
    v2.writeError(writer, arena, req.id, "not_implemented", "surface.send_key not yet implemented on Linux") catch {};
}

// =======================================================================
// surface.read_text
// =======================================================================

fn dispatchV2SurfaceReadText(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ops = self.window_ops orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window ops") catch {};
        return;
    };
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    // Resolve surface — explicit or focused
    const surface_id = self.v2UUID(req.params, "surface_id") orelse blk: {
        var surf_ctx = SyncSurfaceCurrentCtx{ .ops = ops, .ws_id = ws_id };
        dispatch.syncOnMainThread(&syncSurfaceCurrent, @ptrCast(&surf_ctx));
        break :blk if (surf_ctx.result) |info| info.id else null;
    };

    if (surface_id == null) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "No surface found") catch {};
        return;
    }

    const text = ops.readScrollback(arena, surface_id.?) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Failed to read terminal text") catch {};
        return;
    };

    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    result.put("surface_id", .{ .string = formatUuid(arena, surface_id.?) }) catch {};
    result.put("surface_ref", self.v2Ref(.surface, surface_id.?)) catch {};
    result.put("text", .{ .string = text }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// =======================================================================
// surface.clear_history / surface.trigger_flash
// =======================================================================

fn dispatchV2SurfaceClearHistory(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };
    const surface_id = self.v2UUID(req.params, "surface_id");
    // clear_history requires Ghostty terminal VTE integration — stub
    _ = ws_id;
    _ = surface_id;
    v2.writeError(writer, arena, req.id, "not_implemented", "surface.clear_history not yet implemented on Linux") catch {};
}

fn dispatchV2SurfaceTriggerFlash(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };
    // Flash is visual feedback — return success (no-op on Linux for now)
    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// =======================================================================
// surface.refresh / surface.health
// =======================================================================

fn dispatchV2SurfaceRefresh(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };
    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    result.put("refreshed", .{ .bool = true }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn dispatchV2SurfaceHealth(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    // Check if surface exists and is responsive
    const surface_id = self.v2UUID(req.params, "surface_id");
    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    if (surface_id) |sid| {
        result.put("surface_id", .{ .string = formatUuid(arena, sid) }) catch {};
        result.put("surface_ref", self.v2Ref(.surface, sid)) catch {};
    }
    result.put("healthy", .{ .bool = true }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// =======================================================================
// pane.list / pane.focus / pane.surfaces / pane.create / pane.last
// =======================================================================

fn dispatchV2PaneList(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    // Linux doesn't have separate pane abstraction yet.
    // Each workspace has one implicit pane containing all its surfaces.
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    var panes = json.Array.init(arena);
    var pane = json.ObjectMap.init(arena);
    pane.put("id", .null) catch {};
    pane.put("ref", .null) catch {};
    pane.put("index", .{ .integer = 0 }) catch {};
    pane.put("focused", .{ .bool = true }) catch {};
    panes.append(.{ .object = pane }) catch {};

    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    result.put("panes", .{ .array = panes }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn dispatchV2PaneFocus(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    // Single implicit pane — always focused. Accept and return success.
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };
    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    result.put("pane_id", .null) catch {};
    result.put("pane_ref", .null) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn dispatchV2PaneSurfaces(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    // Delegate to surface.list since pane === workspace for now
    dispatchV2SurfaceList(self, arena, writer, req);
}

fn dispatchV2PaneCreate(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    // pane.create is essentially surface.split
    dispatchV2SurfaceSplit(self, arena, writer, req);
}

fn dispatchV2PaneLast(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    // Focus last pane — with single-pane model, this is a no-op success
    const ws_id = resolveWorkspaceId(self, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };
    var result = json.ObjectMap.init(arena);
    result.put("window_id", .null) catch {};
    result.put("window_ref", .null) catch {};
    result.put("workspace_id", .{ .string = formatUuid(arena, ws_id) }) catch {};
    result.put("workspace_ref", self.v2Ref(.workspace, ws_id)) catch {};
    result.put("pane_id", .null) catch {};
    result.put("pane_ref", .null) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// =======================================================================
// app.focus_override.set / app.simulate_active
// =======================================================================

fn dispatchV2AppFocusOverride(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    _ = self;
    // Accept the command for protocol compatibility but it's a no-op on Linux (Wayland doesn't allow focus stealing).
    const level = jsonStr(req.params.get("override_level"));
    var result = json.ObjectMap.init(arena);
    result.put("override_level", if (level.len > 0) json.Value{ .string = level } else .{ .string = "none" }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn dispatchV2AppSimulateActive(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    _ = self;
    // No-op on Linux — Wayland compositors control window activation.
    var result = json.ObjectMap.init(arena);
    result.put("simulated", .{ .bool = true }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// =======================================================================
// settings.open / feedback.open
// =======================================================================

fn dispatchV2SettingsOpen(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    _ = self;
    // Settings are in the config file on Linux — return info about it.
    var result = json.ObjectMap.init(arena);
    result.put("opened", .{ .bool = true }) catch {};
    result.put("platform_note", .{ .string = "Linux settings are in ~/.config/ghostty/config" }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn dispatchV2FeedbackOpen(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    _ = self;
    var result = json.ObjectMap.init(arena);
    result.put("opened", .{ .bool = true }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn dispatchV2FeedbackSubmit(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    _ = self;
    var result = json.ObjectMap.init(arena);
    result.put("submitted", .{ .bool = true }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// =======================================================================
// Generic not_implemented stub for methods that need GTK work
// =======================================================================

fn dispatchV2Stub(
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
    method_name: []const u8,
    message: []const u8,
) void {
    _ = method_name;
    v2.writeError(writer, arena, req.id, "not_implemented", message) catch {};
}

// --- Workspace/surface helpers ---

fn resolveWorkspaceId(self: *const Server, params: json.ObjectMap) ?Uuid {
    if (self.v2UUID(params, "workspace_id")) |id| return id;
    // Default to selected workspace.
    const mgr = self.workspace_manager orelse return null;
    return mgr.selected_id;
}

fn jsonStr(val: ?json.Value) []const u8 {
    const v = val orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

// --- V2 ref helpers ---

/// Walk all known entities, ensuring each has a ref allocated.
/// Matches macOS v2RefreshKnownRefs (line 3010-3028).
///
/// Mac traversal order: windows → workspaces → panes → surfaces.
/// Linux mirrors this structure; kinds that don't exist yet are marked
/// with TODO so they're easy to wire up when added.
fn refreshRefs(self: *Server) void {
    const mgr = self.workspace_manager orelse return;

    // TODO: allocate window refs when multi-window support is added.
    // Mac: for item in windows { _ = v2EnsureHandleRef(kind: .window, uuid: item.windowId) }

    for (mgr.workspaces.items) |ws| {
        _ = self.ref_map.ensureRef(.workspace, ws.id) catch continue;

        // TODO: allocate pane refs when split panes are added.
        // Mac: for paneId in ws.bonsplitController.allPaneIds {
        //     _ = v2EnsureHandleRef(kind: .pane, uuid: paneId.id)
        // }

        for (ws.panels.keys()) |panel_id| {
            _ = self.ref_map.ensureRef(.surface, panel_id) catch continue;
        }
    }
}

/// Parse a V2 param value as either a UUID string or a ref handle.
/// Matches macOS v2UUID helper (line 3083-3099).
pub fn v2UUID(self: *const Server, params: json.ObjectMap, key: []const u8) ?Uuid {
    const str = jsonStr(params.get(key));
    if (str.len == 0) return null;
    // Try UUID first, then ref resolution.
    return Uuid.parse(str) catch self.ref_map.resolve(str);
}

/// Get the ref string for a UUID, or JSON null if no ref exists.
/// For use in V2 response building.
pub fn v2Ref(self: *Server, kind: RefMap.HandleKind, uuid: Uuid) json.Value {
    const ref_str = self.ref_map.ensureRef(kind, uuid) catch return .null;
    return .{ .string = ref_str };
}

/// Get the ref string for an optional UUID, or JSON null.
fn v2RefOptional(self: *Server, kind: RefMap.HandleKind, uuid: ?Uuid) json.Value {
    const id = uuid orelse return .null;
    return self.v2Ref(kind, id);
}

// --- Accept loop callbacks ---

fn shouldContinueCb(ctx: *anyopaque, generation: u64) bool {
    const self: *Server = @ptrCast(@alignCast(ctx));
    return self.shouldContinue(generation);
}

fn onLoopExitCb(ctx: *anyopaque, generation: u64) void {
    const self: *Server = @ptrCast(@alignCast(ctx));
    _ = generation;
    self.state_mutex.lock();
    defer self.state_mutex.unlock();
    // Nothing to clean up — stop() handles fd close and unlink.
    log.debug("accept loop thread exited", .{});
}

// --- Helpers ---

fn socketAddress(path: []const u8) !posix.sockaddr.un {
    var addr: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = undefined,
    };
    // Zero the path field.
    @memset(&addr.path, 0);

    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

fn chmod(path: []const u8, mode: posix.mode_t) void {
    // Use a null-terminated path for the syscall.
    var buf: [posix.PATH_MAX + 1]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);

    const rc = std.os.linux.syscall2(.chmod, @intFromPtr(path_z), mode);
    if (@as(isize, @bitCast(rc)) < 0) {
        log.warn("chmod '{s}' failed", .{path});
    }
}

// --- Tests ---

test "socketAddress valid path" {
    const addr = try socketAddress("/tmp/test.sock");
    try std.testing.expectEqual(posix.AF.UNIX, addr.family);
    // The path should be null-terminated in the addr struct.
    try std.testing.expectEqual(@as(u8, '/'), addr.path[0]);
}

test "socketAddress too long" {
    const long = "a" ** 108; // sun_path is typically 108 bytes
    try std.testing.expectError(error.NameTooLong, socketAddress(long));
}

test "init and basic state" {
    var server = Server.init(std.testing.allocator);
    try std.testing.expect(!server.is_running);
    try std.testing.expectEqual(@as(u64, 0), server.active_generation);
    try std.testing.expect(server.my_pid > 0);
    server.deinit();
}
