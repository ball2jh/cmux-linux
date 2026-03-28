# Omnibar GTK Wiring Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the fully-ported omnibar state machine (`omnibar.zig`) into the GTK browser panel UI so users get a functional address bar with suggestions popup, keyboard navigation, inline completion, and Ctrl+L focus.

**Architecture:** The omnibar state machine (`omnibar.zig`) is already ported — all reduce logic, suggestion ranking, inline completion, and remote merge. The work is purely GTK widget plumbing: connecting `gtk.Entry` signals to `omnibarReduce`, creating a `GtkPopover` with a `GtkListBox` for suggestions, intercepting keyboard events via `EventControllerKey`, and adding a window-level Ctrl+L action. No new pure-logic files needed.

**Tech Stack:** Zig, GTK4 (via zig-gobject bindings), GDK key constants, GtkPopover, GtkListBox, EventControllerKey

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/cmux/gtk/browser_panel_view.zig` | Modify | Add omnibar state, popover, key controller, all signal wiring |
| `src/cmux/gtk/window.zig` | Modify | Add `focus-address-bar` GAction + Ctrl+L accelerator |

All changes are in 2 existing files. No new files.

---

### Task 1: Add omnibar state and text-change wiring to BrowserPanelView

**Files:**
- Modify: `src/cmux/gtk/browser_panel_view.zig:8` (add import)
- Modify: `src/cmux/gtk/browser_panel_view.zig:42-65` (add fields to Private)
- Modify: `src/cmux/gtk/browser_panel_view.zig:97-164` (wire signals in init)

This task wires the `gtk.Entry` text changes and focus events to the omnibar state machine, and applies effects (select-all, blur to webview). No popup yet — just the state machine driving the entry.

- [ ] **Step 1: Add omnibar import and Private fields**

In `browser_panel_view.zig`, add the omnibar import at line 8:

```zig
const omnibar = @import("../omnibar.zig");
```

Add to the `Private` struct after `on_state_change_ctx`:

```zig
        // Omnibar state machine
        omnibar_state: omnibar.OmnibarState = .{},
        is_programmatic_mutation: bool = false,
        suppress_next_focus_lost_revert: bool = false,

        // Persistent suggestions buffer (avoids dangling slice in OmnibarState)
        suggestions_store: [8]omnibar.OmnibarSuggestion = undefined,
        suggestions_count: usize = 0,
```

- [ ] **Step 2: Connect text-changed signal in init**

After the `activate` signal connection (line 138), add an `Editable` `notify::text` handler:

```zig
        // Omnibar: text change → state machine
        _ = gobject.Object.signals.notify.connect(
            url_entry.as(gobject.Object),
            *Self,
            onUrlEntryTextChanged,
            self,
            .{ .detail = "text" },
        );
```

- [ ] **Step 3: Connect focus signals in init**

After the text-changed connection, add focus-in/focus-out via the `GtkWidget` `notify::has-focus` signal:

```zig
        // Omnibar: focus tracking
        _ = gobject.Object.signals.notify.connect(
            url_entry.as(gobject.Object),
            *Self,
            onUrlEntryFocusChanged,
            self,
            .{ .detail = "has-focus" },
        );
```

- [ ] **Step 4: Implement onUrlEntryTextChanged handler**

Add this handler in the signal handlers section (after `onUrlEntryActivate`):

```zig
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
        var state = priv.omnibar_state;
        const effects = omnibar.omnibarReduce(&state, .{ .buffer_changed = text });
        priv.omnibar_state = state;
        self.applyOmnibarEffects(effects);
    }
```

- [ ] **Step 5: Implement onUrlEntryFocusChanged handler**

```zig
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
```

- [ ] **Step 6: Implement helper methods**

Add `applyOmnibarEffects` and `currentUrlSlice`:

```zig
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
```

- [ ] **Step 7: Add stub refreshSuggestions**

This will be filled in Task 2. For now, a no-op:

```zig
    /// Rebuild suggestions from current state and show/hide the popup.
    fn refreshSuggestions(self: *Self) void {
        _ = self;
        // Will be implemented in Task 2 (suggestions popup).
    }
```

- [ ] **Step 8: Update onUrlEntryActivate to use state machine**

Replace the existing `onUrlEntryActivate` to commit suggestions when available:

```zig
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
```

- [ ] **Step 9: Add commit and hide stubs**

```zig
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
        _ = self;
        // Will be implemented in Task 2.
    }
```

- [ ] **Step 10: Wire WebView URI change to state machine**

In `onWebViewNotifyUri`, after updating the entry text, also fire `panel_url_changed`:

```zig
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
```

- [ ] **Step 11: Compile and verify**

Run: `zig build -Dcmux=true -Dversion-string="0.1.0-dev" 2>&1 | head -30`
Expected: Successful compilation (or only pre-existing warnings)

- [ ] **Step 12: Commit**

```bash
git add src/cmux/gtk/browser_panel_view.zig
git commit -m "feat(omnibar): wire state machine to GTK entry (text change, focus, URI sync)"
```

---

### Task 2: Add suggestions popup (GtkPopover + GtkListBox)

**Files:**
- Modify: `src/cmux/gtk/browser_panel_view.zig:42-65` (add popover fields to Private)
- Modify: `src/cmux/gtk/browser_panel_view.zig` (init, refreshSuggestions, hideSuggestions)

This task creates the suggestions dropdown below the URL entry and populates it from the state machine.

- [ ] **Step 1: Add popover fields to Private**

Add after the omnibar state fields:

```zig
        // Suggestions popup
        suggestions_popover: ?*gtk.Popover = null,
        suggestions_list: ?*gtk.ListBox = null,
```

- [ ] **Step 2: Create the popover in init**

After creating the url_entry and before appending the toolbar, create the suggestions popover:

```zig
        // --- Suggestions popover ---
        const suggestions_list = gtk.ListBox.new();
        suggestions_list.as(gtk.Widget).setName("BrowserOmnibarSuggestions");
        suggestions_list.setSelectionMode(.none); // We handle selection ourselves
        suggestions_list.as(gtk.Widget).addCssClass("boxed-list");
        _ = gtk.ListBox.signals.row_activated.connect(
            suggestions_list,
            *Self,
            onSuggestionRowActivated,
            self,
            .{},
        );

        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setPolicy(.never, .automatic);
        scrolled.setMaxContentHeight(400);
        scrolled.setPropagateNaturalHeight(1);
        scrolled.setChild(suggestions_list.as(gtk.Widget));

        const popover = gtk.Popover.new();
        popover.setChild(scrolled.as(gtk.Widget));
        popover.setParent(url_entry.as(gtk.Widget));
        popover.setAutohide(0); // Don't auto-hide; we control visibility
        popover.setHasArrow(0);
        popover.as(gtk.Widget).setHalign(.start);
        popover.as(gtk.Widget).setName("BrowserOmnibarPopover");

        priv.suggestions_popover = popover;
        priv.suggestions_list = suggestions_list;
```

- [ ] **Step 3: Implement refreshSuggestions**

Replace the stub with the real implementation. Since we don't have browser history persistence yet, we build suggestions from just the current query (search + navigate rows):

```zig
    fn refreshSuggestions(self: *Self) void {
        const priv = self.private();
        const state = priv.omnibar_state;

        if (!state.is_focused) {
            self.updateSuggestionsPopup(&.{});
            return;
        }

        const query = std.mem.trim(u8, state.buffer, " \t\n\r");
        if (query.len == 0) {
            priv.suggestions_count = 0;
            self.updateSuggestionsPopup(&.{});
            return;
        }

        // Build suggestions into the persistent Private buffer (avoids
        // dangling slices — OmnibarState.suggestions points here).
        var count: usize = 0;

        // Search row
        priv.suggestions_store[count] = omnibar.OmnibarSuggestion.search("Google", query);
        count += 1;

        // Navigate row (if it looks like a URL)
        const intent = omnibar.inputIntent(query);
        if (intent != .query_like and count < priv.suggestions_store.len) {
            priv.suggestions_store[count] = omnibar.OmnibarSuggestion.navigate(query);
            count += 1;
        }

        priv.suggestions_count = count;
        const suggestions = priv.suggestions_store[0..count];

        // Feed to state machine
        var new_state = priv.omnibar_state;
        const effects = omnibar.omnibarReduce(&new_state, .{ .suggestions_updated = suggestions });
        priv.omnibar_state = new_state;
        _ = effects; // select_all/blur effects don't apply for suggestion updates

        self.updateSuggestionsPopup(suggestions);
    }
```

- [ ] **Step 4: Implement updateSuggestionsPopup**

This rebuilds the GtkListBox rows and shows/hides the popover:

```zig
    fn updateSuggestionsPopup(self: *Self, suggestions: []const omnibar.OmnibarSuggestion) void {
        const priv = self.private();
        const list = priv.suggestions_list orelse return;
        const popover = priv.suggestions_popover orelse return;

        // Clear existing rows
        while (list.getRowAtIndex(0)) |row| {
            list.remove(row.as(gtk.Widget));
        }

        if (suggestions.len == 0) {
            popover.popdown();
            return;
        }

        const state = priv.omnibar_state;

        for (suggestions, 0..) |*suggestion, idx| {
            const row = self.createSuggestionRow(suggestion, idx == state.selected_suggestion_index);
            list.append(row.as(gtk.Widget));
        }

        popover.popup();
    }

    fn createSuggestionRow(self: *Self, suggestion: *const omnibar.OmnibarSuggestion, is_selected: bool) *gtk.Widget {
        _ = self;
        const hbox = gtk.Box.new(.horizontal, 6);
        hbox.as(gtk.Widget).setMarginStart(8);
        hbox.as(gtk.Widget).setMarginEnd(8);
        hbox.as(gtk.Widget).setMarginTop(4);
        hbox.as(gtk.Widget).setMarginBottom(4);

        // Build display text into a function-scoped buffer (must outlive
        // gtk.Label.new which copies the string).
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
        label.setEllipsize(3); // PANGO_ELLIPSIZE_END
        label.as(gtk.Widget).setHexpand(1);
        hbox.append(label.as(gtk.Widget));

        // Badge for switch-to-tab
        if (is_switch_to_tab) {
            const badge = gtk.Label.new("Switch to tab");
            badge.as(gtk.Widget).addCssClass("dim-label");
            badge.as(gtk.Widget).addCssClass("caption");
            hbox.append(badge.as(gtk.Widget));
        }

        // Highlight selected row
        if (is_selected) {
            hbox.as(gtk.Widget).addCssClass("suggested-action");
        }

        return hbox.as(gtk.Widget);
    }
```

- [ ] **Step 5: Implement hideSuggestions**

Replace the stub:

```zig
    fn hideSuggestions(self: *Self) void {
        const priv = self.private();
        if (priv.suggestions_popover) |popover| {
            popover.popdown();
        }
        // Clear suggestions in state
        var state = priv.omnibar_state;
        _ = omnibar.omnibarReduce(&state, .{ .suggestions_updated = &.{} });
        priv.omnibar_state = state;
    }
```

- [ ] **Step 6: Implement onSuggestionRowActivated**

```zig
    fn onSuggestionRowActivated(
        _: *gtk.ListBox,
        row: *gtk.ListBoxRow,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const state = priv.omnibar_state;
        const idx: usize = @intCast(row.getIndex());
        if (idx < state.suggestions.len) {
            self.commitSuggestion(&state.suggestions[idx]);
        }
    }
```

- [ ] **Step 7: Clean up popover in dispose**

In the dispose section, before `gtk.Widget.disposeTemplate`, unparent the popover:

```zig
        // Clean up suggestions popover
        if (priv.suggestions_popover) |popover| {
            popover.unparent();
            priv.suggestions_popover = null;
        }
```

Note: `browser_panel_view.zig` currently has no dispose. We need to add the GObject dispose virtual method override to the Class init. Add to the Class:

```zig
    pub const Class = extern struct {
        parent_class: Parent.Class,

        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        pub fn init(class: *Class) callconv(.c) void {
            // Override dispose for cleanup
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
    };
```

And add the dispose function:

```zig
    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.suggestions_popover) |popover| {
            popover.unparent();
            priv.suggestions_popover = null;
        }
        gobject.Object.virtual_methods.dispose.call(
            Class.parent.as(gobject.Object.Class),
            self.as(gobject.Object),
        );
    }
```

- [ ] **Step 8: Compile and verify**

Run: `zig build -Dcmux=true -Dversion-string="0.1.0-dev" 2>&1 | head -30`
Expected: Successful compilation

- [ ] **Step 9: Commit**

```bash
git add src/cmux/gtk/browser_panel_view.zig
git commit -m "feat(omnibar): add suggestions popover with GtkListBox"
```

---

### Task 3: Add keyboard event handling (EventControllerKey)

**Files:**
- Modify: `src/cmux/gtk/browser_panel_view.zig` (init + new handler)

This task adds keyboard interception on the URL entry for Up/Down, Ctrl+N/P, Escape, and Tab.

- [ ] **Step 1: Add EventControllerKey in init**

After the `notify::has-focus` connection, add the key controller:

```zig
        // Omnibar: keyboard interception
        const key_controller = gtk.EventControllerKey.new();
        key_controller.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            key_controller,
            *Self,
            onOmnibarKeyPressed,
            self,
            .{},
        );
        url_entry.as(gtk.Widget).addController(key_controller.as(gtk.EventController));
```

- [ ] **Step 2: Implement onOmnibarKeyPressed**

```zig
    fn onOmnibarKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        modifiers: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        const has_ctrl = modifiers.control_mask;
        var state = priv.omnibar_state;

        switch (keyval) {
            gdk.KEY_Escape => {
                if (!state.is_focused) return 0;
                const effects = omnibar.omnibarReduce(&state, .escape);
                priv.omnibar_state = state;
                self.applyOmnibarEffects(effects);
                if (effects.should_blur_to_web_view) {
                    self.hideSuggestions();
                }
                return 1; // handled
            },
            gdk.KEY_Down => {
                if (state.suggestions.len == 0) return 0;
                const effects = omnibar.omnibarReduce(&state, .{ .move_selection = .{ .delta = 1 } });
                priv.omnibar_state = state;
                _ = effects;
                self.updateSuggestionHighlight();
                return 1;
            },
            gdk.KEY_Up => {
                if (state.suggestions.len == 0) return 0;
                const effects = omnibar.omnibarReduce(&state, .{ .move_selection = .{ .delta = -1 } });
                priv.omnibar_state = state;
                _ = effects;
                self.updateSuggestionHighlight();
                return 1;
            },
            gdk.KEY_n => {
                if (has_ctrl and state.suggestions.len > 0) {
                    const effects = omnibar.omnibarReduce(&state, .{ .move_selection = .{ .delta = 1 } });
                    priv.omnibar_state = state;
                    _ = effects;
                    self.updateSuggestionHighlight();
                    return 1;
                }
                return 0;
            },
            gdk.KEY_p => {
                if (has_ctrl and state.suggestions.len > 0) {
                    const effects = omnibar.omnibarReduce(&state, .{ .move_selection = .{ .delta = -1 } });
                    priv.omnibar_state = state;
                    _ = effects;
                    self.updateSuggestionHighlight();
                    return 1;
                }
                return 0;
            },
            gdk.KEY_Tab => {
                // Accept inline completion (future) or move selection
                if (state.suggestions.len > 0) {
                    self.commitSelectedSuggestion();
                    return 1;
                }
                return 0;
            },
            else => return 0,
        }
    }
```

- [ ] **Step 3: Add GDK import**

Add `gdk` import at the top of browser_panel_view.zig:

```zig
const gdk = @import("gdk");
```

- [ ] **Step 4: Implement updateSuggestionHighlight**

This updates the visual highlight in the list without rebuilding all rows:

```zig
    fn updateSuggestionHighlight(self: *Self) void {
        const priv = self.private();
        const list = priv.suggestions_list orelse return;
        const state = priv.omnibar_state;

        var idx: c_int = 0;
        while (list.getRowAtIndex(idx)) |row| : (idx += 1) {
            const child = row.getChild() orelse continue;
            if (@as(usize, @intCast(idx)) == state.selected_suggestion_index) {
                child.addCssClass("suggested-action");
            } else {
                child.removeCssClass("suggested-action");
            }
        }
    }
```

- [ ] **Step 5: Compile and verify**

Run: `zig build -Dcmux=true -Dversion-string="0.1.0-dev" 2>&1 | head -30`
Expected: Successful compilation

- [ ] **Step 6: Commit**

```bash
git add src/cmux/gtk/browser_panel_view.zig
git commit -m "feat(omnibar): add keyboard navigation (Up/Down, Ctrl+N/P, Escape, Tab)"
```

---

### Task 4: Add Ctrl+L window action to focus the omnibar

**Files:**
- Modify: `src/cmux/gtk/window.zig:330-347` (add action to initActionMap)
- Modify: `src/cmux/gtk/window.zig` (add handler + public method)
- Modify: `src/cmux/gtk/browser_panel_view.zig` (add public focusOmnibar method)

- [ ] **Step 1: Add public focusOmnibar method to BrowserPanelView**

In `browser_panel_view.zig`, add to the public API section:

```zig
    /// Focus the omnibar entry and select all text (Ctrl+L equivalent).
    pub fn focusOmnibar(self: *Self) void {
        const priv = self.private();
        const entry = priv.url_entry orelse return;
        _ = entry.as(gtk.Widget).grabFocus();
        // Focus signal handler will fire omnibar.focus_gained via onUrlEntryFocusChanged
    }
```

- [ ] **Step 2: Add focus-address-bar action to window initActionMap**

In `window.zig`, add to the `actions` array in `initActionMap`:

```zig
            .init("focus-address-bar", actionFocusAddressBar, null),
```

- [ ] **Step 3: Implement actionFocusAddressBar handler**

Add the handler function in window.zig after the other action handlers:

```zig
    fn actionFocusAddressBar(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        // Find the active browser panel in the current workspace and focus its omnibar.
        // For now, iterate the browser_panel_map and focus the first visible one.
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
```

- [ ] **Step 4: Register Ctrl+L accelerator**

In `window.zig`'s `new()` function, after the existing setup but before `return self`, register the accelerator directly on the GTK application:

```zig
        // Register Ctrl+L accelerator for address bar focus
        const gtk_app = app.as(gtk.Application);
        const focus_accels = [_:null]?[*:0]const u8{"<Ctrl>l"};
        gtk_app.setAccelsForAction("win.focus-address-bar", &focus_accels);
```

- [ ] **Step 5: Compile and verify**

Run: `zig build -Dcmux=true -Dversion-string="0.1.0-dev" 2>&1 | head -30`
Expected: Successful compilation

- [ ] **Step 6: Manual test**

Run the app, open a browser panel, and verify:
1. Ctrl+L focuses the URL entry and selects all text
2. Typing updates the entry and shows a suggestions popup
3. Up/Down and Ctrl+N/P navigate suggestions
4. Enter commits the selected suggestion (navigates)
5. Escape reverts text and closes popup, second Escape blurs to webview
6. WebView URI changes update the entry text

Run: `./zig-out/bin/cmux`

- [ ] **Step 7: Commit**

```bash
git add src/cmux/gtk/browser_panel_view.zig src/cmux/gtk/window.zig
git commit -m "feat(omnibar): add Ctrl+L focus action and complete GTK wiring"
```
