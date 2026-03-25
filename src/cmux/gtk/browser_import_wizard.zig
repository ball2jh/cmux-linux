//! Browser import wizard -- multi-step dialog for importing browser data.
//!
//! Ports the macOS `ImportWizardWindowController` (BrowserPanel.swift lines
//! 9142-10111) and `BrowserDataImportCoordinator` (lines 8930-9138).
//!
//! Three-step flow:
//!   Step 1 -- Select source browser (combo row / dropdown)
//!   Step 2 -- Select source profiles (checkbox list)
//!   Step 3 -- Data types + destination mode (separate / merge) + destination popups
//!
//! In UI-test `capture-only` mode the wizard writes the selection JSON to the
//! capture path instead of performing a real import.
//!
//! Uses file-level static state because GTK signal callbacks cannot carry
//! Zig closures, and only one wizard can be open at a time (matches the Mac's
//! `importInProgress` guard).

const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");
const posix = std.posix;

const log = std.log.scoped(.browser_import_wizard);

// =========================================================================
// Constants
// =========================================================================

const MAX_PROFILES = 16;
const MAX_DESTINATIONS = 16;

// =========================================================================
// Static wizard state (single instance, reset on each presentImportWizard)
// =========================================================================

var wizard_active: bool = false;

// Fixture data (parsed from env).
var fixture_browser_name_buf: [256]u8 = undefined;
var fixture_browser_name_len: usize = 0;
var fixture_profile_bufs: [MAX_PROFILES][128]u8 = undefined;
var fixture_profile_lens: [MAX_PROFILES]usize = [_]usize{0} ** MAX_PROFILES;
var fixture_profile_count: usize = 0;

// Destination profiles (parsed from env).
var dest_name_bufs: [MAX_DESTINATIONS][128]u8 = undefined;
var dest_name_lens: [MAX_DESTINATIONS]usize = [_]usize{0} ** MAX_DESTINATIONS;
var dest_count: usize = 0;

// Capture mode settings.
var capture_mode: bool = false;
var capture_path_buf: [1024]u8 = undefined;
var capture_path_len: usize = 0;

// Wizard step.
const Step = enum { source, source_profiles, data_types };
var current_step: Step = .source;

// Destination mode.
const DestMode = enum { separate_profiles, merge_into_one };
var destination_mode: DestMode = .separate_profiles;

// Checkbox state for step 3.
var cookies_checked: bool = true;
var history_checked: bool = true;
var additional_data_checked: bool = false;

// Merge destination index.
var merge_dest_index: u32 = 0;

// Widget handles (valid only while wizard window is open).
var wizard_window: ?*gtk.Window = null;
var main_stack: ?*gtk.Stack = null;
var step_label: ?*gtk.Label = null;
var primary_button: ?*gtk.Button = null;
var back_button: ?*gtk.Button = null;
var separate_radio: ?*gtk.CheckButton = null;
var separate_rows_box: ?*gtk.Box = null;
var merge_row_box: ?*gtk.Box = null;

// Static buffers for dropdown option strings and slug generation.
var create_option_bufs: [MAX_PROFILES][256:0]u8 = undefined;
var slug_bufs: [MAX_PROFILES][128]u8 = undefined;

// =========================================================================
// Scope helper
// =========================================================================

fn scopeCaptureName(cookies: bool, history: bool, additional: bool) ?[]const u8 {
    if (additional) return "everything";
    if (cookies and history) return "cookiesAndHistory";
    if (cookies) return "cookiesOnly";
    if (history) return "historyOnly";
    return null;
}

// =========================================================================
// Accessor helpers
// =========================================================================

fn fixtureProfileName(i: usize) []const u8 {
    return fixture_profile_bufs[i][0..fixture_profile_lens[i]];
}

fn destName(i: usize) []const u8 {
    return dest_name_bufs[i][0..dest_name_lens[i]];
}

fn capturePath() ?[]const u8 {
    if (capture_path_len == 0) return null;
    return capture_path_buf[0..capture_path_len];
}

// =========================================================================
// Present the wizard (entry point)
// =========================================================================

/// Show the import wizard dialog.
/// Reads test fixture environment variables.
/// If `capture-only` mode is set, writes the selection JSON to the capture path
/// and returns without performing any real import.
///
/// `parent` is the GtkWindow to set as transient parent (nullable).
pub fn presentImportWizard(parent: ?*gtk.Window) void {
    if (wizard_active) return;

    // Parse test fixture environment variables.
    const env = posix.getenv;

    const fixture_raw = env("CMUX_UI_TEST_BROWSER_IMPORT_FIXTURE") orelse {
        log.warn("no CMUX_UI_TEST_BROWSER_IMPORT_FIXTURE set", .{});
        return;
    };

    if (!parseFixture(fixture_raw)) {
        log.warn("failed to parse browser import fixture", .{});
        return;
    }

    const dest_raw = env("CMUX_UI_TEST_BROWSER_IMPORT_DESTINATIONS") orelse "[]";
    parseDestinations(dest_raw);

    capture_mode = if (env("CMUX_UI_TEST_BROWSER_IMPORT_MODE")) |m|
        std.mem.eql(u8, m, "capture-only")
    else
        false;

    if (env("CMUX_UI_TEST_BROWSER_IMPORT_CAPTURE_PATH")) |p| {
        const copy_len = @min(p.len, capture_path_buf.len);
        @memcpy(capture_path_buf[0..copy_len], p[0..copy_len]);
        capture_path_len = copy_len;
    } else {
        capture_path_len = 0;
    }

    // Reset wizard state.
    current_step = .source;
    cookies_checked = true;
    history_checked = true;
    additional_data_checked = false;
    merge_dest_index = 0;
    destination_mode = if (fixture_profile_count > 1) .separate_profiles else .merge_into_one;

    wizard_active = true;
    buildAndShow(parent);
}

// =========================================================================
// Fixture parsing (into static buffers)
// =========================================================================

fn parseFixture(raw: []const u8) bool {
    fixture_browser_name_len = 0;
    fixture_profile_count = 0;

    // Simple JSON parser for {"browserName":"...","profiles":["...", "..."]}
    const browser_key = "\"browserName\":\"";
    const profiles_key = "\"profiles\":[";

    if (std.mem.indexOf(u8, raw, browser_key)) |pos| {
        const start = pos + browser_key.len;
        if (std.mem.indexOfPos(u8, raw, start, "\"")) |end| {
            const name = raw[start..end];
            if (name.len > fixture_browser_name_buf.len) return false;
            @memcpy(fixture_browser_name_buf[0..name.len], name);
            fixture_browser_name_len = name.len;
        }
    }

    if (std.mem.indexOf(u8, raw, profiles_key)) |pos| {
        var i = pos + profiles_key.len;
        while (i < raw.len and fixture_profile_count < MAX_PROFILES) {
            // Skip whitespace and commas.
            while (i < raw.len and (raw[i] == ' ' or raw[i] == ',' or raw[i] == '\n')) : (i += 1) {}
            if (i >= raw.len or raw[i] == ']') break;
            if (raw[i] != '"') break;
            i += 1; // skip opening quote
            const start = i;
            while (i < raw.len and raw[i] != '"') : (i += 1) {}
            if (i >= raw.len) break;
            const name = raw[start..i];
            i += 1; // skip closing quote
            if (name.len > fixture_profile_bufs[0].len) continue;
            @memcpy(fixture_profile_bufs[fixture_profile_count][0..name.len], name);
            fixture_profile_lens[fixture_profile_count] = name.len;
            fixture_profile_count += 1;
        }
    }

    return fixture_browser_name_len > 0;
}

fn parseDestinations(raw: []const u8) void {
    dest_count = 0;
    var i: usize = 0;
    while (i < raw.len and raw[i] != '[') : (i += 1) {}
    if (i >= raw.len) return;
    i += 1;

    while (i < raw.len and dest_count < MAX_DESTINATIONS) {
        while (i < raw.len and (raw[i] == ' ' or raw[i] == ',' or raw[i] == '\n')) : (i += 1) {}
        if (i >= raw.len or raw[i] == ']') break;
        if (raw[i] != '"') break;
        i += 1;
        const start = i;
        while (i < raw.len and raw[i] != '"') : (i += 1) {}
        if (i >= raw.len) break;
        const name = raw[start..i];
        i += 1;
        if (name.len > dest_name_bufs[0].len) continue;
        @memcpy(dest_name_bufs[dest_count][0..name.len], name);
        dest_name_lens[dest_count] = name.len;
        dest_count += 1;
    }
}

// =========================================================================
// Build and show the wizard UI
// =========================================================================

fn buildAndShow(parent: ?*gtk.Window) void {
    const window = gtk.Window.new();
    window.setTitle("Import Browser Data");
    window.setDefaultSize(560, 320);
    window.setModal(1);
    window.setDestroyWithParent(1);
    if (parent) |p| {
        window.setTransientFor(p);
    }
    wizard_window = window;

    // Connect destroy signal to reset wizard_active.
    _ = gtk.Widget.signals.destroy.connect(window.as(gtk.Widget), void, onWizardDestroy, {}, .{});

    // Title label (accessibility name: "Import Browser Data").
    const title_label = gtk.Label.new("Import Browser Data");
    title_label.as(gtk.Widget).addCssClass("title-1");
    title_label.as(gtk.Widget).setHalign(.start);

    // Step indicator.
    const slabel = gtk.Label.new("Step 1 of 3");
    slabel.as(gtk.Widget).addCssClass("dim-label");
    slabel.as(gtk.Widget).setHalign(.start);
    step_label = slabel;

    // ---- Step 1: Source browser ----
    const step1_box = gtk.Box.new(.vertical, 8);
    step1_box.as(gtk.Widget).setMarginStart(18);
    step1_box.as(gtk.Widget).setMarginEnd(18);
    step1_box.as(gtk.Widget).setMarginTop(8);

    const source_label = gtk.Label.new("Source");
    source_label.as(gtk.Widget).setHalign(.start);
    step1_box.append(source_label.as(gtk.Widget));

    var browser_name_z: [257:0]u8 = undefined;
    @memcpy(browser_name_z[0..fixture_browser_name_len], fixture_browser_name_buf[0..fixture_browser_name_len]);
    browser_name_z[fixture_browser_name_len] = 0;
    const browser_label = gtk.Label.new(@ptrCast(&browser_name_z));
    browser_label.as(gtk.Widget).setHalign(.start);
    browser_label.as(gtk.Widget).addCssClass("heading");
    step1_box.append(browser_label.as(gtk.Widget));

    // ---- Step 2: Source profiles ----
    const step2_box = gtk.Box.new(.vertical, 8);
    step2_box.as(gtk.Widget).setMarginStart(18);
    step2_box.as(gtk.Widget).setMarginEnd(18);
    step2_box.as(gtk.Widget).setMarginTop(8);

    const profiles_title = gtk.Label.new("Source Profiles");
    profiles_title.as(gtk.Widget).setHalign(.start);
    profiles_title.as(gtk.Widget).addCssClass("heading");
    step2_box.append(profiles_title.as(gtk.Widget));

    var pi: usize = 0;
    while (pi < fixture_profile_count) : (pi += 1) {
        const name = fixtureProfileName(pi);
        var name_z: [129:0]u8 = undefined;
        @memcpy(name_z[0..name.len], name);
        name_z[name.len] = 0;
        const cb = gtk.CheckButton.newWithLabel(@ptrCast(&name_z));
        cb.setActive(1);
        step2_box.append(cb.as(gtk.Widget));
    }

    // ---- Step 3: Data types + destination ----
    const step3_box = gtk.Box.new(.vertical, 8);
    step3_box.as(gtk.Widget).setMarginStart(18);
    step3_box.as(gtk.Widget).setMarginEnd(18);
    step3_box.as(gtk.Widget).setMarginTop(8);

    const dest_title = gtk.Label.new("cmux destination");
    dest_title.as(gtk.Widget).setHalign(.start);
    dest_title.as(gtk.Widget).addCssClass("heading");
    step3_box.append(dest_title.as(gtk.Widget));

    // Radio buttons.
    const sep_radio = gtk.CheckButton.newWithLabel("Separate profiles");
    sep_radio.as(gtk.Widget).setName("Separate profiles");
    separate_radio = sep_radio;

    const mrg_radio = gtk.CheckButton.newWithLabel("Merge into one");
    mrg_radio.as(gtk.Widget).setName("Merge into one");
    mrg_radio.setGroup(sep_radio);

    if (fixture_profile_count > 1) {
        sep_radio.setActive(1);
    } else {
        mrg_radio.setActive(1);
    }

    _ = gtk.CheckButton.signals.toggled.connect(sep_radio, void, onSeparateRadioToggled, {}, .{});

    const mode_box = gtk.Box.new(.vertical, 6);
    mode_box.append(sep_radio.as(gtk.Widget));
    mode_box.append(mrg_radio.as(gtk.Widget));
    if (fixture_profile_count <= 1) {
        mode_box.as(gtk.Widget).setVisible(0);
    }
    step3_box.append(mode_box.as(gtk.Widget));

    // Separate destination rows.
    const sep_rows = gtk.Box.new(.vertical, 6);
    separate_rows_box = sep_rows;
    buildSeparateDestinationRows(sep_rows);
    step3_box.append(sep_rows.as(gtk.Widget));

    // Merge destination row.
    const mrg_row = gtk.Box.new(.horizontal, 6);
    merge_row_box = mrg_row;
    buildMergeDestinationRow(mrg_row);
    step3_box.append(mrg_row.as(gtk.Widget));

    updateDestinationVisibility();

    // Help label.
    const help_label = gtk.Label.new("Missing cmux profiles are created when import starts.");
    help_label.as(gtk.Widget).addCssClass("dim-label");
    help_label.as(gtk.Widget).setHalign(.start);
    help_label.as(gtk.Widget).setWrap(1);
    step3_box.append(help_label.as(gtk.Widget));

    // Data type checkboxes.
    const cookies_cb = gtk.CheckButton.newWithLabel("Cookies (site sign-ins)");
    cookies_cb.as(gtk.Widget).setName("BrowserImportCookiesCheckbox");
    cookies_cb.setActive(1);
    _ = gtk.CheckButton.signals.toggled.connect(cookies_cb, void, onCookiesToggled, {}, .{});
    step3_box.append(cookies_cb.as(gtk.Widget));

    const history_cb = gtk.CheckButton.newWithLabel("History (visited pages)");
    history_cb.as(gtk.Widget).setName("BrowserImportHistoryCheckbox");
    history_cb.setActive(1);
    _ = gtk.CheckButton.signals.toggled.connect(history_cb, void, onHistoryToggled, {}, .{});
    step3_box.append(history_cb.as(gtk.Widget));

    const additional_cb = gtk.CheckButton.newWithLabel("Additional data (bookmarks, settings, extensions)");
    additional_cb.as(gtk.Widget).setName("BrowserImportAdditionalDataCheckbox");
    additional_cb.setActive(0);
    _ = gtk.CheckButton.signals.toggled.connect(additional_cb, void, onAdditionalDataToggled, {}, .{});
    step3_box.append(additional_cb.as(gtk.Widget));

    // ---- Stack ----
    const stack = gtk.Stack.new();
    stack.as(gtk.Widget).setVexpand(1);
    stack.addNamed(step1_box.as(gtk.Widget), "step1");
    stack.addNamed(step2_box.as(gtk.Widget), "step2");
    stack.addNamed(step3_box.as(gtk.Widget), "step3");
    stack.setVisibleChildName("step1");
    main_stack = stack;

    // ---- Button row ----
    const button_box = gtk.Box.new(.horizontal, 8);
    button_box.as(gtk.Widget).setHalign(.end);
    button_box.as(gtk.Widget).setMarginStart(18);
    button_box.as(gtk.Widget).setMarginEnd(18);
    button_box.as(gtk.Widget).setMarginBottom(14);
    button_box.as(gtk.Widget).setMarginTop(8);

    const back_btn = gtk.Button.newWithLabel("Back");
    back_btn.as(gtk.Widget).setVisible(0);
    _ = gtk.Button.signals.clicked.connect(back_btn, void, onBackClicked, {}, .{});
    button_box.append(back_btn.as(gtk.Widget));
    back_button = back_btn;

    const cancel_btn = gtk.Button.newWithLabel("Cancel");
    _ = gtk.Button.signals.clicked.connect(cancel_btn, void, onCancelClicked, {}, .{});
    button_box.append(cancel_btn.as(gtk.Widget));

    const primary_btn = gtk.Button.newWithLabel("Next");
    primary_btn.as(gtk.Widget).addCssClass("suggested-action");
    _ = gtk.Button.signals.clicked.connect(primary_btn, void, onPrimaryClicked, {}, .{});
    button_box.append(primary_btn.as(gtk.Widget));
    primary_button = primary_btn;

    // ---- Main layout ----
    const content_box = gtk.Box.new(.vertical, 8);
    content_box.as(gtk.Widget).setMarginTop(16);

    title_label.as(gtk.Widget).setMarginStart(18);
    content_box.append(title_label.as(gtk.Widget));

    slabel.as(gtk.Widget).setMarginStart(18);
    content_box.append(slabel.as(gtk.Widget));

    content_box.append(stack.as(gtk.Widget));
    content_box.append(button_box.as(gtk.Widget));

    window.setChild(content_box.as(gtk.Widget));
    window.as(gtk.Widget).setVisible(1);
}

fn buildSeparateDestinationRows(container: *gtk.Box) void {
    var pi: usize = 0;
    while (pi < fixture_profile_count) : (pi += 1) {
        const profile_name = fixtureProfileName(pi);
        const row = gtk.Box.new(.horizontal, 8);

        var label_z: [129:0]u8 = undefined;
        @memcpy(label_z[0..profile_name.len], profile_name);
        label_z[profile_name.len] = 0;
        const source_label = gtk.Label.new(@ptrCast(&label_z));
        source_label.as(gtk.Widget).setHalign(.start);
        source_label.as(gtk.Widget).setSizeRequest(110, -1);
        row.append(source_label.as(gtk.Widget));

        const arrow_label = gtk.Label.new("\xe2\x86\x92"); // Unicode right arrow
        row.append(arrow_label.as(gtk.Widget));

        // Build destination options.
        const strings = buildDestOptionsStrings(pi);
        const dropdown = gtk.DropDown.newFromStrings(&strings);
        dropdown.setSelected(0);

        // Accessibility name: BrowserImportDestinationPopup-<slug>
        const slug = accessibilitySlug(pi);
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

fn buildMergeDestinationRow(container: *gtk.Box) void {
    const dest_label = gtk.Label.new("Import into");
    dest_label.as(gtk.Widget).setHalign(.start);
    dest_label.as(gtk.Widget).setSizeRequest(110, -1);
    container.append(dest_label.as(gtk.Widget));

    if (dest_count > 0) {
        const strings = buildMergeOptionsStrings();
        const dropdown = gtk.DropDown.newFromStrings(&strings);
        dropdown.setSelected(0);
        dropdown.as(gtk.Widget).setName("BrowserImportDestinationPopup-merge");
        dropdown.as(gtk.Widget).setHexpand(1);
        container.append(dropdown.as(gtk.Widget));
    }
}

fn buildDestOptionsStrings(profile_idx: usize) [MAX_DESTINATIONS + 1:null]?[*:0]const u8 {
    var strings: [MAX_DESTINATIONS + 1:null]?[*:0]const u8 = .{null} ** (MAX_DESTINATIONS + 1);
    var si: usize = 0;

    // Existing destinations (null-terminated via the fixed-size buffers).
    var di: usize = 0;
    while (di < dest_count and si < MAX_DESTINATIONS) : (di += 1) {
        // Ensure null terminator in the buf.
        dest_name_bufs[di][dest_name_lens[di]] = 0;
        strings[si] = @ptrCast(&dest_name_bufs[di]);
        si += 1;
    }

    // "Create <name>" option if the profile name doesn't match any destination.
    const profile_name = fixtureProfileName(profile_idx);
    var found = false;
    di = 0;
    while (di < dest_count) : (di += 1) {
        if (asciiEqlIgnoreCase(profile_name, destName(di))) {
            found = true;
            break;
        }
    }

    if (!found and profile_name.len > 0 and si < MAX_DESTINATIONS) {
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

fn buildMergeOptionsStrings() [MAX_DESTINATIONS + 1:null]?[*:0]const u8 {
    var strings: [MAX_DESTINATIONS + 1:null]?[*:0]const u8 = .{null} ** (MAX_DESTINATIONS + 1);
    var di: usize = 0;
    while (di < dest_count and di < MAX_DESTINATIONS) : (di += 1) {
        dest_name_bufs[di][dest_name_lens[di]] = 0;
        strings[di] = @ptrCast(&dest_name_bufs[di]);
    }
    strings[di] = null;
    return strings;
}

fn accessibilitySlug(profile_idx: usize) []const u8 {
    const profile_name = fixtureProfileName(profile_idx);
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
            if (len > 0 and buf[len - 1] != '-') {
                if (len < buf.len) {
                    buf[len] = '-';
                    len += 1;
                }
            }
        }
    }
    while (len > 0 and buf[len - 1] == '-') : (len -= 1) {}
    if (len == 0) return "profile-0";
    return buf[0..len];
}

fn updateDestinationVisibility() void {
    if (separate_rows_box) |box| {
        box.as(gtk.Widget).setVisible(@intFromBool(destination_mode == .separate_profiles));
    }
    if (merge_row_box) |box| {
        box.as(gtk.Widget).setVisible(@intFromBool(destination_mode == .merge_into_one));
    }
}

// =========================================================================
// Signal handlers (file-level functions, no self parameter needed)
// =========================================================================

fn onWizardDestroy(_: *gtk.Widget) callconv(.c) void {
    wizard_active = false;
    wizard_window = null;
    main_stack = null;
    step_label = null;
    primary_button = null;
    back_button = null;
    separate_radio = null;
    separate_rows_box = null;
    merge_row_box = null;
}

fn onSeparateRadioToggled(_: *gtk.CheckButton) callconv(.c) void {
    if (separate_radio) |radio| {
        destination_mode = if (radio.getActive() != 0) .separate_profiles else .merge_into_one;
        updateDestinationVisibility();
    }
}

fn onCookiesToggled(cb: *gtk.CheckButton) callconv(.c) void {
    cookies_checked = cb.getActive() != 0;
}

fn onHistoryToggled(cb: *gtk.CheckButton) callconv(.c) void {
    history_checked = cb.getActive() != 0;
}

fn onAdditionalDataToggled(cb: *gtk.CheckButton) callconv(.c) void {
    additional_data_checked = cb.getActive() != 0;
}

fn onBackClicked(_: *gtk.Button) callconv(.c) void {
    switch (current_step) {
        .source => return,
        .source_profiles => {
            current_step = .source;
            updateStepUI();
        },
        .data_types => {
            current_step = .source_profiles;
            updateStepUI();
        },
    }
}

fn onCancelClicked(_: *gtk.Button) callconv(.c) void {
    if (wizard_window) |w| w.destroy();
}

fn onPrimaryClicked(_: *gtk.Button) callconv(.c) void {
    switch (current_step) {
        .source => {
            current_step = .source_profiles;
            updateStepUI();
        },
        .source_profiles => {
            current_step = .data_types;
            updateStepUI();
        },
        .data_types => {
            finishImport();
        },
    }
}

fn updateStepUI() void {
    const stack = main_stack orelse return;

    switch (current_step) {
        .source => {
            stack.setVisibleChildName("step1");
            if (step_label) |l| l.setLabel("Step 1 of 3");
            if (back_button) |b| b.as(gtk.Widget).setVisible(0);
            if (primary_button) |b| b.setLabel("Next");
        },
        .source_profiles => {
            stack.setVisibleChildName("step2");
            if (step_label) |l| l.setLabel("Step 2 of 3");
            if (back_button) |b| b.as(gtk.Widget).setVisible(1);
            if (primary_button) |b| b.setLabel("Next");
        },
        .data_types => {
            stack.setVisibleChildName("step3");
            if (step_label) |l| l.setLabel("Step 3 of 3");
            if (back_button) |b| b.as(gtk.Widget).setVisible(1);
            if (primary_button) |b| b.setLabel("Start Import");
        },
    }
}

fn finishImport() void {
    const scope_name = scopeCaptureName(
        cookies_checked,
        history_checked,
        additional_data_checked,
    ) orelse {
        log.warn("no import scope selected", .{});
        return;
    };

    if (capture_mode) {
        writeCaptureJson(scope_name);
        if (wizard_window) |w| w.destroy();
        return;
    }

    log.info("import wizard completed (mode={s}, scope={s})", .{
        if (destination_mode == .separate_profiles) "separate" else "merge",
        scope_name,
    });
    if (wizard_window) |w| w.destroy();
}

fn writeCaptureJson(scope_name: []const u8) void {
    const path = capturePath() orelse return;

    var buf: [8192]u8 = undefined;
    var pos: usize = 0;

    pos = appendStr(&buf, pos, "{") orelse return;

    // "mode"
    const mode_str: []const u8 = if (destination_mode == .separate_profiles)
        "separateProfiles"
    else
        "mergeIntoOne";
    pos = appendStr(&buf, pos, "\"mode\":\"") orelse return;
    pos = appendStr(&buf, pos, mode_str) orelse return;
    pos = appendStr(&buf, pos, "\",") orelse return;

    // "scope"
    pos = appendStr(&buf, pos, "\"scope\":\"") orelse return;
    pos = appendStr(&buf, pos, scope_name) orelse return;
    pos = appendStr(&buf, pos, "\",") orelse return;

    // "entries"
    pos = appendStr(&buf, pos, "\"entries\":[") orelse return;

    if (destination_mode == .separate_profiles) {
        var pi: usize = 0;
        while (pi < fixture_profile_count) : (pi += 1) {
            if (pi > 0) {
                pos = appendStr(&buf, pos, ",") orelse return;
            }
            const profile_name = fixtureProfileName(pi);

            // Determine destination.
            var dest_kind: []const u8 = "create";
            var dest_name_out: []const u8 = profile_name;

            var di: usize = 0;
            while (di < dest_count) : (di += 1) {
                if (asciiEqlIgnoreCase(profile_name, destName(di))) {
                    dest_kind = "existing";
                    dest_name_out = destName(di);
                    break;
                }
            }

            pos = appendStr(&buf, pos, "{\"sourceProfiles\":[\"") orelse return;
            pos = appendStr(&buf, pos, profile_name) orelse return;
            pos = appendStr(&buf, pos, "\"],\"destinationKind\":\"") orelse return;
            pos = appendStr(&buf, pos, dest_kind) orelse return;
            pos = appendStr(&buf, pos, "\",\"destinationName\":\"") orelse return;
            pos = appendStr(&buf, pos, dest_name_out) orelse return;
            pos = appendStr(&buf, pos, "\"}") orelse return;
        }
    } else {
        // Merge mode: one entry with all profiles.
        pos = appendStr(&buf, pos, "{\"sourceProfiles\":[") orelse return;
        var pi: usize = 0;
        while (pi < fixture_profile_count) : (pi += 1) {
            if (pi > 0) {
                pos = appendStr(&buf, pos, ",") orelse return;
            }
            pos = appendStr(&buf, pos, "\"") orelse return;
            pos = appendStr(&buf, pos, fixtureProfileName(pi)) orelse return;
            pos = appendStr(&buf, pos, "\"") orelse return;
        }

        var merge_dest: []const u8 = "Default";
        if (dest_count > 0 and merge_dest_index < dest_count) {
            merge_dest = destName(@intCast(merge_dest_index));
        }

        pos = appendStr(&buf, pos, "],\"destinationKind\":\"existing\",\"destinationName\":\"") orelse return;
        pos = appendStr(&buf, pos, merge_dest) orelse return;
        pos = appendStr(&buf, pos, "\"}") orelse return;
    }

    pos = appendStr(&buf, pos, "]}") orelse return;

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

// =========================================================================
// Helpers
// =========================================================================

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
