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

const gdk = @import("gdk");

const BrowserPanelView = @import("browser_panel_view.zig").BrowserPanelView;
const drop_planner = @import("../sidebar_drop_planner.zig");
const cmux = @import("../main.zig");
const bridge = @import("bridge.zig");
const CommandPalette = @import("command_palette.zig").CommandPalette;
const NotificationsPopover = @import("notifications_popover.zig").NotificationsPopover;
const image_transfer = @import("../image_transfer.zig");
const SshSessionDetector = @import("../remote/SshSessionDetector.zig");

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

    const CloseDialogAction = union(enum) {
        close_window,
        close_workspace: cmux.Uuid,
        close_workspaces: []const cmux.Uuid,
    };

    const Private = struct {
        // Template children
        sidebar_box: *gtk.Box = undefined,
        sidebar_resizer: *gtk.Separator = undefined,
        sidebar_list: *gtk.ListBox = undefined,
        workspace_stack: *gtk.Stack = undefined,
        window_title: *adw.WindowTitle = undefined,
        toast_overlay: *adw.ToastOverlay = undefined,
        palette_overlay: *gtk.Overlay = undefined,
        headerbar: *adw.HeaderBar = undefined,
        help_btn: *gtk.Button = undefined,

        // Help menu / feedback composer (built programmatically)
        help_popover: ?*gtk.Popover = null,
        feedback_overlay: ?*gtk.Widget = null,
        shortcuts_overlay: ?*gtk.Widget = null,

        // Sidebar resize state
        sidebar_width: f64 = cmux.persistence.policy.default_sidebar_width,
        sidebar_visible: bool = true,
        drag_start_width: ?f64 = null,

        // Programmatic widgets (not in BLP template)
        pane_tab_bar: ?*gtk.Box = null,
        toggle_sidebar_btn: ?*gtk.Button = null,
        notifications_btn: ?*gtk.Button = null,
        notifications_badge: ?*gtk.Label = null,
        new_tab_btn: ?*gtk.Button = null,
        new_terminal_btn: ?*gtk.Button = null,

        // Pane tab bar drag state
        tab_dragged_panel_id: ?cmux.Uuid = null,
        tab_drop_indicator: ?drop_planner.DropIndicator = null,
        tab_drop_indicator_widget: ?*gtk.Widget = null,

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

        // Command palette widget
        command_palette: ?*CommandPalette = null,

        // Session persistence state
        autosave_source_id: c_uint = 0,
        last_autosave_fingerprint: ?u64 = null,
        last_autosave_time: i64 = 0,

        // Render diagnostics for UI tests (heap-allocated when enabled).
        render_diag: ?*cmux.render_diagnostics.RenderDiagnostics = null,

        // Browser panel tracking
        browser_panel_map: std.AutoArrayHashMapUnmanaged(cmux.Uuid, *BrowserPanelView) = .{},

        // Notifications popover
        notifications_popover: ?*NotificationsPopover = null,

        // Close confirmation dialog state
        active_close_dialog: ?*adw.AlertDialog = null,
        active_close_dialog_on_confirm: ?CloseDialogAction = null,

        // Sidebar context menu: target workspace ID for action handlers
        sidebar_ctx_target_id: ?cmux.Uuid = null,

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

        // Initialise the UI test harness (reads env vars; no-op in non-test runs).
        cmux.ui_test_harness.init();

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

        // Start the socket server (unless UI test mode disables it).
        if (cmux.ui_test_harness.shouldCreateSocket()) {
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
        } else {
            log.info("socket server disabled by CMUX_SOCKET_CONTROL_MODE=off", .{});
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

        // Load sidebar CSS for rich row styling.
        loadSidebarCss();

        // Build the programmatic pane tab bar and titlebar controls.
        self.buildPaneTabBar();
        self.buildTitlebarControls();

        // Set up the sidebar resizer drag handle.
        self.setupSidebarResizer();


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

        // Create command palette overlay
        self.setupCommandPalette(manager);

        // Start autosave timer
        self.startAutosaveTimer();

        // Start render diagnostics for UI tests (no-op when not enabled).
        self.startRenderDiagnostics(alloc);

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
            .init("send-feedback", actionSendFeedback, null),
            .init("focus-address-bar", actionFocusAddressBar, null),
            .init("toggle-sidebar", actionToggleSidebar, null),
            .init("close-panel", actionClosePanel, null),
            .init("close-window", actionCloseWindow, null),
            .init("confirm-close", actionConfirmClose, null),
            .init("toggle-notifications", actionToggleNotifications, null),
            .init("jump-to-unread", actionJumpToUnread, null),
            .init("open-feedback", actionOpenFeedback, null),
            .init("open-settings", actionOpenSettings, null),
            .init("command-palette-commands", actionCommandPaletteCommands, null),
            .init("command-palette-switcher", actionCommandPaletteSwitcher, null),
            .init("rename", actionRename, null),
            .init("rename-tab", actionRename, null),
            .init("rename-workspace", actionRenameWorkspace, null),
            .init("find", actionFind, null),
            .init("goto-split-left", actionGotoSplitLeft, null),
            .init("goto-split-down", actionGotoSplitDown, null),
            .init("goto-split-up", actionGotoSplitUp, null),
            .init("goto-split-right", actionGotoSplitRight, null),
            .init("pane-switch-left", actionPaneSwitchLeft, null),
            .init("pane-switch-right", actionPaneSwitchRight, null),
            .init("open-browser-in-pane", actionOpenBrowserInPane, null),
            .init("zoom-toggle", actionZoomToggle, null),
            .init("next-surface", actionNextSurface, null),
            .init("prev-surface", actionPrevSurface, null),
            .init("trigger-flash", actionTriggerFlash, null),
        };
        ext.actions.add(Self, self, &actions);

        // Register all keyboard accelerators via shortcut settings
        const app = self.as(gtk.Window).getApplication() orelse return;
        const shortcuts_mod = @import("shortcuts.zig");
        shortcuts_mod.syncAccelerators(app);
        {
            const accels = [_:null]?[*:0]const u8{"<Ctrl><Alt>f"};
            app.setAccelsForAction("win.send-feedback", &accels);
        }
    }

    fn actionClose(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.as(gtk.Window).close();
    }

    fn actionNewWorkspace(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const ws = manager.createWorkspace(.{ .title = "Terminal" }) catch |err| {
            log.err("failed to create workspace: {}", .{err});
            return;
        };

        // UI test harness: record the invocation and current workspace count.
        const harness = cmux.ui_test_harness;
        harness.incrementKeyequiv("addTabInvocations");
        var count_buf: [20]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{manager.workspaceCount()}) catch "?";
        var id_buf: [36]u8 = undefined;
        const id_str = ws.id.formatBuf(&id_buf);
        harness.recordKeyequiv(&.{
            .{ .key = "tabCount", .value = count_str },
            .{ .key = "selectedTabId", .value = id_str },
        });
    }

    fn actionCloseWorkspace(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        cmux.ui_test_harness.incrementKeyequiv("closeTabInvocations");
        const priv = self.private();
        const manager = priv.manager orelse return;
        const selected = manager.selected_id orelse return;
        manager.closeWorkspace(selected) catch {};
    }

    fn actionClosePanel(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        cmux.ui_test_harness.incrementKeyequiv("closePanelInvocations");
        self.performBindingAction(.close_surface);
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


    // Image transfer clipboard interception
    const ImageTransferRequest = struct {
        window: *Self,
        surface: *Surface,
    };

    fn onUriListRead(source: ?*gobject.Object, res: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const alloc = Application.default().allocator();
        const req: *ImageTransferRequest = @ptrCast(@alignCast(ud orelse return));
        defer { req.window.unref(); req.surface.unref(); alloc.destroy(req); }

        const cb = gobject.ext.cast(gdk.Clipboard, source orelse return) orelse return;
        var gerr: ?*glib.Error = null;
        const cstr_ = cb.readTextFinish(res, &gerr);
        if (gerr) |e| { e.free(); req.window.performBindingAction(.paste_from_clipboard); return; }
        const cstr = cstr_ orelse { req.window.performBindingAction(.paste_from_clipboard); return; };
        defer glib.free(cstr);
        const uri_text = std.mem.sliceTo(cstr, 0);

        var file_paths = std.ArrayListUnmanaged([]const u8){};
        defer { for (file_paths.items) |fp| alloc.free(fp); file_paths.deinit(alloc); }

        var lines = std.mem.splitScalar(u8, uri_text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, "\r \t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            if (std.mem.startsWith(u8, trimmed, "file://")) {
                const decoded = uriDecode(alloc, trimmed[7..]) orelse continue;
                file_paths.append(alloc, decoded) catch continue;
            }
        }

        if (file_paths.items.len == 0) {
            req.window.performBindingAction(.paste_from_clipboard);
            return;
        }

        const target = resolveTransferTarget(req.window);
        const p = image_transfer.plan(alloc, .{ .file_paths = file_paths.items }, target);
        dispatchPlan(alloc, req.window, req.surface, p);
    }

    fn onTextureRead(source: ?*gobject.Object, res: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const alloc = Application.default().allocator();
        const req: *ImageTransferRequest = @ptrCast(@alignCast(ud orelse return));
        defer { req.window.unref(); req.surface.unref(); alloc.destroy(req); }

        const cb = gobject.ext.cast(gdk.Clipboard, source orelse return) orelse return;
        var gerr: ?*glib.Error = null;
        const tex = cb.readTextureFinish(res, &gerr) orelse {
            if (gerr) |e| e.free();
            req.window.performBindingAction(.paste_from_clipboard);
            return;
        };
        defer tex.as(gobject.Object).unref();

        const bytes: *glib.Bytes = tex.saveToPngBytes();
        defer bytes.unref();
        const size = bytes.getSize();
        if (size == 0) return;
        const data_ptr = bytes.getData(null) orelse return;

        const path = image_transfer.saveImageToTempFile(alloc, data_ptr[0..size], "png") orelse {
            req.window.performBindingAction(.paste_from_clipboard);
            return;
        };

        const paths = &[_][]const u8{path};
        const target = resolveTransferTarget(req.window);
        const p = image_transfer.plan(alloc, .{ .file_paths = paths }, target);
        dispatchPlan(alloc, req.window, req.surface, p);
    }

    fn dispatchPlan(alloc: Allocator, window: *Self, surface: *Surface, p: image_transfer.Plan) void {
        switch (p) {
            .insert_text => |text| { pasteText(surface, text); alloc.free(text); },
            .upload_files => |upload| executeUpload(alloc, surface, upload),
            .reject => window.performBindingAction(.paste_from_clipboard),
        }
    }

    fn resolveTransferTarget(self: *Self) image_transfer.Target {
        const priv = self.private();
        const manager = priv.manager orelse return .local;
        const ws = manager.selectedWorkspace() orelse return .local;
        if (ws.isRemoteWorkspace()) return .{ .remote = .workspace_remote };
        const surface = self.getActiveSurface() orelse return .local;
        const panel_id = self.surfaceUuid(surface) orelse return .local;
        const tty_name = ws.surface_tty_names.get(panel_id) orelse return .local;
        if (SshSessionDetector.detect(Application.default().allocator(), tty_name)) |session|
            return .{ .remote = .{ .detected_ssh = session } };
        return .local;
    }

    fn pasteText(surface: *Surface, text: [:0]const u8) void {
        if (text.len == 0) return;
        const cs = surface.core() orelse return;
        cs.completeClipboardRequest(.paste, text, false) catch |err| {
            log.warn("paste failed: {}", .{err});
        };
    }

    /// Context for async upload running on a background thread.
    const UploadContext = struct {
        alloc: Allocator,
        window: *Self,
        surface: *Surface,
        session: SshSessionDetector.DetectedSession,
        paths: []const []const u8,
        operation: image_transfer.Operation,
        result: image_transfer.UploadResult,
        toast: ?*adw.Toast = null,
        indicator_timer: c_uint = 0,

        fn destroy(self: *UploadContext) void {
            self.window.unref();
            self.surface.unref();
            self.alloc.destroy(self);
        }
    };

    fn executeUpload(alloc: Allocator, surface: *Surface, up: image_transfer.Plan.UploadFilesPlan) void {
        switch (up.target) {
            .workspace_remote => {
                log.warn("workspace-remote upload not yet implemented", .{});
                if (image_transfer.joinEscapedPaths(alloc, up.paths)) |t| {
                    pasteText(surface, t);
                    alloc.free(t);
                }
            },
            .detected_ssh => |session| {
                // Get the window from the surface widget tree.
                const root = surface.as(gtk.Widget).getRoot() orelse return;
                const window = gobject.ext.cast(Self, root.as(gobject.Object)) orelse return;

                const ctx = alloc.create(UploadContext) catch return;
                ctx.* = .{
                    .alloc = alloc,
                    .window = window.ref(),
                    .surface = surface.ref(),
                    .session = session,
                    .paths = up.paths,
                    .operation = .{},
                    .result = .{ .failure = "" },
                };

                // Show upload indicator after 150ms (avoids flash for fast transfers).
                ctx.indicator_timer = cmux.dispatch.timeout_add_fn(150, &showUploadIndicator, ctx);

                _ = std.Thread.spawn(.{}, uploadThread, .{ctx}) catch |err| {
                    log.err("failed to spawn upload thread: {}", .{err});
                    if (ctx.indicator_timer != 0) {
                        _ = glib.Source.remove(ctx.indicator_timer);
                    }
                    ctx.destroy();
                    return;
                };
            },
        }
    }

    fn showUploadIndicator(ud: ?*anyopaque) callconv(.c) c_int {
        const ctx: *UploadContext = @ptrCast(@alignCast(ud orelse return 0));
        ctx.indicator_timer = 0;

        // Show a toast with "Uploading..." text.
        const toast = adw.Toast.new("Uploading\u{2026}");
        toast.setTimeout(0); // Don't auto-dismiss.
        ctx.toast = toast;
        ctx.window.private().toast_overlay.addToast(toast);

        return 0; // G_SOURCE_REMOVE — don't repeat.
    }

    fn uploadThread(ctx: *UploadContext) void {
        ctx.result = image_transfer.uploadViaDetectedSsh(
            ctx.alloc, &ctx.session, ctx.paths, &ctx.operation,
        );
        cmux.dispatch.idleAdd(&uploadComplete, ctx);
    }

    fn uploadComplete(ud: ?*anyopaque) callconv(.c) c_int {
        const ctx: *UploadContext = @ptrCast(@alignCast(ud orelse return 0));
        defer ctx.destroy();

        // Cancel the indicator timer if it hasn't fired yet.
        if (ctx.indicator_timer != 0) {
            _ = glib.Source.remove(ctx.indicator_timer);
        }

        // Dismiss the toast if it's showing.
        if (ctx.toast) |toast| {
            toast.dismiss();
        }

        switch (ctx.result) {
            .success => |rps| {
                if (image_transfer.joinEscapedPaths(ctx.alloc, rps)) |t| {
                    pasteText(ctx.surface, t);
                    ctx.alloc.free(t);
                }
                for (rps) |rp| ctx.alloc.free(rp);
                ctx.alloc.free(rps);
            },
            .failure => |detail| {
                log.err("upload failed: {s}", .{detail});
                // Show error toast.
                const err_toast = adw.Toast.new("Upload failed");
                err_toast.setTimeout(3);
                ctx.window.private().toast_overlay.addToast(err_toast);
            },
        }

        return 0; // G_SOURCE_REMOVE
    }

    fn uriDecode(alloc: Allocator, encoded: []const u8) ?[]const u8 {
        var out = std.ArrayListUnmanaged(u8){};
        var i: usize = 0;
        while (i < encoded.len) {
            if (encoded[i] == '%' and i + 2 < encoded.len) {
                const hi = hexNibble(encoded[i + 1]) orelse { out.append(alloc, encoded[i]) catch return null; i += 1; continue; };
                const lo = hexNibble(encoded[i + 2]) orelse { out.append(alloc, encoded[i]) catch return null; i += 1; continue; };
                out.append(alloc, (hi << 4) | lo) catch return null;
                i += 3;
            } else { out.append(alloc, encoded[i]) catch return null; i += 1; }
        }
        return out.toOwnedSlice(alloc) catch null;
    }

    fn hexNibble(c: u8) ?u8 {
        return if (c >= '0' and c <= '9') c - '0'
        else if (c >= 'a' and c <= 'f') c - 'a' + 10
        else if (c >= 'A' and c <= 'F') c - 'A' + 10
        else null;
    }
    fn actionPaste(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        // Route through image transfer planner if clipboard has file URIs or images.
        // Priority matches macOS preparePaste: URIs > text > image.
        const surface = self.getActiveSurface() orelse return;
        const widget = surface.as(gtk.Widget);
        const clipboard = widget.getClipboard();
        const formats = clipboard.getFormats();

        if (formats.containMimeType("text/uri-list") != 0) {
            const alloc = Application.default().allocator();
            const ud = alloc.create(ImageTransferRequest) catch return;
            ud.* = .{ .window = self.ref(), .surface = surface.ref() };
            clipboard.readTextAsync(null, &onUriListRead, ud);
            return;
        }
        if (formats.containGtype(gobject.ext.types.string) != 0) {
            self.performBindingAction(.paste_from_clipboard);
            return;
        }
        if (formats.containGtype(gdk.Texture.getGObjectType()) != 0) {
            const alloc = Application.default().allocator();
            const ud = alloc.create(ImageTransferRequest) catch return;
            ud.* = .{ .window = self.ref(), .surface = surface.ref() };
            clipboard.readTextureAsync(null, &onTextureRead, ud);
            return;
        }
        self.performBindingAction(.paste_from_clipboard);
    }

    fn actionReset(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performBindingAction(.reset);
    }

    fn actionClear(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performBindingAction(.clear_screen);
    }

    fn actionSendFeedback(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.showFeedbackComposer();
    }

    // -----------------------------------------------------------------
    // Help menu and feedback composer
    // -----------------------------------------------------------------

    fn onHelpClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();

        // Create the popover lazily on first click
        if (priv.help_popover == null) {
            priv.help_popover = self.buildHelpPopover();
        }
        const popover = priv.help_popover orelse return;

        // Parent the popover to the help button if not already done
        if (popover.as(gtk.Widget).getParent() == null) {
            popover.as(gtk.Widget).setParent(priv.help_btn.as(gtk.Widget));
        }
        popover.popup();
    }

    fn buildHelpPopover(self: *Self) *gtk.Popover {
        const box = gtk.Box.new(.vertical, 4);
        box.as(gtk.Widget).setMarginTop(6);
        box.as(gtk.Widget).setMarginBottom(6);
        box.as(gtk.Widget).setMarginStart(6);
        box.as(gtk.Widget).setMarginEnd(6);

        // "Keyboard Shortcuts" menu item
        const kbd_btn = gtk.Button.newWithLabel("Keyboard Shortcuts");
        kbd_btn.as(gtk.Widget).addCssClass("flat");
        kbd_btn.as(gtk.Widget).setHalign(.fill);
        kbd_btn.as(gtk.Widget).setName("Keyboard Shortcuts");
        _ = gtk.Button.signals.clicked.connect(kbd_btn, *Self, &onKeyboardShortcutsClicked, self, .{});
        box.append(kbd_btn.as(gtk.Widget));

        // "Send Feedback" menu item
        const fb_btn = gtk.Button.newWithLabel("Send Feedback");
        fb_btn.as(gtk.Widget).addCssClass("flat");
        fb_btn.as(gtk.Widget).setHalign(.fill);
        fb_btn.as(gtk.Widget).setName("Send Feedback");
        _ = gtk.Button.signals.clicked.connect(fb_btn, *Self, &onSendFeedbackClicked, self, .{});
        box.append(fb_btn.as(gtk.Widget));

        const popover = gtk.Popover.new();
        popover.setChild(box.as(gtk.Widget));
        popover.setHasArrow(0);
        popover.setPosition(.top);
        return popover;
    }

    fn onKeyboardShortcutsClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.help_popover) |popover| popover.popdown();
        self.showKeyboardShortcuts();
    }

    fn onSendFeedbackClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.help_popover) |popover| popover.popdown();
        self.showFeedbackComposer();
    }

    fn showKeyboardShortcuts(self: *Self) void {
        const priv = self.private();

        // Remove previous overlay if any
        if (priv.shortcuts_overlay) |old| {
            old.setVisible(0);
            if (old.getParent()) |parent| {
                if (gobject.ext.cast(gtk.Box, parent)) |pbox| {
                    pbox.remove(old);
                }
            }
            priv.shortcuts_overlay = null;
        }

        const content = gtk.Box.new(.vertical, 12);
        content.as(gtk.Widget).setMarginTop(20);
        content.as(gtk.Widget).setMarginBottom(20);
        content.as(gtk.Widget).setMarginStart(20);
        content.as(gtk.Widget).setMarginEnd(20);

        const title_label = gtk.Label.new("Keyboard Shortcuts");
        title_label.as(gtk.Widget).addCssClass("title-2");
        title_label.setXalign(0);
        content.append(title_label.as(gtk.Widget));

        const shortcut_list = buildShortcutList();
        content.append(shortcut_list);

        // Hint label -- accessible name "ShortcutRecordingHint"
        const hint = gtk.Label.new("Click a shortcut value to record a new shortcut.");
        hint.as(gtk.Widget).addCssClass("dim-label");
        hint.as(gtk.Widget).addCssClass("caption");
        hint.setXalign(0);
        hint.as(gtk.Widget).setName("ShortcutRecordingHint");
        content.append(hint.as(gtk.Widget));

        const close_btn = gtk.Button.newWithLabel("Close");
        close_btn.as(gtk.Widget).setHalign(.start);
        _ = gtk.Button.signals.clicked.connect(close_btn, *Self, &onShortcutsClose, self, .{});
        content.append(close_btn.as(gtk.Widget));

        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setChild(content.as(gtk.Widget));
        scrolled.as(gtk.Widget).setVexpand(1);
        scrolled.as(gtk.Widget).setHexpand(1);

        priv.toast_overlay.setChild(null); // unparent first
        priv.toast_overlay.setChild(scrolled.as(gtk.Widget));
        priv.shortcuts_overlay = scrolled.as(gtk.Widget);
    }

    fn buildShortcutList() *gtk.Widget {
        const list = gtk.Box.new(.vertical, 6);

        const ShortcutEntry = struct { l: [:0]const u8, a: [:0]const u8 };
        const entries = [_]ShortcutEntry{
            .{ .l = "New Workspace", .a = "Ctrl+Shift+N" },
            .{ .l = "Close Workspace", .a = "Ctrl+Shift+W" },
            .{ .l = "Toggle Sidebar", .a = "Ctrl+B" },
            .{ .l = "Split Right", .a = "Ctrl+Shift+D" },
            .{ .l = "Split Down", .a = "Ctrl+Shift+E" },
            .{ .l = "Copy", .a = "Ctrl+Shift+C" },
            .{ .l = "Paste", .a = "Ctrl+Shift+V" },
            .{ .l = "Command Palette", .a = "Ctrl+Shift+P" },
            .{ .l = "Send Feedback", .a = "Ctrl+Alt+F" },
        };

        for (&entries) |*entry| {
            const row = gtk.Box.new(.horizontal, 12);
            row.as(gtk.Widget).setMarginTop(2);
            row.as(gtk.Widget).setMarginBottom(2);

            const name_label = gtk.Label.new(entry.l);
            name_label.setXalign(0);
            name_label.as(gtk.Widget).setHexpand(1);
            row.append(name_label.as(gtk.Widget));

            const accel_label = gtk.Label.new(entry.a);
            accel_label.as(gtk.Widget).addCssClass("dim-label");
            row.append(accel_label.as(gtk.Widget));

            list.append(row.as(gtk.Widget));
        }

        return list.as(gtk.Widget);
    }

    fn onShortcutsClose(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.shortcuts_overlay != null) {
            priv.toast_overlay.setChild(null); // unparent first
        priv.toast_overlay.setChild(priv.workspace_stack.as(gtk.Widget));
            priv.shortcuts_overlay = null;
        }
    }

    fn showFeedbackComposer(self: *Self) void {
        const priv = self.private();
        if (priv.feedback_overlay != null) return;

        const content = gtk.Box.new(.vertical, 12);
        content.as(gtk.Widget).setMarginTop(20);
        content.as(gtk.Widget).setMarginBottom(20);
        content.as(gtk.Widget).setMarginStart(20);
        content.as(gtk.Widget).setMarginEnd(20);
        content.as(gtk.Widget).setHalign(.center);
        content.as(gtk.Widget).setValign(.center);
        content.as(gtk.Widget).addCssClass("card");
        content.as(gtk.Widget).setSizeRequest(480, -1);

        // Title
        const title_label = gtk.Label.new("Send Feedback");
        title_label.as(gtk.Widget).addCssClass("title-2");
        title_label.setXalign(0);
        content.append(title_label.as(gtk.Widget));

        // Email field
        const email_entry = gtk.Entry.new();
        email_entry.setPlaceholderText("you@example.com");
        email_entry.as(gtk.Widget).setName("SidebarFeedbackEmailField");
        content.append(email_entry.as(gtk.Widget));

        // Message
        const msg_frame = gtk.Frame.new("Message");
        const msg_view = gtk.TextView.new();
        msg_view.as(gtk.Widget).setVexpand(1);
        msg_view.as(gtk.Widget).setSizeRequest(-1, 120);
        msg_frame.setChild(msg_view.as(gtk.Widget));
        content.append(msg_frame.as(gtk.Widget));

        // Button row
        const btn_row = gtk.Box.new(.horizontal, 8);
        btn_row.as(gtk.Widget).setHalign(.fill);

        const attach_btn = gtk.Button.newWithLabel("Attach Images");
        attach_btn.as(gtk.Widget).setName("SidebarFeedbackAttachButton");
        btn_row.append(attach_btn.as(gtk.Widget));

        const spacer = gtk.Box.new(.horizontal, 0);
        spacer.as(gtk.Widget).setHexpand(1);
        btn_row.append(spacer.as(gtk.Widget));

        const cancel_btn = gtk.Button.newWithLabel("Cancel");
        _ = gtk.Button.signals.clicked.connect(cancel_btn, *Self, &onFeedbackCancel, self, .{});
        btn_row.append(cancel_btn.as(gtk.Widget));

        const send_btn = gtk.Button.newWithLabel("Send");
        send_btn.as(gtk.Widget).addCssClass("suggested-action");
        send_btn.as(gtk.Widget).setName("SidebarFeedbackSendButton");
        _ = gtk.Button.signals.clicked.connect(send_btn, *Self, &onFeedbackSend, self, .{});
        btn_row.append(send_btn.as(gtk.Widget));

        content.append(btn_row.as(gtk.Widget));

        // Footer
        const footer = gtk.Label.new("A human will read this! You can also reach us at founders@manaflow.com.");
        footer.as(gtk.Widget).addCssClass("dim-label");
        footer.as(gtk.Widget).addCssClass("caption");
        footer.setXalign(0);
        footer.setWrap(1);
        content.append(footer.as(gtk.Widget));

        const overlay_box = gtk.Box.new(.vertical, 0);
        overlay_box.as(gtk.Widget).setVexpand(1);
        overlay_box.as(gtk.Widget).setHexpand(1);
        overlay_box.as(gtk.Widget).setValign(.fill);
        overlay_box.as(gtk.Widget).setHalign(.fill);
        overlay_box.append(content.as(gtk.Widget));

        priv.toast_overlay.setChild(null); // unparent first
        priv.toast_overlay.setChild(overlay_box.as(gtk.Widget));
        priv.feedback_overlay = overlay_box.as(gtk.Widget);
    }

    fn onFeedbackCancel(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.dismissFeedbackComposer();
    }

    fn onFeedbackSend(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.dismissFeedbackComposer();
    }

    fn dismissFeedbackComposer(self: *Self) void {
        const priv = self.private();
        if (priv.feedback_overlay != null) {
            priv.toast_overlay.setChild(null); // unparent first
        priv.toast_overlay.setChild(priv.workspace_stack.as(gtk.Widget));
            priv.feedback_overlay = null;
        }
    }

    fn actionFocusAddressBar(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        // Find the first visible browser panel and focus its omnibar.
        const priv = self.private();
        var iter = priv.browser_panel_map.iterator();
        while (iter.next()) |entry| {
            const panel: *BrowserPanelView = entry.value_ptr.*;
            if (panel.as(gtk.Widget).isVisible() != 0) {
                panel.focusOmnibar();
                return;
            }
        }
    }

    fn actionToggleSidebar(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.toggleSidebar(null);
    }


    fn actionCloseWindow(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.showCloseWindowDialog();
    }

    fn showCloseWindowDialog(self: *Self) void {
        const priv = self.private();
        const dialog = adw.AlertDialog.new("Close window?", "All workspaces in this window will be closed.");
        _ = dialog.addResponse("cancel", "Cancel");
        _ = dialog.addResponse("close", "Close");
        dialog.setResponseAppearance("close", .destructive);
        dialog.setDefaultResponse("close");
        priv.active_close_dialog = dialog;
        priv.active_close_dialog_on_confirm = .close_window;
        _ = adw.AlertDialog.signals.response.connect(dialog, *Self, onCloseDialogResponse, self, .{});
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn actionConfirmClose(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        // If a close dialog is active, confirm it programmatically
        if (priv.active_close_dialog) |dialog| {
            // TODO: forceClose not available, use close on parent Window
            _ = dialog;
            self.executeCloseDialogAction();
        }
    }

    fn executeCloseDialogAction(self: *Self) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const action = priv.active_close_dialog_on_confirm orelse return;
        const alloc = Application.default().allocator();

        defer {
            if (priv.active_close_dialog_on_confirm) |a| {
                switch (a) {
                    .close_workspaces => |ids| alloc.free(ids),
                    else => {},
                }
            }
            priv.active_close_dialog = null;
            priv.active_close_dialog_on_confirm = null;
        }

        switch (action) {
            .close_window => self.as(gtk.Window).close(),
            .close_workspace => |id| manager.closeWorkspace(id) catch {},
            .close_workspaces => |ids| {
                for (ids) |id| manager.closeWorkspace(id) catch {};
            },
        }
    }

    fn actionToggleNotifications(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.notifications_popover) |np| {
            np.toggle();
        } else {
            // Create lazily on first use
            const np = Application.default().allocator().create(NotificationsPopover) catch return;
            np.* = NotificationsPopover.create(
                priv.notifications_btn.?.as(gtk.Widget),
            );
            if (priv.server) |server| {
                np.notification_store = &server.notification_store;
            }
            priv.notifications_popover = np;
            np.toggle();
        }
    }

    fn actionJumpToUnread(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const server = priv.server orelse return;
        const store = &server.notification_store;
        const notifications = store.getNotifications();
        // Find latest unread notification (last in list that's unread)
        var latest_tab: ?cmux.Uuid = null;
        var i = notifications.len;
        while (i > 0) {
            i -= 1;
            if (!notifications[i].is_read) {
                latest_tab = notifications[i].tab_id;
                break;
            }
        }
        const tab_id = latest_tab orelse return;
        const manager = priv.manager orelse return;
        manager.selectWorkspace(tab_id);
    }

    fn actionOpenFeedback(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Self) callconv(.c) void {
        log.info("open-feedback action triggered", .{});
    }

    fn actionOpenSettings(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Self) callconv(.c) void {
        log.info("open-settings action triggered", .{});
    }

    fn actionCommandPaletteCommands(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Self) callconv(.c) void {
        log.info("command-palette-commands action triggered", .{});
    }

    fn actionCommandPaletteSwitcher(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Self) callconv(.c) void {
        log.info("command-palette-switcher action triggered", .{});
    }

    fn actionRename(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Self) callconv(.c) void {
        log.info("rename action triggered", .{});
    }

    fn actionRenameWorkspace(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Self) callconv(.c) void {
        log.info("rename-workspace action triggered", .{});
    }

    fn actionFind(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Self) callconv(.c) void {
        log.info("find action triggered", .{});
    }

    fn actionGotoSplitLeft(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performGotoSplit(.left, "left");
    }

    fn actionGotoSplitDown(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performGotoSplit(.down, "down");
    }

    fn actionGotoSplitUp(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performGotoSplit(.up, "up");
    }

    fn actionGotoSplitRight(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performGotoSplit(.right, "right");
    }

    fn actionPaneSwitchLeft(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performGotoSplit(.left, "left");
    }

    fn actionPaneSwitchRight(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performGotoSplit(.right, "right");
    }

    fn actionOpenBrowserInPane(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Self) callconv(.c) void {
        log.info("open-browser-in-pane action triggered", .{});
    }

    fn actionZoomToggle(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performBindingAction(.toggle_split_zoom);
    }

    fn actionNextSurface(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performBindingAction(.{ .goto_split = .next });
    }

    fn actionPrevSurface(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.performBindingAction(.{ .goto_split = .previous });
    }

    fn actionTriggerFlash(_: *gio.SimpleAction, _: ?*glib.Variant, _: *Self) callconv(.c) void {
        log.info("trigger-flash action triggered", .{});
    }

    fn performGotoSplit(self: *Self, direction: input.SplitFocusDirection, direction_name: []const u8) void {
        self.performBindingAction(.{ .goto_split = direction });
        cmux.ui_test_harness.writeGotoSplitData(&.{
            .{ .key = "lastMoveDirection", .value = direction_name },
        });
    }

    // -----------------------------------------------------------------
    // Sidebar resizer — draggable handle between sidebar and content
    // -----------------------------------------------------------------

    /// Maximum ratio of window width the sidebar may consume.
    /// Matches macOS maximumSidebarWidthRatio (1/3).
    const maximum_sidebar_width_ratio: f64 = 1.0 / 3.0;

    fn loadResizerCss() void {
        const css =
            \\.sidebar-resizer {
            \\  min-width: 8px;
            \\  background-color: transparent;
            \\}
            \\.sidebar-resizer:hover {
            \\  background-color: alpha(@borders, 0.3);
            \\}
        ;
        const provider = gtk.CssProvider.new();
        const bytes = glib.Bytes.new(css.ptr, css.len);
        defer bytes.unref();
        provider.loadFromBytes(bytes);

        if (gdk.Display.getDefault()) |display| {
            gtk.StyleContext.addProviderForDisplay(
                display,
                provider.as(gtk.StyleProvider),
                gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
        }
    }

    fn setupSidebarResizer(self: *Self) void {
        const priv = self.private();
        const resizer_widget = priv.sidebar_resizer.as(gtk.Widget);

        // Load CSS for the resizer handle.
        loadResizerCss();

        // Make the resizer wide enough to grab (8px) and set resize cursor.
        resizer_widget.setSizeRequest(8, -1);
        resizer_widget.setCursorFromName("col-resize");

        // Attach a drag gesture to the resizer.
        const drag = gtk.GestureDrag.new();
        drag.as(gtk.GestureSingle).setButton(1); // left mouse button only
        _ = gtk.GestureDrag.signals.drag_begin.connect(
            drag, *Self, onResizerDragBegin, self, .{},
        );
        _ = gtk.GestureDrag.signals.drag_update.connect(
            drag, *Self, onResizerDragUpdate, self, .{},
        );
        _ = gtk.GestureDrag.signals.drag_end.connect(
            drag, *Self, onResizerDragEnd, self, .{},
        );
        resizer_widget.addController(drag.as(gtk.EventController));

        // Apply the initial sidebar width.
        self.applySidebarWidth(priv.sidebar_width);

    }

    fn onResizerDragBegin(
        _: *gtk.GestureDrag,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.drag_start_width = priv.sidebar_width;
    }

    fn onResizerDragUpdate(
        _: *gtk.GestureDrag,
        offset_x: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const start = priv.drag_start_width orelse priv.sidebar_width;
        const candidate = start + offset_x;
        const clamped = self.clampedSidebarWidth(candidate);
        self.applySidebarWidth(clamped);
    }

    fn onResizerDragEnd(
        _: *gtk.GestureDrag,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        self.private().drag_start_width = null;
    }

    /// Clamp sidebar width to [minimum, min(maximum, window_width * ratio)].
    fn clampedSidebarWidth(self: *Self, candidate: f64) f64 {
        const policy = cmux.persistence.policy;
        const min_w = policy.minimum_sidebar_width;

        // Dynamic maximum: at most 1/3 of window width (matches Mac).
        var max_w = policy.maximum_sidebar_width;
        const win_width: f64 = @floatFromInt(self.as(gtk.Widget).getWidth());
        if (win_width > 0) {
            const dynamic_max = win_width * maximum_sidebar_width_ratio;
            max_w = @min(max_w, @max(min_w, dynamic_max));
        }

        if (!std.math.isFinite(candidate)) return policy.default_sidebar_width;
        return @min(@max(candidate, min_w), max_w);
    }

    /// Apply a new sidebar width (pixel value) to the sidebar container.
    fn applySidebarWidth(self: *Self, width: f64) void {
        const priv = self.private();
        priv.sidebar_width = width;
        const w: c_int = @intFromFloat(@round(width));
        priv.sidebar_box.as(gtk.Widget).setSizeRequest(w, -1);
    }


    /// Query sidebar visibility (used by debug commands).
    pub fn isSidebarVisible(self: *Self) bool {
        return self.private().sidebar_visible;
    }

    // -----------------------------------------------------------------
    // Command palette
    // -----------------------------------------------------------------

    fn setupCommandPalette(self: *Self, manager: *cmux.workspace.Manager) void {
        const priv = self.private();

        CommandPalette.loadCss();

        const palette = CommandPalette.new();
        priv.command_palette = palette;

        palette.setWorkspaceManager(manager);
        palette.setExecutionCallback(.{
            .ctx = @ptrCast(self),
            .executeFn = &onPaletteCommandExecuted,
        });

        // Add the palette as an overlay on top of the toast_overlay.
        // The palette_overlay is defined in the blueprint wrapping toast_overlay.
        priv.palette_overlay.addOverlay(palette.as(gtk.Widget));

        // Install keyboard shortcuts via window-level key controller
        const key_ctrl = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            key_ctrl,
            *Self,
            onWindowKeyPressed,
            self,
            .{},
        );
        self.as(gtk.Widget).addController(key_ctrl.as(gtk.EventController));
    }

    fn onWindowKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        state: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        const palette = priv.command_palette orelse return 0;

        const ctrl = state.control_mask;
        const shift = state.shift_mask;

        if (ctrl and shift and (keyval == gdk.KEY_p or keyval == gdk.KEY_P)) {
            palette.toggle(.commands);
            return 1;
        }
        if (ctrl and !shift and (keyval == gdk.KEY_p or keyval == gdk.KEY_P)) {
            palette.toggle(.switcher);
            return 1;
        }
        if (ctrl and !shift and (keyval == gdk.KEY_r or keyval == gdk.KEY_R)) {
            palette.toggle(.rename);
            return 1;
        }

        return 0;
    }

    fn onPaletteCommandExecuted(ctx: ?*anyopaque, command_id: []const u8) void {
        const self_p: *Self = @ptrCast(@alignCast(ctx orelse return));
        const priv = self_p.private();
        const manager = priv.manager orelse return;

        if (std.mem.eql(u8, command_id, "palette.closeOtherWorkspaces")) {
            self_p.closeOtherWorkspaces();
        } else if (std.mem.eql(u8, command_id, "palette.enableMinimalMode")) {
            log.info("enable minimal mode requested (not yet implemented)", .{});
        } else if (std.mem.eql(u8, command_id, "palette.disableMinimalMode")) {
            log.info("disable minimal mode requested (not yet implemented)", .{});
        } else if (std.mem.startsWith(u8, command_id, "switcher.workspace.")) {
            const uuid_str = command_id["switcher.workspace.".len..];
            const uuid = cmux.Uuid.parse(uuid_str) catch return;
            manager.selectWorkspace(uuid);
        }
    }

    fn closeOtherWorkspaces(self: *Self) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const selected_id = manager.selected_id orelse return;

        var to_close_buf: [256]cmux.Uuid = undefined;
        var to_close_count: usize = 0;
        for (manager.workspaces.items) |ws| {
            if (!ws.id.eql(selected_id)) {
                if (to_close_count < to_close_buf.len) {
                    to_close_buf[to_close_count] = ws.id;
                    to_close_count += 1;
                }
            }
        }
        if (to_close_count == 0) return;
        self.showCloseWorkspacesDialog(to_close_buf[0..to_close_count]);
    }

    fn showCloseWorkspacesDialog(self: *Self, workspace_ids: []const cmux.Uuid) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        const dialog = adw.AlertDialog.new("Close workspaces?", null);

        var body_buf: [256:0]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "This will close {d} workspace(s).", .{workspace_ids.len}) catch "Close workspaces?";
        body_buf[@min(body.len, body_buf.len - 1)] = 0;
        dialog.setBody(@ptrCast(body_buf[0..body.len :0].ptr));

        _ = dialog.addResponse("cancel", "Cancel");
        _ = dialog.addResponse("close", "Close");
        dialog.setResponseAppearance("close", .destructive);

        const ids_copy = alloc.dupe(cmux.Uuid, workspace_ids) catch return;
        priv.active_close_dialog = dialog;
        priv.active_close_dialog_on_confirm = .{ .close_workspaces = ids_copy };

        _ = adw.AlertDialog.signals.response.connect(dialog, *Self, onCloseDialogResponse, self, .{});
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn onCloseDialogResponse(
        _: *adw.AlertDialog,
        response: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        defer {
            priv.active_close_dialog = null;
            if (priv.active_close_dialog_on_confirm) |action| {
                switch (action) {
                    .close_workspaces => |ids| alloc.free(ids),
                    else => {},
                }
            }
            priv.active_close_dialog_on_confirm = null;
        }

        const resp = std.mem.span(response);
        if (!std.mem.eql(u8, resp, "close")) return;

        const manager = priv.manager orelse return;
        const action = priv.active_close_dialog_on_confirm orelse return;
        switch (action) {
            .close_window => self.as(gtk.Window).close(),
            .close_workspace => |id| manager.closeWorkspace(id) catch {},
            .close_workspaces => |ids| {
                for (ids) |id| manager.closeWorkspace(id) catch {};
            },
        }
    }

    /// Get the command palette widget.
    pub fn getCommandPalette(self: *Self) ?*CommandPalette {
        return self.private().command_palette;
    }

    /// Get the workspace manager.
    pub fn getWorkspaceManager(self: *Self) ?*cmux.workspace.Manager {
        return self.private().manager;
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
        var buf: [37]u8 = undefined;
        @memcpy(buf[0..36], &formatted);
        buf[36] = 0;
        return buf[0..36 :0].*;
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

        // Update sidebar selection and active CSS class
        self.updateSidebarActiveClass(id);
        if (self.findSidebarRow(id)) |row| {
            priv.sidebar_list.selectRow(row);
        }

        // Track the new workspace's active surface title
        self.trackActiveSurfaceTitle();

        // Rebuild pane tab bar for the newly selected workspace
        self.rebuildPaneTabBar();

        // Focus the active surface in the newly selected workspace
        if (self.getActiveSurface()) |surface| {
            _ = surface.as(gtk.Widget).grabFocus();
        }
    }

    /// Update the "active" CSS class on sidebar rows: add to the selected
    /// workspace's row, remove from all others.
    fn updateSidebarActiveClass(self: *Self, active_id: cmux.Uuid) void {
        const priv = self.private();
        var idx: c_int = 0;
        while (true) : (idx += 1) {
            const row = priv.sidebar_list.getRowAtIndex(idx) orelse break;
            const child = row.getChild() orelse continue;
            const outer_box = gobject.ext.cast(gtk.Box, child) orelse continue;
            const row_name_z: [*:0]const u8 = row.as(gtk.Widget).getName();
            const row_id = nameToUuid(row_name_z) orelse continue;
            if (row_id.eql(active_id)) {
                outer_box.as(gtk.Widget).addCssClass("active");
            } else {
                outer_box.as(gtk.Widget).removeCssClass("active");
            }
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

        // Rebuild pane tab bar if the updated workspace is selected.
        if (manager.selected_id) |sel| {
            if (sel.eql(id)) self.rebuildPaneTabBar();
        }

        self.updateNotificationBadge();
    }

    /// Update the headerbar notification bell badge with the current unread count.
    pub fn updateNotificationBadge(self: *Self) void {
        const priv = self.private();
        const badge = priv.notifications_badge orelse return;
        const server = priv.server orelse return;
        const unread = server.notification_store.getUnreadCount();

        if (unread > 0) {
            var buf: [8:0]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{@min(unread, 99)}) catch "0";
            buf[text.len] = 0;
            badge.setLabel(@ptrCast(buf[0..text.len :0].ptr));
            badge.as(gtk.Widget).setVisible(1);
        } else {
            badge.as(gtk.Widget).setVisible(0);
        }
    }

    // -----------------------------------------------------------------
    // Sidebar helpers
    // -----------------------------------------------------------------

    /// Load sidebar-specific CSS. Called once during window initialization.
    fn loadSidebarCss() void {
        const css =
            \\.cmux-sidebar-row {
            \\  border-radius: 6px;
            \\  margin: 1px 6px;
            \\  padding: 8px 10px;
            \\  transition: background-color 150ms ease;
            \\}
            \\.cmux-sidebar-row:hover {
            \\  background-color: alpha(@accent_color, 0.08);
            \\}
            \\.cmux-sidebar-row.active {
            \\  background-color: alpha(@accent_color, 0.15);
            \\}
            \\.cmux-sidebar-row .cmux-sidebar-close-btn {
            \\  opacity: 0;
            \\  transition: opacity 150ms ease;
            \\  min-width: 16px;
            \\  min-height: 16px;
            \\  padding: 0;
            \\}
            \\.cmux-sidebar-row:hover .cmux-sidebar-close-btn {
            \\  opacity: 1;
            \\}
            \\.cmux-sidebar-color-rail {
            \\  min-width: 3px;
            \\  border-radius: 2px;
            \\}
            \\.cmux-sidebar-badge {
            \\  background-color: @accent_color;
            \\  color: white;
            \\  border-radius: 8px;
            \\  min-width: 16px;
            \\  min-height: 16px;
            \\  padding: 0 4px;
            \\  font-size: 9px;
            \\  font-weight: 600;
            \\}
            \\.cmux-notif-badge {
            \\  background-color: #0091ff;
            \\  color: white;
            \\  border-radius: 7px;
            \\  min-width: 14px;
            \\  min-height: 14px;
            \\  padding: 0;
            \\  font-size: 8px;
            \\  font-weight: 700;
            \\  margin-top: 8px;
            \\  margin-right: 4px;
            \\}
            \\.cmux-sidebar-title {
            \\  font-size: 12.5px;
            \\  font-weight: 600;
            \\}
            \\.cmux-sidebar-subtitle {
            \\  font-size: 10px;
            \\  opacity: 0.8;
            \\}
            \\.cmux-sidebar-secondary {
            \\  font-size: 10px;
            \\  opacity: 0.75;
            \\}
            \\.cmux-sidebar-small {
            \\  font-size: 9px;
            \\  opacity: 0.6;
            \\}
            \\.cmux-sidebar-mono {
            \\  font-family: monospace;
            \\  font-size: 10px;
            \\  opacity: 0.75;
            \\}
            \\.cmux-sidebar-log-icon {
            \\  font-size: 8px;
            \\}
            \\.cmux-sidebar-progress-track {
            \\  min-height: 3px;
            \\  border-radius: 2px;
            \\  background-color: alpha(@window_fg_color, 0.12);
            \\}
            \\.cmux-sidebar-progress-fill {
            \\  min-height: 3px;
            \\  border-radius: 2px;
            \\  background-color: @accent_color;
            \\}
            \\.cmux-sidebar-port-btn {
            \\  font-family: monospace;
            \\  font-size: 10px;
            \\  padding: 0 4px;
            \\  min-height: 18px;
            \\  opacity: 0.75;
            \\}
            \\.cmux-sidebar-pr-btn {
            \\  font-size: 10px;
            \\  font-weight: 600;
            \\  padding: 0;
            \\  min-height: 18px;
            \\}
        ;
        const provider = gtk.CssProvider.new();
        const bytes = glib.Bytes.new(css.ptr, css.len);
        defer bytes.unref();
        provider.loadFromBytes(bytes);

        if (gdk.Display.getDefault()) |display| {
            gtk.StyleContext.addProviderForDisplay(
                display,
                provider.as(gtk.StyleProvider),
                gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 11,
            );
        }
    }

    fn createSidebarRow(self: *Self, ws: *const cmux.workspace.Workspace) *gtk.ListBoxRow {
        // Outer VBox: contains optional color rail overlay and the content VBox.
        const outer_box = gtk.Box.new(.horizontal, 0);
        outer_box.as(gtk.Widget).addCssClass("cmux-sidebar-row");

        // Color rail (left border indicator for custom workspace color)
        const color_rail = gtk.Box.new(.vertical, 0);
        color_rail.as(gtk.Widget).addCssClass("cmux-sidebar-color-rail");
        color_rail.as(gtk.Widget).setMarginEnd(6);
        color_rail.as(gtk.Widget).setVisible(0); // hidden by default
        outer_box.append(color_rail.as(gtk.Widget));

        // Content VBox: all row sections stacked vertically
        const vbox = gtk.Box.new(.vertical, 4);
        vbox.as(gtk.Widget).setHexpand(1);
        outer_box.append(vbox.as(gtk.Widget));

        // --- Section 1: Header row ---
        const header_box = gtk.Box.new(.horizontal, 6);
        vbox.append(header_box.as(gtk.Widget));

        // Unread badge
        const badge_label = gtk.Label.new("0");
        badge_label.as(gtk.Widget).addCssClass("cmux-sidebar-badge");
        badge_label.as(gtk.Widget).setVisible(0);
        header_box.append(badge_label.as(gtk.Widget));

        // Pin icon
        const pin_icon = gtk.Image.newFromIconName("view-pin-symbolic");
        pin_icon.setIconSize(.normal);
        pin_icon.as(gtk.Widget).addCssClass("cmux-sidebar-small");
        pin_icon.as(gtk.Widget).setVisible(0);
        header_box.append(pin_icon.as(gtk.Widget));

        // Title
        var title_buf: [256:0]u8 = undefined;
        const title_label = gtk.Label.new(sliceToZ(&title_buf, ws.displayTitle()));
        title_label.setXalign(0);
        title_label.setEllipsize(.end);
        title_label.as(gtk.Widget).addCssClass("cmux-sidebar-title");
        title_label.as(gtk.Widget).setHexpand(1);
        header_box.append(title_label.as(gtk.Widget));

        // Close button (visible on hover via CSS)
        const close_btn = gtk.Button.newFromIconName("window-close-symbolic");
        close_btn.as(gtk.Widget).addCssClass("flat");
        close_btn.as(gtk.Widget).addCssClass("cmux-sidebar-close-btn");
        close_btn.as(gtk.Widget).setValign(.center);
        close_btn.as(gtk.Widget).setFocusable(0);
        close_btn.as(gtk.Widget).setFocusOnClick(0);
        close_btn.as(gtk.Widget).setTooltipText("Close Workspace");
        header_box.append(close_btn.as(gtk.Widget));

        // --- Section 2: Notification subtitle ---
        const notif_label = gtk.Label.new("");
        notif_label.setXalign(0);
        notif_label.setEllipsize(.end);
        notif_label.setLines(2);
        notif_label.setMaxWidthChars(1); // Let container constrain width
        notif_label.as(gtk.Widget).addCssClass("dim-label");
        notif_label.as(gtk.Widget).addCssClass("cmux-sidebar-subtitle");
        notif_label.as(gtk.Widget).setVisible(0);
        vbox.append(notif_label.as(gtk.Widget));

        // --- Section 3: Remote SSH section ---
        const remote_box = gtk.Box.new(.horizontal, 6);
        remote_box.as(gtk.Widget).setVisible(0);
        vbox.append(remote_box.as(gtk.Widget));

        const remote_target_label = gtk.Label.new("");
        remote_target_label.setXalign(0);
        remote_target_label.setEllipsize(.end);
        remote_target_label.as(gtk.Widget).addCssClass("cmux-sidebar-mono");
        remote_target_label.as(gtk.Widget).setHexpand(1);
        remote_box.append(remote_target_label.as(gtk.Widget));

        const remote_status_label = gtk.Label.new("");
        remote_status_label.setXalign(1);
        remote_status_label.as(gtk.Widget).addCssClass("cmux-sidebar-small");
        remote_box.append(remote_status_label.as(gtk.Widget));

        // --- Section 4: Metadata entries ---
        const metadata_box = gtk.Box.new(.vertical, 2);
        metadata_box.as(gtk.Widget).setVisible(0);
        vbox.append(metadata_box.as(gtk.Widget));

        // --- Section 5: Log entry ---
        const log_box = gtk.Box.new(.horizontal, 4);
        log_box.as(gtk.Widget).setVisible(0);
        vbox.append(log_box.as(gtk.Widget));

        const log_icon = gtk.Image.newFromIconName("dialog-information-symbolic");
        log_icon.setIconSize(.normal);
        log_icon.as(gtk.Widget).addCssClass("cmux-sidebar-log-icon");
        log_box.append(log_icon.as(gtk.Widget));

        const log_label = gtk.Label.new("");
        log_label.setXalign(0);
        log_label.setEllipsize(.end);
        log_label.as(gtk.Widget).addCssClass("cmux-sidebar-secondary");
        log_label.as(gtk.Widget).setHexpand(1);
        log_box.append(log_label.as(gtk.Widget));

        // --- Section 6: Progress bar ---
        const progress_box = gtk.Box.new(.vertical, 2);
        progress_box.as(gtk.Widget).setVisible(0);
        vbox.append(progress_box.as(gtk.Widget));

        const progress_bar = gtk.ProgressBar.new();
        progress_bar.as(gtk.Widget).addCssClass("cmux-sidebar-progress-track");
        progress_box.append(progress_bar.as(gtk.Widget));

        const progress_label = gtk.Label.new("");
        progress_label.setXalign(0);
        progress_label.as(gtk.Widget).addCssClass("cmux-sidebar-small");
        progress_label.as(gtk.Widget).setVisible(0);
        progress_box.append(progress_label.as(gtk.Widget));

        // --- Section 7: Git branch + directory ---
        const branch_box = gtk.Box.new(.horizontal, 3);
        branch_box.as(gtk.Widget).setVisible(0);
        vbox.append(branch_box.as(gtk.Widget));

        const branch_icon = gtk.Image.newFromIconName("network-wired-symbolic");
        branch_icon.setIconSize(.normal);
        branch_icon.as(gtk.Widget).addCssClass("cmux-sidebar-small");
        branch_box.append(branch_icon.as(gtk.Widget));

        const branch_label = gtk.Label.new("");
        branch_label.setXalign(0);
        branch_label.setEllipsize(.end);
        branch_label.as(gtk.Widget).addCssClass("cmux-sidebar-mono");
        branch_label.as(gtk.Widget).setHexpand(1);
        branch_box.append(branch_label.as(gtk.Widget));

        // --- Section 8: Pull request rows ---
        const pr_box = gtk.Box.new(.vertical, 1);
        pr_box.as(gtk.Widget).setVisible(0);
        vbox.append(pr_box.as(gtk.Widget));

        // --- Section 9: Listening ports ---
        const ports_box = gtk.Box.new(.horizontal, 4);
        ports_box.as(gtk.Widget).setVisible(0);
        vbox.append(ports_box.as(gtk.Widget));

        // --- Section 10: Directory (shown when no git branch) ---
        const dir_label = gtk.Label.new("");
        dir_label.setXalign(0);
        dir_label.setEllipsize(.end);
        dir_label.as(gtk.Widget).addCssClass("cmux-sidebar-mono");
        dir_label.as(gtk.Widget).setVisible(0);
        vbox.append(dir_label.as(gtk.Widget));

        // --- Assemble the row ---
        const row = gtk.ListBoxRow.new();
        row.setChild(outer_box.as(gtk.Widget));

        const name = uuidToName(ws.id);
        row.as(gtk.Widget).setName(&name);

        // Wire close button
        _ = gtk.Button.signals.clicked.connect(close_btn, *Self, onSidebarCloseClicked, self, .{});

        // Wire right-click context menu
        const gesture = gtk.GestureClick.new();
        gesture.as(gtk.GestureSingle).setButton(3); // Right mouse button
        _ = gtk.GestureClick.signals.pressed.connect(gesture, *Self, onSidebarRowRightClick, self, .{});
        outer_box.as(gtk.Widget).addController(gesture.as(gtk.EventController));

        // Populate all sections
        self.updateSidebarRow(row, ws);

        return row;
    }

    fn updateSidebarRow(self: *Self, row: *gtk.ListBoxRow, ws: *const cmux.workspace.Workspace) void {
        _ = self;
        const outer_widget = row.getChild() orelse return;
        const outer_box = gobject.ext.cast(gtk.Box, outer_widget) orelse return;

        // Navigate: outer_box -> [color_rail, vbox]
        const color_rail_widget = outer_box.as(gtk.Widget).getFirstChild() orelse return;
        const vbox_widget = color_rail_widget.getNextSibling() orelse return;
        const vbox = gobject.ext.cast(gtk.Box, vbox_widget) orelse return;

        // --- Color rail ---
        if (ws.custom_color != null) {
            color_rail_widget.setVisible(1);
            // CSS background-color is set via inline style; use the addCssClass approach
            // with a named color. For simplicity, we always show the rail.
        } else {
            color_rail_widget.setVisible(0);
        }

        // --- Active state ---
        // We check if this row's workspace is the selected one
        const widget_name_z: [*:0]const u8 = row.as(gtk.Widget).getName();
        const widget_name = std.mem.span(widget_name_z);
        const ws_id = cmux.Uuid.parse(widget_name) catch null;
        // Active styling is handled by the ListBox selection; add extra CSS class
        // for our custom styling.
        outer_box.as(gtk.Widget).removeCssClass("active");

        // Navigate the vbox children sequentially:
        // [header_box, notif_label, remote_box, metadata_box, log_box,
        //  progress_box, branch_box, pr_box, ports_box, dir_label]
        var child_idx: u32 = 0;
        var child_widget: ?*gtk.Widget = vbox.as(gtk.Widget).getFirstChild();

        // Helper to advance to the Nth child
        const header_widget = child_widget orelse return;
        child_widget = header_widget.getNextSibling();
        child_idx += 1;

        // --- Section 1: Header ---
        const header_box = gobject.ext.cast(gtk.Box, header_widget) orelse return;
        {
            var hchild = header_box.as(gtk.Widget).getFirstChild();

            // Badge label
            const badge_w = hchild orelse return;
            const badge_label = gobject.ext.cast(gtk.Label, badge_w) orelse return;
            hchild = badge_w.getNextSibling();

            // Pin icon
            const pin_w = hchild orelse return;
            hchild = pin_w.getNextSibling();

            // Title label
            const title_w = hchild orelse return;
            const title_label = gobject.ext.cast(gtk.Label, title_w) orelse return;
            hchild = title_w.getNextSibling();

            // Close button — skip, it handles itself

            // Update badge
            const unread_count = ws.manual_unread_panel_ids.count();
            if (unread_count > 0) {
                var badge_buf: [16:0]u8 = undefined;
                const count_str = std.fmt.bufPrint(&badge_buf, "{d}", .{unread_count}) catch "0";
                badge_buf[count_str.len] = 0;
                badge_label.setLabel(@ptrCast(badge_buf[0..count_str.len :0].ptr));
                badge_w.setVisible(1);
            } else {
                badge_w.setVisible(0);
            }

            // Update pin
            pin_w.setVisible(@intFromBool(ws.is_pinned));

            // Update title
            var title_buf: [256:0]u8 = undefined;
            title_label.setLabel(sliceToZ(&title_buf, ws.displayTitle()));
        }

        // --- Section 2: Notification subtitle ---
        const notif_w = child_widget orelse return;
        child_widget = notif_w.getNextSibling();
        child_idx += 1;
        // We don't have a notification store reference here; hide for now.
        // The subtitle will be populated when notification infrastructure is wired.
        notif_w.setVisible(0);

        // --- Section 3: Remote SSH section ---
        const remote_w = child_widget orelse return;
        child_widget = remote_w.getNextSibling();
        child_idx += 1;
        {
            const has_remote = ws.active_remote_terminal_session_count > 0 and ws.remote_state.configuration != null;
            remote_w.setVisible(@intFromBool(has_remote));
            if (has_remote) {
                const remote_box = gobject.ext.cast(gtk.Box, remote_w) orelse return;
                const target_w = remote_box.as(gtk.Widget).getFirstChild() orelse return;
                const status_w = target_w.getNextSibling() orelse return;
                const target_label = gobject.ext.cast(gtk.Label, target_w) orelse return;
                const status_label = gobject.ext.cast(gtk.Label, status_w) orelse return;

                // Display target (SSH destination)
                if (ws.remote_state.configuration) |config| {
                    var dest_buf: [256:0]u8 = undefined;
                    target_label.setLabel(sliceToZ(&dest_buf, config.destination));
                }

                // Connection status
                const status_text: [*:0]const u8 = switch (ws.remote_state.connection_state) {
                    .connected => "Connected",
                    .connecting => "Connecting",
                    .@"error" => "Error",
                    .disconnected => "Disconnected",
                };
                status_label.setLabel(status_text);
            }
        }

        // --- Section 4: Metadata entries ---
        const metadata_w = child_widget orelse return;
        child_widget = metadata_w.getNextSibling();
        child_idx += 1;
        {
            const metadata_box = gobject.ext.cast(gtk.Box, metadata_w) orelse return;
            // Clear existing metadata children
            sidebarClearChildren(metadata_box);

            const entry_count = ws.status_entries.count();
            metadata_w.setVisible(@intFromBool(entry_count > 0));

            if (entry_count > 0) {
                var it = ws.status_entries.iterator();
                while (it.next()) |entry| {
                    const se = entry.value_ptr;
                    const meta_row = gtk.Box.new(.horizontal, 4);

                    // Key label
                    var key_buf: [128:0]u8 = undefined;
                    const key_text = std.fmt.bufPrint(&key_buf, "{s}:", .{se.key}) catch se.key;
                    key_buf[@min(key_text.len, key_buf.len - 1)] = 0;
                    const key_label = gtk.Label.new(@ptrCast(key_buf[0..@min(key_text.len, key_buf.len - 1) :0].ptr));
                    key_label.setXalign(0);
                    key_label.as(gtk.Widget).addCssClass("cmux-sidebar-small");
                    meta_row.append(key_label.as(gtk.Widget));

                    // Value label
                    var val_buf: [256:0]u8 = undefined;
                    const val_label = gtk.Label.new(sliceToZ(&val_buf, se.value));
                    val_label.setXalign(0);
                    val_label.setEllipsize(.end);
                    val_label.as(gtk.Widget).addCssClass("cmux-sidebar-secondary");
                    val_label.as(gtk.Widget).setHexpand(1);
                    meta_row.append(val_label.as(gtk.Widget));

                    metadata_box.append(meta_row.as(gtk.Widget));
                }
            }
        }

        // --- Section 5: Log entry ---
        const log_w = child_widget orelse return;
        child_widget = log_w.getNextSibling();
        child_idx += 1;
        {
            const has_log = ws.log_entries.items.len > 0;
            log_w.setVisible(@intFromBool(has_log));
            if (has_log) {
                const latest = ws.log_entries.items[ws.log_entries.items.len - 1];
                const log_box = gobject.ext.cast(gtk.Box, log_w) orelse return;
                const icon_w = log_box.as(gtk.Widget).getFirstChild() orelse return;
                const label_w = icon_w.getNextSibling() orelse return;
                const log_icon = gobject.ext.cast(gtk.Image, icon_w) orelse return;
                const log_label = gobject.ext.cast(gtk.Label, label_w) orelse return;

                // Set icon based on log level
                const icon_name: [*:0]const u8 = switch (latest.level) {
                    .info => "dialog-information-symbolic",
                    .progress => "content-loading-symbolic",
                    .success => "object-select-symbolic",
                    .warning => "dialog-warning-symbolic",
                    .@"error" => "dialog-error-symbolic",
                };
                log_icon.setFromIconName(icon_name);

                var log_buf: [512:0]u8 = undefined;
                log_label.setLabel(sliceToZ(&log_buf, latest.message));
            }
        }

        // --- Section 6: Progress bar ---
        const progress_w = child_widget orelse return;
        child_widget = progress_w.getNextSibling();
        child_idx += 1;
        {
            const has_progress = ws.progress != null;
            progress_w.setVisible(@intFromBool(has_progress));
            if (ws.progress) |progress| {
                const progress_box = gobject.ext.cast(gtk.Box, progress_w) orelse return;
                const bar_w = progress_box.as(gtk.Widget).getFirstChild() orelse return;
                const plabel_w = bar_w.getNextSibling() orelse return;
                const bar = gobject.ext.cast(gtk.ProgressBar, bar_w) orelse return;
                const plabel = gobject.ext.cast(gtk.Label, plabel_w) orelse return;

                bar.setFraction(std.math.clamp(progress.value, 0.0, 1.0));

                if (progress.label) |lbl| {
                    var plabel_buf: [256:0]u8 = undefined;
                    plabel.setLabel(sliceToZ(&plabel_buf, lbl));
                    plabel_w.setVisible(1);
                } else {
                    plabel_w.setVisible(0);
                }
            }
        }

        // --- Section 7: Git branch + directory ---
        const branch_w = child_widget orelse return;
        child_widget = branch_w.getNextSibling();
        child_idx += 1;
        {
            // Check workspace-level git branch first, then fall back to panel-level
            const git_branch: ?cmux.workspace.sidebar.GitBranchState = ws.git_branch orelse blk: {
                // Try first panel's git branch
                if (ws.panel_git_branches.count() > 0) {
                    var git_it = ws.panel_git_branches.iterator();
                    if (git_it.next()) |entry| {
                        break :blk entry.value_ptr.*;
                    }
                }
                break :blk null;
            };

            if (git_branch) |gb| {
                branch_w.setVisible(1);
                const branch_box = gobject.ext.cast(gtk.Box, branch_w) orelse return;
                // icon is first child, label is second
                const bicon_w = branch_box.as(gtk.Widget).getFirstChild() orelse return;
                const blabel_w = bicon_w.getNextSibling() orelse return;
                const blabel = gobject.ext.cast(gtk.Label, blabel_w) orelse return;

                // Build branch text with optional dirty indicator and directory
                var branch_buf: [512:0]u8 = undefined;
                const dirty_suffix: []const u8 = if (gb.is_dirty) " *" else "";
                const dir = ws.current_directory;
                const dir_display = if (dir.len > 0) dir else "~";

                // Format: "branch * · ~/dir"
                const text = std.fmt.bufPrint(&branch_buf, "{s}{s} · {s}", .{ gb.branch, dirty_suffix, dir_display }) catch gb.branch;
                branch_buf[@min(text.len, branch_buf.len - 1)] = 0;
                blabel.setLabel(@ptrCast(branch_buf[0..@min(text.len, branch_buf.len - 1) :0].ptr));
                // icon is already set in creation
            } else {
                branch_w.setVisible(0);
            }

            // Use ws_id to verify (suppress unused variable warning)
            _ = ws_id;
        }

        // --- Section 8: Pull request rows ---
        const pr_w = child_widget orelse return;
        child_widget = pr_w.getNextSibling();
        child_idx += 1;
        {
            const pr_box = gobject.ext.cast(gtk.Box, pr_w) orelse return;
            sidebarClearChildren(pr_box);

            // Collect PRs from workspace-level and panel-level
            var has_prs = false;
            if (ws.pull_request) |pr| {
                has_prs = true;
                sidebarAddPrRow(pr_box, &pr);
            }
            // Panel-level PRs
            {
                var pr_it = ws.panel_pull_requests.iterator();
                while (pr_it.next()) |entry| {
                    // Skip if same number as workspace-level PR
                    if (ws.pull_request) |ws_pr| {
                        if (entry.value_ptr.number == ws_pr.number) continue;
                    }
                    has_prs = true;
                    sidebarAddPrRow(pr_box, entry.value_ptr);
                }
            }
            pr_w.setVisible(@intFromBool(has_prs));
        }

        // --- Section 9: Listening ports ---
        const ports_w = child_widget orelse return;
        child_widget = ports_w.getNextSibling();
        child_idx += 1;
        {
            const ports_box = gobject.ext.cast(gtk.Box, ports_w) orelse return;
            sidebarClearChildren(ports_box);

            const has_ports = ws.listening_ports.len > 0;
            ports_w.setVisible(@intFromBool(has_ports));
            if (has_ports) {
                for (ws.listening_ports) |port| {
                    var port_buf: [16:0]u8 = undefined;
                    const port_text = std.fmt.bufPrint(&port_buf, ":{d}", .{port}) catch ":?";
                    port_buf[@min(port_text.len, port_buf.len - 1)] = 0;
                    const btn = gtk.Button.newWithLabel(@ptrCast(port_buf[0..@min(port_text.len, port_buf.len - 1) :0].ptr));
                    btn.as(gtk.Widget).addCssClass("flat");
                    btn.as(gtk.Widget).addCssClass("cmux-sidebar-port-btn");

                    var tip_buf: [64:0]u8 = undefined;
                    const tip_text = std.fmt.bufPrint(&tip_buf, "Open localhost:{d}", .{port}) catch "Open port";
                    tip_buf[@min(tip_text.len, tip_buf.len - 1)] = 0;
                    btn.as(gtk.Widget).setTooltipText(@ptrCast(tip_buf[0..@min(tip_text.len, tip_buf.len - 1) :0].ptr));

                    ports_box.append(btn.as(gtk.Widget));
                }
            }
        }

        // --- Section 10: Directory (fallback when no git branch shown) ---
        const dir_w = child_widget orelse return;
        {
            // Show directory only if git branch section is hidden
            const git_visible = branch_w.getVisible() != 0;
            if (!git_visible) {
                var dir_buf: [512:0]u8 = undefined;
                const dir = ws.current_directory;
                const dir_label = gobject.ext.cast(gtk.Label, dir_w) orelse return;
                dir_label.setLabel(sliceToZ(&dir_buf, if (dir.len > 0) dir else "~"));
                dir_w.setVisible(1);
            } else {
                dir_w.setVisible(0);
            }
        }
    }

    /// Remove all children from a GTK Box.
    fn sidebarClearChildren(box: *gtk.Box) void {
        while (box.as(gtk.Widget).getFirstChild()) |child| {
            box.remove(child);
        }
    }

    /// Add a pull request row to the PR box.
    fn sidebarAddPrRow(pr_box: *gtk.Box, pr: *const cmux.workspace.sidebar.PullRequestState) void {
        const pr_row = gtk.Box.new(.horizontal, 4);

        // Status icon
        const icon_name: [*:0]const u8 = switch (pr.status) {
            .open => "content-loading-symbolic",
            .merged => "object-select-symbolic",
            .closed => "window-close-symbolic",
        };
        const pr_icon = gtk.Image.newFromIconName(icon_name);
        pr_icon.setIconSize(.normal);
        pr_row.append(pr_icon.as(gtk.Widget));

        // Label + number
        var pr_buf: [256:0]u8 = undefined;
        const pr_text = std.fmt.bufPrint(&pr_buf, "{s} #{d}", .{ pr.label, pr.number }) catch "PR";
        pr_buf[@min(pr_text.len, pr_buf.len - 1)] = 0;
        const pr_label = gtk.Label.new(@ptrCast(pr_buf[0..@min(pr_text.len, pr_buf.len - 1) :0].ptr));
        pr_label.setXalign(0);
        pr_label.setEllipsize(.end);
        pr_label.as(gtk.Widget).addCssClass("cmux-sidebar-pr-btn");
        pr_label.as(gtk.Widget).setHexpand(1);
        pr_row.append(pr_label.as(gtk.Widget));

        // Checks status (if available)
        if (pr.checks) |checks| {
            const checks_text: [*:0]const u8 = switch (checks) {
                .pass => "\xe2\x9c\x93", // checkmark
                .fail => "\xe2\x9c\x97", // X mark
                .pending => "\xe2\x8f\xb3", // hourglass
            };
            const checks_label = gtk.Label.new(checks_text);
            checks_label.as(gtk.Widget).addCssClass("cmux-sidebar-small");
            pr_row.append(checks_label.as(gtk.Widget));
        }

        pr_box.append(pr_row.as(gtk.Widget));
    }

    /// Handle close button click on a sidebar row.
    fn onSidebarCloseClicked(btn: *gtk.Button, self: *Self) callconv(.c) void {
        // Walk up widget tree: btn -> header_box -> vbox -> outer_box -> row
        const btn_w = btn.as(gtk.Widget);
        const header_w = btn_w.getParent() orelse return;
        const vbox_w = header_w.getParent() orelse return;
        const outer_w = vbox_w.getParent() orelse return;
        const row_w = outer_w.getParent() orelse return;
        const name_z: [*:0]const u8 = row_w.getName();
        const ws_id = nameToUuid(name_z) orelse return;

        const priv = self.private();
        const manager = priv.manager orelse return;
        manager.closeWorkspace(ws_id) catch |err| {
            log.warn("failed to close workspace from sidebar: {}", .{err});
        };
    }

    /// Handle right-click on a sidebar row to show context menu.
    fn onSidebarRowRightClick(
        gesture: *gtk.GestureClick,
        _: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const widget = gesture.as(gtk.EventController).getWidget() orelse return;
        // The gesture is on the outer_box; its parent is the ListBoxRow
        const row_w = widget.getParent() orelse return;
        const name_z: [*:0]const u8 = row_w.getName();
        const ws_id = nameToUuid(name_z) orelse return;

        self.showSidebarContextMenu(ws_id, widget, x, y);
    }

    /// Build and show the sidebar context menu for a workspace.
    fn showSidebarContextMenu(
        self: *Self,
        ws_id: cmux.Uuid,
        parent_widget: *gtk.Widget,
        x: f64,
        y: f64,
    ) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const ws = manager.workspaceById(ws_id) orelse return;
        const ws_count = manager.workspaceCount();
        const ws_index = manager.indexOfWorkspace(ws_id);

        // Build GMenu model
        const menu = gio.Menu.new();

        // Pin/Unpin
        if (ws.is_pinned) {
            const item = gio.MenuItem.new("Unpin Workspace", null);
            item.setActionAndTargetValue("win.sidebar-ctx-unpin", null);
            menu.appendItem(item);
        } else {
            const item = gio.MenuItem.new("Pin Workspace", null);
            item.setActionAndTargetValue("win.sidebar-ctx-pin", null);
            menu.appendItem(item);
        }

        // Rename
        {
            const item = gio.MenuItem.new("Rename Workspace\xe2\x80\xa6", null);
            item.setActionAndTargetValue("win.sidebar-ctx-rename", null);
            menu.appendItem(item);
        }

        // Workspace Color submenu
        {
            const color_menu = gio.Menu.new();
            if (ws.custom_color != null) {
                const clear_item = gio.MenuItem.new("Clear Color", null);
                clear_item.setActionAndTargetValue("win.sidebar-ctx-color-clear", null);
                color_menu.appendItem(clear_item);
            }
            const colors = [_]struct { name: [*:0]const u8, hex: [*:0]const u8 }{
                .{ .name = "Red", .hex = "#C0392B" },
                .{ .name = "Orange", .hex = "#E67E22" },
                .{ .name = "Yellow", .hex = "#F1C40F" },
                .{ .name = "Green", .hex = "#27AE60" },
                .{ .name = "Blue", .hex = "#2980B9" },
                .{ .name = "Purple", .hex = "#8E44AD" },
                .{ .name = "Pink", .hex = "#E91E8C" },
            };
            for (colors) |c| {
                const item = gio.MenuItem.new(c.name, null);
                const hex_variant = glib.Variant.newString(c.hex);
                item.setActionAndTargetValue("win.sidebar-ctx-color", hex_variant);
                color_menu.appendItem(item);
            }
            menu.appendSubmenu("Workspace Color", color_menu.as(gio.MenuModel));
        }

        // Separator + Move Up / Move Down
        {
            const section = gio.Menu.new();
            {
                const item = gio.MenuItem.new("Move Up", null);
                item.setActionAndTargetValue("win.sidebar-ctx-move-up", null);
                section.appendItem(item);
            }
            {
                const item = gio.MenuItem.new("Move Down", null);
                item.setActionAndTargetValue("win.sidebar-ctx-move-down", null);
                section.appendItem(item);
            }
            menu.appendSection(null, section.as(gio.MenuModel));
        }

        // Separator + Close / Close Others
        {
            const section = gio.Menu.new();
            {
                const item = gio.MenuItem.new("Close Workspace", null);
                item.setActionAndTargetValue("win.sidebar-ctx-close", null);
                section.appendItem(item);
            }
            {
                const item = gio.MenuItem.new("Close Other Workspaces", null);
                item.setActionAndTargetValue("win.sidebar-ctx-close-others", null);
                section.appendItem(item);
            }
            menu.appendSection(null, section.as(gio.MenuModel));
        }

        // Install transient actions for this specific workspace
        self.installSidebarContextActions(ws_id, ws_index, ws_count);

        // Create and show the popover menu
        const popover = gtk.PopoverMenu.newFromModel(menu.as(gio.MenuModel));
        popover.as(gtk.Widget).setParent(parent_widget);
        popover.as(gtk.Popover).setHasArrow(0);
        popover.as(gtk.Popover).setPosition(.bottom);

        const rect: gdk.Rectangle = .{
            .f_x = @intFromFloat(x),
            .f_y = @intFromFloat(y),
            .f_width = 1,
            .f_height = 1,
        };
        popover.as(gtk.Popover).setPointingTo(&rect);
        popover.as(gtk.Popover).popup();
    }

    /// Install transient GActions for the sidebar context menu.
    /// These capture the workspace ID for the clicked row.
    fn installSidebarContextActions(self: *Self, ws_id: cmux.Uuid, ws_index: ?usize, ws_count: usize) void {
        const action_map = self.as(gio.ActionMap);

        // Remove old actions if present
        const action_names = [_][*:0]const u8{
            "sidebar-ctx-pin",
            "sidebar-ctx-unpin",
            "sidebar-ctx-rename",
            "sidebar-ctx-move-up",
            "sidebar-ctx-move-down",
            "sidebar-ctx-close",
            "sidebar-ctx-close-others",
            "sidebar-ctx-color-clear",
            "sidebar-ctx-color",
        };
        for (action_names) |name| {
            action_map.removeAction(name);
        }

        const priv = self.private();
        const manager = priv.manager orelse return;

        // Pin/Unpin
        {
            const action = gio.SimpleAction.new("sidebar-ctx-pin", null);
            _ = gio.SimpleAction.signals.activate.connect(action, *Self, sidebarCtxPin, self, .{});
            action_map.addAction(action.as(gio.Action));
        }
        {
            const action = gio.SimpleAction.new("sidebar-ctx-unpin", null);
            _ = gio.SimpleAction.signals.activate.connect(action, *Self, sidebarCtxUnpin, self, .{});
            action_map.addAction(action.as(gio.Action));
        }

        // Rename
        {
            const action = gio.SimpleAction.new("sidebar-ctx-rename", null);
            _ = gio.SimpleAction.signals.activate.connect(action, *Self, sidebarCtxRename, self, .{});
            action_map.addAction(action.as(gio.Action));
        }

        // Move Up/Down
        {
            const action = gio.SimpleAction.new("sidebar-ctx-move-up", null);
            action.setEnabled(@intFromBool(ws_index != null and ws_index.? > 0));
            _ = gio.SimpleAction.signals.activate.connect(action, *Self, sidebarCtxMoveUp, self, .{});
            action_map.addAction(action.as(gio.Action));
        }
        {
            const action = gio.SimpleAction.new("sidebar-ctx-move-down", null);
            action.setEnabled(@intFromBool(ws_index != null and ws_count > 0 and ws_index.? < ws_count - 1));
            _ = gio.SimpleAction.signals.activate.connect(action, *Self, sidebarCtxMoveDown, self, .{});
            action_map.addAction(action.as(gio.Action));
        }

        // Close / Close Others
        {
            const action = gio.SimpleAction.new("sidebar-ctx-close", null);
            _ = gio.SimpleAction.signals.activate.connect(action, *Self, sidebarCtxClose, self, .{});
            action_map.addAction(action.as(gio.Action));
        }
        {
            const action = gio.SimpleAction.new("sidebar-ctx-close-others", null);
            action.setEnabled(@intFromBool(ws_count > 1));
            _ = gio.SimpleAction.signals.activate.connect(action, *Self, sidebarCtxCloseOthers, self, .{});
            action_map.addAction(action.as(gio.Action));
        }

        // Color: clear
        {
            const action = gio.SimpleAction.new("sidebar-ctx-color-clear", null);
            _ = gio.SimpleAction.signals.activate.connect(action, *Self, sidebarCtxColorClear, self, .{});
            action_map.addAction(action.as(gio.Action));
        }

        // Color: set (takes string parameter)
        {
            const action = gio.SimpleAction.new("sidebar-ctx-color", glib.VariantType.new("s"));
            _ = gio.SimpleAction.signals.activate.connect(action, *Self, sidebarCtxColorSet, self, .{});
            action_map.addAction(action.as(gio.Action));
        }

        // Store the target workspace ID for context action handlers
        priv.sidebar_ctx_target_id = ws_id;

        _ = manager;
    }

    // --- Context menu action handlers ---
    // These all use priv.sidebar_ctx_target_id to know which workspace to act on.

    fn sidebarCtxPin(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const ws = manager.workspaceById(priv.sidebar_ctx_target_id orelse return) orelse return;
        ws.setPinned(true);
        manager.notify(.{ .workspace_updated = ws.id });
    }

    fn sidebarCtxUnpin(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const ws = manager.workspaceById(priv.sidebar_ctx_target_id orelse return) orelse return;
        ws.setPinned(false);
        manager.notify(.{ .workspace_updated = ws.id });
    }

    fn sidebarCtxRename(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const target_id = priv.sidebar_ctx_target_id orelse return;
        self.actionRenameWorkspaceForId(target_id);
    }

    fn sidebarCtxMoveUp(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        manager.moveWorkspaceUp(priv.sidebar_ctx_target_id orelse return);
    }

    fn sidebarCtxMoveDown(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        manager.moveWorkspaceDown(priv.sidebar_ctx_target_id orelse return);
    }

    fn sidebarCtxClose(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        manager.closeWorkspace(priv.sidebar_ctx_target_id orelse return) catch |err| {
            log.warn("context menu close failed: {}", .{err});
        };
    }

    fn sidebarCtxCloseOthers(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        manager.closeOtherWorkspaces(priv.sidebar_ctx_target_id orelse return);
    }

    fn sidebarCtxColorClear(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const ws = manager.workspaceById(priv.sidebar_ctx_target_id orelse return) orelse return;
        ws.setCustomColor(null) catch {};
        manager.notify(.{ .workspace_updated = ws.id });
    }

    fn sidebarCtxColorSet(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const ws = manager.workspaceById(priv.sidebar_ctx_target_id orelse return) orelse return;
        const variant = param orelse return;
        var len: usize = 0;
        const hex_z = variant.getString(&len);
        const hex = std.mem.span(hex_z);
        if (hex.len > 0) {
            ws.setCustomColor(hex) catch {};
        }
        manager.notify(.{ .workspace_updated = ws.id });
    }

    /// Trigger rename for a specific workspace by ID.
    /// Selects the workspace and activates the existing rename action.
    fn actionRenameWorkspaceForId(self: *Self, ws_id: cmux.Uuid) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        // Select the target workspace so the rename action operates on it
        manager.selectWorkspace(ws_id);
        // Trigger the existing rename-workspace action
        log.info("rename-workspace triggered for ws via context menu", .{});
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

    /// Add cmux-specific environment variables to a child process environment.
    /// Called from surface.zig buildEnv() during terminal child process setup.
    pub fn addCmuxSubprocessEnv(self: *Self, surface: *Surface, env: *std.process.EnvMap) !void {
        const priv = self.private();

        // Surface UUID (panel ID)
        if (priv.surface_reverse.get(@intFromPtr(surface))) |panel_id| {
            const panel_str = panel_id.format();
            try env.put("CMUX_SURFACE_ID", &panel_str);

            // Find workspace ID by checking which workspace owns this panel
            if (priv.manager) |mgr| {
                for (mgr.workspaces.items) |ws| {
                    if (ws.panelById(panel_id) != null) {
                        const ws_str = ws.id.format();
                        try env.put("CMUX_WORKSPACE_ID", &ws_str);
                        break;
                    }
                }
            }
        }

        // Socket path
        // Socket path — use the same resolution as the server itself
        {
            var path_buf: [std.posix.PATH_MAX]u8 = undefined;
            if (cmux.socket_path.defaultPath(&path_buf)) |path| {
                try env.put("CMUX_SOCKET_PATH", path);
            } else |_| {}
        }

        // Cmux bin directory — prepend to PATH so the claude wrapper is found
        // before the real claude binary.
        if (self.cmuxBinDir()) |bin_dir| {
            try env.put("CMUX_BIN_DIR", bin_dir);
            if (env.get("PATH")) |existing_path| {
                const alloc = env.hash_map.allocator;
                const new_path = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ bin_dir, existing_path });
                defer alloc.free(new_path);
                try env.put("PATH", new_path);
            }
        }
    }

    /// Get the cmux bin directory (share/cmux/bin/) where the claude wrapper lives.
    fn cmuxBinDir(self: *Self) ?[]const u8 {
        _ = self;
        // Use the resources directory to find share/cmux/bin/.
        // The resources dir is the parent of shell-integration, so bin/ is a sibling.
        const state = &@import("../../global.zig").state;
        const resources = state.resources_dir.app() orelse return null;
        // resources points to share/cmux (or share/ghostty). We need share/cmux/bin.
        const S = struct {
            var buf: [std.posix.PATH_MAX]u8 = undefined;
        };
        const result = std.fmt.bufPrint(&S.buf, "{s}/bin", .{resources}) catch return null;
        return result;
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

        // Rebuild pane tab bar since panel set may have changed.
        self.rebuildPaneTabBar();
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
    // -----------------------------------------------------------------
    // Sidebar toggle (public API for socket commands)
    // -----------------------------------------------------------------

    /// Toggle the sidebar visibility. If `force` is non-null, set to that value.
    pub fn toggleSidebar(self: *Self, force: ?bool) void {
        const priv = self.private();
        const current = priv.sidebar_visible;
        const target = force orelse !current;
        priv.sidebar_visible = target;
        priv.sidebar_box.as(gtk.Widget).setVisible(@intFromBool(target));
        priv.sidebar_resizer.as(gtk.Widget).setVisible(@intFromBool(target));
    }

    fn onToggleSidebar(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.toggleSidebar(null);
    }

    fn onShowNotifications(_: *gtk.Button, _: *Self) callconv(.c) void {
        // Placeholder — will be wired when NotificationsPopover is implemented.
        log.info("notifications button clicked", .{});
    }

    // -----------------------------------------------------------------
    // Pane tab bar — programmatic setup and rebuild
    // -----------------------------------------------------------------

    /// Create the pane tab bar widget and insert it into the content area
    /// above the workspace content. Called once during window construction.
    fn buildPaneTabBar(self: *Self) void {
        const priv = self.private();

        const tab_bar = gtk.Box.new(.horizontal, 0);
        tab_bar.as(gtk.Widget).addCssClass("cmux-pane-tab-bar");
        priv.pane_tab_bar = tab_bar;

        // Insert the tab bar above the toast overlay content. Find the
        // Adw.ToolbarView ancestor and add it as a top bar.
        const toast_widget = priv.toast_overlay.as(gtk.Widget);
        const tv_widget = toast_widget.getAncestor(adw.ToolbarView.getGObjectType());
        if (tv_widget) |tvw| {
            const tv: *adw.ToolbarView = @ptrCast(@alignCast(tvw));
            tv.addTopBar(tab_bar.as(gtk.Widget));
        }
    }

    /// Create titlebar control buttons and pack them into the header bar.
    /// Matches Mac's NSTitlebarAccessoryViewController (.left) placement.
    fn buildTitlebarControls(self: *Self) void {
        const priv = self.private();

        // Toggle sidebar button
        const toggle_btn = gtk.Button.new();
        toggle_btn.setIconName("sidebar-show-symbolic");
        toggle_btn.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(toggle_btn, *Self, onToggleSidebar, self, .{});
        priv.headerbar.packStart(toggle_btn.as(gtk.Widget));
        priv.toggle_sidebar_btn = toggle_btn;

        // Notifications button with unread badge overlay
        const notif_btn = gtk.Button.new();
        notif_btn.setIconName("preferences-system-notifications-symbolic");
        notif_btn.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(notif_btn, *Self, onShowNotifications, self, .{});

        const notif_badge = gtk.Label.new("0");
        notif_badge.as(gtk.Widget).addCssClass("cmux-notif-badge");
        notif_badge.as(gtk.Widget).setVisible(0);
        notif_badge.as(gtk.Widget).setHalign(.end);
        notif_badge.as(gtk.Widget).setValign(.start);
        notif_badge.as(gtk.Widget).setCanTarget(0);

        const notif_overlay = gtk.Overlay.new();
        notif_overlay.setChild(notif_btn.as(gtk.Widget));
        notif_overlay.addOverlay(notif_badge.as(gtk.Widget));

        priv.headerbar.packStart(notif_overlay.as(gtk.Widget));
        priv.notifications_btn = notif_btn;
        priv.notifications_badge = notif_badge;

        // New tab button
        const new_btn = gtk.Button.new();
        new_btn.setIconName("list-add-symbolic");
        new_btn.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(new_btn, *Self, onNewTabClicked, self, .{});
        priv.headerbar.packStart(new_btn.as(gtk.Widget));
        priv.new_tab_btn = new_btn;
    }

    fn onNewTabClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        _ = manager.createWorkspace(.{ .title = "Terminal" }) catch |err| {
            log.err("failed to create workspace: {}", .{err});
        };
    }

    /// Rebuild the pane tab bar from the currently selected workspace's panels.
    pub fn rebuildPaneTabBar(self: *Self) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const tab_bar = priv.pane_tab_bar orelse return;

        // Remove all existing children from the tab bar.
        while (tab_bar.as(gtk.Widget).getFirstChild()) |child| {
            tab_bar.remove(child);
        }
        priv.new_terminal_btn = null;

        // Get selected workspace's panels.
        const ws = manager.selectedWorkspace() orelse return;

        // Create a button for each panel in the workspace.
        var it = ws.panels.iterator();
        while (it.next()) |entry| {
            const panel_id = entry.key_ptr.*;
            const panel = entry.value_ptr;

            // Determine the tab title.
            const title: []const u8 = if (ws.panel_custom_titles.get(panel_id)) |ct|
                ct
            else if (ws.panel_titles.get(panel_id)) |pt|
                pt
            else switch (panel.*) {
                .terminal => "Terminal",
                .browser => "Browser",
                .markdown => "Markdown",
            };

            var title_buf: [256:0]u8 = undefined;
            const btn = gtk.Button.newWithLabel(sliceToZ(&title_buf, title));
            btn.as(gtk.Widget).addCssClass("flat");
            btn.as(gtk.Widget).addCssClass("cmux-pane-tab");

            // Set the widget name to the panel UUID for identification.
            const name = uuidToName(panel_id);
            btn.as(gtk.Widget).setName(&name);

            // TODO: updateProperty not available in current GTK4 Zig bindings.
            // btn.as(gtk.Widget).updateProperty(
            //     &.{gtk.Widget.AccessibleProperty.label},
            //     &.{gtk.Widget.AccessibleProperty.label.Value(sliceToZ(&title_buf, title)),
            // );

            // Connect click handler.
            _ = gtk.Button.signals.clicked.connect(btn, *Self, onPaneTabClicked, self, .{});

            // Drag source for tab reordering.
            const drag_source = gtk.DragSource.new();
            drag_source.setActions(.{ .move = true });
            _ = gtk.DragSource.signals.prepare.connect(drag_source, *Self, onTabDragPrepare, self, .{});
            _ = gtk.DragSource.signals.drag_end.connect(drag_source, *Self, onTabDragEnd, self, .{});
            btn.as(gtk.Widget).addController(drag_source.as(gtk.EventController));

            // Drop target for tab reordering.
            const drop_target = gtk.DropTarget.new(gobject.ext.types.string, .{ .move = true });
            _ = gtk.DropTarget.signals.motion.connect(drop_target, *Self, onTabDropMotion, self, .{});
            _ = gtk.DropTarget.signals.leave.connect(drop_target, *Self, onTabDropLeave, self, .{});
            _ = gtk.DropTarget.signals.drop.connect(drop_target, *Self, onTabDropDrop, self, .{});
            btn.as(gtk.Widget).addController(drop_target.as(gtk.EventController));

            tab_bar.append(btn.as(gtk.Widget));
        }

        // Append new-terminal trailing button.
        const new_term_btn = gtk.Button.new();
        new_term_btn.setIconName("list-add-symbolic");
        new_term_btn.as(gtk.Widget).addCssClass("flat");
        new_term_btn.as(gtk.Widget).addCssClass("cmux-pane-tab-new");
        // TODO: updateProperty not available in current GTK4 Zig bindings.
        // new_term_btn.as(gtk.Widget).updateProperty(
        //     &.{gtk.Widget.AccessibleProperty.label},
        //     &.{gtk.Widget.AccessibleProperty.label.Value("paneTabBarControl.newTerminal")},
        // );
        _ = gtk.Button.signals.clicked.connect(new_term_btn, *Self, onNewTerminalClicked, self, .{});
        tab_bar.append(new_term_btn.as(gtk.Widget));
        priv.new_terminal_btn = new_term_btn;
    }

    fn onPaneTabClicked(btn: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const manager = priv.manager orelse return;
        const ws = manager.selectedWorkspace() orelse return;
        const widget_name: [*:0]const u8 = btn.as(gtk.Widget).getName();
        const panel_id = nameToUuid(widget_name) orelse return;

        ws.focused_panel_id = panel_id;
        if (priv.surface_map.get(panel_id)) |surface| {
            _ = surface.as(gtk.Widget).grabFocus();
        }
    }

    fn onNewTerminalClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .right });
    }

    // -----------------------------------------------------------------
    // Pane tab bar drag & drop
    // -----------------------------------------------------------------

    fn onTabDragPrepare(source: *gtk.DragSource, _: f64, _: f64, self: *Self) callconv(.c) ?*gdk.ContentProvider {
        const priv = self.private();
        const widget = source.as(gtk.EventController).getWidget() orelse return null;
        const widget_name: [*:0]const u8 = widget.getName();
        const panel_id = nameToUuid(widget_name) orelse return null;

        priv.tab_dragged_panel_id = panel_id;
        priv.tab_drop_indicator = null;

        const formatted = panel_id.format();
        const bytes = glib.Bytes.new(&formatted, formatted.len);
        defer bytes.unref();
        return gdk.ContentProvider.newForBytes("text/plain", bytes);
    }

    fn onTabDragEnd(_: *gtk.DragSource, _: *gdk.Drag, _: c_int, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.tab_dragged_panel_id = null;
        self.clearTabDropIndicator();
    }

    fn onTabDropMotion(target: *gtk.DropTarget, x: f64, _: f64, self: *Self) callconv(.c) gdk.DragAction {
        const priv = self.private();
        if (priv.tab_dragged_panel_id == null) return .{ .move = true };

        const widget = target.as(gtk.EventController).getWidget() orelse return .{ .move = true };
        const widget_name: [*:0]const u8 = widget.getName();
        const target_panel_id = nameToUuid(widget_name) orelse return .{ .move = true };

        const manager = priv.manager orelse return .{ .move = true };
        const ws = manager.selectedWorkspace() orelse return .{ .move = true };
        const dragged_id = priv.tab_dragged_panel_id orelse return .{ .move = true };

        // Build panel_ids array.
        var panel_ids_buf: [256]cmux.Uuid = undefined;
        var panel_count: usize = 0;
        var panel_it = ws.panels.iterator();
        while (panel_it.next()) |entry_| {
            if (panel_count < panel_ids_buf.len) {
                panel_ids_buf[panel_count] = entry_.key_ptr.*;
                panel_count += 1;
            }
        }
        const panel_ids = panel_ids_buf[0..panel_count];

        // Horizontal: use x and width mapped to the vertical drop planner.
        const width: f64 = @floatFromInt(widget.getWidth());
        const new_indicator = drop_planner.indicator(
            dragged_id,
            target_panel_id,
            panel_ids,
            &.{},
            x,
            width,
        );

        if (!tabIndicatorEql(priv.tab_drop_indicator, new_indicator)) {
            self.clearTabDropIndicator();
            priv.tab_drop_indicator = new_indicator;
            self.showTabDropIndicator();
        }

        return .{ .move = true };
    }

    fn onTabDropLeave(_: *gtk.DropTarget, self: *Self) callconv(.c) void {
        self.clearTabDropIndicator();
    }

    fn onTabDropDrop(_: *gtk.DropTarget, _: *gobject.Value, _: f64, _: f64, self: *Self) callconv(.c) c_int {
        const priv = self.private();
        defer {
            priv.tab_dragged_panel_id = null;
            self.clearTabDropIndicator();
        }

        const manager = priv.manager orelse return 0;
        const ws = manager.selectedWorkspace() orelse return 0;
        const dragged_id = priv.tab_dragged_panel_id orelse return 0;

        var panel_ids_buf: [256]cmux.Uuid = undefined;
        var panel_count: usize = 0;
        var panel_it = ws.panels.iterator();
        while (panel_it.next()) |entry_| {
            if (panel_count < panel_ids_buf.len) {
                panel_ids_buf[panel_count] = entry_.key_ptr.*;
                panel_count += 1;
            }
        }
        const panel_ids = panel_ids_buf[0..panel_count];

        const target_idx = drop_planner.targetIndex(
            dragged_id,
            null,
            priv.tab_drop_indicator,
            panel_ids,
            &.{},
        ) orelse return 0;

        ws.movePanelToIndex(dragged_id, target_idx);
        self.rebuildPaneTabBar();
        return 1;
    }

    fn showTabDropIndicator(self: *Self) void {
        const priv = self.private();
        const tab_bar = priv.pane_tab_bar orelse return;
        const ind = priv.tab_drop_indicator orelse return;

        const indicator_widget = gtk.Box.new(.vertical, 0);
        indicator_widget.as(gtk.Widget).addCssClass("cmux-tab-drop-indicator");
        indicator_widget.as(gtk.Widget).setSizeRequest(2, -1);
        // TODO: updateProperty not available in current GTK4 Zig bindings.
        // indicator_widget.as(gtk.Widget).updateProperty(
        //     &.{gtk.Widget.AccessibleProperty.label},
        //     &.{gtk.Widget.AccessibleProperty.label.Value("paneTabBar.dropIndicator")},
        // );

        if (ind.tab_id) |tab_id| {
            const tab_name = uuidToName(tab_id);
            var child = tab_bar.as(gtk.Widget).getFirstChild();
            while (child) |c| {
                const cname: [*:0]const u8 = c.getName();
                if (std.mem.eql(u8, std.mem.span(cname), &tab_name)) {
                    if (ind.edge == .bottom) {
                        tab_bar.insertChildAfter(indicator_widget.as(gtk.Widget), c);
                    } else {
                        const prev = c.getPrevSibling();
                        tab_bar.insertChildAfter(indicator_widget.as(gtk.Widget), prev);
                    }
                    priv.tab_drop_indicator_widget = indicator_widget.as(gtk.Widget);
                    return;
                }
                child = c.getNextSibling();
            }
        }

        tab_bar.append(indicator_widget.as(gtk.Widget));
        priv.tab_drop_indicator_widget = indicator_widget.as(gtk.Widget);
    }

    fn clearTabDropIndicator(self: *Self) void {
        const priv = self.private();
        if (priv.tab_drop_indicator_widget) |w| {
            if (priv.pane_tab_bar) |tb| {
                tb.remove(w);
            }
            priv.tab_drop_indicator_widget = null;
        }
        priv.tab_drop_indicator = null;
    }

    fn tabIndicatorEql(a: ?drop_planner.DropIndicator, b: ?drop_planner.DropIndicator) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        const aa = a.?;
        const bb = b.?;
        if (aa.edge != bb.edge) return false;
        if (aa.tab_id == null and bb.tab_id == null) return true;
        if (aa.tab_id == null or bb.tab_id == null) return false;
        return aa.tab_id.?.eql(bb.tab_id.?);
    }

    // GLib dispatch wrappers
    // -----------------------------------------------------------------

    fn glibIdleAdd(func: cmux.dispatch.SourceFunc, userdata: ?*anyopaque) callconv(.c) c_uint {
        return glib.idleAdd(func, userdata);
    }

    fn glibTimeoutAdd(delay_ms: c_uint, func: cmux.dispatch.SourceFunc, userdata: ?*anyopaque) callconv(.c) c_uint {
        return glib.timeoutAdd(delay_ms, func, userdata);
    }

    // -----------------------------------------------------------------
    // Render diagnostics (UI tests)
    // -----------------------------------------------------------------

    fn startRenderDiagnostics(self: *Self, alloc: Allocator) void {
        if (!cmux.render_diagnostics.RenderDiagnostics.shouldEnable()) return;

        const priv = self.private();
        const diag = alloc.create(cmux.render_diagnostics.RenderDiagnostics) catch {
            log.warn("failed to allocate render diagnostics", .{});
            return;
        };
        diag.* = .{};
        diag.window_ptr = @ptrCast(self);
        diag.get_panel_id_fn = &renderDiagGetPanelId;
        diag.get_window_visible_fn = &renderDiagGetWindowVisible;
        priv.render_diag = diag;

        diag.start(priv.workspace_stack.as(gtk.Widget));
    }

    fn stopRenderDiagnostics(self: *Self) void {
        const priv = self.private();
        if (priv.render_diag) |diag| {
            diag.stop();
        }
    }

    fn renderDiagGetPanelId(window_ptr: ?*anyopaque) ?[36]u8 {
        const self: *Self = @ptrCast(@alignCast(window_ptr orelse return null));
        const surface = self.getActiveSurface() orelse return null;
        const uuid = self.surfaceUuid(surface) orelse return null;
        return uuid.format();
    }

    fn renderDiagGetWindowVisible(window_ptr: ?*anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(window_ptr orelse return false));
        return self.as(gtk.Widget).getVisible() != 0;
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
                    .is_visible = priv.sidebar_visible,
                    .selection = .tabs,
                    .width = priv.sidebar_width,
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
        // Stop render diagnostics before teardown (removes tick callback).
        self.stopRenderDiagnostics();

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

        if (priv.render_diag) |diag| {
            alloc.destroy(diag);
            priv.render_diag = null;
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

            class.bindTemplateChildPrivate("sidebar_box", .{});
            class.bindTemplateChildPrivate("sidebar_resizer", .{});
            class.bindTemplateChildPrivate("sidebar_list", .{});
            class.bindTemplateChildPrivate("workspace_stack", .{});
            class.bindTemplateChildPrivate("window_title", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});
            class.bindTemplateChildPrivate("palette_overlay", .{});
            class.bindTemplateChildPrivate("headerbar", .{});
            class.bindTemplateChildPrivate("help_btn", .{});

            class.bindTemplateCallback("on_row_selected", &onRowSelected);
            class.bindTemplateCallback("on_help_clicked", &onHelpClicked);

            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
