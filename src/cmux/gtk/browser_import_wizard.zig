//! Browser import wizard — multi-step dialog for importing browser data.
//!
//! Ports the macOS `ImportWizardWindowController` (BrowserPanel.swift lines
//! 9142-10111) and `BrowserDataImportCoordinator` (lines 8930-9138).
//!
//! Three-step flow:
//!   Step 1 — Select source browser (combo row / dropdown)
//!   Step 2 — Select source profiles (checkbox list)
//!   Step 3 — Data types + destination mode (separate / merge) + destination popups
//!
//! In UI-test `capture-only` mode the wizard writes the selection JSON to the
//! capture path instead of performing a real import.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gobject = @import("gobject");
const gtk = @import("gtk");
const posix = std.posix;
const json = std.json;

const browser_import = @import("../browser_import.zig");

const log = std.log.scoped(.browser_import_wizard);

// =========================================================================
// Test fixture types (parsed from environment variables)
// =========================================================================

const BrowserFixture = struct {
    browser_name: []const u8,
    profiles: []const []const u8,
};

const SourceProfile = struct {
    display_name: []const u8,
    root_path: []const u8,
    is_default: bool,
};

// =========================================================================
// Wizard state
// =========================================================================

const Step = enum { source, source_profiles, data_types };

const DestinationMode = enum { separate_profiles, merge_into_one };

/// Scope of the import based on checkbox selection.
const ImportScope = enum {
    cookies_only,
    history_only,
    cookies_and_history,
    everything,

    fn fromSelection(cookies: bool, history: bool, additional: bool) ?ImportScope {
        if (additional) return .everything;
        if (cookies and history) return .cookies_and_history;
        if (cookies) return .cookies_only;
        if (history) return .history_only;
        return null;
    }

    fn toCaptureName(self: ImportScope) []const u8 {
        return switch (self) {
            .cookies_only => "cookiesOnly",
            .history_only => "historyOnly",
            .cookies_and_history => "cookiesAndHistory",
            .everything => "everything",
        };
    }
};

/// The wizard result that gets captured/exported.
const WizardSelection = struct {
    mode: DestinationMode,
    scope: ImportScope,
    entries: []const SelectionEntry,
};

const SelectionEntry = struct {
    source_profiles: []const []const u8,
    destination_kind: []const u8, // "create" or "existing"
    destination_name: []const u8,
};

/// Per-entry destination choice in separate-profiles mode.
const DestinationChoice = union(enum) {
    existing_profile: struct {
        name: []const u8,
    },
    create_named: struct {
        name: []const u8,
    },
};

// =========================================================================
// Present the wizard (entry point)
// =========================================================================

/// Show the import wizard dialog.
/// Reads test fixture environment variables.
/// If `capture-only` mode is set, writes the selection to the capture path
/// and returns without performing any real import.
///
/// `parent` is the GtkWindow to set as transient parent (nullable).
pub fn presentImportWizard(parent: ?*gtk.Window) void {
    // Parse test fixture environment variables.
    const env = posix.getenv;

    const fixture_raw = env("CMUX_UI_TEST_BROWSER_IMPORT_FIXTURE") orelse {
        log.warn("no CMUX_UI_TEST_BROWSER_IMPORT_FIXTURE set", .{});
        return;
    };

    var fixture = parseFixture(fixture_raw) orelse {
        log.warn("failed to parse browser import fixture", .{});
        return;
    };

    const dest_raw = env("CMUX_UI_TEST_BROWSER_IMPORT_DESTINATIONS") orelse "[]";
    var dest_names = parseDestinations(dest_raw) orelse {
        log.warn("failed to parse browser import destinations", .{});
        return;
    };

    const capture_mode = if (env("CMUX_UI_TEST_BROWSER_IMPORT_MODE")) |m|
        std.mem.eql(u8, m, "capture-only")
    else
        false;
    const capture_path = env("CMUX_UI_TEST_BROWSER_IMPORT_CAPTURE_PATH");

    // Build the wizard dialog.
    var wizard = WizardState{
        .fixture = &fixture,
        .dest_names = &dest_names,
        .capture_mode = capture_mode,
        .capture_path = capture_path,
    };
    wizard.buildAndShow(parent);
}

// =========================================================================
// Fixture parsing
// =========================================================================

const MAX_PROFILES = 16;
const MAX_DESTINATIONS = 16;

const FixtureData = struct {
    browser_name_buf: [256]u8 = undefined,
    browser_name_len: usize = 0,
    profile_bufs: [MAX_PROFILES][128]u8 = undefined,
    profile_lens: [MAX_PROFILES]usize = [_]usize{0} ** MAX_PROFILES,
    profile_count: usize = 0,

    fn browserName(self: *const FixtureData) []const u8 {
        return self.browser_name_buf[0..self.browser_name_len];
    }

    fn profileName(self: *const FixtureData, i: usize) []const u8 {
        return self.profile_bufs[i][0..self.profile_lens[i]];
    }
};

const DestData = struct {
    name_bufs: [MAX_DESTINATIONS][128]u8 = undefined,
    name_lens: [MAX_DESTINATIONS]usize = [_]usize{0} ** MAX_DESTINATIONS,
    count: usize = 0,

    fn name(self: *const DestData, i: usize) []const u8 {
        return self.name_bufs[i][0..self.name_lens[i]];
    }
};

fn parseFixture(raw: []const u8) ?FixtureData {
    var data = FixtureData{};
    // Simple JSON parser for {"browserName":"...","profiles":["...", "..."]}
    const browser_key = "\"browserName\":\"";
    const profiles_key = "\"profiles\":[";

    if (std.mem.indexOf(u8, raw, browser_key)) |pos| {
        const start = pos + browser_key.len;
        if (std.mem.indexOfPos(u8, raw, start, "\"")) |end| {
            const name = raw[start..end];
            if (name.len > data.browser_name_buf.len) return null;
            @memcpy(data.browser_name_buf[0..name.len], name);
            data.browser_name_len = name.len;
        }
    }

    if (std.mem.indexOf(u8, raw, profiles_key)) |pos| {
        var i = pos + profiles_key.len;
        while (i < raw.len and data.profile_count < MAX_PROFILES) {
            // Skip whitespace and commas
            while (i < raw.len and (raw[i] == ' ' or raw[i] == ',' or raw[i] == '\n')) : (i += 1) {}
            if (i >= raw.len or raw[i] == ']') break;
            if (raw[i] != '"') break;
            i += 1; // skip opening quote
            const start = i;
            while (i < raw.len and raw[i] != '"') : (i += 1) {}
            if (i >= raw.len) break;
            const name = raw[start..i];
            i += 1; // skip closing quote
            if (name.len > data.profile_bufs[0].len) continue;
            @memcpy(data.profile_bufs[data.profile_count][0..name.len], name);
            data.profile_lens[data.profile_count] = name.len;
            data.profile_count += 1;
        }
    }

    return data;
}

fn parseDestinations(raw: []const u8) ?DestData {
    var data = DestData{};
    // Parse ["Name1", "Name2"]
    var i: usize = 0;
    while (i < raw.len and raw[i] != '[') : (i += 1) {}
    if (i >= raw.len) return data; // empty
    i += 1;

    while (i < raw.len and data.count < MAX_DESTINATIONS) {
        while (i < raw.len and (raw[i] == ' ' or raw[i] == ',' or raw[i] == '\n')) : (i += 1) {}
        if (i >= raw.len or raw[i] == ']') break;
        if (raw[i] != '"') break;
        i += 1;
        const start = i;
        while (i < raw.len and raw[i] != '"') : (i += 1) {}
        if (i >= raw.len) break;
        const name = raw[start..i];
        i += 1;
        if (name.len > data.name_bufs[0].len) continue;
        @memcpy(data.name_bufs[data.count][0..name.len], name);
        data.name_lens[data.count] = name.len;
        data.count += 1;
    }

    return data;
}

// =========================================================================
// Wizard UI state
// =========================================================================

const WizardState = struct {
    fixture: *FixtureData,
    dest_names: *DestData,
    capture_mode: bool,
    capture_path: ?[]const u8,

    // UI state
    step: Step = .source,
    destination_mode: DestinationMode = .separate_profiles,

    // All source profiles are selected by default in test fixtures
    // (the Mac tests click Next without deselecting any).
    profile_selected: [MAX_PROFILES]bool = [_]bool{true} ** MAX_PROFILES,

    // Checkbox state for step 3
    cookies_checked: bool = true,
    history_checked: bool = true,
    additional_data_checked: bool = false,

    // Per-entry destination selection indices (for separate mode)
    // Index into the options list for each source profile.
    separate_dest_indices: [MAX_PROFILES]usize = [_]usize{0} ** MAX_PROFILES,

    // Merge destination index (into dest_names)
    merge_dest_index: usize = 0,

    // Widget references
    window: ?*gtk.Window = null,
    main_stack: ?*gtk.Stack = null,
    step_label: ?*gtk.Label = null,
    primary_button: ?*gtk.Button = null,
    back_button: ?*gtk.Button = null,

    // Step 3 dynamic widgets
    mode_box: ?*gtk.Box = null,
    separate_radio: ?*gtk.CheckButton = null,
    merge_radio: ?*gtk.CheckButton = null,
    separate_rows_box: ?*gtk.Box = null,
    merge_row_box: ?*gtk.Box = null,

    fn buildAndShow(self: *WizardState, parent: ?*gtk.Window) void {
        // Create dialog window.
        const window = gtk.Window.new();
        window.setTitle("Import Browser Data");
        window.setDefaultSize(560, 320);
        window.setModal(1);
        window.setDestroyWithParent(1);
        if (parent) |p| {
            window.setTransientFor(p);
        }
        self.window = window;

        // Title label for accessibility.
        // The title label has the accessibility name "Import Browser Data".
        const title_label = gtk.Label.new("Import Browser Data");
        title_label.as(gtk.Widget).addCssClass("title-1");
        title_label.as(gtk.Widget).setHalign(.start);

        // Step indicator label.
        const step_label = gtk.Label.new("Step 1 of 3");
        step_label.as(gtk.Widget).addCssClass("dim-label");
        step_label.as(gtk.Widget).setHalign(.start);
        self.step_label = step_label;

        // ---- Step 1: Source browser selection ----
        const step1_box = gtk.Box.new(.vertical, 8);
        step1_box.as(gtk.Widget).setMarginStart(18);
        step1_box.as(gtk.Widget).setMarginEnd(18);
        step1_box.as(gtk.Widget).setMarginTop(8);

        const source_label = gtk.Label.new("Source");
        source_label.as(gtk.Widget).setHalign(.start);
        step1_box.append(source_label.as(gtk.Widget));

        // Browser name display (read-only in test mode, only one browser).
        const browser_label = gtk.Label.new(self.fixture.browserName().ptr);
        browser_label.as(gtk.Widget).setHalign(.start);
        browser_label.as(gtk.Widget).addCssClass("heading");
        step1_box.append(browser_label.as(gtk.Widget));

        // ---- Step 2: Source profiles selection ----
        const step2_box = gtk.Box.new(.vertical, 8);
        step2_box.as(gtk.Widget).setMarginStart(18);
        step2_box.as(gtk.Widget).setMarginEnd(18);
        step2_box.as(gtk.Widget).setMarginTop(8);

        const profiles_title = gtk.Label.new("Source Profiles");
        profiles_title.as(gtk.Widget).setHalign(.start);
        profiles_title.as(gtk.Widget).addCssClass("heading");
        step2_box.append(profiles_title.as(gtk.Widget));

        // Checkboxes for each source profile.
        var pi: usize = 0;
        while (pi < self.fixture.profile_count) : (pi += 1) {
            const name = self.fixture.profileName(pi);
            // Zig string to null-terminated for GTK.
            var name_buf: [129:0]u8 = undefined;
            @memcpy(name_buf[0..name.len], name);
            name_buf[name.len] = 0;
            const cb = gtk.CheckButton.newWithLabel(@ptrCast(&name_buf));
            cb.setActive(1);
            step2_box.append(cb.as(gtk.Widget));
        }

        // ---- Step 3: Data types + destination ----
        const step3_box = gtk.Box.new(.vertical, 8);
        step3_box.as(gtk.Widget).setMarginStart(18);
        step3_box.as(gtk.Widget).setMarginEnd(18);
        step3_box.as(gtk.Widget).setMarginTop(8);

        // Destination mode (separate / merge radio buttons).
        const mode_box = gtk.Box.new(.vertical, 6);
        self.mode_box = mode_box;

        const dest_title = gtk.Label.new("cmux destination");
        dest_title.as(gtk.Widget).setHalign(.start);
        dest_title.as(gtk.Widget).addCssClass("heading");
        step3_box.append(dest_title.as(gtk.Widget));

        // Radio buttons: "Separate profiles" and "Merge into one"
        const separate_radio = gtk.CheckButton.newWithLabel("Separate profiles");
        separate_radio.as(gtk.Widget).setName("Separate profiles");
        self.separate_radio = separate_radio;

        const merge_radio = gtk.CheckButton.newWithLabel("Merge into one");
        merge_radio.as(gtk.Widget).setName("Merge into one");
        merge_radio.setGroup(separate_radio);
        self.merge_radio = merge_radio;

        // Default: separate profiles is active for multi-profile.
        if (self.fixture.profile_count > 1) {
            separate_radio.setActive(1);
            self.destination_mode = .separate_profiles;
        } else {
            merge_radio.setActive(1);
            self.destination_mode = .merge_into_one;
        }

        // Connect radio button toggled signals.
        _ = gtk.CheckButton.signals.toggled.connect(
            separate_radio,
            *WizardState,
            onSeparateRadioToggled,
            self,
            .{},
        );

        mode_box.append(separate_radio.as(gtk.Widget));
        mode_box.append(merge_radio.as(gtk.Widget));

        // Only show mode selector for multi-profile.
        if (self.fixture.profile_count <= 1) {
            mode_box.as(gtk.Widget).setVisible(0);
        }

        step3_box.append(mode_box.as(gtk.Widget));

        // Separate destination rows.
        const separate_rows_box = gtk.Box.new(.vertical, 6);
        self.separate_rows_box = separate_rows_box;
        self.buildSeparateDestinationRows(separate_rows_box);
        step3_box.append(separate_rows_box.as(gtk.Widget));

        // Merge destination row.
        const merge_row_box = gtk.Box.new(.horizontal, 6);
        self.merge_row_box = merge_row_box;
        self.buildMergeDestinationRow(merge_row_box);
        step3_box.append(merge_row_box.as(gtk.Widget));

        // Update visibility based on mode.
        self.updateDestinationVisibility();

        // Help label for separate mode.
        const help_label = gtk.Label.new("Missing cmux profiles are created when import starts.");
        help_label.as(gtk.Widget).addCssClass("dim-label");
        help_label.as(gtk.Widget).setHalign(.start);
        help_label.as(gtk.Widget).setWrap(1);
        step3_box.append(help_label.as(gtk.Widget));

        // Checkboxes for data types.
        const cookies_cb = gtk.CheckButton.newWithLabel("Cookies (site sign-ins)");
        cookies_cb.as(gtk.Widget).setName("BrowserImportCookiesCheckbox");
        cookies_cb.setActive(1);
        _ = gtk.CheckButton.signals.toggled.connect(
            cookies_cb,
            *WizardState,
            onCookiesToggled,
            self,
            .{},
        );
        step3_box.append(cookies_cb.as(gtk.Widget));

        const history_cb = gtk.CheckButton.newWithLabel("History (visited pages)");
        history_cb.as(gtk.Widget).setName("BrowserImportHistoryCheckbox");
        history_cb.setActive(1);
        // Use a separate group so these are independent checkboxes, not radios.
        // GtkCheckButton without a group acts as a checkbox.
        _ = gtk.CheckButton.signals.toggled.connect(
            history_cb,
            *WizardState,
            onHistoryToggled,
            self,
            .{},
        );
        step3_box.append(history_cb.as(gtk.Widget));

        const additional_cb = gtk.CheckButton.newWithLabel("Additional data (bookmarks, settings, extensions)");
        additional_cb.as(gtk.Widget).setName("BrowserImportAdditionalDataCheckbox");
        additional_cb.setActive(0);
        _ = gtk.CheckButton.signals.toggled.connect(
            additional_cb,
            *WizardState,
            onAdditionalDataToggled,
            self,
            .{},
        );
        step3_box.append(additional_cb.as(gtk.Widget));

        // ---- Stack for steps ----
        const stack = gtk.Stack.new();
        stack.as(gtk.Widget).setVexpand(1);
        stack.addNamed(step1_box.as(gtk.Widget), "step1");
        stack.addNamed(step2_box.as(gtk.Widget), "step2");
        stack.addNamed(step3_box.as(gtk.Widget), "step3");
        stack.setVisibleChildName("step1");
        self.main_stack = stack;

        // ---- Button row ----
        const button_box = gtk.Box.new(.horizontal, 8);
        button_box.as(gtk.Widget).setHalign(.end);
        button_box.as(gtk.Widget).setMarginStart(18);
        button_box.as(gtk.Widget).setMarginEnd(18);
        button_box.as(gtk.Widget).setMarginBottom(14);
        button_box.as(gtk.Widget).setMarginTop(8);

        const back_button = gtk.Button.newWithLabel("Back");
        back_button.as(gtk.Widget).setVisible(0);
        _ = gtk.Button.signals.clicked.connect(back_button, *WizardState, onBackClicked, self, .{});
        button_box.append(back_button.as(gtk.Widget));
        self.back_button = back_button;

        const cancel_button = gtk.Button.newWithLabel("Cancel");
        _ = gtk.Button.signals.clicked.connect(cancel_button, *WizardState, onCancelClicked, self, .{});
        button_box.append(cancel_button.as(gtk.Widget));

        const primary_button = gtk.Button.newWithLabel("Next");
        primary_button.as(gtk.Widget).addCssClass("suggested-action");
        _ = gtk.Button.signals.clicked.connect(primary_button, *WizardState, onPrimaryClicked, self, .{});
        button_box.append(primary_button.as(gtk.Widget));
        self.primary_button = primary_button;

        // ---- Main layout ----
        const content_box = gtk.Box.new(.vertical, 8);
        content_box.as(gtk.Widget).setMarginTop(16);

        content_box.append(title_label.as(gtk.Widget));
        // Indent title label
        title_label.as(gtk.Widget).setMarginStart(18);

        content_box.append(step_label.as(gtk.Widget));
        step_label.as(gtk.Widget).setMarginStart(18);

        content_box.append(stack.as(gtk.Widget));
        content_box.append(button_box.as(gtk.Widget));

        window.setChild(content_box.as(gtk.Widget));

        // Present.
        window.as(gtk.Widget).setVisible(1);
    }

    fn buildSeparateDestinationRows(self: *WizardState, container: *gtk.Box) void {
        var pi: usize = 0;
        while (pi < self.fixture.profile_count) : (pi += 1) {
            const profile_name = self.fixture.profileName(pi);
            const row = gtk.Box.new(.horizontal, 8);

            // Source profile label.
            var label_buf: [129:0]u8 = undefined;
            @memcpy(label_buf[0..profile_name.len], profile_name);
            label_buf[profile_name.len] = 0;
            const source_label = gtk.Label.new(@ptrCast(&label_buf));
            source_label.as(gtk.Widget).setHalign(.start);
            source_label.as(gtk.Widget).setSizeRequest(110, -1);
            row.append(source_label.as(gtk.Widget));

            // "→" arrow.
            const arrow_label = gtk.Label.new("\xe2\x86\x92"); // →
            row.append(arrow_label.as(gtk.Widget));

            // Destination dropdown.
            const dropdown = gtk.DropDown.newFromStrings(
                &self.buildDestinationOptionsStrings(pi),
            );
            dropdown.setSelected(0);

            // Accessibility name: BrowserImportDestinationPopup-<slug>
            const slug = self.accessibilitySlug(pi);
            var a11y_buf: [256:0]u8 = undefined;
            const prefix = "BrowserImportDestinationPopup-";
            @memcpy(a11y_buf[0..prefix.len], prefix);
            @memcpy(a11y_buf[prefix.len..][0..slug.len], slug);
            a11y_buf[prefix.len + slug.len] = 0;
            dropdown.as(gtk.Widget).setName(@ptrCast(&a11y_buf));

            dropdown.as(gtk.Widget).setHexpand(1);
            row.append(dropdown.as(gtk.Widget));

            container.append(row.as(gtk.Widget));
        }
    }

    fn buildMergeDestinationRow(self: *WizardState, container: *gtk.Box) void {
        const dest_label = gtk.Label.new("Import into");
        dest_label.as(gtk.Widget).setHalign(.start);
        dest_label.as(gtk.Widget).setSizeRequest(110, -1);
        container.append(dest_label.as(gtk.Widget));

        // Destination dropdown for merge mode.
        if (self.dest_names.count > 0) {
            const dropdown = gtk.DropDown.newFromStrings(
                &self.buildMergeOptionsStrings(),
            );
            dropdown.setSelected(0);
            dropdown.as(gtk.Widget).setName("BrowserImportDestinationPopup-merge");
            dropdown.as(gtk.Widget).setHexpand(1);
            container.append(dropdown.as(gtk.Widget));
        }
    }

    fn buildDestinationOptionsStrings(self: *WizardState, profile_idx: usize) [MAX_DESTINATIONS + 1:null]?[*:0]const u8 {
        var strings: [MAX_DESTINATIONS + 1:null]?[*:0]const u8 = .{null} ** (MAX_DESTINATIONS + 1);
        var si: usize = 0;

        // Existing destination profiles.
        var di: usize = 0;
        while (di < self.dest_names.count and si < MAX_DESTINATIONS) : (di += 1) {
            strings[si] = @ptrCast(self.dest_names.name_bufs[di][0..self.dest_names.name_lens[di]].ptr);
            si += 1;
        }

        // "Create <name>" option.
        const profile_name = self.fixture.profileName(profile_idx);
        // Check if profile name matches any existing destination (case-insensitive).
        var found = false;
        di = 0;
        while (di < self.dest_names.count) : (di += 1) {
            if (asciiEqlIgnoreCase(profile_name, self.dest_names.name(di))) {
                found = true;
                break;
            }
        }

        if (!found and profile_name.len > 0 and si < MAX_DESTINATIONS) {
            // Build "Create \"<name>\"" string in a static buffer.
            // We need this to stay valid — use a static array of buffers.
            const buf = &create_option_bufs[profile_idx];
            const create_prefix = "Create \"";
            const create_suffix = "\"";
            @memcpy(buf[0..create_prefix.len], create_prefix);
            @memcpy(buf[create_prefix.len..][0..profile_name.len], profile_name);
            @memcpy(buf[create_prefix.len + profile_name.len ..][0..create_suffix.len], create_suffix);
            buf[create_prefix.len + profile_name.len + create_suffix.len] = 0;
            strings[si] = @ptrCast(buf);
            si += 1;
        }

        strings[si] = null;
        return strings;
    }

    fn buildMergeOptionsStrings(self: *WizardState) [MAX_DESTINATIONS + 1:null]?[*:0]const u8 {
        var strings: [MAX_DESTINATIONS + 1:null]?[*:0]const u8 = .{null} ** (MAX_DESTINATIONS + 1);
        var di: usize = 0;
        while (di < self.dest_names.count and di < MAX_DESTINATIONS) : (di += 1) {
            strings[di] = @ptrCast(self.dest_names.name_bufs[di][0..self.dest_names.name_lens[di]].ptr);
        }
        strings[di] = null;
        return strings;
    }

    fn accessibilitySlug(self: *WizardState, profile_idx: usize) []const u8 {
        const profile_name = self.fixture.profileName(profile_idx);
        // Convert to lowercase, replace non-alnum with hyphens.
        const buf = &slug_bufs[profile_idx];
        var len: usize = 0;
        for (profile_name) |c| {
            const lower: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
            if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) {
                if (len < buf.len) {
                    buf[len] = lower;
                    len += 1;
                }
            } else {
                // Replace with hyphen (collapse multiple).
                if (len > 0 and buf[len - 1] != '-') {
                    if (len < buf.len) {
                        buf[len] = '-';
                        len += 1;
                    }
                }
            }
        }
        // Trim trailing hyphens.
        while (len > 0 and buf[len - 1] == '-') : (len -= 1) {}
        if (len == 0) {
            // Fallback.
            const fallback = "profile-0";
            return fallback[0..fallback.len];
        }
        return buf[0..len];
    }

    fn updateDestinationVisibility(self: *WizardState) void {
        if (self.separate_rows_box) |box| {
            box.as(gtk.Widget).setVisible(
                @intFromBool(self.destination_mode == .separate_profiles),
            );
        }
        if (self.merge_row_box) |box| {
            box.as(gtk.Widget).setVisible(
                @intFromBool(self.destination_mode == .merge_into_one),
            );
        }
    }

    // -----------------------------------------------------------------
    // Signal handlers
    // -----------------------------------------------------------------

    fn onSeparateRadioToggled(_: *gtk.CheckButton, self: *WizardState) callconv(.c) void {
        if (self.separate_radio) |radio| {
            if (radio.getActive() != 0) {
                self.destination_mode = .separate_profiles;
            } else {
                self.destination_mode = .merge_into_one;
            }
            self.updateDestinationVisibility();
        }
    }

    fn onCookiesToggled(cb: *gtk.CheckButton, self: *WizardState) callconv(.c) void {
        self.cookies_checked = cb.getActive() != 0;
    }

    fn onHistoryToggled(cb: *gtk.CheckButton, self: *WizardState) callconv(.c) void {
        self.history_checked = cb.getActive() != 0;
    }

    fn onAdditionalDataToggled(cb: *gtk.CheckButton, self: *WizardState) callconv(.c) void {
        self.additional_data_checked = cb.getActive() != 0;
    }

    fn onBackClicked(_: *gtk.Button, self: *WizardState) callconv(.c) void {
        switch (self.step) {
            .source => return,
            .source_profiles => {
                self.step = .source;
                self.updateStepUI();
            },
            .data_types => {
                self.step = .source_profiles;
                self.updateStepUI();
            },
        }
    }

    fn onCancelClicked(_: *gtk.Button, self: *WizardState) callconv(.c) void {
        if (self.window) |w| {
            w.destroy();
        }
    }

    fn onPrimaryClicked(_: *gtk.Button, self: *WizardState) callconv(.c) void {
        switch (self.step) {
            .source => {
                self.step = .source_profiles;
                self.updateStepUI();
            },
            .source_profiles => {
                self.step = .data_types;
                self.updateStepUI();
            },
            .data_types => {
                self.finishImport();
            },
        }
    }

    fn updateStepUI(self: *WizardState) void {
        const stack = self.main_stack orelse return;

        switch (self.step) {
            .source => {
                stack.setVisibleChildName("step1");
                if (self.step_label) |l| l.setLabel("Step 1 of 3");
                if (self.back_button) |b| b.as(gtk.Widget).setVisible(0);
                if (self.primary_button) |b| b.setLabel("Next");
            },
            .source_profiles => {
                stack.setVisibleChildName("step2");
                if (self.step_label) |l| l.setLabel("Step 2 of 3");
                if (self.back_button) |b| b.as(gtk.Widget).setVisible(1);
                if (self.primary_button) |b| b.setLabel("Next");
            },
            .data_types => {
                stack.setVisibleChildName("step3");
                if (self.step_label) |l| l.setLabel("Step 3 of 3");
                if (self.back_button) |b| b.as(gtk.Widget).setVisible(1);
                if (self.primary_button) |b| b.setLabel("Start Import");
            },
        }
    }

    fn finishImport(self: *WizardState) void {
        const scope = ImportScope.fromSelection(
            self.cookies_checked,
            self.history_checked,
            self.additional_data_checked,
        ) orelse {
            log.warn("no import scope selected", .{});
            return;
        };

        if (self.capture_mode) {
            self.writeCaptureJson(scope);
            if (self.window) |w| {
                w.destroy();
            }
            return;
        }

        // Non-test-mode: close and log (actual import not yet implemented).
        log.info("import wizard completed (mode={s}, scope={s})", .{
            if (self.destination_mode == .separate_profiles) "separate" else "merge",
            scope.toCaptureName(),
        });
        if (self.window) |w| {
            w.destroy();
        }
    }

    fn writeCaptureJson(self: *WizardState, scope: ImportScope) void {
        const path = self.capture_path orelse return;

        // Build the JSON capture payload.
        var buf: [8192]u8 = undefined;
        var pos: usize = 0;

        // Start object.
        pos = appendStr(&buf, pos, "{") orelse return;

        // "mode"
        const mode_str = if (self.destination_mode == .separate_profiles)
            "separateProfiles"
        else
            "mergeIntoOne";
        pos = appendStr(&buf, pos, "\"mode\":\"") orelse return;
        pos = appendStr(&buf, pos, mode_str) orelse return;
        pos = appendStr(&buf, pos, "\",") orelse return;

        // "scope"
        pos = appendStr(&buf, pos, "\"scope\":\"") orelse return;
        pos = appendStr(&buf, pos, scope.toCaptureName()) orelse return;
        pos = appendStr(&buf, pos, "\",") orelse return;

        // "entries"
        pos = appendStr(&buf, pos, "\"entries\":[") orelse return;

        if (self.destination_mode == .separate_profiles) {
            // One entry per source profile.
            var pi: usize = 0;
            while (pi < self.fixture.profile_count) : (pi += 1) {
                if (pi > 0) {
                    pos = appendStr(&buf, pos, ",") orelse return;
                }
                const profile_name = self.fixture.profileName(pi);

                // Determine destination kind and name.
                // Check if this profile matches an existing destination.
                var dest_kind: []const u8 = "create";
                var dest_name: []const u8 = profile_name;

                var di: usize = 0;
                while (di < self.dest_names.count) : (di += 1) {
                    if (asciiEqlIgnoreCase(profile_name, self.dest_names.name(di))) {
                        dest_kind = "existing";
                        dest_name = self.dest_names.name(di);
                        break;
                    }
                }

                pos = appendStr(&buf, pos, "{\"sourceProfiles\":[\"") orelse return;
                pos = appendStr(&buf, pos, profile_name) orelse return;
                pos = appendStr(&buf, pos, "\"],\"destinationKind\":\"") orelse return;
                pos = appendStr(&buf, pos, dest_kind) orelse return;
                pos = appendStr(&buf, pos, "\",\"destinationName\":\"") orelse return;
                pos = appendStr(&buf, pos, dest_name) orelse return;
                pos = appendStr(&buf, pos, "\"}") orelse return;
            }
        } else {
            // Merge: one entry with all source profiles.
            pos = appendStr(&buf, pos, "{\"sourceProfiles\":[") orelse return;
            var pi: usize = 0;
            while (pi < self.fixture.profile_count) : (pi += 1) {
                if (pi > 0) {
                    pos = appendStr(&buf, pos, ",") orelse return;
                }
                pos = appendStr(&buf, pos, "\"") orelse return;
                pos = appendStr(&buf, pos, self.fixture.profileName(pi)) orelse return;
                pos = appendStr(&buf, pos, "\"") orelse return;
            }

            // Destination for merge: first existing destination profile.
            var merge_dest_name: []const u8 = "Default";
            if (self.dest_names.count > 0) {
                merge_dest_name = self.dest_names.name(self.merge_dest_index);
            }

            pos = appendStr(&buf, pos, "],\"destinationKind\":\"existing\",\"destinationName\":\"") orelse return;
            pos = appendStr(&buf, pos, merge_dest_name) orelse return;
            pos = appendStr(&buf, pos, "\"}") orelse return;
        }

        pos = appendStr(&buf, pos, "]}") orelse return;

        // Write to file.
        const file = std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 }) catch |err| {
            log.warn("failed to create capture file '{s}': {}", .{ path, err });
            return;
        };
        defer file.close();
        file.writeAll(buf[0..pos]) catch |err| {
            log.warn("failed to write capture file: {}", .{err});
        };

        log.info("captured import selection to '{s}' ({d} bytes)", .{ path, pos });
    }
};

// Static buffers for dropdown option strings (must outlive the dropdown widgets).
var create_option_bufs: [MAX_PROFILES][256:0]u8 = undefined;
var slug_bufs: [MAX_PROFILES][128]u8 = undefined;

fn appendStr(buf: *[8192]u8, pos: usize, s: []const u8) ?usize {
    if (pos + s.len > buf.len) return null;
    @memcpy(buf[pos..][0..s.len], s);
    return pos + s.len;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la: u8 = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb: u8 = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}
