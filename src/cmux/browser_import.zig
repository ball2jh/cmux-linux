//! Browser import plan resolution and presentation logic.
//!
//! Ports the macOS `BrowserImportPlanResolver`, `BrowserImportStep3Presentation`,
//! `BrowserImportSourceProfilesPresentation`, and `BrowserImportHintPresentation`.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ===========================================================================
// Data types
// ===========================================================================

pub const Uuid = [36]u8;

pub fn uuidFromString(s: []const u8) Uuid {
    var result: Uuid = undefined;
    @memcpy(&result, s[0..36]);
    return result;
}

pub const BrowserProfileDefinition = struct {
    id: Uuid,
    display_name: []const u8,
    is_built_in_default: bool = false,
};

pub const InstalledBrowserProfile = struct {
    display_name: []const u8,
    root_path: []const u8,
    is_default: bool,
};

pub const DestinationMode = enum {
    single_destination,
    separate_profiles,
    merge_into_one,
};

pub const DestinationRequest = union(enum) {
    existing: Uuid,
    create_named: []const u8,
};

pub const ExecutionEntry = struct {
    source_profiles: []const InstalledBrowserProfile,
    destination: DestinationRequest,
};

pub const ExecutionPlan = struct {
    mode: DestinationMode,
    entries: []const ExecutionEntry,
};

// ===========================================================================
// BrowserImportPlanResolver
// ===========================================================================

/// Compute a default import plan.
/// Multiple sources -> separate mode; single source -> single destination.
/// Mirrors `BrowserImportPlanResolver.defaultPlan`.
pub fn defaultPlan(
    allocator: Allocator,
    selected_source_profiles: []const InstalledBrowserProfile,
    destination_profiles: []const BrowserProfileDefinition,
    preferred_single_destination_profile_id: Uuid,
) !ExecutionPlan {
    if (selected_source_profiles.len == 0) {
        return ExecutionPlan{
            .mode = .single_destination,
            .entries = &.{},
        };
    }

    if (selected_source_profiles.len <= 1) {
        const source = selected_source_profiles[0];
        const dest: DestinationRequest = if (matchingDestinationProfile(source.display_name, destination_profiles)) |match|
            .{ .existing = match.id }
        else
            .{ .existing = preferred_single_destination_profile_id };

        const entries = try allocator.alloc(ExecutionEntry, 1);
        entries[0] = .{
            .source_profiles = selected_source_profiles[0..1],
            .destination = dest,
        };
        return ExecutionPlan{
            .mode = .single_destination,
            .entries = entries,
        };
    }

    return separateProfilesPlan(allocator, selected_source_profiles, destination_profiles);
}

/// Build a plan that maps each source profile to a separate destination.
/// Mirrors `BrowserImportPlanResolver.separateProfilesPlan`.
pub fn separateProfilesPlan(
    allocator: Allocator,
    selected_source_profiles: []const InstalledBrowserProfile,
    destination_profiles: []const BrowserProfileDefinition,
) !ExecutionPlan {
    // Build set of reserved names.
    var reserved = std.StringHashMap(void).init(allocator);
    defer reserved.deinit();
    for (destination_profiles) |p| {
        const normalized = normalizedProfileName(p.display_name);
        if (normalized.len > 0) {
            try reserved.put(normalized, {});
        }
    }

    var entries = std.ArrayListUnmanaged(ExecutionEntry){};
    defer entries.deinit(allocator);

    for (selected_source_profiles, 0..) |profile, i| {
        if (matchingDestinationProfile(profile.display_name, destination_profiles)) |match| {
            try entries.append(allocator, .{
                .source_profiles = selected_source_profiles[i .. i + 1],
                .destination = .{ .existing = match.id },
            });
        } else {
            const create_name = try nextCreateName(allocator, profile.display_name, &reserved);
            try reserved.put(normalizedProfileName(create_name), {});
            try entries.append(allocator, .{
                .source_profiles = selected_source_profiles[i .. i + 1],
                .destination = .{ .create_named = create_name },
            });
        }
    }

    return ExecutionPlan{
        .mode = .separate_profiles,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn matchingDestinationProfile(
    source_name: []const u8,
    destination_profiles: []const BrowserProfileDefinition,
) ?*const BrowserProfileDefinition {
    const trimmed_source = std.mem.trim(u8, source_name, " \t\n\r");
    if (trimmed_source.len == 0) return null;
    for (destination_profiles) |*p| {
        const trimmed_dest = std.mem.trim(u8, p.display_name, " \t\n\r");
        if (asciiEqlIgnoreCase(trimmed_source, trimmed_dest)) {
            return p;
        }
    }
    return null;
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

fn nextCreateName(
    allocator: Allocator,
    base_name: []const u8,
    reserved: *const std.StringHashMap(void),
) ![]const u8 {
    const trimmed = std.mem.trim(u8, base_name, " \t\n\r");
    const resolved = if (trimmed.len == 0) "Profile" else trimmed;

    if (!containsIgnoreCase(reserved, resolved)) {
        return resolved;
    }

    var suffix: u32 = 2;
    while (true) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s} ({d})", .{ resolved, suffix });
        if (!containsIgnoreCase(reserved, candidate)) {
            return candidate;
        }
        allocator.free(candidate);
    }
}

/// Check if the hash map contains a key that case-insensitively matches `name`.
fn containsIgnoreCase(map: *const std.StringHashMap(void), name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t\n\r");
    var iter = map.keyIterator();
    while (iter.next()) |key_ptr| {
        if (asciiEqlIgnoreCase(std.mem.trim(u8, key_ptr.*, " \t\n\r"), trimmed)) return true;
    }
    return false;
}

fn normalizedProfileName(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\n\r");
}

// ===========================================================================
// BrowserImportStep3Presentation
// ===========================================================================

pub const Step3Presentation = struct {
    shows_mode_selector: bool,
    shows_separate_rows: bool,
    shows_single_destination_picker: bool,

    pub fn init(plan: ExecutionPlan) Step3Presentation {
        var has_multi_source = false;
        for (plan.entries) |e| {
            if (e.source_profiles.len > 1) {
                has_multi_source = true;
                break;
            }
        }
        return .{
            .shows_mode_selector = plan.entries.len > 1 or has_multi_source,
            .shows_separate_rows = plan.mode == .separate_profiles,
            .shows_single_destination_picker = plan.mode != .separate_profiles,
        };
    }
};

// ===========================================================================
// BrowserImportSourceProfilesPresentation
// ===========================================================================

pub const SourceProfilesPresentation = struct {
    scroll_height: u32,
    shows_help_text: bool,

    pub fn init(profile_count: u32) SourceProfilesPresentation {
        const visible_rows: u32 = @min(@max(profile_count, 1), 5);
        const content_height: u32 = visible_rows * 26 + 14;
        return .{
            .scroll_height = @max(76, content_height),
            .shows_help_text = profile_count > 1,
        };
    }
};

// ===========================================================================
// BrowserImportHintPresentation
// ===========================================================================

pub const HintVariant = enum {
    inline_strip,
    floating_card,
    toolbar_chip,
    settings_only,
};

pub const BlankTabPlacement = enum {
    hidden,
    inline_strip,
    floating_card,
    toolbar_chip,
};

pub const SettingsStatus = enum {
    visible,
    hidden,
    settings_only,
};

pub const HintPresentation = struct {
    blank_tab_placement: BlankTabPlacement,
    settings_status: SettingsStatus,

    pub fn init(
        variant: HintVariant,
        show_on_blank_tabs: bool,
        is_dismissed: bool,
    ) HintPresentation {
        if (variant == .settings_only) {
            return .{
                .blank_tab_placement = .hidden,
                .settings_status = .settings_only,
            };
        }

        if (!show_on_blank_tabs or is_dismissed) {
            return .{
                .blank_tab_placement = .hidden,
                .settings_status = .hidden,
            };
        }

        const placement: BlankTabPlacement = switch (variant) {
            .inline_strip => .inline_strip,
            .floating_card => .floating_card,
            .toolbar_chip => .toolbar_chip,
            .settings_only => .hidden,
        };

        return .{
            .blank_tab_placement = placement,
            .settings_status = .visible,
        };
    }
};

/// Default hint settings — mirrors `BrowserImportHintSettings`.
pub const HintSettings = struct {
    pub const default_variant: HintVariant = .toolbar_chip;
    pub const default_show_on_blank_tabs: bool = true;
    pub const default_dismissed: bool = false;

    /// Compute the default presentation (no stored preferences).
    pub fn defaultPresentation() HintPresentation {
        return HintPresentation.init(
            default_variant,
            default_show_on_blank_tabs,
            default_dismissed,
        );
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

// ---- defaultPlan tests ----

test "default plan uses separate mode for multiple source profiles" {
    const allocator = testing.allocator;
    const default_profile_id = uuidFromString("52B43C05-4A1D-45D3-8FD5-9EF94952E445");
    const dest_profiles = [_]BrowserProfileDefinition{
        .{ .id = default_profile_id, .display_name = "Default", .is_built_in_default = true },
    };
    const source_profiles = [_]InstalledBrowserProfile{
        .{ .display_name = "You", .root_path = "/tmp/browser-import-you", .is_default = true },
        .{ .display_name = "austin", .root_path = "/tmp/browser-import-austin", .is_default = false },
    };

    const plan = try defaultPlan(allocator, &source_profiles, &dest_profiles, default_profile_id);
    defer allocator.free(plan.entries);

    try testing.expectEqual(DestinationMode.separate_profiles, plan.mode);
    try testing.expectEqual(@as(usize, 2), plan.entries.len);
    try testing.expectEqualStrings("You", plan.entries[0].source_profiles[0].display_name);
    try testing.expectEqualStrings("austin", plan.entries[1].source_profiles[0].display_name);
}

test "default plan uses single destination for single source profile" {
    const allocator = testing.allocator;
    const default_profile_id = uuidFromString("52B43C05-4A1D-45D3-8FD5-9EF94952E445");
    const source_profiles = [_]InstalledBrowserProfile{
        .{ .display_name = "You", .root_path = "/tmp/browser-import-single", .is_default = true },
    };

    const plan = try defaultPlan(allocator, &source_profiles, &.{}, default_profile_id);
    defer allocator.free(plan.entries);

    try testing.expectEqual(DestinationMode.single_destination, plan.mode);
    try testing.expectEqual(@as(usize, 1), plan.entries.len);
    try testing.expectEqualStrings("You", plan.entries[0].source_profiles[0].display_name);
}

// ---- separateProfilesPlan tests ----

test "separate plan reuses existing same-named destination profiles" {
    const allocator = testing.allocator;
    const work_id = uuidFromString("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE");
    const dest_profiles = [_]BrowserProfileDefinition{
        .{ .id = work_id, .display_name = "You" },
    };
    // Source has leading/trailing whitespace — should still match.
    const source_profiles = [_]InstalledBrowserProfile{
        .{ .display_name = " you ", .root_path = "/tmp/browser-import-match", .is_default = true },
    };

    const plan = try separateProfilesPlan(allocator, &source_profiles, &dest_profiles);
    defer allocator.free(plan.entries);

    try testing.expectEqual(@as(usize, 1), plan.entries.len);
    switch (plan.entries[0].destination) {
        .existing => |id| try testing.expect(std.mem.eql(u8, &id, &work_id)),
        else => return error.TestUnexpectedResult,
    }
}

test "separate plan uses stable create names when two source profiles share display name" {
    const allocator = testing.allocator;
    const source_profiles = [_]InstalledBrowserProfile{
        .{ .display_name = "Work", .root_path = "/tmp/browser-import-work-1", .is_default = true },
        .{ .display_name = "Work", .root_path = "/tmp/browser-import-work-2", .is_default = false },
    };

    const plan = try separateProfilesPlan(allocator, &source_profiles, &.{});
    defer {
        // Free allocated name strings for .create_named entries.
        for (plan.entries) |e| {
            switch (e.destination) {
                .create_named => |name| {
                    // Only free if it was allocated (contains parenthetical suffix).
                    if (std.mem.indexOf(u8, name, "(") != null) {
                        allocator.free(name);
                    }
                },
                else => {},
            }
        }
        allocator.free(plan.entries);
    }

    try testing.expectEqual(@as(usize, 2), plan.entries.len);
    switch (plan.entries[0].destination) {
        .create_named => |name| try testing.expectEqualStrings("Work", name),
        else => return error.TestUnexpectedResult,
    }
    switch (plan.entries[1].destination) {
        .create_named => |name| try testing.expectEqualStrings("Work (2)", name),
        else => return error.TestUnexpectedResult,
    }
}

// ---- Step3Presentation tests ----

test "step3 presentation shows per-profile rows when plan uses separate mode" {
    const source_profiles = [_]InstalledBrowserProfile{
        .{ .display_name = "You", .root_path = "/tmp/browser-import-presentation-separate", .is_default = true },
    };
    const entries = [_]ExecutionEntry{
        .{
            .source_profiles = &source_profiles,
            .destination = .{ .create_named = "You" },
        },
    };
    const presentation = Step3Presentation.init(.{
        .mode = .separate_profiles,
        .entries = &entries,
    });

    try testing.expect(presentation.shows_separate_rows);
    try testing.expect(!presentation.shows_single_destination_picker);
}

test "step3 presentation shows single destination picker when plan uses merge mode" {
    const presentation = Step3Presentation.init(.{
        .mode = .merge_into_one,
        .entries = &.{},
    });

    try testing.expect(!presentation.shows_separate_rows);
    try testing.expect(presentation.shows_single_destination_picker);
}

// ---- SourceProfilesPresentation tests ----

test "source profiles presentation shrinks list for small profile counts" {
    const presentation = SourceProfilesPresentation.init(2);
    try testing.expectEqual(@as(u32, 76), presentation.scroll_height);
    try testing.expect(presentation.shows_help_text);
}

test "source profiles presentation caps list height and hides help for single profile" {
    const single = SourceProfilesPresentation.init(1);
    const many = SourceProfilesPresentation.init(9);

    try testing.expectEqual(@as(u32, 76), single.scroll_height);
    try testing.expect(!single.shows_help_text);
    try testing.expectEqual(@as(u32, 144), many.scroll_height);
    try testing.expect(many.shows_help_text);
}

// ---- HintPresentation tests ----

test "browser import hint settings default to toolbar chip" {
    const presentation = HintSettings.defaultPresentation();
    try testing.expectEqual(BlankTabPlacement.toolbar_chip, presentation.blank_tab_placement);
    try testing.expectEqual(SettingsStatus.visible, presentation.settings_status);
}

test "browser import hint presentation hides blank tab hint when dismissed" {
    const presentation = HintPresentation.init(.floating_card, true, true);
    try testing.expectEqual(BlankTabPlacement.hidden, presentation.blank_tab_placement);
    try testing.expectEqual(SettingsStatus.hidden, presentation.settings_status);
}

test "browser import hint presentation uses toolbar chip when enabled" {
    const presentation = HintPresentation.init(.toolbar_chip, true, false);
    try testing.expectEqual(BlankTabPlacement.toolbar_chip, presentation.blank_tab_placement);
    try testing.expectEqual(SettingsStatus.visible, presentation.settings_status);
}

test "browser import hint presentation settings only variant stays in settings" {
    const presentation = HintPresentation.init(.settings_only, true, false);
    try testing.expectEqual(BlankTabPlacement.hidden, presentation.blank_tab_placement);
    try testing.expectEqual(SettingsStatus.settings_only, presentation.settings_status);
}

// ── Additional browser import tests ──────────────────────────────────

test "hint presentation inline strip variant" {
    const presentation = HintPresentation.init(.inline_strip, true, false);
    try testing.expectEqual(BlankTabPlacement.inline_strip, presentation.blank_tab_placement);
    try testing.expectEqual(SettingsStatus.visible, presentation.settings_status);
}

test "hint presentation floating card variant" {
    const presentation = HintPresentation.init(.floating_card, true, false);
    try testing.expectEqual(BlankTabPlacement.floating_card, presentation.blank_tab_placement);
    try testing.expectEqual(SettingsStatus.visible, presentation.settings_status);
}

test "hint presentation hidden when show_on_blank_tabs is false" {
    const presentation = HintPresentation.init(.toolbar_chip, false, false);
    try testing.expectEqual(BlankTabPlacement.hidden, presentation.blank_tab_placement);
    try testing.expectEqual(SettingsStatus.hidden, presentation.settings_status);
}

test "source profiles presentation for zero profiles" {
    const presentation = SourceProfilesPresentation.init(0);
    try testing.expectEqual(@as(u32, 76), presentation.scroll_height);
    try testing.expect(!presentation.shows_help_text);
}

test "source profiles presentation for three profiles" {
    const presentation = SourceProfilesPresentation.init(3);
    try testing.expect(presentation.scroll_height >= 76);
    try testing.expect(presentation.shows_help_text);
}

test "step3 presentation shows mode selector for multi-entry plan" {
    const source1 = [_]InstalledBrowserProfile{
        .{ .display_name = "A", .root_path = "/tmp/a", .is_default = true },
    };
    const source2 = [_]InstalledBrowserProfile{
        .{ .display_name = "B", .root_path = "/tmp/b", .is_default = false },
    };
    const entries = [_]ExecutionEntry{
        .{ .source_profiles = &source1, .destination = .{ .create_named = "A" } },
        .{ .source_profiles = &source2, .destination = .{ .create_named = "B" } },
    };
    const presentation = Step3Presentation.init(.{
        .mode = .separate_profiles,
        .entries = &entries,
    });
    try testing.expect(presentation.shows_mode_selector);
}

test "step3 presentation single destination mode" {
    const source = [_]InstalledBrowserProfile{
        .{ .display_name = "You", .root_path = "/tmp/you", .is_default = true },
    };
    const entries = [_]ExecutionEntry{
        .{ .source_profiles = &source, .destination = .{ .create_named = "You" } },
    };
    const presentation = Step3Presentation.init(.{
        .mode = .single_destination,
        .entries = &entries,
    });
    try testing.expect(!presentation.shows_separate_rows);
    try testing.expect(presentation.shows_single_destination_picker);
}

test "asciiEqlIgnoreCase basic cases" {
    try testing.expect(asciiEqlIgnoreCase("Hello", "hello"));
    try testing.expect(asciiEqlIgnoreCase("WORK", "work"));
    try testing.expect(!asciiEqlIgnoreCase("a", "b"));
    try testing.expect(!asciiEqlIgnoreCase("abc", "ab"));
}
