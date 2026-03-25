//! Command palette GTK widget — mirrors Mac's CommandPaletteOverlayView.
//!
//! A modal overlay containing a search field and results list.
//! Ctrl+Shift+P opens in commands mode (prefix ">"), Ctrl+P in switcher mode.
//! The search field fuzzy-matches against registered commands and workspace/surface
//! entries using the command_palette_search module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gobject = @import("gobject");
const glib = @import("glib");
const gtk = @import("gtk");
const gdk = @import("gdk");

const cmux = @import("../main.zig");
const search_mod = cmux.command_palette_search;
const Application = @import("../../apprt/gtk/class/application.zig").Application;

const log = std.log.scoped(.command_palette);

// =========================================================================
// PaletteCommand — a command registered for the palette
// =========================================================================

pub const PaletteCommand = struct {
    command_id: []const u8,
    title: []const u8,
    action_fn: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

// =========================================================================
// PaletteResult — a result row in the palette display
// =========================================================================

pub const PaletteResult = struct {
    command_id: []const u8,
    title: []const u8,
    trailing_label: []const u8 = "",
    score: i32 = 0,
};

// =========================================================================
// PaletteMode
// =========================================================================

pub const PaletteMode = enum {
    commands,
    switcher,
    rename,

    pub fn toString(self: PaletteMode) []const u8 {
        return switch (self) {
            .commands => "commands",
            .switcher => "switcher",
            .rename => "rename",
        };
    }
};

// =========================================================================
// CommandExecutionCallback — called by palette to execute commands
// =========================================================================

pub const CommandExecutionCallback = struct {
    ctx: ?*anyopaque = null,
    executeFn: ?*const fn (ctx: ?*anyopaque, command_id: []const u8) void = null,
};

// =========================================================================
// CommandPalette GObject widget
// =========================================================================

pub const CommandPalette = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "CmuxCommandPalette",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        // Widgets
        search_entry: ?*gtk.SearchEntry = null,
        rename_entry: ?*gtk.Entry = null,
        results_list: ?*gtk.ListBox = null,
        empty_label: ?*gtk.Label = null,
        scroll_window: ?*gtk.ScrolledWindow = null,

        // State
        mode: PaletteMode = .commands,
        is_visible: bool = false,
        selected_index: i32 = 0,

        // Results storage
        results: [128]PaletteResult = undefined,
        results_count: usize = 0,

        // Registered commands
        commands: [64]PaletteCommand = undefined,
        commands_count: usize = 0,

        // External dependencies (set by CmuxWindow)
        workspace_manager: ?*cmux.workspace.Manager = null,
        exec_callback: CommandExecutionCallback = .{},

        pub var offset: c_int = 0;
    };

    const C = @import("../../apprt/gtk/class.zig").Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();

        // Root: vertical box as the palette panel
        const widget = self.as(gtk.Widget);
        widget.setHexpand(1);
        widget.setVexpand(0);
        widget.setHalign(.center);
        widget.setValign(.start);
        widget.setVisible(0);

        const outer_box = gtk.Box.new(.vertical, 0);
        outer_box.as(gtk.Widget).addCssClass("command-palette-container");
        outer_box.as(gtk.Widget).setSizeRequest(600, -1);

        // Search entry
        const search_entry = gtk.SearchEntry.new();
        search_entry.as(gtk.Widget).setName("CommandPaletteSearchField");
        // TODO: updateProperty not available in current GTK4 Zig bindings.
        // search_entry.as(gtk.Widget).updateProperty(
        //     &[_]gtk.AccessibleProperty{.label},
        //     &[_]gtk.AccessiblePropertyVals{.{ .label = .{ .value = "CommandPaletteSearchField" } }},
        // );
        search_entry.as(gtk.Widget).setMarginTop(8);
        search_entry.as(gtk.Widget).setMarginBottom(4);
        search_entry.as(gtk.Widget).setMarginStart(8);
        search_entry.as(gtk.Widget).setMarginEnd(8);
        priv.search_entry = search_entry;

        // Connect search-changed signal
        _ = gobject.Object.signals.notify.connect(
            search_entry,
            *Self,
            onSearchTextNotify,
            self,
            .{ .detail = "text" },
        );

        // Connect activate (Return key)
        _ = gtk.SearchEntry.signals.activate.connect(
            search_entry,
            *Self,
            onSearchActivate,
            self,
            .{},
        );

        // Connect stop-search (Escape)
        _ = gtk.SearchEntry.signals.stop_search.connect(
            search_entry,
            *Self,
            onSearchStopped,
            self,
            .{},
        );

        outer_box.append(search_entry.as(gtk.Widget));

        // Rename entry (hidden by default)
        const rename_entry = gtk.Entry.new();
        rename_entry.as(gtk.Widget).setName("CommandPaletteRenameField");
        // TODO: updateProperty not available in current GTK4 Zig bindings.
        // rename_entry.as(gtk.Widget).updateProperty(
        //     &[_]gtk.AccessibleProperty{.label},
        //     &[_]gtk.AccessiblePropertyVals{.{ .label = .{ .value = "CommandPaletteRenameField" } }},
        // );
        rename_entry.as(gtk.Widget).setMarginTop(8);
        rename_entry.as(gtk.Widget).setMarginBottom(4);
        rename_entry.as(gtk.Widget).setMarginStart(8);
        rename_entry.as(gtk.Widget).setMarginEnd(8);
        rename_entry.as(gtk.Widget).setVisible(0);
        priv.rename_entry = rename_entry;

        // Connect rename activate
        _ = gtk.Entry.signals.activate.connect(
            rename_entry,
            *Self,
            onRenameActivate,
            self,
            .{},
        );

        outer_box.append(rename_entry.as(gtk.Widget));

        // Scrolled window for results
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.setMaxContentHeight(400);
        scroll.setPropagateNaturalHeight(1);
        scroll.as(gtk.Widget).setMarginStart(4);
        scroll.as(gtk.Widget).setMarginEnd(4);
        scroll.as(gtk.Widget).setMarginBottom(4);
        priv.scroll_window = scroll;

        // Results list box
        const results_list = gtk.ListBox.new();
        results_list.setSelectionMode(.single);
        results_list.as(gtk.Widget).addCssClass("rich-list");
        priv.results_list = results_list;

        // Connect row-activated
        _ = gtk.ListBox.signals.row_activated.connect(
            results_list,
            *Self,
            onRowActivated,
            self,
            .{},
        );

        scroll.setChild(results_list.as(gtk.Widget));
        outer_box.append(scroll.as(gtk.Widget));

        // Empty state label
        const empty_label = gtk.Label.new("No workspaces match your search.");
        empty_label.as(gtk.Widget).addCssClass("dim-label");
        empty_label.as(gtk.Widget).setMarginTop(16);
        empty_label.as(gtk.Widget).setMarginBottom(16);
        empty_label.as(gtk.Widget).setVisible(0);
        priv.empty_label = empty_label;
        outer_box.append(empty_label.as(gtk.Widget));

        self.as(gtk.Box).append(outer_box.as(gtk.Widget));

        // Key controller for Up/Down navigation
        const key_ctrl = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            key_ctrl,
            *Self,
            onKeyPressed,
            self,
            .{},
        );
        self.as(gtk.Widget).addController(key_ctrl.as(gtk.EventController));

        // Register default commands
        self.registerDefaultCommands();
    }

    // -----------------------------------------------------------------
    // Public API
    // -----------------------------------------------------------------

    /// Show the palette in the given mode.
    pub fn show(self: *Self, mode: PaletteMode) void {
        const priv = self.private();
        priv.mode = mode;
        priv.is_visible = true;
        priv.selected_index = 0;

        self.as(gtk.Widget).setVisible(1);

        if (mode == .rename) {
            // Rename mode: hide search, show rename entry
            if (priv.search_entry) |se| se.as(gtk.Widget).setVisible(0);
            if (priv.rename_entry) |re| {
                re.as(gtk.Widget).setVisible(1);
                _ = re.as(gtk.Widget).grabFocus();
                self.prepopulateRenameField();
            }
            if (priv.scroll_window) |sw| sw.as(gtk.Widget).setVisible(0);
            if (priv.empty_label) |el| el.as(gtk.Widget).setVisible(0);
        } else {
            // Commands or switcher mode
            if (priv.search_entry) |se| {
                se.as(gtk.Widget).setVisible(1);
                if (mode == .commands) {
                    se.as(gtk.Editable).setText(">");
                    se.as(gtk.Editable).setPosition(-1);
                } else {
                    se.as(gtk.Editable).setText("");
                }
                _ = se.as(gtk.Widget).grabFocus();
            }
            if (priv.rename_entry) |re| re.as(gtk.Widget).setVisible(0);
            if (priv.scroll_window) |sw| sw.as(gtk.Widget).setVisible(1);

            self.updateResults();
        }
    }

    /// Hide the palette.
    pub fn hide(self: *Self) void {
        const priv = self.private();
        priv.is_visible = false;
        self.as(gtk.Widget).setVisible(0);

        // Clear search
        if (priv.search_entry) |se| se.as(gtk.Editable).setText("");
        if (priv.rename_entry) |re| {
            re.as(gtk.Editable).deleteText(0, -1);
            re.as(gtk.Widget).setVisible(0);
        }

        priv.results_count = 0;
    }

    /// Toggle visibility. If visible, hide; if hidden, show in given mode.
    pub fn toggle(self: *Self, mode: PaletteMode) void {
        const priv = self.private();
        if (priv.is_visible) {
            self.hide();
        } else {
            self.show(mode);
        }
    }

    /// Check if the palette is currently visible.
    pub fn isVisible(self: *Self) bool {
        return self.private().is_visible;
    }

    /// Get the current mode.
    pub fn getMode(self: *Self) PaletteMode {
        return self.private().mode;
    }

    /// Get the current selected index.
    pub fn getSelectedIndex(self: *Self) i32 {
        return self.private().selected_index;
    }

    /// Get the full query text from the search field.
    pub fn getQuery(self: *Self) []const u8 {
        const priv = self.private();
        const se = priv.search_entry orelse return "";
        return std.mem.span(se.as(gtk.Editable).getText());
    }

    /// Get the current results snapshot.
    pub fn getResults(self: *Self) []const PaletteResult {
        const priv = self.private();
        return priv.results[0..priv.results_count];
    }

    /// Set the workspace manager reference.
    pub fn setWorkspaceManager(self: *Self, manager: *cmux.workspace.Manager) void {
        self.private().workspace_manager = manager;
    }

    /// Set the command execution callback.
    pub fn setExecutionCallback(self: *Self, cb: CommandExecutionCallback) void {
        self.private().exec_callback = cb;
    }

    /// Register a palette command.
    pub fn registerCommand(self: *Self, cmd: PaletteCommand) void {
        const priv = self.private();
        if (priv.commands_count < priv.commands.len) {
            priv.commands[priv.commands_count] = cmd;
            priv.commands_count += 1;
        }
    }

    /// Get the rename entry widget (for debug commands).
    pub fn getRenameEntry(self: *Self) ?*gtk.Entry {
        return self.private().rename_entry;
    }

    // -----------------------------------------------------------------
    // Default commands registration
    // -----------------------------------------------------------------

    fn registerDefaultCommands(self: *Self) void {
        self.registerCommand(.{
            .command_id = "palette.closeOtherWorkspaces",
            .title = "Close Other Workspaces",
        });
        self.registerCommand(.{
            .command_id = "palette.enableMinimalMode",
            .title = "Enable Minimal Mode",
        });
        self.registerCommand(.{
            .command_id = "palette.disableMinimalMode",
            .title = "Disable Minimal Mode",
        });
    }

    // -----------------------------------------------------------------
    // Search / update
    // -----------------------------------------------------------------

    fn updateResults(self: *Self) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        // Determine raw query text
        const se = priv.search_entry orelse return;
        const full_query = std.mem.span(se.as(gtk.Editable).getText());

        // Determine scope from query
        const scope = search_mod.scopeFromQuery(full_query);
        priv.mode = switch (scope) {
            .commands => .commands,
            .switcher => .switcher,
        };

        // Strip ">" prefix for the actual search query
        const query = if (full_query.len > 0 and full_query[0] == '>')
            std.mem.trimLeft(u8, full_query[1..], " ")
        else
            full_query;

        // Clear previous results
        priv.results_count = 0;

        if (priv.mode == .commands) {
            self.searchCommands(alloc, query);
        } else {
            self.searchSwitcher(alloc, query);
        }

        // Rebuild list box
        self.rebuildResultsList();

        // Update empty label
        if (priv.empty_label) |el| {
            el.as(gtk.Widget).setVisible(if (priv.results_count == 0) 1 else 0);
        }

        // Select first result
        priv.selected_index = 0;
        self.updateListSelection();
    }

    fn searchCommands(self: *Self, alloc: Allocator, query: []const u8) void {
        const priv = self.private();

        // Build corpus entries from registered commands
        var entries_buf: [64]search_mod.SearchCorpusEntry = undefined;
        var searchable_texts_buf: [64][1][]const u8 = undefined;
        var entry_count: usize = 0;

        for (priv.commands[0..priv.commands_count]) |cmd| {
            if (entry_count < entries_buf.len) {
                searchable_texts_buf[entry_count] = .{cmd.title};
                entries_buf[entry_count] = .{
                    .payload = cmd.command_id,
                    .rank = entry_count,
                    .title = cmd.title,
                    .searchable_texts = &searchable_texts_buf[entry_count],
                };
                entry_count += 1;
            }
        }

        const results = search_mod.SearchEngine.search(
            alloc,
            entries_buf[0..entry_count],
            query,
            null,
            null,
        ) catch return;
        defer search_mod.SearchEngine.freeResults(alloc, results);

        for (results) |r| {
            if (priv.results_count >= priv.results.len) break;
            priv.results[priv.results_count] = .{
                .command_id = r.payload,
                .title = r.title,
                .trailing_label = "",
                .score = r.score,
            };
            priv.results_count += 1;
        }
    }

    fn searchSwitcher(self: *Self, alloc: Allocator, query: []const u8) void {
        const priv = self.private();
        const manager = priv.workspace_manager orelse return;

        // Build corpus from workspaces. We need stable payload strings
        // that outlive the search engine call, so we use a stack buffer.
        var entries_buf: [128]search_mod.SearchCorpusEntry = undefined;
        var searchable_texts_buf: [128][1][]const u8 = undefined;
        var payload_storage: [128][64]u8 = undefined;
        var payload_slices: [128][]const u8 = undefined;
        var entry_count: usize = 0;

        for (manager.workspaces.items, 0..) |ws, rank| {
            if (entry_count >= entries_buf.len) break;

            const uuid_formatted = ws.id.format();
            const payload = std.fmt.bufPrint(&payload_storage[entry_count], "switcher.workspace.{s}", .{uuid_formatted}) catch continue;
            payload_slices[entry_count] = payload;

            searchable_texts_buf[entry_count] = .{ws.displayTitle()};
            entries_buf[entry_count] = .{
                .payload = payload_slices[entry_count],
                .rank = rank,
                .title = ws.displayTitle(),
                .searchable_texts = &searchable_texts_buf[entry_count],
            };
            entry_count += 1;
        }

        const results = search_mod.SearchEngine.search(
            alloc,
            entries_buf[0..entry_count],
            query,
            null,
            null,
        ) catch return;
        defer search_mod.SearchEngine.freeResults(alloc, results);

        for (results) |r| {
            if (priv.results_count >= priv.results.len) break;

            const trailing = workspaceTrailingLabel(manager, r.payload);

            priv.results[priv.results_count] = .{
                .command_id = r.payload,
                .title = r.title,
                .trailing_label = trailing,
                .score = r.score,
            };
            priv.results_count += 1;
        }
    }

    fn workspaceTrailingLabel(
        manager: *cmux.workspace.Manager,
        payload: []const u8,
    ) []const u8 {
        const prefix = "switcher.workspace.";
        if (!std.mem.startsWith(u8, payload, prefix)) return "";
        const uuid_str = payload[prefix.len..];
        const uuid = cmux.Uuid.parse(uuid_str) catch return "";
        const ws = manager.workspaceById(uuid) orelse return "";
        if (ws.current_directory.len > 0) return ws.current_directory;
        return "";
    }

    // -----------------------------------------------------------------
    // UI rebuild
    // -----------------------------------------------------------------

    fn rebuildResultsList(self: *Self) void {
        const priv = self.private();
        const list = priv.results_list orelse return;

        // Remove all existing rows
        while (true) {
            const row = list.getRowAtIndex(0) orelse break;
            list.remove(row.as(gtk.Widget));
        }

        // Add new rows
        for (priv.results[0..priv.results_count]) |result| {
            const row_widget = createResultRow(result);
            list.append(row_widget);
        }
    }

    fn createResultRow(result: PaletteResult) *gtk.Widget {
        const hbox = gtk.Box.new(.horizontal, 8);
        hbox.as(gtk.Widget).setMarginTop(6);
        hbox.as(gtk.Widget).setMarginBottom(6);
        hbox.as(gtk.Widget).setMarginStart(12);
        hbox.as(gtk.Widget).setMarginEnd(12);

        // Title label
        var title_buf: [256:0]u8 = undefined;
        const title_z = sliceToZ(&title_buf, result.title);
        const title_label = gtk.Label.new(title_z);
        title_label.setXalign(0);
        title_label.as(gtk.Widget).setHexpand(1);
        title_label.setEllipsize(.end);
        hbox.append(title_label.as(gtk.Widget));

        // Trailing label (if any)
        if (result.trailing_label.len > 0) {
            var trail_buf: [256:0]u8 = undefined;
            const trail_z = sliceToZ(&trail_buf, result.trailing_label);
            const trail_label = gtk.Label.new(trail_z);
            trail_label.as(gtk.Widget).addCssClass("dim-label");
            trail_label.setEllipsize(.end);
            hbox.append(trail_label.as(gtk.Widget));
        }

        return hbox.as(gtk.Widget);
    }

    fn updateListSelection(self: *Self) void {
        const priv = self.private();
        const list = priv.results_list orelse return;
        const row = list.getRowAtIndex(priv.selected_index) orelse return;
        list.selectRow(row);
    }

    // -----------------------------------------------------------------
    // Signal handlers
    // -----------------------------------------------------------------

    fn onSearchTextNotify(
        _: *gtk.SearchEntry,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.updateResults();
    }

    fn onSearchActivate(
        _: *gtk.SearchEntry,
        self: *Self,
    ) callconv(.c) void {
        self.activateSelected();
    }

    fn onSearchStopped(
        _: *gtk.SearchEntry,
        self: *Self,
    ) callconv(.c) void {
        self.hide();
    }

    fn onRenameActivate(
        _: *gtk.Entry,
        self: *Self,
    ) callconv(.c) void {
        self.executeRename();
    }

    fn onRowActivated(
        _: *gtk.ListBox,
        _: ?*gtk.ListBoxRow,
        self: *Self,
    ) callconv(.c) void {
        self.activateSelected();
    }

    fn onKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        _: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();

        switch (keyval) {
            gdk.KEY_Up => {
                if (priv.selected_index > 0) {
                    priv.selected_index -= 1;
                    self.updateListSelection();
                }
                return 1;
            },
            gdk.KEY_Down => {
                if (priv.selected_index < @as(i32, @intCast(priv.results_count)) - 1) {
                    priv.selected_index += 1;
                    self.updateListSelection();
                }
                return 1;
            },
            gdk.KEY_Escape => {
                self.hide();
                return 1;
            },
            else => return 0,
        }
    }

    // -----------------------------------------------------------------
    // Command execution
    // -----------------------------------------------------------------

    fn activateSelected(self: *Self) void {
        const priv = self.private();
        if (priv.results_count == 0) return;

        const idx: usize = @intCast(@max(0, priv.selected_index));
        if (idx >= priv.results_count) return;

        const result = priv.results[idx];
        const command_id = result.command_id;

        // Hide the palette first
        self.hide();

        // Try the execution callback (CmuxWindow handles all commands)
        if (priv.exec_callback.executeFn) |execFn| {
            execFn(priv.exec_callback.ctx, command_id);
            return;
        }

        // Fallback: handle switcher results directly
        self.executeSwitcherFallback(command_id);
    }

    fn executeSwitcherFallback(self: *Self, command_id: []const u8) void {
        const priv = self.private();
        const ws_prefix = "switcher.workspace.";
        if (!std.mem.startsWith(u8, command_id, ws_prefix)) return;

        const uuid_str = command_id[ws_prefix.len..];
        const uuid = cmux.Uuid.parse(uuid_str) catch return;
        const manager = priv.workspace_manager orelse return;
        manager.selectWorkspace(uuid);
    }

    fn executeRename(self: *Self) void {
        const priv = self.private();
        const entry = priv.rename_entry orelse return;

        const buffer = entry.getBuffer();
        const new_name = std.mem.span(buffer.getText());

        if (new_name.len == 0) {
            self.hide();
            return;
        }

        // Rename the selected workspace
        const manager = priv.workspace_manager orelse {
            self.hide();
            return;
        };

        if (manager.selected_id) |ws_id| {
            if (manager.workspaceById(ws_id)) |ws| {
                ws.setCustomTitle(new_name) catch {};
            }
        }

        self.hide();
    }

    fn prepopulateRenameField(self: *Self) void {
        const priv = self.private();
        const entry = priv.rename_entry orelse return;
        const manager = priv.workspace_manager orelse return;

        if (manager.selected_id) |ws_id| {
            if (manager.workspaceById(ws_id)) |ws| {
                const title = ws.displayTitle();
                // Set rename entry text to current workspace title and select all.
                var buf: [256:0]u8 = undefined;
                const len = @min(title.len, buf.len);
                @memcpy(buf[0..len], title[0..len]);
                buf[len] = 0;
                entry.as(gtk.Editable).setText(&buf);
                entry.as(gtk.Editable).selectRegion(0, -1);
            }
        }
    }

    // -----------------------------------------------------------------
    // CSS loading
    // -----------------------------------------------------------------

    pub fn loadCss() void {
        const css =
            \\.command-palette-container {
            \\  background-color: alpha(@window_bg_color, 0.97);
            \\  border: 1px solid @borders;
            \\  border-radius: 8px;
            \\  margin-top: 48px;
            \\  padding: 4px;
            \\  box-shadow: 0 4px 12px alpha(black, 0.3);
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
                gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 10,
            );
        }
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    fn sliceToZ(buf: [:0]u8, src: []const u8) [*:0]const u8 {
        const len = @min(src.len, buf.len);
        @memcpy(buf[0..len], src[0..len]);
        buf[len] = 0;
        return @ptrCast(buf.ptr);
    }

    // -----------------------------------------------------------------
    // GObject class
    // -----------------------------------------------------------------

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;
        pub const as = C.Class.as;

        fn init(class: *Class) callconv(.c) void {
            _ = class;
        }
    };
};
