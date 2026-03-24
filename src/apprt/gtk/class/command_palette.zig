const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const input = @import("../../../input.zig");
const gresource = @import("../build/gresource.zig");
const key = @import("../key.zig");
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const Config = @import("config.zig").Config;
const search_mod = @import("../../../cmux/command_palette_search.zig");

const log = std.log.scoped(.gtk_ghostty_command_palette);

pub const CommandPalette = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCommandPalette",
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

    pub const signals = struct {
        /// Emitted when a command from the command palette is activated. The
        /// action contains pointers to allocated data so if a receiver of this
        /// signal needs to keep the action around it will need to clone the
        /// action or there may be use-after-free errors.
        pub const trigger = struct {
            pub const name = "trigger";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{*const input.Binding.Action},
                void,
            );
        };
    };

    /// The palette scope: commands (">") or switcher (no prefix).
    pub const Scope = search_mod.PaletteScope;

    /// The current mode of the palette.
    pub const Mode = enum {
        /// Showing command results (with ">" prefix).
        commands,
        /// Showing switcher results (no prefix).
        switcher,
        /// Text input for renaming a tab or workspace.
        rename_input,
    };

    /// Target of a rename operation.
    pub const RenameTarget = struct {
        kind: enum { workspace, tab },
        current_name: [:0]const u8,
    };

    const Private = struct {
        /// The configuration that this command palette is using.
        config: ?*Config = null,

        /// The dialog object containing the palette UI.
        dialog: *adw.Dialog,

        /// The search input text field.
        search: *gtk.SearchEntry,

        /// The view containing each result row.
        view: *gtk.ListView,

        /// The model that provides filtered data for the view to display.
        model: *gtk.SingleSelection,

        /// The list that serves as the visible data source of the model.
        /// Populated by fuzzy search from the corpus.
        source: *gio.ListStore,

        /// The current scope of the palette (commands vs switcher).
        scope: Scope = .commands,

        /// The current mode of the palette.
        mode: Mode = .commands,

        /// The rename target when in rename_input mode.
        rename_target: ?RenameTarget = null,

        /// Full corpus of all commands (regular + jump), holding strong refs.
        /// The source ListStore is populated from this via fuzzy search.
        corpus: std.ArrayList(*Command) = .{},

        pub var offset: c_int = 0;
    };

    /// Create a new instance of the command palette. The caller will own a
    /// reference to the object.
    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});

        // Sink ourselves so that we aren't floating anymore. We'll unref
        // ourselves when the palette is closed or an action is activated.
        _ = self.refSink();

        // Bump the ref so that the caller has a reference.
        return self.ref();
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Listen for any changes to our config.
        _ = gobject.Object.signals.notify.connect(
            self,
            ?*anyopaque,
            propConfig,
            null,
            .{
                .detail = "config",
            },
        );

        // Listen for search text changes to detect scope transitions.
        _ = gtk.SearchEntry.signals.search_changed.connect(
            self.private().search,
            *CommandPalette,
            searchChanged,
            self,
            .{},
        );

        // Add key event controller for custom navigation (Ctrl+N/J/P/K).
        const key_controller = gtk.EventControllerKey.new();
        key_controller.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            key_controller,
            *CommandPalette,
            keyPressed,
            self,
            .{},
        );
        self.private().search.as(gtk.Widget).addController(key_controller.as(gtk.EventController));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        priv.source.removeAll();

        // Release corpus refs.
        for (priv.corpus.items) |cmd| cmd.unref();
        priv.corpus.deinit(alloc);
        priv.corpus = .{};

        if (priv.config) |config| {
            config.unref();
            priv.config = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal Handlers

    fn propConfig(self: *CommandPalette, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
        const priv = self.private();

        const config = priv.config orelse {
            log.warn("command palette does not have a config!", .{});
            return;
        };

        const alloc = Application.default().allocator();

        // Clear old corpus (release refs).
        for (priv.corpus.items) |cmd| cmd.unref();
        priv.corpus.clearRetainingCapacity();

        self.collectJumpCommands(config, &priv.corpus) catch |err| {
            log.warn("failed to collect jump commands: {}", .{err});
        };

        self.collectRegularCommands(config, &priv.corpus, alloc);

        // Re-run search with current query to repopulate visible results.
        self.refreshSearchResults();
    }

    /// Collect regular commands from configuration, filtering out unsupported actions.
    fn collectRegularCommands(
        self: *CommandPalette,
        config: *Config,
        commands: *std.ArrayList(*Command),
        alloc: std.mem.Allocator,
    ) void {
        _ = self;
        const cfg = config.get();

        for (cfg.@"command-palette-entry".value.items) |command| {
            // Filter out actions that are not implemented or don't make sense
            // for GTK.
            if (!isActionSupportedOnGtk(command.action)) continue;

            const cmd = Command.new(config, command) catch |err| {
                log.warn("failed to create command: {}", .{err});
                continue;
            };
            errdefer cmd.unref();

            commands.append(alloc, cmd) catch |err| {
                log.warn("failed to add command to list: {}", .{err});
                continue;
            };
        }
    }

    /// Check if an action is supported on GTK.
    fn isActionSupportedOnGtk(action: input.Binding.Action) bool {
        return switch (action) {
            .close_all_windows,
            .toggle_secure_input,
            .check_for_updates,
            .redo,
            .undo,
            .reset_window_size,
            .toggle_window_float_on_top,
            => false,

            else => true,
        };
    }

    /// Collect jump commands for all surfaces across all windows.
    fn collectJumpCommands(
        self: *CommandPalette,
        config: *Config,
        commands: *std.ArrayList(*Command),
    ) !void {
        _ = self;
        const app = Application.default();
        const alloc = app.allocator();

        // Get all surfaces from the core app
        const core_app = app.core();
        for (core_app.surfaces.items) |apprt_surface| {
            const surface = apprt_surface.gobj();
            const cmd = Command.newJump(config, surface);
            errdefer cmd.unref();
            try commands.append(alloc, cmd);
        }
    }

    /// Compare two commands for sorting.
    /// Sorts alphabetically by title (case-insensitive), with colon normalization
    /// so "Foo:" sorts before "Foo Bar:". Uses sort_key as tie-breaker.
    fn compareCommands(a: *Command, b: *Command) bool {
        const a_title = a.propGetTitle() orelse return false;
        const b_title = b.propGetTitle() orelse return true;

        // Compare case-insensitively with colon normalization
        for (0..@min(a_title.len, b_title.len)) |i| {
            // Get characters, replacing ':' with '\t'
            const a_char = if (a_title[i] == ':') '\t' else a_title[i];
            const b_char = if (b_title[i] == ':') '\t' else b_title[i];

            const a_lower = std.ascii.toLower(a_char);
            const b_lower = std.ascii.toLower(b_char);

            if (a_lower != b_lower) {
                return a_lower < b_lower;
            }
        }

        // If one title is a prefix of the other, shorter one comes first
        if (a_title.len != b_title.len) {
            return a_title.len < b_title.len;
        }

        // Titles are equal - use sort_key as tie-breaker if both are jump commands
        const a_sort_key = switch (a.private().data) {
            .regular => return false,
            .jump => |*ja| ja.sort_key,
        };
        const b_sort_key = switch (b.private().data) {
            .regular => return false,
            .jump => |*jb| jb.sort_key,
        };

        return a_sort_key < b_sort_key;
    }

    /// Handle key presses for custom navigation (Ctrl+N/J down, Ctrl+P/K up).
    /// Returns 1 (TRUE) if the key was handled, 0 (FALSE) to propagate.
    fn keyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        gtk_mods: gdk.ModifierType,
        self: *CommandPalette,
    ) callconv(.c) c_int {
        const priv = self.private();
        const has_ctrl = gtk_mods.control_mask;
        const no_other_mods = !gtk_mods.shift_mask and !gtk_mods.alt_mask and !gtk_mods.super_mask;

        if (has_ctrl and no_other_mods) {
            const delta: ?i64 = switch (keyval) {
                gdk.KEY_n, gdk.KEY_j => 1, // Down
                gdk.KEY_p, gdk.KEY_k => -1, // Up
                else => null,
            };

            if (delta) |d| {
                const n_items = priv.model.as(gio.ListModel).getNItems();
                if (n_items == 0) return 1;
                const current: i64 = @intCast(priv.model.getSelected());
                const new_idx = std.math.clamp(current + d, 0, @as(i64, @intCast(n_items)) - 1);
                priv.model.setSelected(@intCast(new_idx));
                return 1;
            }
        }

        // Page Up / Page Down (no modifier needed).
        if (no_other_mods and !has_ctrl) {
            const page_delta: ?i64 = switch (keyval) {
                gdk.KEY_Page_Up => -10,
                gdk.KEY_Page_Down => 10,
                else => null,
            };

            if (page_delta) |d| {
                const n_items = priv.model.as(gio.ListModel).getNItems();
                if (n_items == 0) return 1;
                const current: i64 = @intCast(priv.model.getSelected());
                const new_idx = std.math.clamp(current + d, 0, @as(i64, @intCast(n_items)) - 1);
                priv.model.setSelected(@intCast(new_idx));
                return 1;
            }
        }

        // Backspace in rename mode on empty input: go back to commands.
        if (priv.mode == .rename_input and keyval == gdk.KEY_BackSpace) {
            const rename_text = priv.search.as(gtk.Editable).getText();
            const rename_query: []const u8 = std.mem.sliceTo(rename_text, 0);
            const has_modifier = has_ctrl or gtk_mods.alt_mask or gtk_mods.super_mask;
            if (search_mod.commandPaletteShouldPopRenameInputOnDelete(rename_query, has_modifier)) {
                self.exitRenameMode();
                return 1;
            }
        }

        return 0; // Not handled, propagate.
    }

    /// Handle search text changes — runs fuzzy search and repopulates results.
    fn searchChanged(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        const priv = self.private();

        // Don't run fuzzy search while in rename mode.
        if (priv.mode == .rename_input) return;

        const text = priv.search.as(gtk.Editable).getText();
        const query: []const u8 = std.mem.sliceTo(text, 0);
        const new_scope = search_mod.scopeFromQuery(query);
        priv.scope = new_scope;

        self.refreshSearchResults();
    }

    /// Get the current scope of the palette.
    pub fn getScope(self: *CommandPalette) Scope {
        return self.private().scope;
    }

    /// Rebuild the visible results from the corpus using fuzzy search.
    fn refreshSearchResults(self: *CommandPalette) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        // Get the current query, stripping the ">" prefix if present.
        const text = priv.search.as(gtk.Editable).getText();
        const raw_query: []const u8 = std.mem.sliceTo(text, 0);
        const matching_query = search_mod.matchingQueryFromRaw(raw_query);

        // Build corpus entries for SearchEngine. We allocate separate
        // searchable_texts arrays so they survive into the search call.
        const corpus = priv.corpus.items;
        const entries = alloc.alloc(search_mod.SearchCorpusEntry, corpus.len) catch {
            log.warn("failed to allocate search corpus entries", .{});
            return;
        };
        defer alloc.free(entries);

        // Allocate searchable text slices for each entry (max 2 texts each).
        const texts_backing = alloc.alloc([2][]const u8, corpus.len) catch {
            log.warn("failed to allocate searchable texts", .{});
            return;
        };
        defer alloc.free(texts_backing);

        for (corpus, 0..) |cmd, i| {
            const title_str: []const u8 = if (cmd.propGetTitle()) |t| @as([]const u8, t) else "";
            const action_key_str: []const u8 = if (cmd.propGetActionKey()) |k| @as([]const u8, k) else "";
            const cmd_id: []const u8 = if (cmd.propGetCommandId()) |id| @as([]const u8, id) else "";

            texts_backing[i] = .{ title_str, action_key_str };
            const text_count: usize = if (action_key_str.len > 0) 2 else 1;

            entries[i] = .{
                .payload = cmd_id,
                .rank = i,
                .title = title_str,
                .searchable_texts = texts_backing[i][0..text_count],
            };
        }

        // Run the search engine.
        const results = search_mod.SearchEngine.search(
            alloc,
            entries,
            matching_query,
            null, // No history boost yet (Step 7).
            null, // No cancellation.
        ) catch {
            log.warn("search engine failed", .{});
            return;
        };
        defer search_mod.SearchEngine.freeResults(alloc, results);

        // Clear current visible results and repopulate with search results.
        priv.source.removeAll();

        for (results) |result| {
            // Find the Command object in the corpus by matching payload (command_id).
            for (corpus) |cmd| {
                const cmd_id: []const u8 = if (cmd.propGetCommandId()) |id| @as([]const u8, id) else "";
                if (std.mem.eql(u8, cmd_id, result.payload)) {
                    priv.source.append(cmd.as(gobject.Object));
                    break;
                }
            }
        }
    }

    fn close(self: *CommandPalette) void {
        const priv = self.private();
        _ = priv.dialog.close();
    }

    fn dialogClosed(_: *adw.Dialog, self: *CommandPalette) callconv(.c) void {
        self.unref();
    }

    fn searchStopped(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        const priv = self.private();
        if (priv.mode == .rename_input) {
            // ESC in rename mode: go back to commands.
            self.exitRenameMode();
            return;
        }
        // ESC was pressed - close the palette
        self.close();
    }

    fn searchActivated(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        const priv = self.private();
        if (priv.mode == .rename_input) {
            // Enter in rename mode: apply the rename.
            self.applyRename();
            return;
        }
        // If Enter is pressed, activate the selected entry
        self.activated(priv.model.getSelected());
    }

    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *CommandPalette) callconv(.c) void {
        self.activated(pos);
    }

    //---------------------------------------------------------------

    /// Show or hide the command palette dialog. If the dialog is shown it will
    /// be modal over the given window.
    pub fn toggle(self: *CommandPalette, window: *Window) void {
        self.toggleWithScope(window, .commands);
    }

    /// Show or hide the command palette dialog with a specific scope.
    pub fn toggleWithScope(self: *CommandPalette, window: *Window, scope: Scope) void {
        const priv = self.private();

        // If the dialog has been shown, close it.
        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            self.close();
            return;
        }

        // Set the scope and initial query.
        priv.scope = scope;
        switch (scope) {
            .commands => {
                priv.search.as(gtk.Editable).setText(">");
                // Position cursor after ">"
                priv.search.as(gtk.Editable).setPosition(-1);
            },
            .switcher => {
                priv.search.as(gtk.Editable).setText("");
            },
        }

        // Show the dialog
        priv.dialog.present(window.as(gtk.Widget));

        // Focus on the search bar when opening the dialog
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    /// Helper function to send a signal containing the action that should be
    /// performed.
    fn activated(self: *CommandPalette, pos: c_uint) void {
        const priv = self.private();

        // Use priv.model and not priv.source here to use the list of *visible* results
        const object_ = priv.model.as(gio.ListModel).getObject(pos);
        defer if (object_) |object| object.unref();

        const cmd = gobject.ext.cast(Command, object_ orelse return) orelse return;

        // Check if this is a rename command — enter rename mode instead of closing.
        if (cmd.propGetCommandId()) |cmd_id| {
            if (std.mem.eql(u8, @as([]const u8, cmd_id), "palette.rename_tab")) {
                self.enterRenameMode(.{ .kind = .tab, .current_name = "" });
                return;
            }
            if (std.mem.eql(u8, @as([]const u8, cmd_id), "palette.rename_workspace")) {
                self.enterRenameMode(.{ .kind = .workspace, .current_name = "" });
                return;
            }
        }

        // Close before running the action in order to avoid being replaced by
        // another dialog (such as the change title dialog). If that occurs then
        // the command palette dialog won't be counted as having closed properly
        // and cannot receive focus when reopened.
        self.close();

        // Handle jump commands differently
        if (cmd.isJump()) {
            const surface = cmd.getJumpSurface() orelse return;
            defer surface.unref();
            surface.present();
            return;
        }

        // Regular command - emit trigger signal
        const action = cmd.getAction() orelse return;

        // Signal that an action has been selected. Signals are synchronous
        // so we shouldn't need to worry about cloning the action.
        signals.trigger.impl.emit(
            self,
            null,
            .{&action},
            null,
        );
    }

    /// Enter rename mode with the given target.
    pub fn enterRenameMode(self: *CommandPalette, target: RenameTarget) void {
        const priv = self.private();
        priv.mode = .rename_input;
        priv.rename_target = target;

        // Clear the list and repurpose the search entry for rename input.
        priv.source.removeAll();

        // Set the search entry text to the current name.
        priv.search.as(gtk.Editable).setText(target.current_name);
        priv.search.as(gtk.Editable).setPosition(-1);

        // Update placeholder based on rename kind.
        switch (target.kind) {
            .tab => priv.search.setPlaceholderText("Rename tab…"),
            .workspace => priv.search.setPlaceholderText("Rename workspace…"),
        }

        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    /// Exit rename mode back to command list.
    fn exitRenameMode(self: *CommandPalette) void {
        const priv = self.private();
        priv.mode = .commands;
        priv.rename_target = null;

        // Restore the search entry to command palette mode.
        priv.search.setPlaceholderText("Execute a command…");
        priv.search.as(gtk.Editable).setText(">");
        priv.search.as(gtk.Editable).setPosition(-1);

        // Re-run search to repopulate results.
        self.refreshSearchResults();
    }

    /// Apply the rename and close the palette.
    fn applyRename(self: *CommandPalette) void {
        const priv = self.private();
        const target = priv.rename_target orelse return;
        _ = target;

        // Get the new name from the search entry.
        const text = priv.search.as(gtk.Editable).getText();
        const new_name: []const u8 = std.mem.sliceTo(text, 0);
        _ = new_name;

        // TODO: Apply the rename via workspace manager.
        // For now, just close the palette. The actual rename application
        // requires wiring to the workspace manager which will be done
        // when the debug API bridge is implemented.

        priv.mode = .commands;
        priv.rename_target = null;
        self.close();
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(Command);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "command-palette",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("view", .{});
            class.bindTemplateChildPrivate("model", .{});
            class.bindTemplateChildPrivate("source", .{});

            // Template Callbacks
            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("search_stopped", &searchStopped);
            class.bindTemplateCallback("search_activated", &searchActivated);
            class.bindTemplateCallback("row_activated", &rowActivated);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            // Signals
            signals.trigger.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// Object that wraps around a command.
///
/// As GTK list models only accept objects that are within the GObject hierarchy,
/// we have to construct a wrapper to be easily consumed by the list model.
const Command = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCommand",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
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

        pub const action_key = struct {
            pub const name = "action-key";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetActionKey,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const action = struct {
            pub const name = "action";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetAction,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetTitle,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const description = struct {
            pub const name = "description";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetDescription,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const command_id = struct {
            pub const name = "command-id";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetCommandId,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
    };

    pub const Private = struct {
        config: ?*Config = null,
        arena: ArenaAllocator,
        data: CommandData,
        command_id: ?[:0]const u8 = null,

        pub var offset: c_int = 0;

        pub const CommandData = union(enum) {
            regular: RegularData,
            jump: JumpData,
        };

        pub const RegularData = struct {
            command: input.Command,
            action: ?[:0]const u8 = null,
            action_key: ?[:0]const u8 = null,
        };

        pub const JumpData = struct {
            surface: WeakRef(Surface) = .empty,
            title: ?[:0]const u8 = null,
            description: ?[:0]const u8 = null,
            sort_key: usize,
        };
    };

    pub fn new(config: *Config, command: input.Command) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{
            .config = config,
        });
        errdefer self.unref();

        const priv = self.private();
        const alloc = priv.arena.allocator();
        const cloned = try command.clone(alloc);

        priv.data = .{
            .regular = .{
                .command = cloned,
            },
        };

        // Generate command_id from the action (e.g., "palette.new_tab").
        priv.command_id = std.fmt.allocPrintSentinel(
            alloc,
            "palette.{f}",
            .{command.action},
            0,
        ) catch null;

        return self;
    }

    /// Create a new jump command that focuses a specific surface.
    pub fn newJump(config: *Config, surface: *Surface) *Self {
        const self = gobject.ext.newInstance(Self, .{
            .config = config,
        });

        const priv = self.private();
        const sort_key = @intFromPtr(surface);
        priv.data = .{
            .jump = .{
                // TODO: Replace with surface id whenever Ghostty adds one
                .sort_key = sort_key,
            },
        };
        priv.data.jump.surface.set(surface);

        // Generate command_id for jump commands.
        priv.command_id = std.fmt.allocPrintSentinel(
            priv.arena.allocator(),
            "switcher.surface.{x}",
            .{sort_key},
            0,
        ) catch null;

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        // NOTE: we do not watch for changes to the config here as the command
        // palette will destroy and recreate this object if/when the config
        // changes.

        const priv = self.private();
        priv.arena = .init(Application.default().allocator());
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.config) |config| {
            config.unref();
            priv.config = null;
        }

        switch (priv.data) {
            .regular => {},
            .jump => |*j| {
                j.surface.set(null);
            },
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.arena.deinit();

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------

    fn propGetActionKey(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        const regular = switch (priv.data) {
            .regular => |*r| r,
            .jump => return null,
        };

        if (regular.action_key) |action_key| return action_key;

        regular.action_key = std.fmt.allocPrintSentinel(
            priv.arena.allocator(),
            "{f}",
            .{regular.command.action},
            0,
        ) catch null;

        return regular.action_key;
    }

    fn propGetAction(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        const regular = switch (priv.data) {
            .regular => |*r| r,
            .jump => return null,
        };

        if (regular.action) |action| return action;

        const cfg = if (priv.config) |config| config.get() else return null;
        const keybinds = cfg.keybind.set;

        const alloc = priv.arena.allocator();

        regular.action = action: {
            var buf: [64]u8 = undefined;
            const trigger = keybinds.getTrigger(regular.command.action) orelse break :action null;
            const accel = (key.accelFromTrigger(&buf, trigger) catch break :action null) orelse break :action null;
            break :action alloc.dupeZ(u8, accel) catch return null;
        };

        return regular.action;
    }

    fn propGetTitle(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        switch (priv.data) {
            .regular => |*r| return r.command.title,
            .jump => |*j| {
                if (j.title) |title| return title;

                const surface = j.surface.get() orelse return null;
                defer surface.unref();

                const alloc = priv.arena.allocator();
                const effective_title = surface.getEffectiveTitle() orelse "Untitled";

                j.title = std.fmt.allocPrintSentinel(
                    alloc,
                    "Focus: {s}",
                    .{effective_title},
                    0,
                ) catch null;

                return j.title;
            },
        }
    }

    fn propGetDescription(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        switch (priv.data) {
            .regular => |*r| return r.command.description,
            .jump => |*j| {
                if (j.description) |desc| return desc;

                const surface = j.surface.get() orelse return null;
                defer surface.unref();

                const alloc = priv.arena.allocator();
                const title = surface.getEffectiveTitle() orelse "Untitled";
                const pwd = surface.getPwd();

                if (pwd) |p| {
                    if (std.mem.indexOf(u8, title, p) == null) {
                        j.description = alloc.dupeZ(u8, p) catch null;
                    }
                }

                return j.description;
            },
        }
    }

    fn propGetCommandId(self: *Self) ?[:0]const u8 {
        return self.private().command_id;
    }

    //---------------------------------------------------------------

    /// Return a copy of the action. Callers must ensure that they do not use
    /// the action beyond the lifetime of this object because it has internally
    /// allocated data that will be freed when this object is.
    pub fn getAction(self: *Self) ?input.Binding.Action {
        const priv = self.private();
        return switch (priv.data) {
            .regular => |*r| r.command.action,
            .jump => null,
        };
    }

    /// Check if this is a jump command.
    pub fn isJump(self: *Self) bool {
        const priv = self.private();
        return priv.data == .jump;
    }

    /// Get the jump surface. Returns a strong reference that the caller
    /// must unref when done, or null if the surface has been destroyed.
    pub fn getJumpSurface(self: *Self) ?*Surface {
        const priv = self.private();
        return switch (priv.data) {
            .regular => null,
            .jump => |*j| j.surface.get(),
        };
    }

    //---------------------------------------------------------------

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
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
                properties.action_key.impl,
                properties.action.impl,
                properties.title.impl,
                properties.description.impl,
                properties.command_id.impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
