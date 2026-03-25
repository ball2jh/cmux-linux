//! Debug socket command handlers.
//!
//! All debug.* V2 socket commands are dispatched through `dispatch()`.
//! `debug.terminals` is available in all builds; every other command is
//! gated behind `build_config.is_debug` (comptime, stripped in release).
//!
//! Matches macOS TerminalController debug commands (lines 2352-2416,
//! 5008-5265, 10262-10772).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const build_config = @import("../../build_config.zig");
const cmux = @import("../main.zig");
const v2 = cmux.protocol.v2;
const client_handler = cmux.client_handler;
const Server = cmux.Server;
const Uuid = cmux.Uuid;

/// POSIX C environment functions for debug.set_env.
const c_env = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const log = std.log.scoped(.cmux_debug);

/// Dispatch a debug.* V2 method. Called from Server.dispatchV2.
pub fn dispatch(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    // debug.terminals is always available (matches Mac line 2125).
    if (std.mem.eql(u8, req.method, "debug.terminals")) {
        debugTerminals(server, arena, writer, req);
        return;
    }

    // All remaining debug commands are debug-only.
    if (comptime !build_config.is_debug) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.method_not_found, "Unknown method") catch {};
        return;
    }

    // --- Terminal inspection ---
    if (std.mem.eql(u8, req.method, "debug.terminal.is_focused")) {
        debugTerminalIsFocused(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.terminal.read_text")) {
        debugTerminalReadText(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.terminal.render_stats")) {
        debugTerminalRenderStats(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.layout")) {
        debugLayout(server, arena, writer, req);

        // --- Input simulation ---
    } else if (std.mem.eql(u8, req.method, "debug.type")) {
        debugType(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.shortcut.set")) {
        debugShortcutSet(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.shortcut.simulate")) {
        debugShortcutSimulate(server, arena, writer, req);

        // --- App & UI state ---
    } else if (std.mem.eql(u8, req.method, "debug.app.activate")) {
        debugAppActivate(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.sidebar.visible")) {
        debugSidebarVisible(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.notification.focus")) {
        debugNotificationFocus(server, arena, writer, req);

        // --- Command palette ---
    } else if (std.mem.eql(u8, req.method, "debug.command_palette.toggle")) {
        debugCommandPaletteToggle(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.command_palette.rename_tab.open")) {
        debugCommandPaletteRenameTabOpen(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.command_palette.visible")) {
        debugCommandPaletteVisible(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.command_palette.selection")) {
        debugCommandPaletteSelection(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.command_palette.results")) {
        debugCommandPaletteResults(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.command_palette.rename_input.interact")) {
        debugCommandPaletteRenameInputInteract(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.command_palette.rename_input.delete_backward")) {
        debugCommandPaletteRenameInputDeleteBackward(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.command_palette.rename_input.selection")) {
        debugCommandPaletteRenameInputSelection(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.command_palette.rename_input.select_all")) {
        debugCommandPaletteRenameInputSelectAll(server, arena, writer, req);

        // --- Counters & diagnostics ---
    } else if (std.mem.eql(u8, req.method, "debug.flash.count")) {
        debugFlashCount(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.flash.reset")) {
        debugFlashReset(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.empty_panel.count")) {
        debugEmptyPanelCount(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.empty_panel.reset")) {
        debugEmptyPanelReset(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.bonsplit_underflow.count")) {
        debugBonsplitUnderflowCount(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.bonsplit_underflow.reset")) {
        debugBonsplitUnderflowReset(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.portal.stats")) {
        debugPortalStats(server, arena, writer, req);

        // --- Screenshots & snapshots ---
    } else if (std.mem.eql(u8, req.method, "debug.panel_snapshot")) {
        debugPanelSnapshot(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.panel_snapshot.reset")) {
        debugPanelSnapshotReset(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.window.screenshot")) {
        debugWindowScreenshot(server, arena, writer, req);

        // --- Browser ---
    } else if (std.mem.eql(u8, req.method, "debug.browser.address_bar_focused")) {
        debugBrowserAddressBarFocused(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.browser.favicon")) {
        debugBrowserFavicon(server, arena, writer, req);
    } else if (std.mem.eql(u8, req.method, "debug.seed_browser_history")) {
        debugSeedBrowserHistory(server, arena, writer, req);

        // --- Environment ---
    } else if (std.mem.eql(u8, req.method, "debug.set_env")) {
        debugSetEnv(server, arena, writer, req);
    } else {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.method_not_found, "Unknown method") catch {};
    }
}

/// List of all debug method names for system.capabilities.
/// `debug.terminals` is always included; the rest are debug-only.
pub const debug_method_names = [_][]const u8{
    "debug.terminals",
};

/// Debug-only method names (appended when build_config.is_debug).
pub const debug_only_method_names = [_][]const u8{
    "debug.app.activate",
    "debug.bonsplit_underflow.count",
    "debug.bonsplit_underflow.reset",
    "debug.browser.address_bar_focused",
    "debug.browser.favicon",
    "debug.command_palette.rename_input.delete_backward",
    "debug.command_palette.rename_input.interact",
    "debug.command_palette.rename_input.select_all",
    "debug.command_palette.rename_input.selection",
    "debug.command_palette.rename_tab.open",
    "debug.command_palette.results",
    "debug.command_palette.selection",
    "debug.command_palette.toggle",
    "debug.command_palette.visible",
    "debug.empty_panel.count",
    "debug.empty_panel.reset",
    "debug.flash.count",
    "debug.flash.reset",
    "debug.layout",
    "debug.notification.focus",
    "debug.panel_snapshot",
    "debug.panel_snapshot.reset",
    "debug.portal.stats",
    "debug.seed_browser_history",
    "debug.set_env",
    "debug.shortcut.set",
    "debug.shortcut.simulate",
    "debug.sidebar.visible",
    "debug.terminal.is_focused",
    "debug.terminal.read_text",
    "debug.terminal.render_stats",
    "debug.type",
    "debug.window.screenshot",
};

// =========================================================================
// Handler implementations
// =========================================================================

// --- debug.terminals (always available) ----------------------------------

/// Enumerate all terminal surfaces with workspace/panel metadata.
/// Matches macOS v2DebugTerminals (lines 5008-5265).
fn debugTerminals(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const mgr = server.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    var terminals = json.Array.init(arena);
    var global_idx: usize = 0;

    for (mgr.workspaces.items, 0..) |ws, ws_idx| {
        const ws_selected = if (mgr.selected_id) |sel| sel.eql(ws.id) else false;

        var ws_id_buf: [36]u8 = undefined;
        _ = ws.id.formatBuf(&ws_id_buf);
        const ws_id_str = arena.dupe(u8, &ws_id_buf) catch continue;

        for (ws.panels.keys(), ws.panels.values(), 0..) |panel_id, panel, surface_idx| {
            var item = json.ObjectMap.init(arena);

            var sid_buf: [36]u8 = undefined;
            _ = panel_id.formatBuf(&sid_buf);
            const sid_str = arena.dupe(u8, &sid_buf) catch continue;

            // Standard fields matching Mac response shape.
            item.put("index", .{ .integer = @intCast(global_idx) }) catch continue;
            item.put("mapped", .{ .bool = true }) catch continue;
            item.put("tree_visible", .{ .bool = true }) catch continue;

            // Window (Linux: single window, always index 0).
            item.put("window_index", .{ .integer = 0 }) catch continue;

            // Workspace
            item.put("workspace_index", .{ .integer = @intCast(ws_idx) }) catch continue;
            item.put("workspace_id", .{ .string = ws_id_str }) catch continue;
            item.put("workspace_ref", server.v2Ref(.workspace, ws.id)) catch continue;
            item.put("workspace_title", .{ .string = ws.displayTitle() }) catch continue;
            item.put("workspace_selected", .{ .bool = ws_selected }) catch continue;

            // Surface
            item.put("surface_index", .{ .integer = @intCast(surface_idx) }) catch continue;
            item.put("surface_id", .{ .string = sid_str }) catch continue;
            item.put("surface_ref", server.v2Ref(.surface, panel_id)) catch continue;
            item.put("surface_focused", .{ .bool = if (ws.focused_panel_id) |fid| fid.eql(panel_id) else false }) catch continue;
            item.put("surface_pinned", .{ .bool = ws.pinned_panel_ids.contains(panel_id) }) catch continue;

            // Panel type
            item.put("panel_type", .{ .string = switch (panel.panelType()) {
                .terminal => "terminal",
                .browser => "browser",
                .markdown => "markdown",
            } }) catch continue;

            // Title
            if (ws.panel_titles.get(panel_id)) |title| {
                item.put("surface_title", .{ .string = title }) catch {};
            } else {
                switch (panel) {
                    .terminal => |tp| if (tp.title.len > 0) {
                        item.put("surface_title", .{ .string = tp.title }) catch {};
                    },
                    else => {},
                }
            }

            // Directory
            if (ws.panel_directories.get(panel_id)) |dir| {
                item.put("current_directory", .{ .string = dir }) catch {};
            } else {
                switch (panel) {
                    .terminal => |tp| if (tp.directory.len > 0) {
                        item.put("current_directory", .{ .string = tp.directory }) catch {};
                    },
                    else => {},
                }
            }

            // TTY
            if (ws.surface_tty_names.get(panel_id)) |tty| {
                item.put("tty", .{ .string = tty }) catch {};
            } else {
                switch (panel) {
                    .terminal => |tp| if (tp.tty_name) |tty| {
                        item.put("tty", .{ .string = tty }) catch {};
                    },
                    else => {},
                }
            }

            // Git branch
            if (ws.panel_git_branches.get(panel_id)) |git| {
                item.put("git_branch", .{ .string = git.branch }) catch {};
                item.put("git_dirty", .{ .bool = git.is_dirty }) catch {};
            }

            // Listening ports
            if (ws.surface_listening_ports.get(panel_id)) |ports| {
                var port_arr = json.Array.init(arena);
                for (ports) |port| {
                    port_arr.append(.{ .integer = @intCast(port) }) catch continue;
                }
                item.put("listening_ports", .{ .array = port_arr }) catch {};
            } else {
                item.put("listening_ports", .{ .array = json.Array.init(arena) }) catch {};
            }

            // Unread
            item.put("manually_unread", .{ .bool = ws.manual_unread_panel_ids.contains(panel_id) }) catch {};

            terminals.append(.{ .object = item }) catch continue;
            global_idx += 1;
        }
    }

    var result = json.ObjectMap.init(arena);
    result.put("count", .{ .integer = @intCast(global_idx) }) catch {};
    result.put("terminals", .{ .array = terminals }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// --- debug.terminal.is_focused -------------------------------------------

fn debugTerminalIsFocused(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };

    const mgr = server.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    // Check if this surface is the focused panel in the selected workspace.
    var focused = false;
    if (mgr.selected_id) |sel_id| {
        if (mgr.workspaceById(sel_id)) |ws| {
            if (ws.focused_panel_id) |fid| {
                focused = fid.eql(surface_id);
            }
        }
    }

    var result = json.ObjectMap.init(arena);
    result.put("focused", .{ .bool = focused }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// --- debug.terminal.read_text --------------------------------------------

fn debugTerminalReadText(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;
    // Terminal text reading requires CoreSurface access which needs a
    // UUID-to-GTK-Surface mapping. This mapping does not exist yet.
    // TODO: Implement when panel_added bridge wiring provides UUID ↔ Surface links.
    v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Not yet implemented — requires UUID-to-Surface mapping") catch {};
}

// --- debug.terminal.render_stats -----------------------------------------

fn debugTerminalRenderStats(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;
    // Render stats require access to the Surface's renderer internals.
    // TODO: Implement when UUID-to-Surface mapping is available.
    v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Not yet implemented — requires UUID-to-Surface mapping") catch {};
}

// --- debug.layout --------------------------------------------------------

fn debugLayout(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const mgr = server.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    var workspaces_arr = json.Array.init(arena);

    for (mgr.workspaces.items) |ws| {
        var ws_obj = json.ObjectMap.init(arena);
        var ws_id_buf: [36]u8 = undefined;
        _ = ws.id.formatBuf(&ws_id_buf);
        ws_obj.put("id", .{ .string = arena.dupe(u8, &ws_id_buf) catch continue }) catch continue;
        ws_obj.put("title", .{ .string = ws.displayTitle() }) catch continue;
        ws_obj.put("selected", .{ .bool = if (mgr.selected_id) |sel| sel.eql(ws.id) else false }) catch continue;

        // Panel list (flat — tree structure requires GTK SplitTree access).
        var panels_arr = json.Array.init(arena);
        for (ws.panels.keys(), ws.panels.values()) |pid, panel| {
            var p_obj = json.ObjectMap.init(arena);
            var pid_buf: [36]u8 = undefined;
            _ = pid.formatBuf(&pid_buf);
            p_obj.put("surface_id", .{ .string = arena.dupe(u8, &pid_buf) catch continue }) catch continue;
            p_obj.put("type", .{ .string = switch (panel.panelType()) {
                .terminal => "terminal",
                .browser => "browser",
                .markdown => "markdown",
            } }) catch continue;
            p_obj.put("focused", .{ .bool = if (ws.focused_panel_id) |fid| fid.eql(pid) else false }) catch continue;
            panels_arr.append(.{ .object = p_obj }) catch continue;
        }
        ws_obj.put("panels", .{ .array = panels_arr }) catch continue;

        workspaces_arr.append(.{ .object = ws_obj }) catch continue;
    }

    var layout = json.ObjectMap.init(arena);
    layout.put("workspaces", .{ .array = workspaces_arr }) catch {};

    var result = json.ObjectMap.init(arena);
    result.put("layout", .{ .object = layout }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// --- debug.type ----------------------------------------------------------

fn debugType(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;
    const text = jsonStr(req.params.get("text"));
    if (text.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing text") catch {};
        return;
    }

    // Text injection requires the focused Surface's PTY fd or insertText.
    // TODO: Implement via syncOnMainThread → getActiveSurface → write to PTY.
    v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Not yet implemented — requires GTK main thread text injection") catch {};
}

// --- debug.shortcut.set --------------------------------------------------

fn debugShortcutSet(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;
    const name = jsonStr(req.params.get("name"));
    const combo = jsonStr(req.params.get("combo"));
    if (name.len == 0 or combo.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing name/combo") catch {};
        return;
    }

    // TODO: Implement via shortcut.zig infrastructure.
    v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Not yet implemented") catch {};
}

// --- debug.shortcut.simulate ---------------------------------------------

fn debugShortcutSimulate(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;
    const combo = jsonStr(req.params.get("combo"));
    if (combo.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing combo") catch {};
        return;
    }

    // TODO: Implement via shortcut_routing.zig.
    v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Not yet implemented") catch {};
}

// --- debug.app.activate --------------------------------------------------

fn debugAppActivate(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const AppActivateCtx = struct {
        window: *anyopaque,
        done: bool = false,

        fn callback(data: ?*anyopaque) callconv(.c) c_int {
            const gtk = @import("gtk");
            const ctx: *@This() = @ptrCast(@alignCast(data orelse return 0));
            const win: *gtk.Window = @ptrCast(@alignCast(ctx.window));
            win.present();
            ctx.done = true;
            return 0; // G_SOURCE_REMOVE
        }
    };

    const win = server.cmux_window orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window") catch {};
        return;
    };

    var ctx = AppActivateCtx{ .window = win };
    cmux.dispatch.syncOnMainThread(&AppActivateCtx.callback, @ptrCast(&ctx));

    writeEmptyOk(writer, arena, req.id);
}

// --- debug.sidebar.visible -----------------------------------------------

fn debugSidebarVisible(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const SidebarCtx = struct {
        window: *anyopaque,
        visible: bool = false,

        fn callback(data: ?*anyopaque) callconv(.c) c_int {
            const ctx: *@This() = @ptrCast(@alignCast(data orelse return 0));
            const win: *CmuxWindow = @ptrCast(@alignCast(ctx.window));
            ctx.visible = win.isSidebarVisible();
            return 0;
        }
    };

    const win = server.cmux_window orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window") catch {};
        return;
    };

    var ctx = SidebarCtx{ .window = win };
    cmux.dispatch.syncOnMainThread(&SidebarCtx.callback, @ptrCast(&ctx));

    var result = json.ObjectMap.init(arena);
    result.put("visible", .{ .bool = ctx.visible }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// --- debug.notification.focus --------------------------------------------

fn debugNotificationFocus(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const workspace_id = server.v2UUID(req.params, "workspace_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing workspace_id") catch {};
        return;
    };

    const mgr = server.workspace_manager orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No workspace manager") catch {};
        return;
    };

    // Select the workspace.
    mgr.selectWorkspace(workspace_id);

    // Optionally focus a specific surface.
    if (server.v2UUID(req.params, "surface_id")) |surface_id| {
        if (mgr.workspaceById(workspace_id)) |ws| {
            ws.focused_panel_id = surface_id;
        }
    }

    writeEmptyOk(writer, arena, req.id);
}

// --- Command palette commands --------------------------------------------

const CmuxWindow = @import("../gtk/window.zig").CmuxWindow;
const CommandPaletteMod = @import("../gtk/command_palette.zig");
const PaletteType = CommandPaletteMod.CommandPalette;

fn debugCommandPaletteToggle(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const mode_str = jsonStr(req.params.get("mode"));

    const PaletteToggleCtx = struct {
        window: *anyopaque,
        mode_str: []const u8,

        fn callback(data: ?*anyopaque) callconv(.c) c_int {
            const ctx: *@This() = @ptrCast(@alignCast(data orelse return 0));
            const win: *CmuxWindow = @ptrCast(@alignCast(ctx.window));
            const palette = win.getCommandPalette() orelse return 0;
            const mode: CommandPaletteMod.PaletteMode = if (std.mem.eql(u8, ctx.mode_str, "switcher"))
                .switcher
            else if (std.mem.eql(u8, ctx.mode_str, "rename"))
                .rename
            else
                .commands;
            palette.toggle(mode);
            return 0;
        }
    };

    const win = server.cmux_window orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window") catch {};
        return;
    };

    var ctx = PaletteToggleCtx{ .window = win, .mode_str = mode_str };
    cmux.dispatch.syncOnMainThread(&PaletteToggleCtx.callback, @ptrCast(&ctx));
    writeEmptyOk(writer, arena, req.id);
}

fn debugCommandPaletteRenameTabOpen(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const PaletteRenameCtx = struct {
        window: *anyopaque,
        fn callback(data: ?*anyopaque) callconv(.c) c_int {
            const ctx: *@This() = @ptrCast(@alignCast(data orelse return 0));
            const win: *CmuxWindow = @ptrCast(@alignCast(ctx.window));
            const palette = win.getCommandPalette() orelse return 0;
            palette.show(.rename);
            return 0;
        }
    };

    const win = server.cmux_window orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window") catch {};
        return;
    };
    var ctx = PaletteRenameCtx{ .window = win };
    cmux.dispatch.syncOnMainThread(&PaletteRenameCtx.callback, @ptrCast(&ctx));
    writeEmptyOk(writer, arena, req.id);
}

fn debugCommandPaletteVisible(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const PaletteVisibleCtx = struct {
        window: *anyopaque,
        visible: bool = false,
        fn callback(data: ?*anyopaque) callconv(.c) c_int {
            const ctx: *@This() = @ptrCast(@alignCast(data orelse return 0));
            const win: *CmuxWindow = @ptrCast(@alignCast(ctx.window));
            const palette = win.getCommandPalette() orelse return 0;
            ctx.visible = palette.isVisible();
            return 0;
        }
    };

    const win = server.cmux_window orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window") catch {};
        return;
    };
    var ctx = PaletteVisibleCtx{ .window = win };
    cmux.dispatch.syncOnMainThread(&PaletteVisibleCtx.callback, @ptrCast(&ctx));

    var result = json.ObjectMap.init(arena);
    result.put("visible", .{ .bool = ctx.visible }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn debugCommandPaletteSelection(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const PaletteSelCtx = struct {
        window: *anyopaque,
        visible: bool = false,
        selected_index: i32 = 0,
        fn callback(data: ?*anyopaque) callconv(.c) c_int {
            const ctx: *@This() = @ptrCast(@alignCast(data orelse return 0));
            const win: *CmuxWindow = @ptrCast(@alignCast(ctx.window));
            const palette = win.getCommandPalette() orelse return 0;
            ctx.visible = palette.isVisible();
            ctx.selected_index = palette.getSelectedIndex();
            return 0;
        }
    };

    const win = server.cmux_window orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window") catch {};
        return;
    };
    var ctx = PaletteSelCtx{ .window = win };
    cmux.dispatch.syncOnMainThread(&PaletteSelCtx.callback, @ptrCast(&ctx));

    var result = json.ObjectMap.init(arena);
    result.put("visible", .{ .bool = ctx.visible }) catch {};
    result.put("selected_index", .{ .integer = @intCast(@max(0, ctx.selected_index)) }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn debugCommandPaletteResults(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const PaletteResultsCtx = struct {
        window: *anyopaque,
        alloc: Allocator,
        visible: bool = false,
        selected_index: i32 = 0,
        query: []const u8 = "",
        mode: []const u8 = "commands",
        rows: json.Array = undefined,

        fn callback(data: ?*anyopaque) callconv(.c) c_int {
            const ctx: *@This() = @ptrCast(@alignCast(data orelse return 0));
            const win: *CmuxWindow = @ptrCast(@alignCast(ctx.window));
            const palette = win.getCommandPalette() orelse return 0;
            ctx.visible = palette.isVisible();
            ctx.selected_index = palette.getSelectedIndex();
            ctx.query = palette.getQuery();
            ctx.mode = palette.getMode().toString();

            ctx.rows = json.Array.init(ctx.alloc);
            const results = palette.getResults();
            for (results) |r| {
                var row = json.ObjectMap.init(ctx.alloc);
                row.put("command_id", .{ .string = r.command_id }) catch continue;
                row.put("title", .{ .string = r.title }) catch continue;
                row.put("trailing_label", if (r.trailing_label.len > 0) json.Value{ .string = r.trailing_label } else .null) catch continue;
                row.put("score", .{ .integer = @intCast(r.score) }) catch continue;
                ctx.rows.append(.{ .object = row }) catch continue;
            }
            return 0;
        }
    };

    const win = server.cmux_window orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window") catch {};
        return;
    };
    var ctx = PaletteResultsCtx{ .window = win, .alloc = arena, .rows = json.Array.init(arena) };
    cmux.dispatch.syncOnMainThread(&PaletteResultsCtx.callback, @ptrCast(&ctx));

    var result = json.ObjectMap.init(arena);
    result.put("visible", .{ .bool = ctx.visible }) catch {};
    result.put("selected_index", .{ .integer = @intCast(@max(0, ctx.selected_index)) }) catch {};
    result.put("query", .{ .string = ctx.query }) catch {};
    result.put("mode", .{ .string = ctx.mode }) catch {};
    result.put("results", .{ .array = ctx.rows }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn debugCommandPaletteRenameInputInteract(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;
    writeEmptyOk(writer, arena, req.id);
}

fn debugCommandPaletteRenameInputDeleteBackward(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const RenameDeleteCtx = struct {
        window: *anyopaque,
        fn callback(data: ?*anyopaque) callconv(.c) c_int {
            const gtk_mod = @import("gtk");
            const ctx: *@This() = @ptrCast(@alignCast(data orelse return 0));
            const win: *CmuxWindow = @ptrCast(@alignCast(ctx.window));
            const palette = win.getCommandPalette() orelse return 0;
            const entry = palette.getRenameEntry() orelse return 0;
            const pos = gtk_mod.Editable.getPosition(entry.as(gtk_mod.Editable));
            if (pos > 0) {
                gtk_mod.Editable.deleteText(entry.as(gtk_mod.Editable), pos - 1, pos);
            }
            return 0;
        }
    };

    const win = server.cmux_window orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window") catch {};
        return;
    };
    var ctx = RenameDeleteCtx{ .window = win };
    cmux.dispatch.syncOnMainThread(&RenameDeleteCtx.callback, @ptrCast(&ctx));
    writeEmptyOk(writer, arena, req.id);
}

fn debugCommandPaletteRenameInputSelection(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const RenameSelCtx = struct {
        window: *anyopaque,
        text: []const u8 = "",
        selection_start: c_int = 0,
        selection_end: c_int = 0,

        fn callback(data: ?*anyopaque) callconv(.c) c_int {
            const gtk_mod = @import("gtk");
            const ctx: *@This() = @ptrCast(@alignCast(data orelse return 0));
            const win: *CmuxWindow = @ptrCast(@alignCast(ctx.window));
            const palette = win.getCommandPalette() orelse return 0;
            const entry = palette.getRenameEntry() orelse return 0;
            const buffer = entry.getBuffer();
            ctx.text = std.mem.span(buffer.getText());
            _ = gtk_mod.Editable.getSelectionBounds(entry.as(gtk_mod.Editable), &ctx.selection_start, &ctx.selection_end);
            return 0;
        }
    };

    const win = server.cmux_window orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window") catch {};
        return;
    };
    var ctx = RenameSelCtx{ .window = win };
    cmux.dispatch.syncOnMainThread(&RenameSelCtx.callback, @ptrCast(&ctx));

    var result = json.ObjectMap.init(arena);
    result.put("text", .{ .string = ctx.text }) catch {};
    result.put("selection_start", .{ .integer = @intCast(ctx.selection_start) }) catch {};
    result.put("selection_end", .{ .integer = @intCast(ctx.selection_end) }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn debugCommandPaletteRenameInputSelectAll(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const RenameSelectAllCtx = struct {
        window: *anyopaque,
        fn callback(data: ?*anyopaque) callconv(.c) c_int {
            const gtk_mod = @import("gtk");
            const ctx: *@This() = @ptrCast(@alignCast(data orelse return 0));
            const win: *CmuxWindow = @ptrCast(@alignCast(ctx.window));
            const palette = win.getCommandPalette() orelse return 0;
            const entry = palette.getRenameEntry() orelse return 0;
            gtk_mod.Editable.selectRegion(entry.as(gtk_mod.Editable), 0, -1);
            return 0;
        }
    };

    const win = server.cmux_window orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window") catch {};
        return;
    };
    var ctx = RenameSelectAllCtx{ .window = win };
    cmux.dispatch.syncOnMainThread(&RenameSelectAllCtx.callback, @ptrCast(&ctx));
    writeEmptyOk(writer, arena, req.id);
}


// --- Counter commands ----------------------------------------------------

fn debugFlashCount(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const surface_id = server.v2UUID(req.params, "surface_id") orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing surface_id") catch {};
        return;
    };

    const count = server.debug_counters.getFlashCount(surface_id);
    var result = json.ObjectMap.init(arena);
    result.put("count", .{ .integer = @intCast(count) }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn debugFlashReset(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    server.debug_counters.resetFlashCounts();
    writeEmptyOk(writer, arena, req.id);
}

fn debugEmptyPanelCount(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const count = server.debug_counters.getEmptyPanelCount();
    var result = json.ObjectMap.init(arena);
    result.put("count", .{ .integer = @intCast(count) }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn debugEmptyPanelReset(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    server.debug_counters.resetEmptyPanelCount();
    writeEmptyOk(writer, arena, req.id);
}

fn debugBonsplitUnderflowCount(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const count = server.debug_counters.getBonsplitUnderflowCount();
    var result = json.ObjectMap.init(arena);
    result.put("count", .{ .integer = @intCast(count) }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

fn debugBonsplitUnderflowReset(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    server.debug_counters.resetBonsplitUnderflowCount();
    writeEmptyOk(writer, arena, req.id);
}

fn debugPortalStats(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;
    // No portal system on Linux. Return empty stats stub.
    var result = json.ObjectMap.init(arena);
    result.put("total", .{ .integer = 0 }) catch {};
    result.put("active", .{ .integer = 0 }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = result }) catch {};
}

// --- Screenshot & snapshot commands --------------------------------------

fn debugPanelSnapshot(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;
    // TODO: Implement via GTK widget snapshot API (gtk_widget_paintable_new).
    v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Not yet implemented — requires GTK snapshot API") catch {};
}

fn debugPanelSnapshotReset(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;
    // TODO: Clear stored previous snapshot.
    v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Not yet implemented") catch {};
}

fn debugWindowScreenshot(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;
    // TODO: Implement via GTK window screenshot API.
    v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Not yet implemented — requires GTK snapshot API") catch {};
}

// --- Browser commands ----------------------------------------------------

fn debugBrowserAddressBarFocused(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;
    // TODO: Implement via syncOnMainThread → find browser panel → check address bar focus.
    v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Not yet implemented — requires browser panel GTK integration") catch {};
}

fn debugBrowserFavicon(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;
    // TODO: Implement via syncOnMainThread → WebKitGTK favicon retrieval.
    v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Not yet implemented — requires WebKitGTK favicon API") catch {};
}

// --- debug.set_env -------------------------------------------------------

/// Set an environment variable at runtime.
/// Matches macOS v2DebugSetEnv -- used by UI tests to configure the import
/// wizard fixture and capture settings after launch.
///
/// Params: { "name": "<VAR>", "value": "<VALUE>" }
/// Pass an empty value or omit it to unset the variable.
fn debugSetEnv(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;

    const name = jsonStr(req.params.get("name"));
    if (name.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing name") catch {};
        return;
    }

    const value = jsonStr(req.params.get("value"));

    // We need null-terminated strings for the C setenv/unsetenv calls.
    var name_buf: [512:0]u8 = undefined;
    if (name.len >= name_buf.len) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Name too long") catch {};
        return;
    }
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const name_z: [*:0]const u8 = @ptrCast(&name_buf);

    if (value.len == 0) {
        // Unset.
        _ = c_env.unsetenv(name_z);
    } else {
        var val_buf: [4096:0]u8 = undefined;
        if (value.len >= val_buf.len) {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Value too long") catch {};
            return;
        }
        @memcpy(val_buf[0..value.len], value);
        val_buf[value.len] = 0;
        const val_z: [*:0]const u8 = @ptrCast(&val_buf);
        _ = c_env.setenv(name_z, val_z, 1);
    }

    writeEmptyOk(writer, arena, req.id);
}

// --- debug.seed_browser_history ------------------------------------------

/// Seed the browser history store with test entries.
/// Params: { "entries": [{ "url": "...", "title": "...", "visitCount": N, "typedCount": N }] }
fn debugSeedBrowserHistory(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    _ = server;

    const BrowserPanelView = @import("../gtk/browser_panel_view.zig");

    // Clear existing history
    BrowserPanelView.shared_history_store.clear();

    // Parse entries array from params
    const entries_val = req.params.get("entries") orelse {
        writeEmptyOk(writer, arena, req.id);
        return;
    };

    const entries = switch (entries_val) {
        .array => |arr| arr.items,
        else => {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "entries must be an array") catch {};
            return;
        },
    };

    for (entries) |entry_val| {
        const entry_obj = switch (entry_val) {
            .object => |obj| obj,
            else => continue,
        };

        const url_str = jsonStr(entry_obj.get("url"));
        if (url_str.len == 0) continue;

        const title_str = jsonStr(entry_obj.get("title"));
        const title_opt: ?[]const u8 = if (title_str.len > 0) title_str else null;

        var visit_count: u32 = 1;
        if (entry_obj.get("visitCount")) |vc| {
            visit_count = switch (vc) {
                .integer => |i| @intCast(@max(0, i)),
                else => 1,
            };
        }

        var typed_count: u32 = 0;
        if (entry_obj.get("typedCount")) |tc| {
            typed_count = switch (tc) {
                .integer => |i| @intCast(@max(0, i)),
                else => 0,
            };
        }

        BrowserPanelView.shared_history_store.addEntry(url_str, title_opt, visit_count, typed_count);
    }

    writeEmptyOk(writer, arena, req.id);
}

// =========================================================================
// Helpers
// =========================================================================

fn jsonStr(val: ?json.Value) []const u8 {
    const v = val orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn writeEmptyOk(writer: *client_handler.ResponseWriter, arena: Allocator, id: json.Value) void {
    const result = json.ObjectMap.init(arena);
    v2.writeOk(writer, arena, id, .{ .object = result }) catch {};
}
