//! Browser panel GTK widget — mirrors Mac's BrowserPanelView.swift.
//!
//! Contains an address bar (back/forward/reload, URL entry, spinner)
//! and a WebKitGTK WebView. State changes on the WebView (title, URI,
//! loading) are synced to GObject properties so the window can observe
//! them via `notify::` signals.

const std = @import("std");
const gobject = @import("gobject");
const gdk = @import("gdk");
const gtk = @import("gtk");

const posix = std.posix;

const cmux = @import("../main.zig");
const omnibar = @import("../omnibar.zig");
const webkit = @import("webkit.zig");
const browser_import_wizard = @import("browser_import_wizard.zig");

const log = std.log.scoped(.browser_panel_view);

// ===========================================================================
// Shared browser history store — seeded via debug.seed_browser_history
// ===========================================================================

/// Module-level shared browser history that can be seeded via V2 socket
/// command and read by any BrowserPanelView during suggestion building.
pub const BrowserHistoryStore = struct {
    const max_entries = 64;

    entries: [max_entries]Entry = undefined,
    count: usize = 0,

    pub const Entry = struct {
        url_buf: [512]u8 = undefined,
        url_len: usize = 0,
        title_buf: [256]u8 = undefined,
        title_len: usize = 0,
        visit_count: u32 = 1,
        typed_count: u32 = 0,

        pub fn url(self: *const Entry) []const u8 {
            return self.url_buf[0..self.url_len];
        }

        pub fn title(self: *const Entry) ?[]const u8 {
            if (self.title_len == 0) return null;
            return self.title_buf[0..self.title_len];
        }
    };

    pub fn addEntry(self: *BrowserHistoryStore, url: []const u8, title_val: ?[]const u8, visit_count: u32, typed_count: u32) void {
        if (self.count >= max_entries) return;
        var entry = &self.entries[self.count];
        entry.* = .{};
        const url_copy_len = @min(url.len, entry.url_buf.len);
        @memcpy(entry.url_buf[0..url_copy_len], url[0..url_copy_len]);
        entry.url_len = url_copy_len;
        if (title_val) |t| {
            const t_copy_len = @min(t.len, entry.title_buf.len);
            @memcpy(entry.title_buf[0..t_copy_len], t[0..t_copy_len]);
            entry.title_len = t_copy_len;
        }
        entry.visit_count = visit_count;
        entry.typed_count = typed_count;
        self.count += 1;
    }

    pub fn clear(self: *BrowserHistoryStore) void {
        self.count = 0;
    }

    pub fn getEntries(self: *const BrowserHistoryStore) []const Entry {
        return self.entries[0..self.count];
    }
};

/// Global shared history store instance.
pub var shared_history_store: BrowserHistoryStore = .{};

pub const BrowserPanelView = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "CmuxBrowserPanelView",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    /// Callback for model sync — mirrors Mac's installBrowserPanelSubscription.
    /// Called when WebView URI, title, or loading state changes.
    pub const StateChangeCallback = *const fn (
        ctx: ?*anyopaque,
        panel_id: cmux.Uuid,
        workspace_id: cmux.Uuid,
        kind: StateChangeKind,
        value: ?[*:0]const u8,
    ) void;

    pub const StateChangeKind = enum { uri, title, loading_started, loading_finished };

    const Private = struct {
        // Panel identity
        panel_id: cmux.Uuid = cmux.Uuid.nil,
        workspace_id: cmux.Uuid = cmux.Uuid.nil,

        // WebKitGTK web view (raw pointer — not in zig-gobject)
        webview: ?*webkit.WebView = null,

        // Toolbar widgets
        back_btn: ?*gtk.Button = null,
        forward_btn: ?*gtk.Button = null,
        reload_btn: ?*gtk.Button = null,
        url_entry: ?*gtk.Entry = null,
        spinner: ?*gtk.Spinner = null,

        // Omnibar pill container (wraps the entry for accessible naming/alignment)
        omnibar_pill: ?*gtk.Box = null,

        // Cached state (avoids round-tripping through WebView)
        is_loading: bool = false,

        // Model sync callback (set by CmuxWindow)
        on_state_change: ?StateChangeCallback = null,
        on_state_change_ctx: ?*anyopaque = null,

        // Omnibar state machine
        omnibar_state: omnibar.OmnibarState = .{},
        is_programmatic_mutation: bool = false,
        suppress_next_focus_lost_revert: bool = false,

        // Inline autocomplete state
        inline_completion: ?omnibar.OmnibarInlineCompletion = null,

        // Persistent suggestions buffer (avoids dangling slice in OmnibarState)
        suggestions_store: [max_suggestions]omnibar.OmnibarSuggestion = undefined,
        suggestions_count: usize = 0,

        // Suggestions popup
        suggestions_popover: ?*gtk.Popover = null,
        suggestions_list: ?*gtk.Box = null,

        // Row name buffers (for setting accessible names like "BrowserOmnibarSuggestions.Row.0")
        row_name_bufs: [max_suggestions][48]u8 = undefined,

        // Inline completion display text buffer (must outlive the OmnibarInlineCompletion struct)
        inline_display_buf: [4096]u8 = undefined,
        inline_typed_buf: [4096]u8 = undefined,
        inline_accepted_buf: [4096]u8 = undefined,

        // Import hint strip (shown on blank browser tabs).
        import_hint_box: ?*gtk.Box = null,

        pub var offset: c_int = 0;
    };

    const max_suggestions = 8;

    const C = @import("../../apprt/gtk/class.zig").Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    // -----------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------

    /// Create a new BrowserPanelView with the given identity and optional initial URL.
    pub fn new(
        panel_id: cmux.Uuid,
        workspace_id: cmux.Uuid,
        initial_url: ?[*:0]const u8,
    ) *Self {
        const self: *Self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.panel_id = panel_id;
        priv.workspace_id = workspace_id;

        if (initial_url) |url| {
            if (priv.webview) |wv| {
                wv.loadUri(url);
            }
        }

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();

        // Set orientation via the Orientable interface.
        self.as(gtk.Orientable).setOrientation(.vertical);

        // --- Address bar ---
        const toolbar = gtk.Box.new(.horizontal, 4);
        toolbar.as(gtk.Widget).setMarginStart(4);
        toolbar.as(gtk.Widget).setMarginEnd(4);
        toolbar.as(gtk.Widget).setMarginTop(4);
        toolbar.as(gtk.Widget).setMarginBottom(4);

        // Back button
        const back_btn = gtk.Button.newFromIconName("go-previous-symbolic");
        back_btn.as(gtk.Widget).setTooltipText("Back");
        back_btn.as(gtk.Widget).setSensitive(0); // disabled initially
        _ = gtk.Button.signals.clicked.connect(back_btn, *Self, onBackClicked, self, .{});
        toolbar.append(back_btn.as(gtk.Widget));
        priv.back_btn = back_btn;

        // Forward button
        const forward_btn = gtk.Button.newFromIconName("go-next-symbolic");
        forward_btn.as(gtk.Widget).setTooltipText("Forward");
        forward_btn.as(gtk.Widget).setSensitive(0);
        _ = gtk.Button.signals.clicked.connect(forward_btn, *Self, onForwardClicked, self, .{});
        toolbar.append(forward_btn.as(gtk.Widget));
        priv.forward_btn = forward_btn;

        // Reload / stop button
        const reload_btn = gtk.Button.newFromIconName("view-refresh-symbolic");
        reload_btn.as(gtk.Widget).setTooltipText("Reload");
        _ = gtk.Button.signals.clicked.connect(reload_btn, *Self, onReloadClicked, self, .{});
        toolbar.append(reload_btn.as(gtk.Widget));
        priv.reload_btn = reload_btn;

        // --- Omnibar pill (wraps URL entry) ---
        const omnibar_pill = gtk.Box.new(.horizontal, 0);
        omnibar_pill.as(gtk.Widget).setHexpand(1);
        omnibar_pill.as(gtk.Widget).setName("BrowserOmnibarPill");

        // URL entry (inside the pill)
        const url_entry = gtk.Entry.new();
        url_entry.setPlaceholderText("Enter URL…");
        url_entry.as(gtk.Widget).setHexpand(1);
        url_entry.as(gtk.Widget).setName("BrowserOmnibarTextField");
        _ = gtk.Entry.signals.activate.connect(url_entry, *Self, onUrlEntryActivate, self, .{});

        // Omnibar: text change → state machine
        _ = gobject.Object.signals.notify.connect(
            url_entry.as(gobject.Object),
            *Self,
            onUrlEntryTextChanged,
            self,
            .{ .detail = "text" },
        );

        // Omnibar: focus tracking
        _ = gobject.Object.signals.notify.connect(
            url_entry.as(gobject.Object),
            *Self,
            onUrlEntryFocusChanged,
            self,
            .{ .detail = "has-focus" },
        );

        // Key event controller on the entry — handles Ctrl+L/N/P, Escape, Backspace, Ctrl+A
        const key_controller = gtk.EventControllerKey.new();
        key_controller.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            key_controller,
            *Self,
            onKeyPressed,
            self,
            .{},
        );
        url_entry.as(gtk.Widget).addController(key_controller.as(gtk.EventController));

        omnibar_pill.append(url_entry.as(gtk.Widget));

        // --- Suggestions popup ---
        // Use a vertical Box for suggestion rows (simpler accessible tree than ListBox).
        const suggestions_box = gtk.Box.new(.vertical, 0);
        suggestions_box.as(gtk.Widget).setName("BrowserOmnibarSuggestions");

        const popover = gtk.Popover.new();
        popover.setChild(suggestions_box.as(gtk.Widget));
        popover.as(gtk.Widget).setParent(omnibar_pill.as(gtk.Widget));
        popover.setAutohide(0); // Don't auto-hide; we control visibility
        popover.setHasArrow(0);
        popover.as(gtk.Widget).setHalign(.start);

        priv.suggestions_popover = popover;
        priv.suggestions_list = suggestions_box;
        priv.omnibar_pill = omnibar_pill;

        toolbar.append(omnibar_pill.as(gtk.Widget));
        priv.url_entry = url_entry;

        // Key event controller on the whole panel for Ctrl+L
        // (needs to capture even when the webview has focus)
        const panel_key_controller = gtk.EventControllerKey.new();
        panel_key_controller.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            panel_key_controller,
            *Self,
            onPanelKeyPressed,
            self,
            .{},
        );
        self.as(gtk.Widget).addController(panel_key_controller.as(gtk.EventController));

        // Loading spinner
        const spinner = gtk.Spinner.new();
        spinner.as(gtk.Widget).setVisible(@intFromBool(false));
        toolbar.append(spinner.as(gtk.Widget));
        priv.spinner = spinner;

        self.as(gtk.Box).append(toolbar.as(gtk.Widget));

        // --- Import hint strip (shown on blank browser tabs when env vars are set) ---
        const show_hint = shouldShowImportHint();
        if (show_hint) {
            const hint_box = gtk.Box.new(.horizontal, 8);
            hint_box.as(gtk.Widget).setMarginStart(12);
            hint_box.as(gtk.Widget).setMarginEnd(12);
            hint_box.as(gtk.Widget).setMarginTop(8);
            hint_box.as(gtk.Widget).setMarginBottom(8);
            hint_box.as(gtk.Widget).setHalign(.center);

            const hint_label = gtk.Label.new("Import browser data to get started");
            hint_label.as(gtk.Widget).addCssClass("dim-label");
            hint_box.append(hint_label.as(gtk.Widget));

            const import_btn = gtk.Button.newWithLabel("Import\xe2\x80\xa6");
            import_btn.as(gtk.Widget).setName("BrowserImportHintImportButton");
            import_btn.as(gtk.Widget).addCssClass("suggested-action");
            _ = gtk.Button.signals.clicked.connect(import_btn, *Self, onImportHintImportClicked, self, .{});
            hint_box.append(import_btn.as(gtk.Widget));

            const settings_btn = gtk.Button.newWithLabel("Browser Settings");
            settings_btn.as(gtk.Widget).setName("BrowserImportHintSettingsButton");
            _ = gtk.Button.signals.clicked.connect(settings_btn, *Self, onImportHintSettingsClicked, self, .{});
            hint_box.append(settings_btn.as(gtk.Widget));

            const dismiss_btn = gtk.Button.newWithLabel("Hide Hint");
            dismiss_btn.as(gtk.Widget).setName("BrowserImportHintDismissButton");
            dismiss_btn.as(gtk.Widget).addCssClass("flat");
            _ = gtk.Button.signals.clicked.connect(dismiss_btn, *Self, onImportHintDismissClicked, self, .{});
            hint_box.append(dismiss_btn.as(gtk.Widget));

            self.as(gtk.Box).append(hint_box.as(gtk.Widget));
            priv.import_hint_box = hint_box;
        }

        // --- WebView ---
        const webview_widget = webkit.WebView.new();
        webview_widget.setVexpand(1);
        webview_widget.setHexpand(1);
        self.as(gtk.Box).append(webview_widget);

        const webview = webkit.fromWidget(webview_widget);
        priv.webview = webview;

        // Connect WebView signals for state sync
        webkit.connectNotify(@ptrCast(webview), "notify::title", &onWebViewNotifyTitle, @ptrCast(self));
        webkit.connectNotify(@ptrCast(webview), "notify::uri", &onWebViewNotifyUri, @ptrCast(self));
        webkit.connectNotify(@ptrCast(webview), "notify::is-loading", &onWebViewNotifyLoading, @ptrCast(self));
        webkit.connectNotify(@ptrCast(webview), "notify::favicon", &onWebViewNotifyFavicon, @ptrCast(self));
    }

    // -----------------------------------------------------------------
    // Public API — matches Mac's BrowserPanel methods
    // -----------------------------------------------------------------

    /// Navigate to a URL with smart scheme detection.
    /// Mirrors Mac's BrowserPanel.resolveBrowserNavigableURL():
    /// - Has scheme (http://, https://, file://) → use as-is
    /// - Starts with localhost/127.0.0.1/[::1] → prepend http://
    /// - Contains "." or ":" or "/" → prepend https://
    /// - Otherwise (looks like a search query) → prepend https://
    pub fn navigate(self: *Self, url: [*:0]const u8) void {
        const priv = self.private();
        const wv = priv.webview orelse return;

        const url_slice = std.mem.span(url);
        if (url_slice.len == 0) return;

        // Already has a scheme → load as-is.
        if (std.mem.indexOf(u8, url_slice, "://") != null) {
            wv.loadUri(url);
            return;
        }

        // Detect localhost / loopback → http:// (not https://).
        const is_localhost = std.mem.startsWith(u8, url_slice, "localhost") or
            std.mem.startsWith(u8, url_slice, "127.0.0.1") or
            std.mem.startsWith(u8, url_slice, "[::1]");

        const prefix: []const u8 = if (is_localhost) "http://" else "https://";

        // Build the full URL. Use a stack buffer up to 8K, which handles
        // virtually all real URLs without allocation.
        var buf: [8192:0]u8 = undefined;
        const total = prefix.len + url_slice.len;
        if (total < buf.len) {
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len..total], url_slice);
            buf[total] = 0;
            wv.loadUri(@ptrCast(&buf));
        } else {
            log.warn("URL too long ({d} bytes), truncated", .{total});
        }
    }

    pub fn goBack(self: *Self) void {
        const priv = self.private();
        if (priv.webview) |wv| wv.goBack();
    }

    pub fn goForward(self: *Self) void {
        const priv = self.private();
        if (priv.webview) |wv| wv.goForward();
    }

    pub fn reload(self: *Self) void {
        const priv = self.private();
        if (priv.webview) |wv| {
            if (priv.is_loading) {
                wv.stopLoading();
            } else {
                wv.reload();
            }
        }
    }

    pub fn getUri(self: *Self) ?[*:0]const u8 {
        const priv = self.private();
        const wv = priv.webview orelse return null;
        return wv.getUri();
    }

    pub fn getTitle(self: *Self) ?[*:0]const u8 {
        const priv = self.private();
        const wv = priv.webview orelse return null;
        return wv.getTitle();
    }

    pub fn getWebView(self: *Self) ?*webkit.WebView {
        return self.private().webview;
    }

    /// Result of synchronous JavaScript evaluation.
    pub const EvalResult = struct {
        /// JSON string of the result value, or null on error.
        /// Owned by the caller — free with webkit.gFree().
        json_value: ?[*:0]u8 = null,
        /// Error message, or null on success.
        error_message: ?[]const u8 = null,
        /// Whether the evaluation timed out.
        timed_out: bool = false,
    };

    /// Synchronously evaluate JavaScript in the WebView.
    /// Blocks the current (main) thread by pumping the GLib main loop
    /// until the WebKit async callback fires. Mirrors Mac's
    /// v2RunBrowserJavaScript + v2AwaitCallback(CFRunLoop) pattern.
    ///
    /// MUST be called on the GTK main thread.
    pub fn evalJsSync(self: *Self, script: [*:0]const u8, timeout_ms: u32) EvalResult {
        const priv = self.private();
        const wv = priv.webview orelse return .{ .error_message = "No WebView" };

        // Build the wrapped script inline (keeps buffer on THIS stack frame).
        // Matches Mac's v2RunBrowserJavaScript async wrapper.
        const script_slice = std.mem.span(script);
        const prefix =
            \\(async () => {
            \\  const __cmuxDoc = document;
            \\  const __cmuxMaybeAwait = async (__r) => {
            \\    if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            \\      return await __r;
            \\    }
            \\    return __r;
            \\  };
            \\  const __cmuxEvalInFrame = async function() {
            \\    const document = __cmuxDoc;
            \\    const __r = eval(
        ;
        const suffix =
            \\);
            \\    const __value = await __cmuxMaybeAwait(__r);
            \\    return __value;
            \\  };
            \\  return await __cmuxEvalInFrame();
            \\})()
        ;

        const total = prefix.len + script_slice.len + suffix.len;
        if (total >= 65536) return .{ .error_message = "Script too long" };

        var wrapped_buf: [65536:0]u8 = undefined;
        @memcpy(wrapped_buf[0..prefix.len], prefix);
        @memcpy(wrapped_buf[prefix.len .. prefix.len + script_slice.len], script_slice);
        @memcpy(wrapped_buf[prefix.len + script_slice.len .. total], suffix);
        wrapped_buf[total] = 0;

        // Create a GMainLoop to pump events while waiting.
        const loop = webkit.GMainLoop.new();
        defer loop.unref();

        var ctx = EvalCallbackCtx{
            .loop = loop,
            .result = .{},
        };

        // Start the async JS evaluation.
        wv.evaluateJavascript(
            @ptrCast(&wrapped_buf),
            -1, // auto-detect length
            null, // no cancellable
            @ptrCast(&evalAsyncCallback),
            @ptrCast(&ctx),
        );

        // Set up a timeout to prevent infinite blocking.
        _ = webkit.timeoutAdd(timeout_ms, &evalTimeoutCallback, @ptrCast(&ctx));

        // Pump the main loop until the callback fires.
        loop.run();

        return ctx.result;
    }

    const EvalCallbackCtx = struct {
        loop: *webkit.GMainLoop,
        result: EvalResult,
        resolved: bool = false,
    };

    fn evalAsyncCallback(
        source_object: ?*anyopaque,
        async_result: ?*anyopaque,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const ctx: *EvalCallbackCtx = @ptrCast(@alignCast(user_data orelse return));
        if (ctx.resolved) return;
        ctx.resolved = true;

        const wv: *webkit.WebView = @ptrCast(@alignCast(source_object orelse {
            ctx.result = .{ .error_message = "No source object" };
            ctx.loop.quit();
            return;
        }));

        const jsc_value = wv.evaluateJavascriptFinish(async_result orelse {
            ctx.result = .{ .error_message = "No async result" };
            ctx.loop.quit();
            return;
        }) orelse {
            ctx.result = .{ .error_message = "JavaScript evaluation failed" };
            ctx.loop.quit();
            return;
        };

        // Convert JSCValue to JSON string.
        if (webkit.jscValueIsUndefined(jsc_value)) {
            // Return the Mac-compatible undefined envelope.
            ctx.result = .{ .json_value = null, .error_message = null };
        } else {
            ctx.result = .{ .json_value = webkit.jscValueToJson(jsc_value, 0) };
        }

        ctx.loop.quit();
    }

    fn evalTimeoutCallback(user_data: ?*anyopaque) callconv(.c) c_int {
        const ctx: *EvalCallbackCtx = @ptrCast(@alignCast(user_data orelse return 0));
        if (!ctx.resolved) {
            ctx.resolved = true;
            ctx.result = .{ .timed_out = true, .error_message = "Timed out waiting for JavaScript result" };
            ctx.loop.quit();
        }
        return 0; // G_SOURCE_REMOVE
    }

    pub fn getPanelId(self: *Self) cmux.Uuid {
        return self.private().panel_id;
    }

    pub fn getWorkspaceId(self: *Self) cmux.Uuid {
        return self.private().workspace_id;
    }

    /// Set a callback for model sync — called when URI/title/loading changes.
    /// Mirrors Mac's installBrowserPanelSubscription pattern.
    pub fn setOnStateChange(self: *Self, cb: ?StateChangeCallback, ctx: ?*anyopaque) void {
        const priv = self.private();
        priv.on_state_change = cb;
        priv.on_state_change_ctx = ctx;
    }

    // -----------------------------------------------------------------
    // Key event handlers
    // -----------------------------------------------------------------

    /// Key handler on the panel (captures Ctrl+L even when webview has focus).
    fn onPanelKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        gtk_mods: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        const has_ctrl = gtk_mods.control_mask;
        const no_other_mods = !gtk_mods.shift_mask and !gtk_mods.alt_mask and !gtk_mods.super_mask;

        // Ctrl+L — focus the omnibar and select all
        if (has_ctrl and no_other_mods and keyval == gdk.KEY_l) {
            self.focusOmnibar();
            return 1;
        }
        return 0;
    }

    /// Key handler on the URL entry (captures Ctrl+N/P, Escape, Backspace, Ctrl+A).
    fn onKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        gtk_mods: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        const has_ctrl = gtk_mods.control_mask;
        const no_other_mods = !gtk_mods.shift_mask and !gtk_mods.alt_mask and !gtk_mods.super_mask;

        // Ctrl+L — re-focus and select all
        if (has_ctrl and no_other_mods and keyval == gdk.KEY_l) {
            self.focusOmnibar();
            return 1;
        }

        // Ctrl+N / Ctrl+P — navigate suggestions
        if (has_ctrl and no_other_mods) {
            const delta: ?i32 = switch (keyval) {
                gdk.KEY_n => 1,
                gdk.KEY_p => @as(i32, -1),
                else => null,
            };
            if (delta) |d| {
                var state = priv.omnibar_state;
                const effects = omnibar.omnibarReduce(&state, .{ .move_selection = .{ .delta = d } });
                priv.omnibar_state = state;
                _ = effects;
                self.updateSuggestionSelectionVisuals();
                return 1;
            }
        }

        // Ctrl+A — select all, preserving inline completion display
        if (has_ctrl and no_other_mods and keyval == gdk.KEY_a) {
            const entry = priv.url_entry orelse return 0;
            // If inline completion is active, select the full display text
            if (priv.inline_completion != null) {
                entry.as(gtk.Editable).selectRegion(0, -1);
                return 1;
            }
            return 0; // Let default Ctrl+A handle it
        }

        // Escape — revert / blur
        if (keyval == gdk.KEY_Escape) {
            // Clear inline completion
            priv.inline_completion = null;

            var state = priv.omnibar_state;
            const effects = omnibar.omnibarReduce(&state, .escape);
            priv.omnibar_state = state;
            self.applyOmnibarEffects(effects);
            return 1;
        }

        // Backspace — handle inline autocomplete deletion
        if (keyval == gdk.KEY_BackSpace and !has_ctrl) {
            if (priv.inline_completion) |ic| {
                // Remove one character from the typed prefix
                if (ic.typed_text.len > 0) {
                    const new_len = ic.typed_text.len - 1;
                    priv.inline_completion = null;

                    // Set the entry text to the shortened prefix
                    const entry = priv.url_entry orelse return 0;
                    priv.is_programmatic_mutation = true;
                    var z_buf: [4096:0]u8 = undefined;
                    @memcpy(z_buf[0..new_len], ic.typed_text[0..new_len]);
                    z_buf[new_len] = 0;
                    entry.as(gtk.Editable).setText(@ptrCast(&z_buf));
                    entry.as(gtk.Editable).setPosition(@intCast(new_len));
                    priv.is_programmatic_mutation = false;

                    // Update state machine
                    var state = priv.omnibar_state;
                    const effects = omnibar.omnibarReduce(&state, .{ .buffer_changed = z_buf[0..new_len] });
                    priv.omnibar_state = state;
                    self.applyOmnibarEffects(effects);
                    return 1;
                }
            }
            return 0;
        }

        return 0;
    }

    /// Focus the omnibar entry and select all text (Ctrl+L behavior).
    pub fn focusOmnibar(self: *Self) void {
        const priv = self.private();
        const entry = priv.url_entry orelse return;
        _ = entry.as(gtk.Widget).grabFocus();

        // The focus-changed handler fires focus_gained which does select_all,
        // but in case it already has focus, manually trigger:
        const current_url = self.currentUrlSlice();
        var state = priv.omnibar_state;
        const effects = omnibar.omnibarReduce(&state, .{
            .focus_gained = .{ .current_url_string = current_url },
        });
        priv.omnibar_state = state;
        priv.inline_completion = null;
        self.applyOmnibarEffects(effects);
    }

    // -----------------------------------------------------------------
    // Import hint handlers
    // -----------------------------------------------------------------

    fn onImportHintImportClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        // Find the parent window for the wizard dialog.
        const widget = self.as(gtk.Widget);
        const root = widget.getRoot() orelse {
            browser_import_wizard.presentImportWizard(null);
            return;
        };
        // Cast the root to a gtk.Window.
        const win: *gtk.Window = @ptrCast(@alignCast(root));
        browser_import_wizard.presentImportWizard(win);
    }

    fn onImportHintSettingsClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self;
        // TODO: Open browser settings page, scrolled to import section.
        // Requires preferences window infrastructure.
        log.info("browser import hint: settings clicked (not yet implemented)", .{});
    }

    fn onImportHintDismissClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.import_hint_box) |hint_box| {
            hint_box.as(gtk.Widget).setVisible(0);
        }
    }

    // -----------------------------------------------------------------
    // Toolbar button handlers
    // -----------------------------------------------------------------

    fn onBackClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.goBack();
    }

    fn onForwardClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.goForward();
    }

    fn onReloadClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.reload();
    }

    fn onUrlEntryActivate(_: *gtk.Entry, self: *Self) callconv(.c) void {
        const priv = self.private();
        const state = priv.omnibar_state;

        if (state.is_focused and state.suggestions.len > 0) {
            self.commitSelectedSuggestion();
        } else {
            const entry = priv.url_entry orelse return;
            const text = entry.as(gtk.Editable).getText();
            self.navigate(text);
            self.hideSuggestions();
            priv.suppress_next_focus_lost_revert = true;
            // Blur back to webview
            if (priv.webview) |wv| {
                const wv_widget: *gtk.Widget = @ptrCast(@alignCast(wv));
                _ = wv_widget.grabFocus();
            }
        }
    }

    fn onUrlEntryTextChanged(
        _: *gobject.Object,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.is_programmatic_mutation) return;
        const entry = priv.url_entry orelse return;
        const text_z = entry.as(gtk.Editable).getText();
        const text = std.mem.span(text_z);

        // Use publishedBufferTextForFieldChange to handle inline completion
        const published = omnibar.publishedBufferTextForFieldChange(
            text,
            if (priv.inline_completion) |*ic| ic else null,
            null, // selection_start not easily available from GtkEntry
            null, // selection_len
            false, // has_marked_text
        );

        // Clear inline completion when user actively types
        priv.inline_completion = null;

        var state = priv.omnibar_state;
        const effects = omnibar.omnibarReduce(&state, .{ .buffer_changed = published });
        priv.omnibar_state = state;
        self.applyOmnibarEffects(effects);
    }

    fn onUrlEntryFocusChanged(
        _: *gobject.Object,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const entry = priv.url_entry orelse return;
        const has_focus = entry.as(gtk.Widget).hasFocus() != 0;

        const current_url = self.currentUrlSlice();
        var state = priv.omnibar_state;

        if (has_focus) {
            const effects = omnibar.omnibarReduce(&state, .{
                .focus_gained = .{ .current_url_string = current_url },
            });
            priv.omnibar_state = state;
            self.applyOmnibarEffects(effects);
        } else {
            if (priv.suppress_next_focus_lost_revert) {
                priv.suppress_next_focus_lost_revert = false;
                const effects = omnibar.omnibarReduce(&state, .{
                    .focus_lost_preserve_buffer = .{ .current_url_string = current_url },
                });
                priv.omnibar_state = state;
                self.applyOmnibarEffects(effects);
            } else {
                const effects = omnibar.omnibarReduce(&state, .{
                    .focus_lost_revert_buffer = .{ .current_url_string = current_url },
                });
                priv.omnibar_state = state;
                self.applyOmnibarEffects(effects);
            }
        }
    }

    // -----------------------------------------------------------------
    // Omnibar helpers
    // -----------------------------------------------------------------

    /// Apply state machine effects to the GTK widgets.
    fn applyOmnibarEffects(self: *Self, effects: omnibar.OmnibarEffects) void {
        const priv = self.private();
        const entry = priv.url_entry orelse return;

        if (effects.should_select_all) {
            // Update entry text to match state buffer, then select all
            priv.is_programmatic_mutation = true;
            const buf = priv.omnibar_state.buffer;
            if (buf.len < 8192) {
                var z_buf: [8192:0]u8 = undefined;
                @memcpy(z_buf[0..buf.len], buf);
                z_buf[buf.len] = 0;
                entry.as(gtk.Editable).setText(@ptrCast(&z_buf));
            }
            // Select all text
            entry.as(gtk.Editable).selectRegion(0, -1);
            priv.is_programmatic_mutation = false;
        }

        if (effects.should_blur_to_web_view) {
            // Return focus to the WebView
            if (priv.webview) |wv| {
                const wv_widget: *gtk.Widget = @ptrCast(@alignCast(wv));
                _ = wv_widget.grabFocus();
            }
        }

        if (effects.should_refresh_suggestions) {
            self.refreshSuggestions();
        }
    }

    /// Get the current URL as a Zig slice (references WebView-owned memory).
    fn currentUrlSlice(self: *Self) []const u8 {
        const priv = self.private();
        if (priv.webview) |wv| {
            if (wv.getUri()) |uri| {
                return std.mem.span(uri);
            }
        }
        return "";
    }

    /// Rebuild suggestions from current state, update inline autocomplete, and show/hide the popup.
    fn refreshSuggestions(self: *Self) void {
        const priv = self.private();
        const state = priv.omnibar_state;

        if (!state.is_focused) {
            priv.inline_completion = null;
            self.updateSuggestionsPopup(&.{});
            return;
        }

        const query = std.mem.trim(u8, state.buffer, " \t\n\r");
        if (query.len == 0) {
            priv.suggestions_count = 0;
            priv.inline_completion = null;
            self.updateSuggestionsPopup(&.{});
            return;
        }

        // Build suggestions into the persistent Private buffer.
        var count: usize = 0;

        // History entries from the shared store
        const history_entries = shared_history_store.getEntries();
        for (history_entries) |*entry| {
            if (count >= max_suggestions - 2) break; // Leave room for search + navigate
            const url_val = entry.url();
            const title_val = entry.title();
            if (omnibar.suggestionMatchesTypedPrefix(query, url_val, title_val)) {
                priv.suggestions_store[count] = omnibar.OmnibarSuggestion.history(url_val, title_val);
                count += 1;
            }
        }

        // Search row
        if (count < max_suggestions) {
            priv.suggestions_store[count] = omnibar.OmnibarSuggestion.search("Google", query);
            count += 1;
        }

        // Navigate row (if it looks like a URL)
        const intent = omnibar.inputIntent(query);
        if (intent != .query_like and count < max_suggestions) {
            priv.suggestions_store[count] = omnibar.OmnibarSuggestion.navigate(query);
            count += 1;
        }

        priv.suggestions_count = count;
        const suggestions = priv.suggestions_store[0..count];

        // Feed to state machine
        var new_state = priv.omnibar_state;
        const effects = omnibar.omnibarReduce(&new_state, .{ .suggestions_updated = suggestions });
        priv.omnibar_state = new_state;
        _ = effects;

        // Inline autocomplete
        self.updateInlineAutocomplete(query, suggestions);

        self.updateSuggestionsPopup(suggestions);
    }

    /// Compute and apply inline autocomplete from the current suggestions.
    fn updateInlineAutocomplete(self: *Self, query: []const u8, suggestions: []const omnibar.OmnibarSuggestion) void {
        const priv = self.private();
        const entry = priv.url_entry orelse return;

        var best_idx: ?usize = null;
        var best_suffix_len: usize = std.math.maxInt(usize);

        for (suggestions, 0..) |*suggestion, idx| {
            if (!omnibar.suggestionSupportsAutocompletion(query, suggestion)) continue;
            const comp = suggestion.completion();
            const display = stripDisplayPrefix(comp, query);
            if (display.len <= query.len) continue;
            const suffix_len = display.len - query.len;
            if (suffix_len < best_suffix_len) {
                best_suffix_len = suffix_len;
                best_idx = idx;
            }
        }

        if (best_idx) |idx| {
            const comp = suggestions[idx].completion();
            const display = stripDisplayPrefix(comp, query);

            const typed_len = @min(query.len, priv.inline_typed_buf.len);
            @memcpy(priv.inline_typed_buf[0..typed_len], query[0..typed_len]);
            const display_len = @min(display.len, priv.inline_display_buf.len);
            @memcpy(priv.inline_display_buf[0..display_len], display[0..display_len]);
            const accepted_len = @min(comp.len, priv.inline_accepted_buf.len);
            @memcpy(priv.inline_accepted_buf[0..accepted_len], comp[0..accepted_len]);

            priv.inline_completion = .{
                .typed_text = priv.inline_typed_buf[0..typed_len],
                .display_text = priv.inline_display_buf[0..display_len],
                .accepted_text = priv.inline_accepted_buf[0..accepted_len],
            };

            // Set entry text to the full display text and select the suffix
            priv.is_programmatic_mutation = true;
            var z_buf: [4096:0]u8 = undefined;
            @memcpy(z_buf[0..display_len], display[0..display_len]);
            z_buf[display_len] = 0;
            entry.as(gtk.Editable).setText(@ptrCast(&z_buf));
            entry.as(gtk.Editable).selectRegion(@intCast(typed_len), @intCast(display_len));
            priv.is_programmatic_mutation = false;
        } else {
            priv.inline_completion = null;
        }
    }

    /// Strip the URL display prefix to match the typed text convention.
    fn stripDisplayPrefix(comp: []const u8, query: []const u8) []const u8 {
        var query_lower_buf: [4096]u8 = undefined;
        const ql = toLowerBuf(query, &query_lower_buf) orelse return comp;

        var comp_lower_buf: [4096]u8 = undefined;
        const cl = toLowerBuf(comp, &comp_lower_buf) orelse return comp;

        const typed_includes_scheme = std.mem.startsWith(u8, ql, "https://") or
            std.mem.startsWith(u8, ql, "http://");
        if (typed_includes_scheme) return comp;

        const typed_includes_www = std.mem.startsWith(u8, ql, "www.");

        var offset: usize = 0;
        if (cl.len >= 8 and std.mem.eql(u8, cl[0..8], "https://")) {
            offset = 8;
        } else if (cl.len >= 7 and std.mem.eql(u8, cl[0..7], "http://")) {
            offset = 7;
        }

        if (!typed_includes_www and comp.len > offset + 4) {
            var www_lower_buf: [4]u8 = undefined;
            if (toLowerBuf(comp[offset .. offset + 4], &www_lower_buf)) |wl| {
                if (std.mem.eql(u8, wl, "www.")) {
                    offset += 4;
                }
            }
        }

        return comp[offset..];
    }

    fn toLowerBuf(input: []const u8, buf: []u8) ?[]const u8 {
        if (input.len > buf.len) return null;
        for (input, 0..) |c, i| {
            buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        return buf[0..input.len];
    }

    fn updateSuggestionsPopup(self: *Self, suggestions: []const omnibar.OmnibarSuggestion) void {
        const priv = self.private();
        const box = priv.suggestions_list orelse return;
        const pop = priv.suggestions_popover orelse return;

        // Clear existing children
        while (box.as(gtk.Widget).getFirstChild()) |child_widget| {
            box.remove(child_widget);
        }

        if (suggestions.len == 0) {
            pop.popdown();
            return;
        }

        const state = priv.omnibar_state;

        for (suggestions, 0..) |*suggestion, idx| {
            const row_widget = self.createSuggestionRow(suggestion, idx, idx == state.selected_suggestion_index);
            box.append(row_widget);
        }

        pop.popup();
    }

    /// Update only the selection visuals without rebuilding the row widgets.
    fn updateSuggestionSelectionVisuals(self: *Self) void {
        const priv = self.private();
        const box = priv.suggestions_list orelse return;
        const state = priv.omnibar_state;

        var idx: usize = 0;
        var child_opt = box.as(gtk.Widget).getFirstChild();
        while (child_opt) |child_widget| {
            if (idx == state.selected_suggestion_index) {
                child_widget.addCssClass("suggested-action");
                child_widget.setTooltipText("selected");
            } else {
                child_widget.removeCssClass("suggested-action");
                child_widget.setTooltipText(null);
            }
            child_opt = child_widget.getNextSibling();
            idx += 1;
        }
    }

    fn createSuggestionRow(self: *Self, suggestion: *const omnibar.OmnibarSuggestion, idx: usize, is_selected: bool) *gtk.Widget {
        const priv = self.private();
        const hbox = gtk.Box.new(.horizontal, 6);
        hbox.as(gtk.Widget).setMarginStart(8);
        hbox.as(gtk.Widget).setMarginEnd(8);
        hbox.as(gtk.Widget).setMarginTop(4);
        hbox.as(gtk.Widget).setMarginBottom(4);

        // Set accessible name: "BrowserOmnibarSuggestions.Row.N"
        if (idx < max_suggestions) {
            const name_result = std.fmt.bufPrint(&priv.row_name_bufs[idx], "BrowserOmnibarSuggestions.Row.{d}", .{idx}) catch null;
            if (name_result) |name| {
                priv.row_name_bufs[idx][name.len] = 0;
                hbox.as(gtk.Widget).setName(@ptrCast(priv.row_name_bufs[idx][0..name.len :0]));
            }
        }

        // Build display text
        var text_buf: [512:0]u8 = undefined;
        var is_switch_to_tab = false;

        const text: [*:0]const u8 = switch (suggestion.kind) {
            .search => |s| blk: {
                const result = std.fmt.bufPrint(&text_buf, "Search {s} for {s}", .{ s.engine_name, s.query }) catch break :blk "Search\xe2\x80\xa6";
                text_buf[result.len] = 0;
                break :blk @ptrCast(text_buf[0..result.len :0]);
            },
            .navigate => |n| blk: {
                const result = std.fmt.bufPrint(&text_buf, "Go to {s}", .{n.url}) catch break :blk "Go to\xe2\x80\xa6";
                text_buf[result.len] = 0;
                break :blk @ptrCast(text_buf[0..result.len :0]);
            },
            .history => |h| blk: {
                const display = if (h.title) |t| (if (t.len > 0) t else h.url) else h.url;
                const result = std.fmt.bufPrint(&text_buf, "{s}", .{display}) catch break :blk "\xe2\x80\xa6";
                text_buf[result.len] = 0;
                break :blk @ptrCast(text_buf[0..result.len :0]);
            },
            .switch_to_tab => |t| blk: {
                is_switch_to_tab = true;
                const display = if (t.title) |title| (if (title.len > 0) title else t.url) else t.url;
                const result = std.fmt.bufPrint(&text_buf, "{s}", .{display}) catch break :blk "\xe2\x80\xa6";
                text_buf[result.len] = 0;
                break :blk @ptrCast(text_buf[0..result.len :0]);
            },
            .remote => |r| blk: {
                const result = std.fmt.bufPrint(&text_buf, "{s}", .{r.query}) catch break :blk "\xe2\x80\xa6";
                text_buf[result.len] = 0;
                break :blk @ptrCast(text_buf[0..result.len :0]);
            },
        };

        const label = gtk.Label.new(text);
        label.setXalign(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).setHexpand(1);
        hbox.append(label.as(gtk.Widget));

        if (is_switch_to_tab) {
            const badge = gtk.Label.new("Switch to tab");
            badge.as(gtk.Widget).addCssClass("dim-label");
            badge.as(gtk.Widget).addCssClass("caption");
            hbox.append(badge.as(gtk.Widget));
        }

        if (is_selected) {
            hbox.as(gtk.Widget).addCssClass("suggested-action");
            hbox.as(gtk.Widget).setTooltipText("selected");
        }

        return hbox.as(gtk.Widget);
    }

    fn commitSelectedSuggestion(self: *Self) void {
        const priv = self.private();
        const state = priv.omnibar_state;
        if (state.suggestions.len == 0) return;
        const idx = state.selected_suggestion_index;
        if (idx >= state.suggestions.len) return;
        const suggestion = &state.suggestions[idx];
        self.commitSuggestion(suggestion);
    }

    fn commitSuggestion(self: *Self, suggestion: *const omnibar.OmnibarSuggestion) void {
        const priv = self.private();
        priv.inline_completion = null;

        // Copy completion into a local buffer before any state changes
        // (suggestion data may reference state that gets invalidated).
        const comp = suggestion.completion();
        var nav_buf: [8192:0]u8 = undefined;
        if (comp.len >= nav_buf.len) return;
        @memcpy(nav_buf[0..comp.len], comp);
        nav_buf[comp.len] = 0;

        // Update state (don't store dangling slice in buffer — the
        // URI notify handler will update it when navigation completes)
        var state = priv.omnibar_state;
        state.is_user_editing = false;
        priv.omnibar_state = state;

        // Navigate
        self.navigate(@ptrCast(&nav_buf));

        self.hideSuggestions();
        priv.suppress_next_focus_lost_revert = true;

        // Blur to webview
        if (priv.webview) |wv| {
            const wv_widget: *gtk.Widget = @ptrCast(@alignCast(wv));
            _ = wv_widget.grabFocus();
        }
    }

    fn hideSuggestions(self: *Self) void {
        const priv = self.private();
        if (priv.suggestions_popover) |pop| {
            pop.popdown();
        }
        // Clear suggestions in state
        var state = priv.omnibar_state;
        _ = omnibar.omnibarReduce(&state, .{ .suggestions_updated = &.{} });
        priv.omnibar_state = state;
    }

    // -----------------------------------------------------------------
    // WebView signal handlers (C callbacks via webkit.connectNotify)
    // -----------------------------------------------------------------

    fn onWebViewNotifyTitle(_: *anyopaque, _: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(user_data orelse return));
        const priv = self.private();
        const wv = priv.webview orelse return;
        // Fire model sync callback with the new title.
        if (priv.on_state_change) |cb| {
            cb(priv.on_state_change_ctx, priv.panel_id, priv.workspace_id, .title, wv.getTitle());
        }
    }

    fn onWebViewNotifyUri(_: *anyopaque, _: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(user_data orelse return));
        const priv = self.private();
        const wv = priv.webview orelse return;

        const uri_z = wv.getUri();

        // Update the address bar text (only if not user-editing)
        if (!priv.omnibar_state.is_user_editing) {
            if (uri_z) |uri| {
                priv.is_programmatic_mutation = true;
                if (priv.url_entry) |entry| {
                    entry.as(gtk.Editable).setText(uri);
                }
                priv.is_programmatic_mutation = false;
            }
        }

        // Update state machine
        const uri_slice = if (uri_z) |u| std.mem.span(u) else "";
        var state = priv.omnibar_state;
        _ = omnibar.omnibarReduce(&state, .{
            .panel_url_changed = .{ .current_url_string = uri_slice },
        });
        priv.omnibar_state = state;

        // Fire model sync callback.
        if (priv.on_state_change) |cb| {
            cb(priv.on_state_change_ctx, priv.panel_id, priv.workspace_id, .uri, uri_z);
        }
    }

    fn onWebViewNotifyLoading(_: *anyopaque, _: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(user_data orelse return));
        const priv = self.private();
        const wv = priv.webview orelse return;
        const loading = wv.isLoading();
        priv.is_loading = loading;

        // Update spinner visibility
        if (priv.spinner) |spinner| {
            spinner.as(gtk.Widget).setVisible(@intFromBool(loading));
            if (loading) {
                spinner.start();
            } else {
                spinner.stop();
            }
        }

        // Toggle reload/stop icon
        if (priv.reload_btn) |btn| {
            btn.setIconName(if (loading) "process-stop-symbolic" else "view-refresh-symbolic");
            btn.as(gtk.Widget).setTooltipText(if (loading) "Stop" else "Reload");
        }

        // Update back/forward sensitivity
        if (priv.back_btn) |btn| {
            btn.as(gtk.Widget).setSensitive(@intFromBool(wv.canGoBack()));
        }
        if (priv.forward_btn) |btn| {
            btn.as(gtk.Widget).setSensitive(@intFromBool(wv.canGoForward()));
        }

        // Fire model sync callback.
        if (priv.on_state_change) |cb| {
            const kind: StateChangeKind = if (loading) .loading_started else .loading_finished;
            cb(priv.on_state_change_ctx, priv.panel_id, priv.workspace_id, kind, null);
        }
    }

    fn onWebViewNotifyFavicon(_: *anyopaque, _: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(user_data orelse return));
        _ = self;
        // Favicon changed — plumbing for future sidebar icon display.
        log.debug("browser favicon changed", .{});
    }

    // -----------------------------------------------------------------
    // GObject class boilerplate
    // -----------------------------------------------------------------

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.suggestions_popover) |pop| {
            pop.as(gtk.Widget).unparent();
            priv.suggestions_popover = null;
        }
        gobject.Object.virtual_methods.dispose.call(
            Class.parent.as(gobject.Object.Class),
            self.as(gobject.Object),
        );
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        pub fn init(class: *Class) callconv(.c) void {
            // Override dispose for popover cleanup
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
    };
};

// ===========================================================================
// Import hint visibility
// ===========================================================================

/// Determine whether the import hint strip should be shown on this blank
/// browser tab. Reads the CMUX_UI_TEST_BROWSER_IMPORT_HINT_* env vars.
/// Mirrors the macOS AppDelegate hint setup (lines 2368-2405).
fn shouldShowImportHint() bool {
    const env = posix.getenv;
    const show_raw = env("CMUX_UI_TEST_BROWSER_IMPORT_HINT_SHOW") orelse return false;
    if (!std.mem.eql(u8, show_raw, "1")) return false;

    const dismissed_raw = env("CMUX_UI_TEST_BROWSER_IMPORT_HINT_DISMISSED") orelse "0";
    if (std.mem.eql(u8, dismissed_raw, "1")) return false;

    return true;
}
