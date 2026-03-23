const std = @import("std");
const build_config = @import("../../../build_config.zig");
const assert = @import("../../../quirks.zig").inlineAssert;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const TitlebarStyle = configpkg.Config.GtkTitlebarStyle;
const input = @import("../../../input.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gtk_version = @import("../gtk_version.zig");
const adw_version = @import("../adw_version.zig");
const gresource = @import("../build/gresource.zig");
const winprotopkg = @import("../winproto.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const DebugWarning = @import("debug_warning.zig").DebugWarning;
const CommandPalette = @import("command_palette.zig").CommandPalette;
const WeakRef = @import("../weak_ref.zig").WeakRef;

const log = std.log.scoped(.gtk_ghostty_window);

// cmux: module-level sidebar state for dynamic refresh
var cmux_sidebar_listbox: ?*gtk.ListBox = null;
var cmux_sidebar_timer: c_uint = 0;
var cmux_sidebar_stack: ?*gtk.Stack = null;
var cmux_sidebar_paned: ?*gtk.Paned = null;
var cmux_sidebar_visible: bool = true;
var cmux_notif_box: ?*gtk.Box = null;
var cmux_sidebar_last_hash: u64 = 0;

pub const Window = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the focus that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = Self.getActiveSurface,
                        },
                    ),
                },
            );
        };

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

        pub const debug = struct {
            pub const name = "debug";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = build_config.is_debug,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = struct {
                            pub fn getter(_: *Self) bool {
                                return build_config.is_debug;
                            }
                        }.getter,
                    }),
                },
            );
        };

        pub const @"titlebar-style" = struct {
            pub const name = "titlebar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                TitlebarStyle,
                .{
                    .default = .native,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        TitlebarStyle,
                        .{
                            .getter = Self.getTitlebarStyle,
                        },
                    ),
                },
            );
        };

        pub const @"headerbar-visible" = struct {
            pub const name = "headerbar-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getHeaderbarVisible,
                    }),
                },
            );
        };

        pub const @"quick-terminal" = struct {
            pub const name = "quick-terminal";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "quick_terminal",
                    ),
                },
            );
        };

        pub const @"tabs-autohide" = struct {
            pub const name = "tabs-autohide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsAutohide,
                    }),
                },
            );
        };

        pub const @"tabs-wide" = struct {
            pub const name = "tabs-wide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsWide,
                    }),
                },
            );
        };

        pub const @"tabs-visible" = struct {
            pub const name = "tabs-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsVisible,
                    }),
                },
            );
        };

        pub const @"toolbar-style" = struct {
            pub const name = "toolbar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                adw.ToolbarStyle,
                .{
                    .default = .raised,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        adw.ToolbarStyle,
                        .{
                            .getter = Self.getToolbarStyle,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// Whether this window is a quick terminal. If it is then it
        /// behaves slightly differently under certain scenarios.
        quick_terminal: bool = false,

        /// The window decoration override. If this is not set then we'll
        /// inherit whatever the config has. This allows overriding the
        /// config on a per-window basis.
        window_decoration: ?configpkg.WindowDecoration = null,

        /// Binding group for our active tab.
        tab_bindings: *gobject.BindingGroup,

        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// State and logic for windowing protocol for a window.
        winproto: winprotopkg.Window,

        /// Kind of hacky to have this but this lets us know if we've
        /// initialized any single surface yet. We need this because we
        /// gate default size on this so that we don't resize the window
        /// after surfaces already exist.
        ///
        /// I think long term we can probably get rid of this by implementing
        /// a property or method that gets us all the surfaces in all the
        /// tabs and checking if we have zero or one that isn't initialized.
        ///
        /// For now, this logic is more similar to our legacy GTK side.
        surface_init: bool = false,

        /// See tabOverviewOpen for why we have this.
        tab_overview_focus_timer: ?c_uint = null,

        /// A weak reference to a command palette.
        command_palette: WeakRef(CommandPalette) = .empty,

        /// Tab page that the context menu was opened for.
        /// setup by `setup-menu`.
        context_menu_page: ?*adw.TabPage = null,

        // Template bindings
        tab_overview: *adw.TabOverview,
        tab_bar: *adw.TabBar,
        tab_view: *adw.TabView,
        toolbar: *adw.ToolbarView,
        toast_overlay: *adw.ToastOverlay,

        pub var offset: c_int = 0;
    };

    pub fn new(app: *Application) *Self {
        return gobject.ext.newInstance(Self, .{
            .application = app,
        });
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // If our configuration is null then we get the configuration
        // from the application.
        const priv = self.private();
        if (priv.config == null) {
            const app = Application.default();
            priv.config = app.getConfig();
        }

        // We initialize our windowing protocol to none because we can't
        // actually initialize this until we get realized.
        priv.winproto = .none;

        // Add our dev CSS class if we're in debug mode.
        if (comptime build_config.is_debug) {
            self.as(gtk.Widget).addCssClass("devel");
        }

        // Setup our tab binding group. This ensures certain properties
        // are only synced from the currently active tab.
        priv.tab_bindings = gobject.BindingGroup.new();
        priv.tab_bindings.bind("title", self.as(gobject.Object), "title", .{});

        // Set our window icon. We can't set this in the blueprint file
        // because its dependent on the build config.
        self.as(gtk.Window).setIconName(build_config.bundle_id);

        // Initialize our actions
        self.initActionMap();

        // Start states based on config.
        if (priv.config) |config_obj| {
            const config = config_obj.get();
            if (config.maximize) self.as(gtk.Window).maximize();
            if (config.fullscreen != .false) self.as(gtk.Window).fullscreen();

            // If we have an explicit title set, we set that immediately
            // so that any applications inspecting the window states see
            // an immediate title set when the window appears, rather than
            // waiting possibly a few event loop ticks for it to sync from
            // the surface.
            if (config.title) |v| self.as(gtk.Window).setTitle(v);
        }

        // We always sync our appearance at the end because loading our
        // config and such can affect our bindings which are setup initially
        // in initTemplate.
        self.syncAppearance();

        // cmux: Initialize workspace sidebar
        if (comptime build_config.cmux) {
            self.initWorkspaceSidebar();
        }

        // We need to do this so that the title initializes properly,
        // I think because its a dynamic getter.
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    /// Setup our action map.
    fn initActionMap(self: *Self) void {
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("about", actionAbout, null),
            .init("close", actionClose, null),
            .init("close-tab", actionCloseTab, s_variant_type),
            .init("new-tab", actionNewTab, null),
            .init("new-window", actionNewWindow, null),
            .init("prompt-surface-title", actionPromptSurfaceTitle, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
            .init("prompt-context-tab-title", actionPromptContextTabTitle, null),
            .init("ring-bell", actionRingBell, null),
            .init("split-right", actionSplitRight, null),
            .init("split-left", actionSplitLeft, null),
            .init("split-up", actionSplitUp, null),
            .init("split-down", actionSplitDown, null),
            .init("copy", actionCopy, null),
            .init("paste", actionPaste, null),
            .init("reset", actionReset, null),
            .init("clear", actionClear, null),
            // TODO: accept the surface that toggled the command palette
            .init("toggle-command-palette", actionToggleCommandPalette, null),
            .init("toggle-inspector", actionToggleInspector, null),
        };

        ext.actions.add(Self, self, &actions);
    }

    /// cmux: Initialize the workspace sidebar.
    /// Wraps the toast_overlay in a gtk.Paned with a sidebar on the left.
    fn initWorkspaceSidebar(self: *Self) void {
        if (comptime !build_config.cmux) return;

        const priv = self.private();
        const toast_widget = priv.toast_overlay.as(gtk.Widget);
        const parent_widget = toast_widget.getParent() orelse return;

        // Create the sidebar list box
        const sidebar = gtk.ListBox.new();
        const sidebar_widget = sidebar.as(gtk.Widget);
        sidebar_widget.addCssClass("cmux-workspace-sidebar");
        sidebar_widget.setSizeRequest(200, -1);
        sidebar.setSelectionMode(.single);

        // Store reference for dynamic refresh
        cmux_sidebar_listbox = sidebar;

        // Add workspace entries from the workspace manager
        const cmux_ws = @import("../../../cmux/workspace/manager.zig");
        const notification_store = @import("../../../cmux/notification/store.zig");
        const port_scanner = @import("../../../cmux/workspace/port_scanner.zig");

        if (cmux_ws.getGlobal()) |mgr| {
            mgr.mutex.lock();
            defer mgr.mutex.unlock();

            for (mgr.workspaces.items) |ws| {
                // === Row container: vertical box, 1px spacing ===
                const row_box = gtk.Box.new(.vertical, 1);
                row_box.as(gtk.Widget).addCssClass("cmux-ws-row");

                // === Top line: HBox with name + badge ===
                const top_hbox = gtk.Box.new(.horizontal, 4);
                top_hbox.as(gtk.Widget).setHexpand(1);

                // Workspace name (12.5pt semibold equivalent)
                const name_label = gtk.Label.new(@ptrCast(ws.name.ptr));
                const name_widget = name_label.as(gtk.Widget);
                name_widget.addCssClass("cmux-ws-name");
                name_widget.setHalign(.start);
                name_widget.setHexpand(1);
                name_label.setEllipsize(.end);
                top_hbox.append(name_widget);

                // Notification badge (16px circle with count)
                const unread = if (notification_store.getGlobal()) |s| s.unreadCount() else 0;
                if (unread > 0) {
                    var badge_buf: [8]u8 = undefined;
                    const badge_text = std.fmt.bufPrintZ(&badge_buf, "{d}", .{unread}) catch "!";
                    const badge_label = gtk.Label.new(badge_text);
                    const badge_widget = badge_label.as(gtk.Widget);
                    badge_widget.addCssClass("cmux-ws-badge");
                    badge_widget.setHalign(.end);
                    top_hbox.append(badge_widget);
                }

                row_box.append(top_hbox.as(gtk.Widget));

                // === Status entries (key: value, 10pt) ===
                for (ws.status.statuses.items) |status_entry| {
                    var status_buf: [128]u8 = undefined;
                    const status_text = std.fmt.bufPrintZ(&status_buf, "{s}: {s}", .{
                        status_entry.key, status_entry.value,
                    }) catch continue;
                    const status_label = gtk.Label.new(status_text);
                    const status_widget = status_label.as(gtk.Widget);
                    status_widget.addCssClass("cmux-ws-status");
                    status_widget.setHalign(.start);
                    status_label.setEllipsize(.end);
                    row_box.append(status_widget);
                }

                // === Progress bars (3pt height, accent fill) ===
                for (ws.status.progress.items) |prog| {
                    const prog_hbox = gtk.Box.new(.horizontal, 4);

                    const progress_bar = gtk.ProgressBar.new();
                    progress_bar.setFraction(prog.value);
                    const prog_widget = progress_bar.as(gtk.Widget);
                    prog_widget.addCssClass("cmux-sidebar-progress");
                    prog_widget.setHexpand(1);
                    prog_widget.setValign(.center);
                    prog_hbox.append(prog_widget);

                    // Progress percentage label (9pt)
                    var pct_buf: [8]u8 = undefined;
                    const pct_text = std.fmt.bufPrintZ(&pct_buf, "{d}%", .{@as(u32, @intFromFloat(prog.value * 100))}) catch "";
                    if (pct_text.len > 0) {
                        const pct_label = gtk.Label.new(pct_text);
                        pct_label.as(gtk.Widget).addCssClass("cmux-ws-progress-label");
                        prog_hbox.append(pct_label.as(gtk.Widget));
                    }

                    row_box.append(prog_hbox.as(gtk.Widget));
                }

                // === Latest log entry (10pt mono, truncated) ===
                if (ws.status.logs.items.len > 0) {
                    const last_log = ws.status.logs.items[ws.status.logs.items.len - 1];
                    var log_buf: [96]u8 = undefined;
                    const log_text = std.fmt.bufPrintZ(&log_buf, "\xE2\x96\xB8 {s}", .{
                        last_log.message,
                    }) catch "";
                    if (log_text.len > 0) {
                        const log_label = gtk.Label.new(log_text);
                        const log_widget = log_label.as(gtk.Widget);
                        log_widget.addCssClass("cmux-ws-log");
                        log_widget.setHalign(.start);
                        log_label.setEllipsize(.end);
                        row_box.append(log_widget);
                    }
                }

                // === Listening ports (10pt mono) ===
                const ports = port_scanner.getPorts();
                if (ports.len > 0) {
                    var ports_buf: [128]u8 = undefined;
                    var ports_len: usize = 0;
                    const max_show: usize = 4;
                    for (ports[0..@min(ports.len, max_show)]) |p| {
                        if (ports_len > 0) {
                            if (ports_len < ports_buf.len - 1) {
                                ports_buf[ports_len] = ' ';
                                ports_len += 1;
                            }
                        }
                        const written = std.fmt.bufPrint(ports_buf[ports_len..], ":{d}", .{p.port}) catch break;
                        ports_len += written.len;
                    }
                    if (ports.len > max_show) {
                        const more = std.fmt.bufPrint(ports_buf[ports_len..], " +{d}", .{ports.len - max_show}) catch "";
                        ports_len += more.len;
                    }
                    if (ports_len > 0) {
                        ports_buf[@min(ports_len, ports_buf.len - 1)] = 0;
                        const ports_label = gtk.Label.new(@ptrCast(&ports_buf));
                        const ports_widget = ports_label.as(gtk.Widget);
                        ports_widget.addCssClass("cmux-ws-ports");
                        ports_widget.setHalign(.start);
                        ports_label.setEllipsize(.end);
                        row_box.append(ports_widget);
                    }
                }

                sidebar.append(row_box.as(gtk.Widget));

                // Select the active workspace row
                if (ws.id == mgr.active_id) {
                    if (sidebar.getRowAtIndex(@intCast(mgr.workspaces.items.len - 1))) |row| {
                        // Zig doesn't have direct selectRow, we'll use CSS class
                        _ = row;
                    }
                }
            }
        }

        // === Build sidebar container: header + stack (workspaces | notifications) ===
        const sidebar_container = gtk.Box.new(.vertical, 0);
        sidebar_container.as(gtk.Widget).setSizeRequest(200, -1);
        sidebar_container.as(gtk.Widget).addCssClass("cmux-sidebar-container");

        // --- Sidebar header with toggle buttons ---
        const header_box = gtk.Box.new(.horizontal, 0);
        header_box.as(gtk.Widget).addCssClass("cmux-sidebar-header");

        const ws_btn = gtk.ToggleButton.newWithLabel("Workspaces");
        ws_btn.as(gtk.Widget).addCssClass("cmux-sidebar-tab");
        ws_btn.as(gtk.Widget).addCssClass("active");
        ws_btn.as(gtk.Widget).setHexpand(1);
        ws_btn.setActive(1);

        const notif_btn = gtk.ToggleButton.newWithLabel("Notifications");
        notif_btn.as(gtk.Widget).addCssClass("cmux-sidebar-tab");
        notif_btn.as(gtk.Widget).setHexpand(1);

        // Sidebar toggle (hide/show) button
        const toggle_sidebar_btn = gtk.Button.newFromIconName("sidebar-show-symbolic");
        toggle_sidebar_btn.as(gtk.Widget).addCssClass("cmux-sidebar-toggle");
        toggle_sidebar_btn.as(gtk.Widget).setTooltipText("Toggle Sidebar");
        _ = gtk.Button.signals.clicked.connect(toggle_sidebar_btn, *gtk.Button, &cmuxToggleSidebarClicked, toggle_sidebar_btn, .{});

        header_box.append(toggle_sidebar_btn.as(gtk.Widget));
        header_box.append(ws_btn.as(gtk.Widget));
        header_box.append(notif_btn.as(gtk.Widget));
        sidebar_container.append(header_box.as(gtk.Widget));

        // --- Stack with two pages ---
        const stack = gtk.Stack.new();
        stack.as(gtk.Widget).setHexpand(1);
        stack.as(gtk.Widget).setVexpand(1);

        // Page 1: Workspaces (scrolled)
        const ws_scrolled = gtk.ScrolledWindow.new();
        ws_scrolled.setChild(sidebar_widget);
        ws_scrolled.setPolicy(.never, .automatic);
        _ = stack.addNamed(ws_scrolled.as(gtk.Widget), "workspaces");

        // Page 2: Notifications
        const notif_scrolled = gtk.ScrolledWindow.new();
        notif_scrolled.setPolicy(.never, .automatic);
        const notif_box = gtk.Box.new(.vertical, 8);
        notif_box.as(gtk.Widget).addCssClass("cmux-notification-panel");
        notif_box.as(gtk.Widget).setMarginTop(8);
        notif_box.as(gtk.Widget).setMarginStart(8);
        notif_box.as(gtk.Widget).setMarginEnd(8);

        // Build notification entries
        if (notification_store.getGlobal()) |store| {
            store.mutex.lock();
            defer store.mutex.unlock();

            if (store.entries.items.len == 0) {
                // Empty state
                const empty_label = gtk.Label.new("No notifications");
                empty_label.as(gtk.Widget).addCssClass("cmux-notification-empty");
                notif_box.append(empty_label.as(gtk.Widget));
            } else {
                for (store.entries.items) |entry| {
                    const notif_row = gtk.Box.new(.horizontal, 8);
                    notif_row.as(gtk.Widget).addCssClass("cmux-notification-row");

                    // Unread dot (8px)
                    if (!entry.read) {
                        const dot = gtk.Label.new("");
                        dot.as(gtk.Widget).addCssClass("cmux-notification-unread-dot");
                        dot.as(gtk.Widget).setValign(.start);
                        dot.as(gtk.Widget).setMarginTop(6);
                        notif_row.append(dot.as(gtk.Widget));
                    }

                    // Content column
                    const content_box = gtk.Box.new(.vertical, 4);
                    content_box.as(gtk.Widget).setHexpand(1);

                    // Title
                    var title_buf: [128]u8 = undefined;
                    const title_z = std.fmt.bufPrintZ(&title_buf, "{s}", .{entry.title}) catch "";
                    const title_label = gtk.Label.new(title_z);
                    title_label.as(gtk.Widget).addCssClass("cmux-notification-title");
                    title_label.as(gtk.Widget).setHalign(.start);
                    title_label.setEllipsize(.end);
                    content_box.append(title_label.as(gtk.Widget));

                    // Body
                    if (entry.body.len > 0) {
                        var body_buf: [256]u8 = undefined;
                        const body_z = std.fmt.bufPrintZ(&body_buf, "{s}", .{entry.body}) catch "";
                        const body_label = gtk.Label.new(body_z);
                        body_label.as(gtk.Widget).addCssClass("cmux-notification-body");
                        body_label.as(gtk.Widget).setHalign(.start);
                        body_label.setEllipsize(.end);
                        body_label.setLines(3);
                        content_box.append(body_label.as(gtk.Widget));
                    }

                    notif_row.append(content_box.as(gtk.Widget));
                    notif_box.append(notif_row.as(gtk.Widget));
                }
            }
        }

        cmux_notif_box = notif_box;
        notif_scrolled.setChild(notif_box.as(gtk.Widget));
        _ = stack.addNamed(notif_scrolled.as(gtk.Widget), "notifications");

        // Set initial page and store reference
        stack.setVisibleChildName("workspaces");
        cmux_sidebar_stack = stack;

        // Connect toggle buttons to switch stack pages
        _ = gtk.ToggleButton.signals.toggled.connect(ws_btn, *gtk.Stack, &cmuxWsTabToggled, stack, .{});
        _ = gtk.ToggleButton.signals.toggled.connect(notif_btn, *gtk.Stack, &cmuxNotifTabToggled, stack, .{});

        // Connect ListBox row selection to switch active workspace
        _ = gtk.ListBox.signals.row_selected.connect(sidebar, *gtk.ListBox, &cmuxWorkspaceRowSelected, sidebar, .{});

        sidebar_container.append(stack.as(gtk.Widget));

        // Create a paned: sidebar | content
        const paned = gtk.Paned.new(.horizontal);
        const paned_widget = paned.as(gtk.Widget);
        paned_widget.addCssClass("cmux-main-paned");

        // Reparent toast_overlay from the parent box to our paned.
        toast_widget.unparent();

        // Set up the paned children
        paned.setStartChild(sidebar_container.as(gtk.Widget));
        paned.setEndChild(toast_widget);
        paned.setPosition(200);
        paned.setShrinkStartChild(0);
        paned.setResizeStartChild(0);
        cmux_sidebar_paned = paned;

        // Add paned to the parent box where toast_overlay was
        const parent_box: *gtk.Box = @ptrCast(@alignCast(parent_widget));
        parent_box.append(paned_widget);

        // Start periodic sidebar refresh (2 seconds)
        cmux_sidebar_timer = glib.timeoutAdd(2000, &cmuxSidebarRefreshCallback, null);

        log.info("cmux workspace sidebar initialized with notification panel", .{});
    }

    /// Periodic callback to refresh sidebar content.
    fn cmuxSidebarRefreshCallback(_: ?*anyopaque) callconv(.c) c_int {
        if (comptime !build_config.cmux) return 0;

        const sidebar_list = cmux_sidebar_listbox orelse return 1;
        const cmux_ws = @import("../../../cmux/workspace/manager.zig");
        const notification_store = @import("../../../cmux/notification/store.zig");
        const port_scanner = @import("../../../cmux/workspace/port_scanner.zig");
        const mgr = cmux_ws.getGlobal() orelse return 1;

        // Compute content hash to skip rebuild if nothing changed
        mgr.mutex.lock();
        defer mgr.mutex.unlock();

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&mgr.workspaces.items.len));
        hasher.update(std.mem.asBytes(&mgr.active_id));
        for (mgr.workspaces.items) |ws| {
            hasher.update(ws.name);
            hasher.update(std.mem.asBytes(&ws.status.statuses.items.len));
            hasher.update(std.mem.asBytes(&ws.status.progress.items.len));
            hasher.update(std.mem.asBytes(&ws.status.logs.items.len));
        }
        const hash_unread = if (notification_store.getGlobal()) |s| s.unreadCount() else 0;
        hasher.update(std.mem.asBytes(&hash_unread));
        const current_hash = hasher.final();

        if (current_hash == cmux_sidebar_last_hash) return 1; // No changes
        cmux_sidebar_last_hash = current_hash;

        // Remove all existing rows
        while (sidebar_list.getRowAtIndex(0)) |row| {
            sidebar_list.remove(row.as(gtk.Widget));
        }

        for (mgr.workspaces.items, 0..) |ws, ws_idx| {
            const row_box = gtk.Box.new(.vertical, 1);
            row_box.as(gtk.Widget).addCssClass("cmux-ws-row");

            // Name + badge
            const top_hbox = gtk.Box.new(.horizontal, 4);
            top_hbox.as(gtk.Widget).setHexpand(1);

            const name_label = gtk.Label.new(@ptrCast(ws.name.ptr));
            name_label.as(gtk.Widget).addCssClass("cmux-ws-name");
            name_label.as(gtk.Widget).setHalign(.start);
            name_label.as(gtk.Widget).setHexpand(1);
            name_label.setEllipsize(.end);
            top_hbox.append(name_label.as(gtk.Widget));

            const unread = if (notification_store.getGlobal()) |s| s.unreadCount() else 0;
            if (unread > 0) {
                var badge_buf: [8]u8 = undefined;
                const badge_text = std.fmt.bufPrintZ(&badge_buf, "{d}", .{unread}) catch "!";
                const badge_label = gtk.Label.new(badge_text);
                badge_label.as(gtk.Widget).addCssClass("cmux-ws-badge");
                badge_label.as(gtk.Widget).setHalign(.end);
                top_hbox.append(badge_label.as(gtk.Widget));
            }

            // Keyboard shortcut hint (Ctrl+1 through Ctrl+9)
            if (ws_idx < 9) {
                var hint_buf: [8]u8 = undefined;
                const hint_text = std.fmt.bufPrintZ(&hint_buf, "^{d}", .{ws_idx + 1}) catch "";
                if (hint_text.len > 0) {
                    const hint_label = gtk.Label.new(hint_text);
                    hint_label.as(gtk.Widget).addCssClass("cmux-ws-shortcut");
                    hint_label.as(gtk.Widget).setHalign(.end);
                    top_hbox.append(hint_label.as(gtk.Widget));
                }
            }

            row_box.append(top_hbox.as(gtk.Widget));

            // Git branch info (detected from terminal PWD)
            const git_info = @import("../../../cmux/workspace/git_info.zig");
            // Try to get branch from home dir as fallback
            const home = std.posix.getenv("HOME") orelse "/home";
            if (git_info.getCachedBranch(home)) |branch| {
                var branch_buf: [64]u8 = undefined;
                const branch_text = std.fmt.bufPrintZ(&branch_buf, "\xE2\x8E\x87 {s}", .{branch}) catch "";
                if (branch_text.len > 0) {
                    const branch_label = gtk.Label.new(branch_text);
                    branch_label.as(gtk.Widget).addCssClass("cmux-ws-branch");
                    branch_label.as(gtk.Widget).setHalign(.start);
                    branch_label.setEllipsize(.end);
                    row_box.append(branch_label.as(gtk.Widget));
                }
            } else {
                // Trigger async branch detection for next refresh
                git_info.refreshBranch(home);
            }

            // Status entries
            for (ws.status.statuses.items) |status_entry| {
                var status_buf: [128]u8 = undefined;
                const status_text = std.fmt.bufPrintZ(&status_buf, "{s}: {s}", .{
                    status_entry.key, status_entry.value,
                }) catch continue;
                const status_label = gtk.Label.new(status_text);
                status_label.as(gtk.Widget).addCssClass("cmux-ws-status");
                status_label.as(gtk.Widget).setHalign(.start);
                status_label.setEllipsize(.end);
                row_box.append(status_label.as(gtk.Widget));
            }

            // Progress bars
            for (ws.status.progress.items) |prog| {
                const prog_hbox = gtk.Box.new(.horizontal, 4);
                const progress_bar = gtk.ProgressBar.new();
                progress_bar.setFraction(prog.value);
                progress_bar.as(gtk.Widget).addCssClass("cmux-sidebar-progress");
                progress_bar.as(gtk.Widget).setHexpand(1);
                progress_bar.as(gtk.Widget).setValign(.center);
                prog_hbox.append(progress_bar.as(gtk.Widget));

                var pct_buf: [8]u8 = undefined;
                const pct_text = std.fmt.bufPrintZ(&pct_buf, "{d}%", .{@as(u32, @intFromFloat(prog.value * 100))}) catch "";
                if (pct_text.len > 0) {
                    const pct_label = gtk.Label.new(pct_text);
                    pct_label.as(gtk.Widget).addCssClass("cmux-ws-progress-label");
                    prog_hbox.append(pct_label.as(gtk.Widget));
                }
                row_box.append(prog_hbox.as(gtk.Widget));
            }

            // Latest log
            if (ws.status.logs.items.len > 0) {
                const last_log = ws.status.logs.items[ws.status.logs.items.len - 1];
                var log_buf: [96]u8 = undefined;
                const log_text = std.fmt.bufPrintZ(&log_buf, "\xE2\x96\xB8 {s}", .{last_log.message}) catch "";
                if (log_text.len > 0) {
                    const log_label = gtk.Label.new(log_text);
                    log_label.as(gtk.Widget).addCssClass("cmux-ws-log");
                    log_label.as(gtk.Widget).setHalign(.start);
                    log_label.setEllipsize(.end);
                    row_box.append(log_label.as(gtk.Widget));
                }
            }

            // Ports
            const ports = port_scanner.getPorts();
            if (ports.len > 0) {
                var ports_buf: [128]u8 = undefined;
                var ports_len: usize = 0;
                const max_show: usize = 4;
                for (ports[0..@min(ports.len, max_show)]) |p| {
                    if (ports_len > 0) {
                        if (ports_len < ports_buf.len - 1) {
                            ports_buf[ports_len] = ' ';
                            ports_len += 1;
                        }
                    }
                    const written = std.fmt.bufPrint(ports_buf[ports_len..], ":{d}", .{p.port}) catch break;
                    ports_len += written.len;
                }
                if (ports.len > max_show) {
                    const more = std.fmt.bufPrint(ports_buf[ports_len..], " +{d}", .{ports.len - max_show}) catch "";
                    ports_len += more.len;
                }
                if (ports_len > 0) {
                    ports_buf[@min(ports_len, ports_buf.len - 1)] = 0;
                    const ports_label = gtk.Label.new(@ptrCast(&ports_buf));
                    ports_label.as(gtk.Widget).addCssClass("cmux-ws-ports");
                    ports_label.as(gtk.Widget).setHalign(.start);
                    ports_label.setEllipsize(.end);
                    row_box.append(ports_label.as(gtk.Widget));
                }
            }

            sidebar_list.append(row_box.as(gtk.Widget));
        }
        // Workspace reordering is available via socket API:
        // V1: reorder-workspace <id> <new-index>
        // V2: workspace.reorder {workspace_id, index}
        // Visual DnD requires C-level GValue glue that the Zig GObject
        // bindings don't fully support yet.

        // Also refresh notification panel
        if (cmux_notif_box) |nbox| {
            // Clear existing children
            while (nbox.as(gtk.Widget).getFirstChild()) |child| {
                nbox.remove(child);
            }

            if (notification_store.getGlobal()) |store| {
                store.mutex.lock();
                defer store.mutex.unlock();

                if (store.entries.items.len == 0) {
                    const empty_label = gtk.Label.new("No notifications");
                    empty_label.as(gtk.Widget).addCssClass("cmux-notification-empty");
                    nbox.append(empty_label.as(gtk.Widget));
                } else {
                    for (store.entries.items) |entry| {
                        const notif_row = gtk.Box.new(.horizontal, 8);
                        notif_row.as(gtk.Widget).addCssClass("cmux-notification-row");

                        if (!entry.read) {
                            const dot = gtk.Label.new("");
                            dot.as(gtk.Widget).addCssClass("cmux-notification-unread-dot");
                            dot.as(gtk.Widget).setValign(.start);
                            dot.as(gtk.Widget).setMarginTop(6);
                            notif_row.append(dot.as(gtk.Widget));
                        }

                        const content_box = gtk.Box.new(.vertical, 4);
                        content_box.as(gtk.Widget).setHexpand(1);

                        var title_buf: [128]u8 = undefined;
                        const title_z = std.fmt.bufPrintZ(&title_buf, "{s}", .{entry.title}) catch "";
                        const title_label = gtk.Label.new(title_z);
                        title_label.as(gtk.Widget).addCssClass("cmux-notification-title");
                        title_label.as(gtk.Widget).setHalign(.start);
                        title_label.setEllipsize(.end);
                        content_box.append(title_label.as(gtk.Widget));

                        if (entry.body.len > 0) {
                            var body_buf: [256]u8 = undefined;
                            const body_z = std.fmt.bufPrintZ(&body_buf, "{s}", .{entry.body}) catch "";
                            const body_label = gtk.Label.new(body_z);
                            body_label.as(gtk.Widget).addCssClass("cmux-notification-body");
                            body_label.as(gtk.Widget).setHalign(.start);
                            body_label.setEllipsize(.end);
                            content_box.append(body_label.as(gtk.Widget));
                        }

                        notif_row.append(content_box.as(gtk.Widget));
                        nbox.append(notif_row.as(gtk.Widget));
                    }
                }
            }
        }

        return 1; // Keep timer
    }

    /// Toggle sidebar visibility.
    fn cmuxToggleSidebarClicked(_: *gtk.Button, _: *gtk.Button) callconv(.c) void {
        const paned_w = cmux_sidebar_paned orelse return;
        if (cmux_sidebar_visible) {
            paned_w.setPosition(0);
            cmux_sidebar_visible = false;
        } else {
            paned_w.setPosition(200);
            cmux_sidebar_visible = true;
        }
    }

    /// Workspaces tab toggled — show workspaces page.
    fn cmuxWsTabToggled(_: *gtk.ToggleButton, stack: *gtk.Stack) callconv(.c) void {
        stack.setVisibleChildName("workspaces");
    }

    /// Notifications tab toggled — show notifications page.
    fn cmuxNotifTabToggled(_: *gtk.ToggleButton, stack: *gtk.Stack) callconv(.c) void {
        stack.setVisibleChildName("notifications");
    }

    /// Workspace row selected — switch active workspace.
    fn cmuxWorkspaceRowSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, _: *gtk.ListBox) callconv(.c) void {
        const selected_row = row orelse return;
        const index = selected_row.getIndex();
        if (index < 0) return;

        const cmux_ws = @import("../../../cmux/workspace/manager.zig");
        const mgr = cmux_ws.getGlobal() orelse return;
        mgr.mutex.lock();
        defer mgr.mutex.unlock();

        const idx: usize = @intCast(index);
        if (idx < mgr.workspaces.items.len) {
            mgr.active_id = mgr.workspaces.items[idx].id;
        }
    }

    /// DragSource prepare: returns a ContentProvider with the workspace index.
    /// Winproto backend for this window.
    pub fn winproto(self: *Self) *winprotopkg.Window {
        return &self.private().winproto;
    }

    /// Create a new tab with the given parent. The tab will be inserted
    /// at the position dictated by the `window-new-tab-position` config.
    /// The new tab will be selected.
    pub fn newTab(self: *Self, parent_: ?*CoreSurface) void {
        _ = self.newTabPage(parent_, .tab);
    }

    pub fn newTabForWindow(self: *Self, parent_: ?*CoreSurface) void {
        _ = self.newTabPage(parent_, .window);
    }

    fn newTabPage(self: *Self, parent_: ?*CoreSurface, context: apprt.surface.NewSurfaceContext) *adw.TabPage {
        const priv = self.private();
        const tab_view = priv.tab_view;

        // Create our new tab object
        const tab = gobject.ext.newInstance(Tab, .{
            .config = priv.config,
        });
        if (parent_) |p| {
            // For a new window's first tab, inherit the parent's initial size hints.
            if (context == .window) {
                surfaceInit(p.rt_surface.gobj(), self);
            }
            tab.setParentWithContext(p, context);
        }

        // Get the position that we should insert the new tab at.
        const config = if (priv.config) |v| v.get() else {
            // If we don't have a config we just append it at the end.
            // This should never happen.
            return tab_view.append(tab.as(gtk.Widget));
        };
        const position = switch (config.@"window-new-tab-position") {
            .current => current: {
                const selected = tab_view.getSelectedPage() orelse
                    break :current tab_view.getNPages();
                const current = tab_view.getPagePosition(selected);
                break :current current + 1;
            },

            .end => tab_view.getNPages(),
        };

        // Add the page and select it
        const page = tab_view.insert(tab.as(gtk.Widget), position);
        tab_view.setSelectedPage(page);

        // Create some property bindings
        _ = tab.as(gobject.Object).bindProperty(
            "title",
            page.as(gobject.Object),
            "title",
            .{ .sync_create = true },
        );
        _ = tab.as(gobject.Object).bindProperty(
            "tooltip",
            page.as(gobject.Object),
            "tooltip",
            .{ .sync_create = true },
        );

        // Bind signals
        const split_tree = tab.getSplitTree();
        _ = SplitTree.signals.changed.connect(
            split_tree,
            *Self,
            tabSplitTreeChanged,
            self,
            .{},
        );

        // Run an initial notification for the surface tree so we can setup
        // initial state.
        tabSplitTreeChanged(
            split_tree,
            null,
            split_tree.getTree(),
            self,
        );

        return page;
    }

    pub const SelectTab = union(enum) {
        previous,
        next,
        last,
        n: usize,
    };

    /// Select the tab as requested. Returns true if the tab selection
    /// changed.
    pub fn selectTab(self: *Self, n: SelectTab) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;

        // Get our current tab numeric position
        const selected = tab_view.getSelectedPage() orelse return false;
        const current = tab_view.getPagePosition(selected);

        // Get our total
        const total = tab_view.getNPages();

        const goto: c_int = switch (n) {
            .previous => if (current > 0)
                current - 1
            else
                total - 1,

            .next => if (current < total - 1)
                current + 1
            else
                0,

            .last => total - 1,

            .n => |v| n: {
                // 1-indexed
                if (v == 0) return false;

                const n_int = std.math.cast(
                    c_int,
                    v,
                ) orelse return false;
                break :n @min(n_int - 1, total - 1);
            },
        };
        assert(goto >= 0);
        assert(goto < total);

        // If our target is the same as our current then we do nothing.
        if (goto == current) return false;

        // Add the page and select it
        const page = tab_view.getNthPage(goto);
        tab_view.setSelectedPage(page);

        return true;
    }

    /// Move the tab containing the given surface by the given amount.
    /// Returns if this affected any tab positioning.
    pub fn moveTab(
        self: *Self,
        surface: *Surface,
        amount: isize,
    ) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;

        // If we have one tab we never move.
        const total = tab_view.getNPages();
        if (total == 1) return false;

        // Get the tab that contains the given surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse return false;

        // Get the page position that contains the tab.
        const page = tab_view.getPage(tab.as(gtk.Widget));
        const pos = tab_view.getPagePosition(page);

        // Move it
        const desired_pos: c_int = desired: {
            const initial: c_int = @intCast(pos + amount);
            const max = total - 1;
            break :desired if (initial < 0)
                max + initial + 1
            else if (initial > max)
                initial - max - 1
            else
                initial;
        };
        assert(desired_pos >= 0);
        assert(desired_pos < total);

        return tab_view.reorderPage(page, desired_pos) != 0;
    }

    pub fn toggleTabOverview(self: *Self) void {
        const priv = self.private();
        const tab_overview = priv.tab_overview;
        const is_open = tab_overview.getOpen() != 0;
        tab_overview.setOpen(@intFromBool(!is_open));
    }

    /// Toggle the visible property.
    pub fn toggleVisibility(self: *Self) void {
        const widget = self.as(gtk.Widget);
        widget.setVisible(@intFromBool(widget.isVisible() == 0));
    }

    /// Updates various appearance properties. This should always be safe
    /// to call multiple times. This should be called whenever a change
    /// happens that might affect how the window appears (config change,
    /// fullscreen, etc.).
    fn syncAppearance(self: *Self) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);

        // Toggle style classes based on whether we're using CSDs or SSDs.
        //
        // These classes are defined in the gtk.Window documentation:
        // https://docs.gtk.org/gtk4/class.Window.html#css-nodes.
        {
            // Reset all style classes first
            inline for (&.{
                "ssd",
                "csd",
                "solid-csd",
                "no-border-radius",
            }) |class|
                widget.removeCssClass(class);

            const csd_enabled = priv.winproto.clientSideDecorationEnabled();
            self.as(gtk.Window).setDecorated(@intFromBool(csd_enabled));

            if (csd_enabled) {
                const display = widget.getDisplay();

                // We do the exact same check GTK is doing internally and toggle
                // either the `csd` or `solid-csd` style, based on whether the user's
                // window manager is deemed _non-compositing_.
                //
                // In practice this only impacts users of traditional X11 window
                // managers (e.g. i3, dwm, awesomewm, etc.) and not X11 desktop
                // environments or Wayland compositors/DEs.
                if (display.isRgba() != 0 and display.isComposited() != 0) {
                    widget.addCssClass("csd");
                } else {
                    widget.addCssClass("solid-csd");
                }
            } else {
                widget.addCssClass("ssd");
                // Fix any artifacting that may occur in window corners.
                widget.addCssClass("no-border-radius");
            }
        }

        // Trigger all our dynamic properties that depend on the config.
        inline for (&.{
            "headerbar-visible",
            "tabs-autohide",
            "tabs-visible",
            "tabs-wide",
            "toolbar-style",
            "titlebar-style",
        }) |key| {
            self.as(gobject.Object).notifyByPspec(
                @field(properties, key).impl.param_spec,
            );
        }

        // Remainder uses the config
        const config = if (priv.config) |v| v.get() else return;

        // Only add a solid background if we're opaque.
        self.toggleCssClass(
            "background",
            config.@"background-opacity" >= 1,
        );

        // Apply class to color headerbar if window-theme is set to `ghostty` and
        // GTK version is before 4.16. The conditional is because above 4.16
        // we use GTK CSS color variables.
        self.toggleCssClass(
            "window-theme-ghostty",
            !gtk_version.atLeast(4, 16, 0) and
                config.@"window-theme" == .ghostty,
        );

        // Move the tab bar to the proper location.
        priv.toolbar.remove(priv.tab_bar.as(gtk.Widget));
        switch (config.@"gtk-tabs-location") {
            .top => priv.toolbar.addTopBar(priv.tab_bar.as(gtk.Widget)),
            .bottom => priv.toolbar.addBottomBar(priv.tab_bar.as(gtk.Widget)),
        }

        // Do our window-protocol specific appearance sync.
        priv.winproto.syncAppearance() catch |err| {
            log.warn("failed to sync winproto appearance error={}", .{err});
        };
    }

    /// Sync the state of any actions on this window.
    fn syncActions(self: *Self) void {
        const has_selection = selection: {
            const surface = self.getActiveSurface() orelse
                break :selection false;
            const core_surface = surface.core() orelse
                break :selection false;
            break :selection core_surface.hasSelection();
        };

        const action_map: *gio.ActionMap = gobject.ext.cast(
            gio.ActionMap,
            self,
        ) orelse return;
        const action: *gio.SimpleAction = gobject.ext.cast(
            gio.SimpleAction,
            action_map.lookupAction("copy") orelse return,
        ) orelse return;
        action.setEnabled(@intFromBool(has_selection));
    }

    fn toggleCssClass(self: *Self, class: [:0]const u8, value: bool) void {
        const widget = self.as(gtk.Widget);
        if (value)
            widget.addCssClass(class.ptr)
        else
            widget.removeCssClass(class.ptr);
    }

    /// Perform a binding action on the window's active surface.
    fn performBindingAction(
        self: *Self,
        action: input.Binding.Action,
    ) void {
        const surface = self.getActiveSurface() orelse return;
        const core_surface = surface.core() orelse return;
        _ = core_surface.performBindingAction(action) catch |err| {
            log.warn("error performing binding action error={}", .{err});
            return;
        };
    }

    /// Queue a simple text-based toast. All text-based toasts share the
    /// same timeout for consistency.
    ///
    // This is not `pub` because we should be using signals emitted by
    // other widgets to trigger our toasts. Other objects should not
    // trigger toasts directly.
    fn addToast(self: *Self, title: [*:0]const u8) void {
        const toast = adw.Toast.new(title);
        toast.setTimeout(3);
        self.private().toast_overlay.addToast(toast);
    }

    fn connectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        const priv = self.private();
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            // Before adding any new signal handlers, disconnect any that we may
            // have added before. Otherwise we may get multiple handlers for the
            // same signal.
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );

            _ = Surface.signals.@"present-request".connect(
                surface,
                *Self,
                surfacePresentRequest,
                self,
                .{},
            );
            _ = Surface.signals.@"clipboard-write".connect(
                surface,
                *Self,
                surfaceClipboardWrite,
                self,
                .{},
            );
            _ = Surface.signals.menu.connect(
                surface,
                *Self,
                surfaceMenu,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-fullscreen".connect(
                surface,
                *Self,
                surfaceToggleFullscreen,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-maximize".connect(
                surface,
                *Self,
                surfaceToggleMaximize,
                self,
                .{},
            );

            // If we've never had a surface initialize yet, then we register
            // this signal. Its theoretically possible to launch multiple surfaces
            // before init so we could register this on multiple and that is not
            // a problem because we'll check the flag again in each handler.
            if (!priv.surface_init) {
                _ = Surface.signals.init.connect(
                    surface,
                    *Self,
                    surfaceInit,
                    self,
                    .{},
                );
            }
        }
    }

    /// Disconnect all the surface handlers for the given tree. This should
    /// be called whenever a tree is no longer present in the window, e.g.
    /// when a tab is detached or the tree changes.
    fn disconnectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }
    }

    //---------------------------------------------------------------
    // Properties

    /// Whether this terminal is a quick terminal or not.
    pub fn isQuickTerminal(self: *Self) bool {
        return self.private().quick_terminal;
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tab = self.getSelectedTab() orelse return null;
        return tab.getActiveSurface();
    }

    /// Returns the configuration for this window. The reference count
    /// is not increased.
    pub fn getConfig(self: *Self) ?*Config {
        return self.private().config;
    }

    /// Get the tab view for this window.
    pub fn getTabView(self: *Self) *adw.TabView {
        return self.private().tab_view;
    }

    /// Get the current window decoration value for this window.
    pub fn getWindowDecoration(self: *Self) configpkg.WindowDecoration {
        const priv = self.private();
        if (priv.window_decoration) |v| return v;
        if (priv.config) |v| return v.get().@"window-decoration";
        return .auto;
    }

    /// Toggle the window decorations for this window.
    pub fn toggleWindowDecorations(self: *Self) void {
        const priv = self.private();

        if (priv.window_decoration) |_| {
            // Unset any previously set window decoration settings
            self.setWindowDecoration(null);
            return;
        }

        const config = if (priv.config) |v| v.get() else return;
        self.setWindowDecoration(switch (config.@"window-decoration") {
            // Use auto when the decoration is initially none
            .none => .auto,

            // Anything non-none to none
            .auto, .client, .server => .none,
        });
    }

    /// Set the window decoration override for this window. If this is null,
    /// then we'll revert back to the configuration's default.
    fn setWindowDecoration(
        self: *Self,
        new_: ?configpkg.WindowDecoration,
    ) void {
        const priv = self.private();
        priv.window_decoration = new_;
        self.syncAppearance();
    }

    /// Get the currently selected tab as a Tab object.
    fn getSelectedTab(self: *Self) ?*Tab {
        const priv = self.private();
        const page = priv.tab_view.getSelectedPage() orelse return null;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));
        return gobject.ext.cast(Tab, child);
    }

    /// Returns true if this window needs confirmation before quitting.
    fn getNeedsConfirmQuit(self: *Self) bool {
        const priv = self.private();
        const n = priv.tab_view.getNPages();
        assert(n >= 0);

        for (0..@intCast(n)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const tab = gobject.ext.cast(Tab, child) orelse {
                log.warn("unexpected non-Tab child in tab view", .{});
                continue;
            };
            if (tab.getNeedsConfirmQuit()) return true;
        }

        return false;
    }

    fn isFullscreen(self: *Window) bool {
        return self.as(gtk.Window).isFullscreen() != 0;
    }

    fn isMaximized(self: *Window) bool {
        return self.as(gtk.Window).isMaximized() != 0;
    }

    fn getHeaderbarVisible(self: *Self) bool {
        const priv = self.private();

        // Never display the header bar when CSDs are disabled.
        const csd_enabled = priv.winproto.clientSideDecorationEnabled();
        if (!csd_enabled) return false;

        // Never display the header bar as a quick terminal.
        if (priv.quick_terminal) return false;

        // If we're fullscreen we never show the header bar.
        if (self.isFullscreen()) return false;

        // The remainder needs a config
        const config_obj = self.private().config orelse return true;
        const config = config_obj.get();

        // *Conditionally* disable the header bar when maximized, and
        // gtk-titlebar-hide-when-maximized is set
        if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") {
            return false;
        }

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs never show the titlebar.
            .tabs => false,

            // If the titlebar style is native show the titlebar if configured
            // to do so.
            .native => config.@"gtk-titlebar",
        };
    }

    fn getTabsAutohide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs we cannot autohide.
            .tabs => false,

            .native => switch (config.@"window-show-tab-bar") {
                // Auto we always autohide... obviously.
                .auto => true,

                // Always we never autohide because we always show the tab bar.
                .always => false,

                // Never we autohide because it doesn't actually matter,
                // since getTabsVisible will return false.
                .never => true,
            },
        };
    }

    fn getTabsVisible(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        switch (config.@"gtk-titlebar-style") {
            .tabs => {
                // *Conditionally* disable the tab bar when maximized, the titlebar
                // style is tabs, and gtk-titlebar-hide-when-maximized is set.
                if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") return false;

                // If the titlebar style is tabs the tab bar must always be visible.
                return true;
            },
            .native => {
                return switch (config.@"window-show-tab-bar") {
                    .always, .auto => true,
                    .never => false,
                };
            },
        }
    }

    fn getTabsWide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;
        return config.@"gtk-wide-tabs";
    }

    fn getToolbarStyle(self: *Self) adw.ToolbarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .raised;
        return switch (config.@"gtk-toolbar-style") {
            .flat => .flat,
            .raised => .raised,
            .@"raised-border" => .raised_border,
        };
    }

    fn getTitlebarStyle(self: *Self) TitlebarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .native;
        return config.@"gtk-titlebar-style";
    }

    fn propConfig(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |config_obj| {
            const config = config_obj.get();
            if (config.@"app-notifications".@"config-reload") {
                self.addToast(i18n._("Reloaded the configuration"));
            }
        }

        self.syncAppearance();
    }

    fn propGdkSurfaceHeight(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // X11 needs to fix blurring on resize, but winproto implementations
        // could do anything.
        self.private().winproto.resizeEvent() catch |err| {
            log.warn(
                "winproto resize event failed error={}",
                .{err},
            );
        };
    }

    fn propIsActive(
        _: *gtk.Window,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Hide quick-terminal if set to autohide
        if (self.isQuickTerminal()) {
            if (self.getConfig()) |cfg| {
                if (cfg.get().@"quick-terminal-autohide" and self.as(gtk.Window).isActive() == 0) {
                    self.toggleVisibility();
                }
            }
        }

        // Don't change urgency if we're not the active window.
        if (self.as(gtk.Window).isActive() == 0) return;

        self.winproto().setUrgent(false) catch |err| {
            log.warn(
                "winproto failed to reset urgency={}",
                .{err},
            );
        };
    }

    fn propGdkSurfaceWidth(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // X11 needs to fix blurring on resize, but winproto implementations
        // could do anything.
        self.private().winproto.resizeEvent() catch |err| {
            log.warn(
                "winproto resize event failed error={}",
                .{err},
            );
        };
    }

    fn propFullscreened(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMaximized(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMenuActive(
        button: *gtk.MenuButton,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Debian 12 is stuck on GTK 4.8
        if (!gtk_version.atLeast(4, 10, 0)) return;

        // We only care if we're activating. If we're activating then
        // we need to check the validity of our menu items.
        const active = button.getActive() != 0;
        if (!active) return;

        self.syncActions();
    }

    fn propQuickTerminal(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.surface_init) {
            log.warn("quick terminal property can't be changed after surfaces have been initialized", .{});
            return;
        }

        if (priv.quick_terminal) {
            // Initialize the quick terminal at the app-layer
            Application.default().winproto().initQuickTerminal(self) catch |err| {
                log.warn("failed to initialize quick terminal error={}", .{err});
                return;
            };
        }
    }

    fn propScaleFactor(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // On some platforms (namely X11) we need to refresh our appearance when
        // the scale factor changes. In theory this could be more fine-grained as
        // a full refresh could be expensive, but a) this *should* be rare, and
        // b) quite noticeable visual bugs would occur if this is not present.
        self.private().winproto.syncAppearance() catch |err| {
            log.warn(
                "failed to sync appearance after scale factor has been updated={}",
                .{err},
            );
            return;
        };
    }

    fn closureTitlebarStyleIsTab(
        _: *Self,
        value: TitlebarStyle,
    ) callconv(.c) c_int {
        return @intFromBool(switch (value) {
            .native => false,
            .tabs => true,
        });
    }

    fn closureSubtitle(
        _: *Self,
        config_: ?*Config,
        pwd_: ?[*:0]const u8,
    ) callconv(.c) ?[*:0]const u8 {
        const config = if (config_) |v| v.get() else return null;
        return switch (config.@"window-subtitle") {
            .false => null,
            .@"working-directory" => pwd: {
                const pwd = pwd_ orelse return null;
                break :pwd glib.ext.dupeZ(u8, std.mem.span(pwd));
            },
        };
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.command_palette.set(null);

        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        priv.tab_bindings.setSource(null);

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.tab_bindings.unref();
        priv.winproto.deinit(Application.default().allocator());

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn windowRealize(_: *gtk.Widget, self: *Window) callconv(.c) void {
        const app = Application.default();

        // Initialize our window protocol logic
        if (winprotopkg.Window.init(
            app.allocator(),
            app.winproto(),
            self,
        )) |wp| {
            self.private().winproto = wp;
        } else |err| {
            log.warn("failed to initialize window protocol error={}", .{err});
            return;
        }

        // We need to setup resize notifications on our surface,
        // which is only available after the window had been realized.
        if (self.as(gtk.Native).getSurface()) |gdk_surface| {
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceWidth,
                self,
                .{ .detail = "width" },
            );
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceHeight,
                self,
                .{ .detail = "height" },
            );
        }

        // When we are realized we always setup our appearance since this
        // calls some winproto functions.
        self.syncAppearance();
    }

    fn btnNewTab(_: *adw.SplitButton, self: *Self) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn tabOverviewCreateTab(
        _: *adw.TabOverview,
        self: *Self,
    ) callconv(.c) *adw.TabPage {
        return self.newTabPage(if (self.getActiveSurface()) |v| v.core() else null, .tab);
    }

    fn tabOverviewOpen(
        tab_overview: *adw.TabOverview,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We only care about when the tab overview is closed.
        if (tab_overview.getOpen() != 0) return;

        // On tab overview close, focus is sometimes lost. This is an
        // upstream issue in libadwaita[1]. When this is resolved we
        // can put a runtime version check here to avoid this workaround.
        //
        // Our workaround is to start a timer after 500ms to refocus
        // the currently selected tab. We choose 500ms because the adw
        // animation is 400ms.
        //
        // [1]: https://gitlab.gnome.org/GNOME/libadwaita/-/issues/670

        // If we have an old timer remove it
        const priv = self.private();
        if (priv.tab_overview_focus_timer) |timer| {
            _ = glib.Source.remove(timer);
        }

        // Restart our timer
        priv.tab_overview_focus_timer = glib.timeoutAdd(
            500,
            tabOverviewFocusTimer,
            self,
        );
    }

    fn tabOverviewFocusTimer(
        ud: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        // Always note our timer is removed
        self.private().tab_overview_focus_timer = null;

        // Get our currently active surface which should respect the newly
        // selected tab. Grab focus.
        const surface = self.getActiveSurface() orelse return 0;
        surface.grabFocus();

        // Remove the timer
        return 0;
    }

    fn windowCloseRequest(
        _: *gtk.Window,
        self: *Self,
    ) callconv(.c) c_int {
        if (self.getNeedsConfirmQuit()) {
            // Show a confirmation dialog
            const dialog: *CloseConfirmationDialog = .new(.window);
            _ = CloseConfirmationDialog.signals.@"close-request".connect(
                dialog,
                *Self,
                closeConfirmationClose,
                self,
                .{},
            );

            // Show it
            dialog.present(self.as(gtk.Widget));
            return @intFromBool(true);
        }

        self.as(gtk.Window).destroy();
        return @intFromBool(false);
    }

    fn closeConfirmationClose(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).destroy();
    }

    fn closeConfirmationCloseTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(true));
    }

    fn closeConfirmationCancelTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(false));
    }

    fn tabViewClosePage(
        _: *adw.TabView,
        page: *adw.TabPage,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse
            return @intFromBool(false);

        // If the tab says it doesn't need confirmation then we go ahead
        // and close immediately.
        if (!tab.getNeedsConfirmQuit()) {
            priv.tab_view.closePageFinish(page, @intFromBool(true));
            return @intFromBool(true);
        }

        // Show a confirmation dialog
        const dialog: *CloseConfirmationDialog = .new(.tab);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCloseTab,
            page,
            .{},
        );
        _ = CloseConfirmationDialog.signals.cancel.connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCancelTab,
            page,
            .{},
        );

        // Show it
        dialog.present(child);
        return @intFromBool(true);
    }

    fn tabViewSelectedPage(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Always reset our binding source in case we have no pages.
        priv.tab_bindings.setSource(null);

        // Get our current page which MUST be a Tab object.
        const page = priv.tab_view.getSelectedPage() orelse return;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));

        // Setup our binding group. This ensures things like the title
        // are synced from the active tab.
        priv.tab_bindings.setSource(child.as(gobject.Object));

        // If the tab was previously marked as needing attention
        // (e.g. due to a bell character), we now unmark that
        page.setNeedsAttention(@intFromBool(false));
    }

    fn tabViewPageAttached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // Get the attached page which must be a Tab object.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;

        // Attach listeners for the tab.
        _ = Tab.signals.@"close-request".connect(
            tab,
            *Self,
            tabCloseRequest,
            self,
            .{},
        );

        // Attach listeners for the surface.
        //
        // Interesting behavior here that was previously undocumented but
        // I'm going to make it explicit here: we accept all the signals here
        // (like toggle-fullscreen) regardless of whether the surface or tab
        // is focused. At the time of writing this we have no API that could
        // really trigger these that way but its theoretically possible.
        //
        // What is DEFINITELY possible is something like OSC52 triggering
        // a clipboard-write signal on an unfocused tab/surface. We definitely
        // want to show the user a notification about that but our notification
        // right now is a toast that doesn't make it clear WHO used the
        // clipboard. We probably want to change that in the future.
        //
        // I'm not sure how desirable all the above is, and we probably
        // should be thoughtful about future signals here. But all of this
        // behavior is consistent with macOS and the previous GTK apprt,
        // but that behavior was all implicit and not documented, so here
        // I am.
        if (tab.getSurfaceTree()) |tree| {
            self.connectSurfaceHandlers(tree);
        }
    }

    fn tabViewPageDetached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // We need to get the tab to disconnect the signals.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        _ = gobject.signalHandlersDisconnectMatched(
            tab.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );

        // Remove the tree handlers
        if (tab.getSurfaceTree()) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }
    }

    fn tabViewCreateWindow(
        _: *adw.TabView,
        _: *Self,
    ) callconv(.c) *adw.TabView {
        // Create a new window without creating a new tab.
        const win = gobject.ext.newInstance(
            Self,
            .{
                .application = Application.default(),
            },
        );

        // We have to show it otherwise it'll just be hidden.
        gtk.Window.present(win.as(gtk.Window));

        // Get our tab view
        return win.private().tab_view;
    }

    fn tabCloseRequest(
        tab: *Tab,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.tab_view.getPage(tab.as(gtk.Widget));
        // TODO: connect close page handler to tab to check for confirmation
        priv.tab_view.closePage(page);
    }

    fn tabViewNPages(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.tab_view.getNPages() == 0) {
            // If we have no pages left then we want to close window.

            // If the tab overview is open, then we don't close the window
            // because its a rather abrupt experience. This also fixes an
            // issue where dragging out the last tab in the tab overview
            // won't cause Ghostty to exit.
            if (priv.tab_overview.getOpen() != 0) return;

            self.as(gtk.Window).close();
        }
    }
    fn setupTabMenu(
        _: *adw.TabView,
        page: ?*adw.TabPage,
        self: *Self,
    ) callconv(.c) void {
        self.private().context_menu_page = page;
    }

    fn surfaceClipboardWrite(
        _: *Surface,
        clipboard_type: apprt.Clipboard,
        text: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        // We only toast for the standard clipboard.
        if (clipboard_type != .standard) return;

        // We only toast if configured to
        const priv = self.private();
        const config_obj = priv.config orelse return;
        const config = config_obj.get();
        if (!config.@"app-notifications".@"clipboard-copy") {
            return;
        }

        if (text[0] != 0)
            self.addToast(i18n._("Copied to clipboard"))
        else
            self.addToast(i18n._("Cleared clipboard"));
    }

    fn surfaceMenu(
        _: *Surface,
        self: *Self,
    ) callconv(.c) void {
        self.syncActions();
    }

    fn surfacePresentRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        // Verify that this surface is actually in this window.
        {
            const surface_window = ext.getAncestor(
                Self,
                surface.as(gtk.Widget),
            ) orelse {
                log.warn(
                    "present request called for non-existent surface",
                    .{},
                );
                return;
            };
            if (surface_window != self) {
                log.warn(
                    "present request called for surface in different window",
                    .{},
                );
                return;
            }
        }

        // Get the tab for this surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse {
            log.warn("present request surface not found", .{});
            return;
        };

        // Get the page that contains this tab
        const priv = self.private();
        const tab_view = priv.tab_view;
        const page = tab_view.getPage(tab.as(gtk.Widget));
        tab_view.setSelectedPage(page);

        // Grab focus
        surface.grabFocus();

        // Bring the window to the front.
        self.as(gtk.Window).present();
    }

    fn surfaceToggleFullscreen(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isFullscreen() != 0) {
            self.as(gtk.Window).unfullscreen();
        } else {
            self.as(gtk.Window).fullscreen();
        }

        // We react to the changes in the propFullscreen callback
    }

    fn surfaceToggleMaximize(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isMaximized() != 0) {
            self.as(gtk.Window).unmaximize();
        } else {
            self.as(gtk.Window).maximize();
        }

        // We react to the changes in the propMaximized callback
    }

    fn surfaceInit(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Make sure we init only once
        if (priv.surface_init) return;
        priv.surface_init = true;

        // Setup our default and minimum size.
        if (surface.getDefaultSize()) |size| {
            self.as(gtk.Window).setDefaultSize(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
        if (surface.getMinSize()) |size| {
            self.as(gtk.Widget).setSizeRequest(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
    }

    fn tabSplitTreeChanged(
        _: *SplitTree,
        old_tree: ?*const Surface.Tree,
        new_tree: ?*const Surface.Tree,
        self: *Self,
    ) callconv(.c) void {
        if (old_tree) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }

        if (new_tree) |tree| {
            self.connectSurfaceHandlers(tree);
        }
    }

    fn actionAbout(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const name = if (comptime build_config.cmux) "cmux" else "Ghostty";
        const icon = build_config.bundle_id;
        const website = if (comptime build_config.cmux)
            "https://github.com/ball2jh/cmux-linux"
        else
            "https://ghostty.org";
        const dev_name = if (comptime build_config.cmux)
            "cmux-linux contributors"
        else
            i18n._("Ghostty Developers");
        const issue_url = if (comptime build_config.cmux)
            "https://github.com/ball2jh/cmux-linux/issues"
        else
            "https://github.com/ghostty-org/ghostty/issues";

        if (adw_version.supportsDialogs()) {
            adw.showAboutDialog(
                self.as(gtk.Widget),
                "application-name",
                name,
                "developer-name",
                dev_name,
                "application-icon",
                icon,
                "version",
                build_config.version_string.ptr,
                "issue-url",
                issue_url,
                "website",
                website,
                @as(?*anyopaque, null),
            );
        } else {
            const about_title = if (comptime build_config.cmux)
                "About cmux"
            else
                i18n._("About Ghostty");
            gtk.showAboutDialog(
                self.as(gtk.Window),
                "program-name",
                name,
                "logo-icon-name",
                icon,
                "title",
                about_title,
                "version",
                build_config.version_string.ptr,
                "website",
                website,
                @as(?*anyopaque, null),
            );
        }
    }

    fn actionClose(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).close();
    }

    fn actionCloseTab(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("win.close-tab called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const mode = std.meta.stringToEnum(
            input.Binding.Action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to win.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            log.warn("invalid mode provided to win.close-tab: {s}", .{str.?});
            return;
        };

        self.performBindingAction(.{ .close_tab = mode });
    }

    fn actionNewWindow(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_window);
    }

    fn actionNewTab(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn actionPromptContextTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.context_menu_page orelse return;
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        tab.promptTabTitle();
    }

    fn actionPromptSurfaceTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_surface_title);
    }

    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_tab_title);
    }

    fn actionSplitRight(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .right });
    }

    fn actionSplitLeft(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .left });
    }

    fn actionSplitUp(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .up });
    }

    fn actionSplitDown(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .down });
    }

    fn actionCopy(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .copy_to_clipboard = .mixed });
    }

    fn actionPaste(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.paste_from_clipboard);
    }

    fn actionReset(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.reset);
    }

    fn actionClear(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.clear_screen);
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return;

        if (config.@"bell-features".system) system: {
            const native = self.as(gtk.Native).getSurface() orelse {
                log.warn("unable to get native surface from window", .{});
                break :system;
            };
            native.beep();
        }

        if (config.@"bell-features".attention) attention: {
            // Dont set urgency if the window is already active.
            if (self.as(gtk.Window).isActive() != 0) break :attention;

            // Request user attention
            self.winproto().setUrgent(true) catch |err| {
                log.warn("winproto failed to set urgency={}", .{err});
            };
        }
    }

    /// Toggle the command palette.
    ///
    /// TODO: accept the surface that toggled the command palette as a parameter
    fn toggleCommandPalette(self: *Window) void {
        const priv = self.private();

        // Get a reference to a command palette. First check the weak reference
        // that we save to see if we already have one stored. If we don't then
        // create a new one.
        const command_palette = priv.command_palette.get() orelse command_palette: {
            // Create a fresh command palette.
            const command_palette = CommandPalette.new();

            // Synchronize our config to the command palette's config.
            _ = gobject.Object.bindProperty(
                self.as(gobject.Object),
                "config",
                command_palette.as(gobject.Object),
                "config",
                .{ .sync_create = true },
            );

            // Listen to the activate signal to know if the user selected an option in
            // the command palette.
            _ = CommandPalette.signals.trigger.connect(
                command_palette,
                *Window,
                signalCommandPaletteTrigger,
                self,
                .{},
            );

            // Save a weak reference to the command palette. We use a weak reference to avoid
            // reference counting cycles that might cause problems later.
            priv.command_palette.set(command_palette);

            break :command_palette command_palette;
        };
        defer command_palette.unref();

        // Tell the command palette to toggle itself. If the dialog gets
        // presented (instead of hidden) it will be modal over our window.
        command_palette.toggle(self);
    }

    // React to a signal from a command palette asking an action to be performed.
    fn signalCommandPaletteTrigger(_: *CommandPalette, action: *const input.Binding.Action, self: *Self) callconv(.c) void {
        // If the activation actually has an action, perform it.
        self.performBindingAction(action.*);
    }

    /// React to a GTK action requesting that the command palette be toggled.
    fn actionToggleCommandPalette(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleCommandPalette();
    }

    /// Toggle the Ghostty inspector for the active surface.
    fn toggleInspector(self: *Self) void {
        const surface = self.getActiveSurface() orelse return;
        _ = surface.controlInspector(.toggle);
    }

    /// React to a GTK action requesting that the Ghostty inspector be toggled.
    fn actionToggleInspector(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleInspector();
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(DebugWarning);
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gobject.ext.ensureType(Tab);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "window",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.debug.impl,
                properties.@"headerbar-visible".impl,
                properties.@"quick-terminal".impl,
                properties.@"tabs-autohide".impl,
                properties.@"tabs-visible".impl,
                properties.@"tabs-wide".impl,
                properties.@"toolbar-style".impl,
                properties.@"titlebar-style".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("tab_overview", .{});
            class.bindTemplateChildPrivate("tab_bar", .{});
            class.bindTemplateChildPrivate("tab_view", .{});
            class.bindTemplateChildPrivate("toolbar", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});

            // Template Callbacks
            class.bindTemplateCallback("realize", &windowRealize);
            class.bindTemplateCallback("new_tab", &btnNewTab);
            class.bindTemplateCallback("overview_create_tab", &tabOverviewCreateTab);
            class.bindTemplateCallback("overview_notify_open", &tabOverviewOpen);
            class.bindTemplateCallback("close_request", &windowCloseRequest);
            class.bindTemplateCallback("close_page", &tabViewClosePage);
            class.bindTemplateCallback("page_attached", &tabViewPageAttached);
            class.bindTemplateCallback("page_detached", &tabViewPageDetached);
            class.bindTemplateCallback("setup_tab_menu", &setupTabMenu);
            class.bindTemplateCallback("tab_create_window", &tabViewCreateWindow);
            class.bindTemplateCallback("notify_n_pages", &tabViewNPages);
            class.bindTemplateCallback("notify_selected_page", &tabViewSelectedPage);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("notify_fullscreened", &propFullscreened);
            class.bindTemplateCallback("notify_is_active", &propIsActive);
            class.bindTemplateCallback("notify_maximized", &propMaximized);
            class.bindTemplateCallback("notify_menu_active", &propMenuActive);
            class.bindTemplateCallback("notify_quick_terminal", &propQuickTerminal);
            class.bindTemplateCallback("notify_scale_factor", &propScaleFactor);
            class.bindTemplateCallback("titlebar_style_is_tabs", &closureTitlebarStyleIsTab);
            class.bindTemplateCallback("computed_subtitle", &closureSubtitle);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
