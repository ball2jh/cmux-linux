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

fn dispatchV1(self: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, line: []const u8) void {
    const cmd = v1.parse(arena, line) catch {
        v1.err(writer, "Failed to parse command") catch {};
        return;
    };

    if (std.mem.eql(u8, cmd.name, "ping")) {
        v1.raw(writer, "PONG") catch {};
    } else if (std.mem.eql(u8, cmd.name, "help")) {
        v1.raw(writer,
            "Available commands: ping, help, new_workspace, list_workspaces, " ++
            "select_workspace, new_window, current_window, toggle_sidebar, " ++
            "new_surface, list_surfaces, report_pwd, focus_window, read_terminal_text, " ++
            "notify, notify_surface, notify_target, list_notifications, clear_notifications",
        ) catch {};
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
    } else if (std.mem.eql(u8, cmd.name, "new_workspace")) {
        self.handleV1NewWorkspace(arena, writer);
    } else if (std.mem.eql(u8, cmd.name, "list_workspaces")) {
        self.handleV1ListWorkspaces(arena, writer);
    } else if (std.mem.eql(u8, cmd.name, "select_workspace")) {
        self.handleV1SelectWorkspace(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "new_window")) {
        self.handleV1NewWindow(writer);
    } else if (std.mem.eql(u8, cmd.name, "current_window")) {
        self.handleV1CurrentWindow(writer);
    } else if (std.mem.eql(u8, cmd.name, "toggle_sidebar")) {
        self.handleV1ToggleSidebar(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "new_surface")) {
        self.handleV1NewSurface(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "list_surfaces")) {
        self.handleV1ListSurfaces(arena, writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "report_pwd")) {
        self.handleV1ReportPwd(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "focus_window")) {
        self.handleV1FocusWindow(writer, cmd.args);
    } else if (std.mem.eql(u8, cmd.name, "read_terminal_text")) {
        self.handleV1ReadTerminalText(arena, writer);
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
        "notification.create",
        "notification.create_for_surface",
        "notification.create_for_target",
        "notification.list",
        "notification.clear",
        "workspace.action",
        "surface.action",
    };
    for (&core_methods) |m| {
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
        const gtk_mod = @import("gtk");
        const adw_mod = @import("adw");
        const gobject_mod = @import("gobject");

        const ctx: *SyncToggleSidebarCtx = @ptrCast(@alignCast(data orelse return 0));
        const win: *gtk_mod.Widget = @ptrCast(@alignCast(ctx.window));
        var child = win.getFirstChild();
        while (child) |c| {
            if (gobject_mod.ext.cast(adw_mod.OverlaySplitView, c)) |split_view| {
                switch (ctx.action) {
                    .show => split_view.setShowSidebar(1),
                    .hide => split_view.setShowSidebar(0),
                    .toggle => {
                        const current = split_view.getShowSidebar();
                        split_view.setShowSidebar(if (current != 0) 0 else 1);
                    },
                }
                return 0;
            }
            child = c.getNextSibling();
        }
        return 0;
    }
};

fn syncToggleSidebar(data: ?*anyopaque) callconv(.c) c_int {
    return SyncToggleSidebarCtx.callback(data);
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

// --- V1 flag argument parser ---

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
