/// Lightweight parser for the Ghostty config file that extracts only the
/// appearance/UI fields cmux needs. Mirrors macOS GhosttyConfig.swift.
const std = @import("std");
const Allocator = std.mem.Allocator;
const RGB = @import("../terminal/color.zig").RGB;
const internal_os = @import("../os/main.zig");
const global_state = &@import("../global.zig").state;
const color_utils = @import("color_utils.zig");

const log = std.log.scoped(.cmux_config);

pub const ColorSchemePreference = enum {
    light,
    dark,
};

pub const GhosttyConfig = struct {
    // Font
    font_family: []const u8 = "monospace",
    font_size: f64 = 12,

    // Theme
    theme: ?[]const u8 = null,
    working_directory: ?[]const u8 = null,
    scrollback_limit: u32 = 10000,

    // Core colors (defaults match macOS GhosttyConfig.swift)
    background_color: RGB = RGB.parse("#272822") catch unreachable,
    background_opacity: f64 = 1.0,
    foreground_color: RGB = RGB.parse("#fdfff1") catch unreachable,
    cursor_color: RGB = RGB.parse("#c0c1b5") catch unreachable,
    cursor_text_color: RGB = RGB.parse("#8d8e82") catch unreachable,
    selection_background: RGB = RGB.parse("#57584f") catch unreachable,
    selection_foreground: RGB = RGB.parse("#fdfff1") catch unreachable,

    // Sidebar appearance
    raw_sidebar_background: ?[]const u8 = null,
    sidebar_background: ?RGB = null,
    sidebar_background_light: ?RGB = null,
    sidebar_background_dark: ?RGB = null,
    sidebar_tint_opacity: ?f64 = null,

    // Split pane appearance
    unfocused_split_opacity: f64 = 0.7,
    unfocused_split_fill: ?RGB = null,
    split_divider_color: ?RGB = null,

    // Palette colors (0-15)
    palette: [16]?RGB = .{null} ** 16,

    // Memory: owns all dynamically allocated strings
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *GhosttyConfig) void {
        self.arena.deinit();
    }

    // -- Computed properties ---------------------------------------------------

    pub fn unfocusedSplitOverlayOpacity(self: *const GhosttyConfig) f64 {
        const clamped = @min(1.0, @max(0.15, self.unfocused_split_opacity));
        return @min(1.0, @max(0.0, 1.0 - clamped));
    }

    pub fn unfocusedSplitOverlayFill(self: *const GhosttyConfig) RGB {
        return self.unfocused_split_fill orelse self.background_color;
    }

    pub fn resolvedSplitDividerColor(self: *const GhosttyConfig) RGB {
        if (self.split_divider_color) |c| return c;
        const is_light = color_utils.isLight(self.background_color);
        return color_utils.darken(self.background_color, if (is_light) 0.08 else 0.4);
    }

    // -- Parsing ---------------------------------------------------------------

    /// Parse config file contents (key=value lines).
    pub fn parse(self: *GhosttyConfig, contents: []const u8) void {
        var line_iter = std.mem.splitScalar(u8, contents, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const raw_value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
                const value = stripQuotes(raw_value);
                self.applyKeyValue(key, value);
            }
        }
    }

    fn applyKeyValue(self: *GhosttyConfig, key: []const u8, value: []const u8) void {
        const alloc = self.arena.allocator();

        if (std.mem.eql(u8, key, "font-family")) {
            self.font_family = alloc.dupe(u8, value) catch return;
        } else if (std.mem.eql(u8, key, "font-size")) {
            self.font_size = std.fmt.parseFloat(f64, value) catch return;
        } else if (std.mem.eql(u8, key, "theme")) {
            self.theme = alloc.dupe(u8, value) catch return;
        } else if (std.mem.eql(u8, key, "working-directory")) {
            self.working_directory = alloc.dupe(u8, value) catch return;
        } else if (std.mem.eql(u8, key, "scrollback-limit")) {
            self.scrollback_limit = std.fmt.parseInt(u32, value, 10) catch return;
        } else if (std.mem.eql(u8, key, "background")) {
            self.background_color = RGB.parse(value) catch return;
        } else if (std.mem.eql(u8, key, "background-opacity")) {
            self.background_opacity = std.fmt.parseFloat(f64, value) catch return;
        } else if (std.mem.eql(u8, key, "foreground")) {
            self.foreground_color = RGB.parse(value) catch return;
        } else if (std.mem.eql(u8, key, "cursor-color")) {
            self.cursor_color = RGB.parse(value) catch return;
        } else if (std.mem.eql(u8, key, "cursor-text")) {
            self.cursor_text_color = RGB.parse(value) catch return;
        } else if (std.mem.eql(u8, key, "selection-background")) {
            self.selection_background = RGB.parse(value) catch return;
        } else if (std.mem.eql(u8, key, "selection-foreground")) {
            self.selection_foreground = RGB.parse(value) catch return;
        } else if (std.mem.eql(u8, key, "palette")) {
            self.parsePaletteEntry(value);
        } else if (std.mem.eql(u8, key, "unfocused-split-opacity")) {
            self.unfocused_split_opacity = std.fmt.parseFloat(f64, value) catch return;
        } else if (std.mem.eql(u8, key, "unfocused-split-fill")) {
            self.unfocused_split_fill = RGB.parse(value) catch return;
        } else if (std.mem.eql(u8, key, "split-divider-color")) {
            self.split_divider_color = RGB.parse(value) catch return;
        } else if (std.mem.eql(u8, key, "sidebar-background")) {
            self.raw_sidebar_background = alloc.dupe(u8, value) catch return;
        } else if (std.mem.eql(u8, key, "sidebar-tint-opacity")) {
            const opacity = std.fmt.parseFloat(f64, value) catch return;
            self.sidebar_tint_opacity = @min(1.0, @max(0.0, opacity));
        }
    }

    fn parsePaletteEntry(self: *GhosttyConfig, value: []const u8) void {
        // Format: "index=hexcolor" e.g. "0=#272822"
        const eq_pos = std.mem.indexOfScalar(u8, value, '=') orelse return;
        const index_str = std.mem.trim(u8, value[0..eq_pos], " \t");
        const color_str = std.mem.trim(u8, value[eq_pos + 1 ..], " \t");
        const index = std.fmt.parseInt(u8, index_str, 10) catch return;
        if (index >= 16) return;
        self.palette[index] = RGB.parse(color_str) catch return;
    }

    // -- Sidebar resolution ----------------------------------------------------

    pub fn resolveSidebarBackground(self: *GhosttyConfig, scheme: ColorSchemePreference) void {
        const raw = self.raw_sidebar_background orelse return;

        const light_resolved = resolveThemeName(raw, .light);
        const dark_resolved = resolveThemeName(raw, .dark);
        const has_dual_mode = !std.mem.eql(u8, light_resolved, dark_resolved);

        if (has_dual_mode) {
            self.sidebar_background_light = RGB.parse(light_resolved) catch null;
            self.sidebar_background_dark = RGB.parse(dark_resolved) catch null;
        }

        const resolved = resolveThemeName(raw, scheme);
        self.sidebar_background = RGB.parse(resolved) catch null;
    }

    // -- Theme resolution ------------------------------------------------------

    /// Resolve a theme name that may contain light:/dark: prefixes.
    /// e.g. "light:Solarized Light,dark:Solarized Dark"
    pub fn resolveThemeName(raw_theme_value: []const u8, scheme: ColorSchemePreference) []const u8 {
        var fallback_theme: ?[]const u8 = null;
        var light_theme: ?[]const u8 = null;
        var dark_theme: ?[]const u8 = null;

        var token_iter = std.mem.splitScalar(u8, raw_theme_value, ',');
        while (token_iter.next()) |token| {
            const entry = std.mem.trim(u8, token, " \t\r\n");
            if (entry.len == 0) continue;

            if (std.mem.indexOfScalar(u8, entry, ':')) |colon_pos| {
                const prefix = std.mem.trim(u8, entry[0..colon_pos], " \t");
                const value = std.mem.trim(u8, entry[colon_pos + 1 ..], " \t");
                if (value.len == 0) continue;

                if (std.ascii.eqlIgnoreCase(prefix, "light")) {
                    if (light_theme == null) light_theme = value;
                } else if (std.ascii.eqlIgnoreCase(prefix, "dark")) {
                    if (dark_theme == null) dark_theme = value;
                } else {
                    if (fallback_theme == null) fallback_theme = value;
                }
            } else {
                if (fallback_theme == null) fallback_theme = entry;
            }
        }

        switch (scheme) {
            .light => if (light_theme) |t| return t,
            .dark => if (dark_theme) |t| return t,
        }

        if (fallback_theme) |t| return t;
        if (dark_theme) |t| return t;
        if (light_theme) |t| return t;
        return std.mem.trim(u8, raw_theme_value, " \t\r\n");
    }

    /// Generate candidate theme names with compatibility aliases.
    /// Handles "Builtin X" → "X" and Solarized ↔ iTerm2 aliases.
    pub fn themeNameCandidates(alloc: Allocator, raw_name: []const u8) !std.ArrayList([]const u8) {
        var candidates: std.ArrayList([]const u8) = .{};
        errdefer candidates.deinit(alloc);

        const CompatGroup = struct { []const u8, []const u8 };
        const compat_groups: []const CompatGroup = &.{
            .{ "Solarized Light", "iTerm2 Solarized Light" },
            .{ "Solarized Dark", "iTerm2 Solarized Dark" },
        };

        // Process queue for "Builtin X" → "X" stripping
        var queue: std.ArrayList([]const u8) = .{};
        defer queue.deinit(alloc);
        try queue.append(alloc, raw_name);

        while (queue.items.len > 0) {
            const current = queue.pop() orelse break;
            const trimmed = std.mem.trim(u8, current, " \t\r\n");
            if (trimmed.len == 0) continue;

            // Add candidate + aliases
            try appendCandidate(alloc, &candidates,trimmed, compat_groups);

            // Strip "builtin " prefix (case-insensitive)
            if (trimmed.len > 8) {
                if (std.ascii.eqlIgnoreCase(trimmed[0..8], "builtin ")) {
                    const stripped = trimmed[8..];
                    try appendCandidate(alloc, &candidates,stripped, compat_groups);
                    try queue.append(alloc, stripped);
                }
            }

            // Strip " (builtin)" suffix (case-insensitive)
            if (lastIndexOfCaseInsensitive(trimmed, "(builtin)")) |pos| {
                const stripped = std.mem.trimRight(u8, trimmed[0..pos], " \t");
                if (stripped.len > 0) {
                    try appendCandidate(alloc, &candidates,stripped, compat_groups);
                    try queue.append(alloc, stripped);
                }
            }
        }

        return candidates;
    }

    fn appendCandidate(
        alloc: Allocator,
        candidates: *std.ArrayList([]const u8),
        value: []const u8,
        compat_groups: []const struct { []const u8, []const u8 },
    ) !void {
        // Add if not already present
        for (candidates.items) |existing| {
            if (std.mem.eql(u8, existing, value)) return;
        }
        try candidates.append(alloc, value);

        // Add compatibility aliases
        for (compat_groups) |group| {
            const a, const b = group;
            if (std.ascii.eqlIgnoreCase(a, value)) {
                for (candidates.items) |existing| {
                    if (std.mem.eql(u8, existing, b)) return;
                }
                try candidates.append(alloc, b);
            } else if (std.ascii.eqlIgnoreCase(b, value)) {
                for (candidates.items) |existing| {
                    if (std.mem.eql(u8, existing, a)) return;
                }
                try candidates.append(alloc, a);
            }
        }
    }

    /// Load a theme file, searching standard locations.
    pub fn loadTheme(
        self: *GhosttyConfig,
        name: []const u8,
        scheme: ColorSchemePreference,
    ) void {
        const alloc = self.arena.allocator();
        const resolved_name = resolveThemeName(name, scheme);

        var candidates = themeNameCandidates(alloc, resolved_name) catch return;
        defer candidates.deinit(alloc);

        for (candidates.items) |candidate_name| {
            if (self.tryLoadThemeFromPaths(alloc, candidate_name)) return;
        }

        log.warn("theme not found: {s}", .{resolved_name});
    }

    fn tryLoadThemeFromPaths(self: *GhosttyConfig, alloc: Allocator, theme_name: []const u8) bool {
        const cwd = std.fs.cwd();

        // Search each theme directory
        const search_dirs = themeSearchDirs(alloc) catch return false;
        for (search_dirs) |dir_path| {
            const path = std.fs.path.join(alloc, &.{ dir_path, theme_name }) catch continue;
            if (cwd.openFile(path, .{})) |file| {
                defer file.close();
                const stat = file.stat() catch continue;
                if (stat.kind != .file) continue;
                const contents = file.readToEndAlloc(alloc, 1024 * 1024) catch continue;
                self.parse(contents);
                return true;
            } else |_| {}
        }

        return false;
    }

    /// Build list of directories to search for theme files.
    fn themeSearchDirs(alloc: Allocator) ![]const []const u8 {
        var dirs: std.ArrayList([]const u8) = .{};

        // 1. GHOSTTY_RESOURCES_DIR/themes/
        if (std.posix.getenv("GHOSTTY_RESOURCES_DIR")) |res_dir| {
            const path = try std.fs.path.join(alloc, &.{ res_dir, "themes" });
            try dirs.append(alloc, path);
        }

        // 2. Global state resources dir (install prefix)
        if (global_state.resources_dir.app()) |app_dir| {
            const path = try std.fs.path.join(alloc, &.{ app_dir, "themes" });
            try dirs.append(alloc, path);
        }

        // 3. XDG_DATA_DIRS ghostty/themes/
        if (std.posix.getenv("XDG_DATA_DIRS")) |data_dirs| {
            var dir_iter = std.mem.splitScalar(u8, data_dirs, ':');
            while (dir_iter.next()) |data_dir| {
                if (data_dir.len == 0) continue;
                const path = try std.fs.path.join(alloc, &.{ data_dir, "ghostty", "themes" });
                try dirs.append(alloc, path);
            }
        }

        // 4. User ghostty themes (~/.config/ghostty/themes/)
        if (internal_os.xdg.config(alloc, .{ .subdir = "ghostty/themes" })) |path| {
            try dirs.append(alloc, path);
        } else |_| {}

        // 5. User cmux themes (~/.config/cmux/themes/)
        if (internal_os.xdg.config(alloc, .{ .subdir = "cmux/themes" })) |path| {
            try dirs.append(alloc, path);
        } else |_| {}

        return dirs.toOwnedSlice(alloc);
    }

    // -- Full load from disk ---------------------------------------------------

    /// Load config from all standard config file paths, apply theme, resolve sidebar.
    pub fn loadFromDisk(alloc: Allocator, scheme: ColorSchemePreference) !GhosttyConfig {
        var config = GhosttyConfig{
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
        const arena = config.arena.allocator();

        // Config paths in priority order (later overrides earlier)
        const config_paths = &[_]struct { dir: []const u8, file: []const u8 }{
            .{ .dir = "ghostty", .file = "config" },
            .{ .dir = "ghostty", .file = "config.ghostty" },
            .{ .dir = "cmux", .file = "config" },
            .{ .dir = "cmux", .file = "config.ghostty" },
        };

        for (config_paths) |entry| {
            const subdir = std.fs.path.join(arena, &.{ entry.dir, entry.file }) catch continue;
            const path = internal_os.xdg.config(arena, .{ .subdir = subdir }) catch continue;
            if (readConfigFile(arena, path)) |contents| {
                config.parse(contents);
            }
        }

        // Load theme if specified
        if (config.theme) |theme_name| {
            config.loadTheme(theme_name, scheme);
        }

        // Resolve sidebar
        config.resolveSidebarBackground(scheme);

        return config;
    }

    fn readConfigFile(alloc: Allocator, path: []const u8) ?[]const u8 {
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        const stat = file.stat() catch return null;
        if (stat.kind != .file) return null;
        if (stat.size == 0) return null;

        return file.readToEndAlloc(alloc, 10 * 1024 * 1024) catch null;
    }

    /// Case-insensitive search for `needle` in `haystack`, returning the last match position.
    fn lastIndexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
        if (needle.len > haystack.len) return null;
        var i: usize = haystack.len - needle.len;
        while (true) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
            if (i == 0) break;
            i -= 1;
        }
        return null;
    }

    fn stripQuotes(value: []const u8) []const u8 {
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            return value[1 .. value.len - 1];
        }
        return value;
    }
};

// -- Cache -------------------------------------------------------------------

var cache_mutex: std.Thread.Mutex = .{};
var cached_light: ?*GhosttyConfig = null;
var cached_dark: ?*GhosttyConfig = null;

/// Load config, using cache if available.
pub fn load(alloc: Allocator, scheme: ColorSchemePreference, use_cache: bool) !*GhosttyConfig {
    if (use_cache) {
        cache_mutex.lock();
        defer cache_mutex.unlock();
        const cached = switch (scheme) {
            .light => cached_light,
            .dark => cached_dark,
        };
        if (cached) |c| return c;
    }

    const config = try alloc.create(GhosttyConfig);
    config.* = try GhosttyConfig.loadFromDisk(alloc, scheme);

    if (use_cache) {
        cache_mutex.lock();
        defer cache_mutex.unlock();
        switch (scheme) {
            .light => {
                if (cached_light) |old| {
                    old.deinit();
                    alloc.destroy(old);
                }
                cached_light = config;
            },
            .dark => {
                if (cached_dark) |old| {
                    old.deinit();
                    alloc.destroy(old);
                }
                cached_dark = config;
            },
        }
    }

    return config;
}

/// Clear all cached configs.
pub fn invalidateCache(alloc: Allocator) void {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    if (cached_light) |old| {
        old.deinit();
        alloc.destroy(old);
        cached_light = null;
    }
    if (cached_dark) |old| {
        old.deinit();
        alloc.destroy(old);
        cached_dark = null;
    }
}

// -- Tests -------------------------------------------------------------------

test "parse basic key-value pairs" {
    const testing = std.testing;
    var config = GhosttyConfig{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer config.deinit();

    config.parse(
        \\font-family = JetBrains Mono
        \\font-size = 14
        \\background = #ff0000
        \\background-opacity = 0.95
        \\scrollback-limit = 5000
    );

    try testing.expectEqualStrings("JetBrains Mono", config.font_family);
    try testing.expectEqual(@as(f64, 14), config.font_size);
    try testing.expectEqual(RGB{ .r = 255, .g = 0, .b = 0 }, config.background_color);
    try testing.expectEqual(@as(f64, 0.95), config.background_opacity);
    try testing.expectEqual(@as(u32, 5000), config.scrollback_limit);
}

test "parse skips comments and blank lines" {
    const testing = std.testing;
    var config = GhosttyConfig{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer config.deinit();

    config.parse(
        \\# This is a comment
        \\
        \\font-size = 16
        \\# Another comment
        \\background = #00ff00
    );

    try testing.expectEqual(@as(f64, 16), config.font_size);
    try testing.expectEqual(RGB{ .r = 0, .g = 255, .b = 0 }, config.background_color);
}

test "parse palette entries" {
    const testing = std.testing;
    var config = GhosttyConfig{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer config.deinit();

    config.parse(
        \\palette = 0=#272822
        \\palette = 1=#f92672
        \\palette = 15=#f8f8f2
    );

    try testing.expectEqual(RGB{ .r = 0x27, .g = 0x28, .b = 0x22 }, config.palette[0].?);
    try testing.expectEqual(RGB{ .r = 0xf9, .g = 0x26, .b = 0x72 }, config.palette[1].?);
    try testing.expectEqual(RGB{ .r = 0xf8, .g = 0xf8, .b = 0xf2 }, config.palette[15].?);
    try testing.expect(config.palette[2] == null);
}

test "parse strips surrounding quotes" {
    const testing = std.testing;
    var config = GhosttyConfig{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer config.deinit();

    config.parse(
        \\font-family = "Fira Code"
    );

    try testing.expectEqualStrings("Fira Code", config.font_family);
}

test "resolveThemeName with light/dark pairs" {
    try std.testing.expectEqualStrings(
        "Solarized Light",
        GhosttyConfig.resolveThemeName("light:Solarized Light,dark:Solarized Dark", .light),
    );
    try std.testing.expectEqualStrings(
        "Solarized Dark",
        GhosttyConfig.resolveThemeName("light:Solarized Light,dark:Solarized Dark", .dark),
    );
}

test "resolveThemeName with plain name" {
    try std.testing.expectEqualStrings(
        "Monokai",
        GhosttyConfig.resolveThemeName("Monokai", .light),
    );
    try std.testing.expectEqualStrings(
        "Monokai",
        GhosttyConfig.resolveThemeName("Monokai", .dark),
    );
}

test "resolveThemeName fallback to first untagged" {
    try std.testing.expectEqualStrings(
        "FallbackTheme",
        GhosttyConfig.resolveThemeName("FallbackTheme,dark:DarkOne", .light),
    );
}

test "resolveThemeName falls back dark then light" {
    // No fallback, no light → falls back to dark
    try std.testing.expectEqualStrings(
        "OnlyDark",
        GhosttyConfig.resolveThemeName("dark:OnlyDark", .light),
    );
    // No fallback, no dark → falls back to light
    try std.testing.expectEqualStrings(
        "OnlyLight",
        GhosttyConfig.resolveThemeName("light:OnlyLight", .dark),
    );
}

test "themeNameCandidates basic" {
    const alloc = std.testing.allocator;
    var candidates = try GhosttyConfig.themeNameCandidates(alloc, "Dracula");
    defer candidates.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), candidates.items.len);
    try std.testing.expectEqualStrings("Dracula", candidates.items[0]);
}

test "themeNameCandidates strips builtin prefix" {
    const alloc = std.testing.allocator;
    var candidates = try GhosttyConfig.themeNameCandidates(alloc, "Builtin Solarized Dark");
    defer candidates.deinit(alloc);

    // Should have: "Builtin Solarized Dark", "iTerm2 Solarized Dark", "Solarized Dark"
    try std.testing.expect(candidates.items.len >= 3);
    try std.testing.expectEqualStrings("Builtin Solarized Dark", candidates.items[0]);
    // Should contain "Solarized Dark" and its alias
    var found_solarized = false;
    var found_iterm = false;
    for (candidates.items) |item| {
        if (std.mem.eql(u8, item, "Solarized Dark")) found_solarized = true;
        if (std.mem.eql(u8, item, "iTerm2 Solarized Dark")) found_iterm = true;
    }
    try std.testing.expect(found_solarized);
    try std.testing.expect(found_iterm);
}

test "computed unfocusedSplitOverlayOpacity" {
    var config = GhosttyConfig{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer config.deinit();

    // Default 0.7 → overlay = 1.0 - 0.7 = 0.3
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), config.unfocusedSplitOverlayOpacity(), 0.001);

    // Below min clamp (0.15) → overlay = 1.0 - 0.15 = 0.85
    config.unfocused_split_opacity = 0.0;
    try std.testing.expectApproxEqAbs(@as(f64, 0.85), config.unfocusedSplitOverlayOpacity(), 0.001);
}

test "sidebar-tint-opacity clamps to 0-1" {
    const testing = std.testing;
    var config = GhosttyConfig{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer config.deinit();

    config.parse("sidebar-tint-opacity = 1.5");
    try testing.expectEqual(@as(f64, 1.0), config.sidebar_tint_opacity.?);

    config.parse("sidebar-tint-opacity = -0.5");
    try testing.expectEqual(@as(f64, 0.0), config.sidebar_tint_opacity.?);
}
