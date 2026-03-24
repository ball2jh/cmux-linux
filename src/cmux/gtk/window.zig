const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");

const gresource = @import("../../apprt/gtk/build/gresource.zig");
const Common = @import("../../apprt/gtk/class.zig").Common;
const ext = @import("../../apprt/gtk/ext.zig");
const Config = @import("../../apprt/gtk/class/config.zig").Config;
const Application = @import("../../apprt/gtk/class/application.zig").Application;
const SplitTree = @import("../../apprt/gtk/class/split_tree.zig").SplitTree;
const Surface = @import("../../apprt/gtk/class/surface.zig").Surface;

const cmux = @import("../main.zig");
const bridge = @import("bridge.zig");

const log = std.log.scoped(.cmux_window);

pub const CmuxWindow = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "CmuxWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };
    };

    const Private = struct {
        // Template children
        split_view: *adw.OverlaySplitView = undefined,
        sidebar_list: *gtk.ListBox = undefined,
        workspace_stack: *gtk.Stack = undefined,
        window_title: *adw.WindowTitle = undefined,
        toast_overlay: *adw.ToastOverlay = undefined,

        // Configuration
        config: ?*Config = null,

        // cmux state (heap-allocated, owned by this window)
        manager: ?*cmux.workspace.Manager = null,
        server: ?*cmux.Server = null,
        ghostty_config: ?*cmux.GhosttyConfig.GhosttyConfig = null,

        // Bridge context (stable pointer for callbacks)
        bridge_ctx: ?*bridge.BridgeContext = null,

        // Title tracking: the surface whose title we're currently displaying.
        tracked_surface: ?*Surface = null,

        // Surface UUID tracking for V2 protocol.
        surface_map: std.AutoArrayHashMapUnmanaged(cmux.Uuid, *Surface) = .{},
        surface_reverse: std.AutoArrayHashMapUnmanaged(usize, cmux.Uuid) = .{},

        // Session persistence state
        autosave_source_id: c_uint = 0,
        last_autosave_fingerprint: ?u64 = null,
        last_autosave_time: i64 = 0,

        pub var offset: c_int = 0;
    };

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    /// Create a new CmuxWindow.
    pub fn new(app: *Application) *Self {
        const self: *Self = gobject.ext.newInstance(Self, .{
            .application = app.as(gtk.Application),
        });

        const priv = self.private();
        const alloc = app.allocator();

        // Wire dispatch to real GLib functions
        cmux.dispatch.idle_add_fn = &glibIdleAdd;
        cmux.dispatch.timeout_add_fn = &glibTimeoutAdd;

        // Create the workspace manager
        const manager = alloc.create(cmux.workspace.Manager) catch @panic("oom");
        manager.* = cmux.workspace.Manager.init(alloc);
        priv.manager = manager;

        // Create the socket server and wire the manager
        const server = alloc.create(cmux.Server) catch @panic("oom");
        server.* = cmux.Server.init(alloc);
        server.workspace_manager = manager;
        server.cmux_window = @ptrCast(self);
        server.window_ops = .{
            .ctx = @ptrCast(self),
            .listSurfacesFn = &windowOpsListSurfaces,
            .currentSurfaceFn = &windowOpsCurrentSurface,
            .splitFn = &windowOpsSplit,
            .closeSurfaceFn = &windowOpsCloseSurface,
            .focusSurfaceFn = &windowOpsFocusSurface,
            .readScrollbackFn = &windowOpsReadScrollback,
        };
        priv.server = server;

        // Wire up the bridge (Manager events → GTK)
        const bridge_ctx = alloc.create(bridge.BridgeContext) catch @panic("oom");
        bridge_ctx.* = .{ .window = self };
        priv.bridge_ctx = bridge_ctx;
        manager.setOnChange(&bridge.onManagerChange, @ptrCast(bridge_ctx));

        // Start the socket server
        var path_buf: [std.posix.PATH_MAX]u8 = undefined;
        if (cmux.socket_path.defaultPath(&path_buf)) |path| {
            cmux.socket_path.ensureParentDir(path) catch |err| {
                log.warn("failed to ensure socket parent dir: {}", .{err});
            };
            server.start(path, .allow_all) catch |err| {
                log.warn("failed to start socket server: {}", .{err});
            };
            cmux.socket_path.recordLastPath(path);
        } else |err| {
            log.warn("failed to resolve socket path: {}", .{err});
        }

        // Load Ghostty appearance config
        const style = app.as(adw.Application).getStyleManager();
        const scheme: cmux.GhosttyConfig.ColorSchemePreference = if (style.getDark() == 0)
            .light
        else
            .dark;
        if (cmux.GhosttyConfig.load(alloc, scheme, true)) |cfg| {
            priv.ghostty_config = cfg;
            log.info("loaded ghostty config (scheme={s}, bg=#{x:0>2}{x:0>2}{x:0>2}, font={s})", .{
                @tagName(scheme),
                cfg.background_color.r,
                cfg.background_color.g,
                cfg.background_color.b,
                cfg.font_family,
            });
        } else |err| {
            log.warn("failed to load ghostty config: {}", .{err});
        }

        // Attempt session restore
        var did_restore = false;
        if (cmux.persistence.restore_policy.shouldAttemptRestore()) {
            if (cmux.persistence.store.load(alloc, null)) |loaded| {
                defer loaded.deinit();
                if (loaded.value.windows.len > 0) {
                    manager.restoreSessionSnapshot(loaded.value.windows[0].tab_manager) catch |err| {
                        log.warn("failed to restore session: {}", .{err});
                    };
                    if (manager.workspaceCount() > 0) {
                        did_restore = true;
                        log.info("restored session with {} workspace(s)", .{manager.workspaceCount()});
                    }
                }
            }
        }

        // Create initial workspace only if restore didn't add any
        if (!did_restore) {
            _ = manager.createWorkspace(.{ .title = "Terminal" }) catch |err| {
                log.err("failed to create initial workspace: {}", .{err});
            };
        }

        // Start autosave timer
        self.startAutosaveTimer();

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        self.initActionMap();
    }

    // -----------------------------------------------------------------
    // Active surface (for routing actions)
    // -----------------------------------------------------------------

    /// Get the active surface from the currently visible workspace's SplitTree.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const priv = self.private();
        const visible = priv.workspace_stack.getVisibleChild() orelse return null;
        const split_tree = gobject.ext.cast(SplitTree, visible) orelse return null;
        return split_tree.getActiveSurface();
    }

    /// Perform a binding action on the active surface.
    fn performBindingAction(self: *Self, action: input.Binding.Action) void {
        const surface = self.getActiveSurface() orelse return;
        const core_surface = surface.core() orelse return;
        _ = core_surface.performBindingAction(action) catch |err| {
            log.warn("error performing binding action error={}", .{err});
            return;
        };
    }

    // -----------------------------------------------------------------
    // Title tracking — keeps headerbar showing terminal process title
    // -----------------------------------------------------------------

    /// Start tracking the active surface's title. Disconnects the previous
    /// surface's handler if any, connects to the new one.
    fn trackActiveSurfaceTitle(self: *Self) void {
        const priv = self.private();

        // Disconnect previous surface's handlers
        if (priv.tracked_surface) |old| {
            _ = gobject.signalHandlersDisconnectMatched(
                old.as(gobject.Object),
                .{ .data = true },
                0, 0, null, null, self,
            );
            priv.tracked_surface = null;
        }

        // Connect to the new active surface
        const surface = self.getActiveSurface() orelse {
            priv.window_title.setTitle("cmux");
            return;
        };

        priv.tracked_surface = surface;
        _ = gobject.Object.signals.notify.connect(
            surface,
            *Self,
            onSurfaceTitleChanged,
            self,
            .{ .detail = "title" },
        );
        // Set initial title from surface
        self.updateTitleFromSurface(surface);
    }

    fn onSurfaceTitleChanged(
        surface: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.updateTitleFromSurface(surface);
    }



    fn updateTitleFromSurface(self: *Self, surface: *Surface) void {
        const priv = self.private();

        // Title: the terminal's effective title (OSC 0/2 or process name).
        // Mac shows only this — no subtitle. Directory context comes from
        // a folder icon (future).
        if (surface.getEffectiveTitle()) |title| {
            if (title.len > 0) {
                priv.window_title.setTitle(title);
                return;
            }
        }
        priv.window_title.setTitle("cmux");
    }

    // -----------------------------------------------------------------
    // Action map (win.* actions)
    // -----------------------------------------------------------------

    fn initActionMap(self: *Self) void {
        const actions = [_]ext.actions.Action(Self){
            .init("close", actionClose, null),
            .init("new-workspace", actionNewWorkspace, null),
            .init("close-workspace", actionCloseWorkspace, null),
            .init("split-right", actionSplitRight, null),
            .init("split-down", actionSplitDown, null),
            .init("split-left", actionSplitLeft, null),
            .init("split-up", actionSplitUp, null),
            .init("copy", actionCopy, null),
            .init("paste", actionPaste, null),
            .init("reset", actionReset, null),
            .init("clear", actionClear, null),
            // Map Ghostty's "new-tab" to new workspace for compat
            .init("new-tab", actionNewWorkspace, null),
        };
        ext.actions.add(Self, self, &actions);
    }

    fn actionClose(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.as(gtk.Window).close();
    }

    fn actionNewWorkspace(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        _ = manager.createWorkspace(.{ .title = "Terminal" }) catch |err| {
            log.err("failed to create workspace: {}", .{err});
        };
    }

    fn actionCloseWorkspace(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const selected = manager.selected_id orelse return;
        manager.closeWorkspace(selected) catch {};
    }

    fn actionSplitRight(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .right });
    }

    fn actionSplitDown(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .down });
    }

    fn actionSplitLeft(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .left });
    }

    fn actionSplitUp(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .up });
    }

    fn actionCopy(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performBindingAction(.{ .copy_to_clipboard = .mixed });
    }

    fn actionPaste(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performBindingAction(.paste_from_clipboard);
    }

    fn actionReset(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performBindingAction(.reset);
    }

    fn actionClear(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performBindingAction(.clear_screen);
    }

    // -----------------------------------------------------------------
    // String helpers
    // -----------------------------------------------------------------

    fn sliceToZ(buf: [:0]u8, src: []const u8) [*:0]const u8 {
        const len = @min(src.len, buf.len);
        @memcpy(buf[0..len], src[0..len]);
        buf[len] = 0;
        return @ptrCast(buf.ptr);
    }

    // -----------------------------------------------------------------
    // UUID ↔ widget name helpers
    // -----------------------------------------------------------------

    fn uuidToName(id: cmux.Uuid) [36:0]u8 {
        const formatted = id.format();
        var buf: [36:0]u8 = undefined;
        @memcpy(&buf, &formatted);
        return buf;
    }

    fn nameToUuid(name_z: [*:0]const u8) ?cmux.Uuid {
        const name = std.mem.span(name_z);
        return cmux.Uuid.parse(name) catch null;
    }

    // -----------------------------------------------------------------
    // Workspace event handlers (called by bridge on GTK main thread)
    // -----------------------------------------------------------------

    pub fn handleWorkspaceAdded(self: *Self, id: cmux.Uuid) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const ws = manager.workspaceById(id) orelse return;

        // Create sidebar row
        const row = self.createSidebarRow(ws);
        priv.sidebar_list.append(row.as(gtk.Widget));

        // Create a SplitTree for this workspace and add to the stack
        const split_tree = gobject.ext.newInstance(SplitTree, .{});

        // If restoring with scrollback, pass the replay file as additional env.
        const scrollback_env: ?[2][:0]const u8 = if (ws.restore_scrollback_path) |path| blk: {
            const alloc = Application.default().allocator();
            const key = alloc.dupeZ(u8, cmux.persistence.scrollback_replay.environment_key) catch break :blk null;
            const val = alloc.dupeZ(u8, path) catch {
                alloc.free(key);
                break :blk null;
            };
            break :blk .{ key, val };
        } else null;

        if (scrollback_env) |env| {
            split_tree.newSplit(.right, null, .{
                .working_directory = if (ws.current_directory.len > 0) blk: {
                    const alloc = Application.default().allocator();
                    break :blk alloc.dupeZ(u8, ws.current_directory) catch null;
                } else null,
                .additional_env = &env,
            }) catch {
                log.err("failed to create initial surface for workspace", .{});
                return;
            };
            // Consume the one-shot scrollback path
            ws.restore_scrollback_path = null;
        } else {
            split_tree.newSplit(.right, null, .none) catch {
                log.err("failed to create initial surface for workspace", .{});
                return;
            };
        }

        // Listen for active-surface changes to update the title
        _ = gobject.Object.signals.notify.connect(
            split_tree,
            *Self,
            onSplitTreeActiveSurfaceChanged,
            self,
            .{ .detail = "active-surface" },
        );

        // Listen for tree changes to sync surface UUID tracking
        _ = SplitTree.signals.changed.connect(
            split_tree,
            *Self,
            onSplitTreeTreeChanged,
            self,
            .{},
        );

        const name = uuidToName(id);
        _ = priv.workspace_stack.addNamed(split_tree.as(gtk.Widget), &name);
    }

    fn onSplitTreeActiveSurfaceChanged(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // The active surface in the current workspace changed (split focus).
        // Re-track the title.
        self.trackActiveSurfaceTitle();
    }

    pub fn handleWorkspaceRemoved(self: *Self, id: cmux.Uuid) void {
        const priv = self.private();

        if (self.findSidebarRow(id)) |row| {
            priv.sidebar_list.remove(row.as(gtk.Widget));
        }

        const name = uuidToName(id);
        if (priv.workspace_stack.getChildByName(&name)) |child| {
            priv.workspace_stack.remove(child);
        }
    }

    pub fn handleWorkspaceSelected(self: *Self, id: cmux.Uuid) void {
        const priv = self.private();

        // Update stack visible child
        const name = uuidToName(id);
        priv.workspace_stack.setVisibleChildName(&name);

        // Update sidebar selection (signal handler breaks feedback loop)
        if (self.findSidebarRow(id)) |row| {
            priv.sidebar_list.selectRow(row);
        }

        // Track the new workspace's active surface title
        self.trackActiveSurfaceTitle();

        // Focus the active surface in the newly selected workspace
        if (self.getActiveSurface()) |surface| {
            _ = surface.as(gtk.Widget).grabFocus();
        }
    }

    pub fn handleWorkspaceReordered(self: *Self) void {
        const priv = self.private();
        const manager = priv.manager orelse return;

        var idx: c_int = 0;
        for (manager.workspaces.items) |ws| {
            if (self.findSidebarRow(ws.id)) |row| {
                priv.sidebar_list.remove(row.as(gtk.Widget));
                priv.sidebar_list.insert(row.as(gtk.Widget), idx);
                idx += 1;
            }
        }
    }

    pub fn handleWorkspaceUpdated(self: *Self, id: cmux.Uuid) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const ws = manager.workspaceById(id) orelse return;

        if (self.findSidebarRow(id)) |row| {
            self.updateSidebarRow(row, ws);
        }
    }

    // -----------------------------------------------------------------
    // Sidebar helpers
    // -----------------------------------------------------------------

    fn createSidebarRow(self: *Self, ws: *const cmux.workspace.Workspace) *gtk.ListBoxRow {
        _ = self;

        const vbox = gtk.Box.new(.vertical, 2);
        vbox.as(gtk.Widget).setMarginTop(8);
        vbox.as(gtk.Widget).setMarginBottom(8);
        vbox.as(gtk.Widget).setMarginStart(10);
        vbox.as(gtk.Widget).setMarginEnd(10);

        var title_buf: [256:0]u8 = undefined;
        const title_label = gtk.Label.new(sliceToZ(&title_buf, ws.displayTitle()));
        title_label.setXalign(0);
        title_label.as(gtk.Widget).addCssClass("heading");
        vbox.append(title_label.as(gtk.Widget));

        var dir_buf: [512:0]u8 = undefined;
        const dir = ws.current_directory;
        const subtitle_label = gtk.Label.new(sliceToZ(&dir_buf, if (dir.len > 0) dir else "~"));
        subtitle_label.setXalign(0);
        subtitle_label.as(gtk.Widget).addCssClass("dim-label");
        subtitle_label.as(gtk.Widget).addCssClass("caption");
        vbox.append(subtitle_label.as(gtk.Widget));

        const row = gtk.ListBoxRow.new();
        row.setChild(vbox.as(gtk.Widget));

        const name = uuidToName(ws.id);
        row.as(gtk.Widget).setName(&name);

        return row;
    }

    fn updateSidebarRow(self: *Self, row: *gtk.ListBoxRow, ws: *const cmux.workspace.Workspace) void {
        _ = self;

        const child = row.getChild() orelse return;
        const box_widget = gobject.ext.cast(gtk.Box, child) orelse return;
        const first_child = box_widget.as(gtk.Widget).getFirstChild() orelse return;
        const title_label = gobject.ext.cast(gtk.Label, first_child) orelse return;

        var title_buf: [256:0]u8 = undefined;
        title_label.setLabel(sliceToZ(&title_buf, ws.displayTitle()));

        const second_child = first_child.getNextSibling() orelse return;
        const subtitle_label = gobject.ext.cast(gtk.Label, second_child) orelse return;
        var dir_buf: [512:0]u8 = undefined;
        const dir = ws.current_directory;
        subtitle_label.setLabel(sliceToZ(&dir_buf, if (dir.len > 0) dir else "~"));
    }

    fn findSidebarRow(self: *Self, id: cmux.Uuid) ?*gtk.ListBoxRow {
        const priv = self.private();
        const target_name = uuidToName(id);

        var idx: c_int = 0;
        while (true) : (idx += 1) {
            const row = priv.sidebar_list.getRowAtIndex(idx) orelse break;
            const widget_name: [*:0]const u8 = row.as(gtk.Widget).getName();
            if (std.mem.eql(u8, std.mem.span(widget_name), &target_name)) {
                return row;
            }
        }
        return null;
    }

    // -----------------------------------------------------------------
    // Surface UUID tracking for V2 protocol
    // -----------------------------------------------------------------

    fn registerSurface(self: *Self, ws_id: cmux.Uuid, surface: *Surface) ?cmux.Uuid {
        const priv = self.private();
        const mgr = priv.manager orelse return null;
        const ws = mgr.workspaceById(ws_id) orelse return null;
        const alloc = Application.default().allocator();

        const panel_id = cmux.Uuid.generate();
        ws.addPanel(.{ .terminal = .{
            .id = panel_id,
            .workspace_id = ws_id,
        } }) catch return null;

        priv.surface_map.put(alloc, panel_id, surface) catch return null;
        priv.surface_reverse.put(alloc, @intFromPtr(surface), panel_id) catch return null;

        return panel_id;
    }

    fn unregisterSurface(self: *Self, surface: *Surface) void {
        const priv = self.private();
        const addr = @intFromPtr(surface);
        const panel_id = priv.surface_reverse.get(addr) orelse return;
        const alloc = Application.default().allocator();

        // Remove from workspace Panel model
        if (priv.manager) |mgr| {
            for (mgr.workspaces.items) |ws| {
                if (ws.panelById(panel_id) != null) {
                    ws.removePanel(panel_id);
                    break;
                }
            }
        }

        _ = priv.surface_map.swapRemove(panel_id);
        _ = priv.surface_reverse.swapRemove(addr);
        _ = alloc;
    }

    fn surfaceUuid(self: *Self, surface: *Surface) ?cmux.Uuid {
        return self.private().surface_reverse.get(@intFromPtr(surface));
    }

    fn findSurface(self: *Self, surface_id: cmux.Uuid) ?*Surface {
        return self.private().surface_map.get(surface_id);
    }

    /// Get the SplitTree widget for a workspace by UUID.
    fn getSplitTreeForWorkspace(self: *Self, ws_id: cmux.Uuid) ?*SplitTree {
        const priv = self.private();
        const name = uuidToName(ws_id);
        const child = priv.workspace_stack.getChildByName(&name) orelse return null;
        return gobject.ext.cast(SplitTree, child);
    }

    /// Find the workspace UUID that owns a given SplitTree widget.
    fn workspaceIdForSplitTree(self: *Self, split_tree: *SplitTree) ?cmux.Uuid {
        const priv = self.private();
        const mgr = priv.manager orelse return null;
        for (mgr.workspaces.items) |ws| {
            const name = uuidToName(ws.id);
            const child = priv.workspace_stack.getChildByName(&name) orelse continue;
            if (gobject.ext.cast(SplitTree, child)) |st| {
                if (st == split_tree) return ws.id;
            }
        }
        return null;
    }

    /// Sync surface registrations when a SplitTree's tree changes.
    /// Diffs old vs new tree leaves and registers/unregisters surfaces.
    fn syncSurfacesForTree(
        self: *Self,
        ws_id: cmux.Uuid,
        old_tree: ?*const Surface.Tree,
        new_tree: ?*const Surface.Tree,
    ) void {
        // Collect old surfaces
        var old_set: [64]*Surface = undefined;
        var old_count: usize = 0;
        if (old_tree) |ot| {
            var it = ot.iterator();
            while (it.next()) |entry| {
                if (old_count < old_set.len) {
                    old_set[old_count] = entry.view;
                    old_count += 1;
                }
            }
        }

        // Collect new surfaces
        var new_set: [64]*Surface = undefined;
        var new_count: usize = 0;
        if (new_tree) |nt| {
            var it = nt.iterator();
            while (it.next()) |entry| {
                if (new_count < new_set.len) {
                    new_set[new_count] = entry.view;
                    new_count += 1;
                }
            }
        }

        // Register surfaces in new but not in old
        for (new_set[0..new_count]) |surface| {
            var found = false;
            for (old_set[0..old_count]) |old_s| {
                if (old_s == surface) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                _ = self.registerSurface(ws_id, surface);
            }
        }

        // Unregister surfaces in old but not in new
        for (old_set[0..old_count]) |surface| {
            var found = false;
            for (new_set[0..new_count]) |new_s| {
                if (new_s == surface) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.unregisterSurface(surface);
            }
        }
    }

    fn onSplitTreeTreeChanged(
        split_tree: *SplitTree,
        old_tree: ?*const Surface.Tree,
        new_tree: ?*const Surface.Tree,
        self: *Self,
    ) callconv(.c) void {
        const ws_id = self.workspaceIdForSplitTree(split_tree) orelse return;
        self.syncSurfacesForTree(ws_id, old_tree, new_tree);
    }

    // -----------------------------------------------------------------
    // WindowOps callbacks (called via syncOnMainThread from socket)
    // -----------------------------------------------------------------

    fn windowOpsListSurfaces(ctx: *anyopaque, ws_id: cmux.Uuid, alloc: Allocator, out: *cmux.window_ops.SurfaceInfoList) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const split_tree = self.getSplitTreeForWorkspace(ws_id) orelse return;
        const tree = split_tree.getTree() orelse return;

        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface: *Surface = entry.view;
            const id = self.surfaceUuid(surface) orelse continue;
            out.append(alloc, .{
                .id = id,
                .title = if (surface.getEffectiveTitle()) |t| t[0..t.len] else "",
                .pwd = if (surface.getPwd()) |p| p[0..p.len] else "",
                .focused = surface.getFocused(),
            }) catch continue;
        }
    }

    fn windowOpsCurrentSurface(ctx: *anyopaque, ws_id: cmux.Uuid) ?cmux.window_ops.SurfaceInfo {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const split_tree = self.getSplitTreeForWorkspace(ws_id) orelse return null;
        const surface = split_tree.getActiveSurface() orelse return null;
        const id = self.surfaceUuid(surface) orelse return null;
        return .{
            .id = id,
            .title = if (surface.getEffectiveTitle()) |t| t[0..t.len] else "",
            .pwd = if (surface.getPwd()) |p| p[0..p.len] else "",
            .focused = surface.getFocused(),
        };
    }

    fn windowOpsSplit(ctx: *anyopaque, ws_id: cmux.Uuid, direction: cmux.window_ops.Direction) ?cmux.window_ops.SplitResult {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const split_tree = self.getSplitTreeForWorkspace(ws_id) orelse return null;

        // Map cmux Direction to SplitTree Direction
        const split_dir: Surface.Tree.Split.Direction = switch (direction) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        };

        split_tree.newSplit(split_dir, null, .none) catch return null;

        // The changed signal fires synchronously during newSplit, so the new
        // surface is already registered. Find it as the new active surface.
        const new_surface = split_tree.getActiveSurface() orelse return null;
        const new_id = self.surfaceUuid(new_surface) orelse return null;
        return .{ .surface_id = new_id };
    }

    fn windowOpsCloseSurface(ctx: *anyopaque, ws_id: cmux.Uuid, surface_id: ?cmux.Uuid) ?cmux.Uuid {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = ws_id;

        const target_surface: *Surface = if (surface_id) |sid|
            self.findSurface(sid) orelse return null
        else blk: {
            // Close focused surface in the visible workspace
            break :blk self.getActiveSurface() orelse return null;
        };

        const closed_id = self.surfaceUuid(target_surface) orelse surface_id;
        target_surface.close();
        return closed_id;
    }

    fn windowOpsFocusSurface(ctx: *anyopaque, ws_id: cmux.Uuid, surface_id: cmux.Uuid) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = ws_id;
        const surface = self.findSurface(surface_id) orelse return false;
        _ = surface.as(gtk.Widget).grabFocus();
        return true;
    }

    /// Read terminal scrollback text for a surface by UUID.
    fn windowOpsReadScrollback(ctx: *anyopaque, alloc: std.mem.Allocator, surface_id: cmux.Uuid) ?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const surface = self.findSurface(surface_id) orelse return null;
        const core_surface = surface.core() orelse return null;

        // Lock the renderer state to safely read the terminal screen.
        core_surface.renderer_state.mutex.lock();
        defer core_surface.renderer_state.mutex.unlock();

        const screen = core_surface.io.terminal.screens.active;
        return screen.dumpStringAlloc(alloc, .{ .screen = .{} }) catch |err| {
            log.warn("failed to read scrollback for surface: {}", .{err});
            return null;
        };
    }

    // -----------------------------------------------------------------
    // Template callbacks
    // -----------------------------------------------------------------

    fn onAddWorkspace(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        _ = manager.createWorkspace(.{ .title = "Terminal" }) catch |err| {
            log.err("failed to create workspace: {}", .{err});
            return;
        };
    }

    fn onRowSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const selected_row = row orelse return;

        const widget_name: [*:0]const u8 = selected_row.as(gtk.Widget).getName();
        const id = nameToUuid(widget_name) orelse return;

        // Break feedback loop
        if (manager.selected_id) |sel| {
            if (sel.eql(id)) return;
        }

        manager.selectWorkspace(id);
    }

    // -----------------------------------------------------------------
    // GLib dispatch wrappers
    // -----------------------------------------------------------------

    fn glibIdleAdd(func: cmux.dispatch.SourceFunc, userdata: ?*anyopaque) callconv(.c) c_uint {
        return glib.idleAdd(func, userdata);
    }

    fn glibTimeoutAdd(delay_ms: c_uint, func: cmux.dispatch.SourceFunc, userdata: ?*anyopaque) callconv(.c) c_uint {
        return glib.timeoutAdd(delay_ms, func, userdata);
    }

    // -----------------------------------------------------------------
    // Session persistence — autosave
    // -----------------------------------------------------------------

    fn startAutosaveTimer(self: *Self) void {
        const priv = self.private();
        if (priv.autosave_source_id != 0) return;
        priv.autosave_source_id = glib.timeoutAdd(
            cmux.persistence.policy.autosave_interval_ms,
            &autosaveCallback,
            @ptrCast(self),
        );
    }

    fn stopAutosaveTimer(self: *Self) void {
        const priv = self.private();
        if (priv.autosave_source_id != 0) {
            _ = glib.Source.remove(priv.autosave_source_id);
            priv.autosave_source_id = 0;
        }
    }

    fn autosaveCallback(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 1));
        self.runAutosave(false);
        return 1; // G_SOURCE_CONTINUE
    }

    fn runAutosave(self: *Self, include_scrollback: bool) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const alloc = Application.default().allocator();

        // Fingerprint-based dedup (skip if unchanged within 60s)
        if (!include_scrollback) {
            const fp = manager.sessionAutosaveFingerprint();
            const now = std.time.milliTimestamp();
            if (priv.last_autosave_fingerprint) |last_fp| {
                if (fp == last_fp and (now - priv.last_autosave_time) < cmux.persistence.policy.max_autosave_skip_interval_ms) {
                    return;
                }
            }
            priv.last_autosave_fingerprint = fp;
            priv.last_autosave_time = now;
        }

        // Build snapshot with scrollback reader bridged from window_ops
        const snap_mod = cmux.workspace.snapshot;
        const Workspace = cmux.workspace.Workspace;
        const scrollback_reader: Workspace.ScrollbackReader = if (priv.server) |s| blk: {
            break :blk if (s.window_ops) |ops|
                .{ .ctx = ops.ctx, .readFn = ops.readScrollbackFn }
            else
                .{};
        } else .{};
        const tm_snap = manager.sessionSnapshot(alloc, include_scrollback, scrollback_reader) catch |err| {
            log.warn("failed to build session snapshot: {}", .{err});
            return;
        };

        const app_snap = snap_mod.AppSessionSnapshot{
            .version = snap_mod.AppSessionSnapshot.current_version,
            .created_at = @as(f64, @floatFromInt(std.time.timestamp())),
            .windows = &.{.{
                .tab_manager = tm_snap,
                .sidebar = .{
                    .is_visible = true,
                    .selection = .tabs,
                },
            }},
        };

        if (cmux.persistence.store.save(alloc, app_snap, null)) {
            log.debug("session saved ({} workspace(s))", .{tm_snap.workspaces.len});
        }

        // Free the snapshot (strings were allocated into alloc)
        for (tm_snap.workspaces) |*ws_s| {
            snap_mod.freeWorkspaceSnapshot(alloc, @constCast(ws_s));
        }
        alloc.free(tm_snap.workspaces);
    }

    // -----------------------------------------------------------------
    // GObject lifecycle
    // -----------------------------------------------------------------

    fn dispose(self: *Self) callconv(.c) void {
        // Save session synchronously before teardown
        self.stopAutosaveTimer();
        self.runAutosave(true);

        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());

        const priv = self.private();

        // Disconnect title tracking
        if (priv.tracked_surface) |old| {
            _ = gobject.signalHandlersDisconnectMatched(
                old.as(gobject.Object),
                .{ .data = true },
                0, 0, null, null, self,
            );
            priv.tracked_surface = null;
        }

        if (priv.config) |c| {
            c.unref();
            priv.config = null;
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent.as(gobject.Object.Class),
            self.as(gobject.Object),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        if (priv.server) |server| {
            server.deinit();
            alloc.destroy(server);
            priv.server = null;
        }

        if (priv.manager) |manager| {
            manager.deinit();
            alloc.destroy(manager);
            priv.manager = null;
        }

        if (priv.bridge_ctx) |ctx| {
            alloc.destroy(ctx);
            priv.bridge_ctx = null;
        }

        priv.surface_map.deinit(alloc);
        priv.surface_reverse.deinit(alloc);

        gobject.Object.virtual_methods.finalize.call(
            Class.parent.as(gobject.Object.Class),
            self.as(gobject.Object),
        );
    }

    // -----------------------------------------------------------------
    // GObject class definition
    // -----------------------------------------------------------------

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(SplitTree);

            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "cmux-window",
                }),
            );

            class.bindTemplateChildPrivate("split_view", .{});
            class.bindTemplateChildPrivate("sidebar_list", .{});
            class.bindTemplateChildPrivate("workspace_stack", .{});
            class.bindTemplateChildPrivate("window_title", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});

            class.bindTemplateCallback("on_add_workspace", &onAddWorkspace);
            class.bindTemplateCallback("on_row_selected", &onRowSelected);

            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
