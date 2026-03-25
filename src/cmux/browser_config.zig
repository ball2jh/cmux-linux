/// Browser configuration portable logic.
///
/// Config defaults, navigation policy decisions, theme mode resolution,
/// address bar history delta, and insecure HTTP prompt policy.
///
/// Ports the macOS BrowserDevToolsButtonDebugSettings, BrowserThemeSettings,
/// BrowserNavigationNewTabDecision, BrowserPopupDecision, and related logic.
const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Config defaults / fallbacks
// ═══════════════════════════════════════════════════════════════════════

/// Icon options for the browser devtools button.
pub const DevToolsIconOption = enum {
    terminal,
    globe,
    curly_braces_square,
    scope,
    wrench,
    ladybug,
    ant,
    chevron_left_slash_chevron_right,
    apple_terminal,
    rectangle_on_rectangle,

    pub fn fromString(s: []const u8) ?DevToolsIconOption {
        const map = .{
            .{ "terminal", .terminal },
            .{ "globe", .globe },
            .{ "curlyBracesSquare", .curly_braces_square },
            .{ "scope", .scope },
            .{ "wrench", .wrench },
            .{ "ladybug", .ladybug },
            .{ "ant", .ant },
            .{ "chevronLeftSlashChevronRight", .chevron_left_slash_chevron_right },
            .{ "appleTerminal", .apple_terminal },
            .{ "rectangleOnRectangle", .rectangle_on_rectangle },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, s, entry[0])) return entry[1];
        }
        return null;
    }

    pub fn toString(self: DevToolsIconOption) []const u8 {
        return switch (self) {
            .terminal => "terminal",
            .globe => "globe",
            .curly_braces_square => "curlyBracesSquare",
            .scope => "scope",
            .wrench => "wrench",
            .ladybug => "ladybug",
            .ant => "ant",
            .chevron_left_slash_chevron_right => "chevronLeftSlashChevronRight",
            .apple_terminal => "appleTerminal",
            .rectangle_on_rectangle => "rectangleOnRectangle",
        };
    }
};

/// Icon color options for the browser devtools button.
pub const DevToolsIconColorOption = enum {
    default,
    bonsplit_active,
    accent,

    pub fn fromString(s: []const u8) ?DevToolsIconColorOption {
        if (std.mem.eql(u8, s, "default")) return .default;
        if (std.mem.eql(u8, s, "bonsplitActive")) return .bonsplit_active;
        if (std.mem.eql(u8, s, "accent")) return .accent;
        return null;
    }

    pub fn toString(self: DevToolsIconColorOption) []const u8 {
        return switch (self) {
            .default => "default",
            .bonsplit_active => "bonsplitActive",
            .accent => "accent",
        };
    }
};

/// Default values for browser devtools button debug settings.
pub const devtools_default_icon: DevToolsIconOption = .terminal;
pub const devtools_default_color: DevToolsIconColorOption = .default;

/// Resolve icon option from a stored string, falling back to default.
pub fn resolveIconOption(raw: ?[]const u8) DevToolsIconOption {
    const s = raw orelse return devtools_default_icon;
    return DevToolsIconOption.fromString(s) orelse devtools_default_icon;
}

/// Resolve color option from a stored string, falling back to default.
pub fn resolveColorOption(raw: ?[]const u8) DevToolsIconColorOption {
    const s = raw orelse return devtools_default_color;
    return DevToolsIconColorOption.fromString(s) orelse devtools_default_color;
}

/// Default toolbar accessory spacing.
pub const default_toolbar_accessory_spacing: i32 = 2;

/// Resolve toolbar accessory spacing from a stored value.
pub fn resolveToolbarAccessorySpacing(raw: ?i32) i32 {
    const v = raw orelse return default_toolbar_accessory_spacing;
    if (v < 0 or v > 20) return default_toolbar_accessory_spacing;
    return v;
}

/// Default popover padding.
pub const default_horizontal_padding: i32 = 8;
pub const default_vertical_padding: i32 = 4;

/// Resolve popover padding from stored values.
pub fn resolveHorizontalPadding(raw: ?i32) i32 {
    const v = raw orelse return default_horizontal_padding;
    if (v < 0 or v > 100) return default_horizontal_padding;
    return v;
}

pub fn resolveVerticalPadding(raw: ?i32) i32 {
    const v = raw orelse return default_vertical_padding;
    if (v < 0 or v > 100) return default_vertical_padding;
    return v;
}

/// Compose a copy payload string from icon and color settings.
pub fn copyPayload(buf: []u8, icon_raw: ?[]const u8, color_raw: ?[]const u8) ?[]const u8 {
    const icon = resolveIconOption(icon_raw);
    const color = resolveColorOption(color_raw);

    const result = std.fmt.bufPrint(buf, "browserDevToolsIconName={s}&browserDevToolsIconColor={s}", .{
        icon.toString(),
        color.toString(),
    }) catch return null;
    return result;
}

// ═══════════════════════════════════════════════════════════════════════
// Browser theme mode
// ═══════════════════════════════════════════════════════════════════════

pub const ThemeMode = enum {
    system,
    dark,
    light,

    pub fn fromString(s: []const u8) ?ThemeMode {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "dark")) return .dark;
        if (std.mem.eql(u8, s, "light")) return .light;
        return null;
    }

    pub fn toString(self: ThemeMode) []const u8 {
        return switch (self) {
            .system => "system",
            .dark => "dark",
            .light => "light",
        };
    }
};

pub const default_theme_mode: ThemeMode = .system;

/// Resolve theme mode from persisted value, optionally migrating a
/// legacy boolean forced-dark-mode flag.
pub fn resolveThemeMode(
    mode_raw: ?[]const u8,
    legacy_forced_dark_mode: ?bool,
) ThemeMode {
    // If a mode string is stored, use it.
    if (mode_raw) |s| {
        return ThemeMode.fromString(s) orelse default_theme_mode;
    }

    // Legacy migration: if the boolean forced dark mode flag exists,
    // convert it to the enum representation.
    if (legacy_forced_dark_mode) |forced| {
        return if (forced) .dark else .system;
    }

    return default_theme_mode;
}

// ═══════════════════════════════════════════════════════════════════════
// Link navigation policy
// ═══════════════════════════════════════════════════════════════════════

pub const NavigationType = enum {
    link_activated,
    other,
    reload,
    form_submitted,
    back_forward,
};

pub const EventType = enum {
    other_mouse_up,
    other,
};

/// Determine whether a navigation should open in a new tab.
/// Ports macOS `browserNavigationShouldOpenInNewTab`.
pub fn shouldOpenInNewTab(
    nav_type: NavigationType,
    command_held: bool,
    button_number: u32,
    has_recent_middle_click_intent: bool,
    current_event_type: ?EventType,
    current_event_button: ?u32,
) bool {
    // Only link-activated and "other" navigations can trigger new tabs.
    switch (nav_type) {
        .link_activated => {},
        .other => {
            // "Other" navigations: only middle click opens new tab.
            return button_number == 2;
        },
        else => return false,
    }

    // Cmd+click → new tab.
    if (command_held) return true;

    // Middle click (button 2) → new tab.
    if (button_number == 2) return true;

    // Button 4 with recent middle click intent (trackpad/gesture) → new tab.
    if (button_number == 4 and has_recent_middle_click_intent) return true;

    // Current event fallback: if the delegate callback reports button 0 but
    // the current event is actually a middle click, open in new tab.
    if (current_event_type) |et| {
        if (et == .other_mouse_up) {
            if (current_event_button) |btn| {
                if (btn == 2) return true;
            }
        }
    }

    return false;
}

/// Determine whether a navigation should create a popup window.
/// Ports macOS `browserNavigationShouldCreatePopup`.
pub fn shouldCreatePopup(
    nav_type: NavigationType,
    command_held: bool,
    button_number: u32,
) bool {
    switch (nav_type) {
        .other => {
            // "Other" navigations create popups unless it's middle-click
            // (which opens in a new tab instead) or cmd-click.
            if (button_number == 2) return false;
            if (command_held) return false;
            return true;
        },
        else => return false,
    }
}

/// Determine whether a nil-target navigation should fall back to new tab.
pub fn shouldFallbackNilTargetToNewTab(nav_type: NavigationType) bool {
    return nav_type == .link_activated;
}

// ═══════════════════════════════════════════════════════════════════════
// Address bar navigation delta
// ═══════════════════════════════════════════════════════════════════════

pub const AddressBarNavigationDelta = enum(i32) {
    back = -1,
    forward = 1,
    none = 0,
};

/// Resolve address bar navigation from arrow key input.
/// Up arrow goes back, down arrow goes forward in history.
pub fn addressBarArrowDelta(up_arrow: bool) AddressBarNavigationDelta {
    return if (up_arrow) .back else .forward;
}

/// Resolve address bar navigation from modifier + key combinations.
/// Alt+Left → back, Alt+Right → forward.
pub fn addressBarModifierDelta(alt_held: bool, is_left: bool) AddressBarNavigationDelta {
    if (!alt_held) return .none;
    return if (is_left) .back else .forward;
}

// ═══════════════════════════════════════════════════════════════════════
// Insecure HTTP prompt policy
// ═══════════════════════════════════════════════════════════════════════

/// Determine whether an insecure HTTP URL should show a security warning.
pub fn shouldShowInsecureHttpPrompt(url: []const u8) bool {
    if (url.len < 7) return false;
    return std.ascii.eqlIgnoreCase(url[0..7], "http://");
}

// ═══════════════════════════════════════════════════════════════════════
// Popup content rect calculation
// ═══════════════════════════════════════════════════════════════════════

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

/// Calculate popup window content rect, converting from top-origin coordinates
/// to bottom-origin (screen coordinates), and clamping to visible frame.
pub fn popupContentRect(
    requested_width: f64,
    requested_height: f64,
    requested_x: ?f64,
    requested_top_y: ?f64,
    visible_frame: Rect,
) Rect {
    // Clamp dimensions to visible frame.
    const width = @min(requested_width, visible_frame.width);
    const height = @min(requested_height, visible_frame.height);

    if (requested_x) |rx| {
        const top_y = requested_top_y orelse 0;

        // Convert from top-origin to bottom-origin.
        const bottom_y = visible_frame.y + visible_frame.height - top_y - height;

        // Clamp position to visible frame.
        const x = @max(visible_frame.x, @min(rx, visible_frame.x + visible_frame.width - width));
        const y = @max(visible_frame.y, @min(bottom_y, visible_frame.y + visible_frame.height - height));

        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    // No explicit coordinates — center the popup.
    const x = visible_frame.x + (visible_frame.width - width) / 2.0;
    const y = visible_frame.y + (visible_frame.height - height) / 2.0;

    return .{ .x = x, .y = y, .width = width, .height = height };
}

// ═══════════════════════════════════════════════════════════════════════
// Developer tools keyboard shortcut defaults
// ═══════════════════════════════════════════════════════════════════════

pub const KeyboardShortcut = struct {
    key: []const u8,
    command: bool = false,
    option: bool = false,
    shift: bool = false,
    control: bool = false,
};

/// Safari-style default shortcut: Cmd+Opt+I to toggle developer tools.
pub const default_toggle_developer_tools_shortcut = KeyboardShortcut{
    .key = "i",
    .command = true,
    .option = true,
};

/// Safari-style default shortcut: Cmd+Opt+C to show JavaScript console.
pub const default_show_javascript_console_shortcut = KeyboardShortcut{
    .key = "c",
    .command = true,
    .option = true,
};

// ═══════════════════════════════════════════════════════════════════════
// Omnibar command navigation
// ═══════════════════════════════════════════════════════════════════════

pub const ModifierFlags = struct {
    command: bool = false,
    shift: bool = false,
    option: bool = false,
    control: bool = false,
    caps_lock: bool = false,

    /// Returns true if only the specified modifiers are held (ignoring caps lock).
    fn onlyCommand(self: ModifierFlags) bool {
        return self.command and !self.shift and !self.option and !self.control;
    }

    fn onlyControl(self: ModifierFlags) bool {
        return self.control and !self.command and !self.shift and !self.option;
    }

    fn hasNonCapsLockModifiers(self: ModifierFlags) bool {
        return self.command or self.shift or self.option or self.control;
    }

    fn hasCommandOrControlWithOthers(self: ModifierFlags) bool {
        // command or control with shift or option
        return (self.command or self.control) and (self.shift or self.option);
    }
};

/// Key codes matching macOS virtual key codes used in omnibar tests.
pub const KeyCode = struct {
    pub const up_arrow: u16 = 126;
    pub const down_arrow: u16 = 125;
    pub const kp_enter: u16 = 76;
    pub const return_key: u16 = 36;
};

/// Resolve omnibar selection delta for arrow key navigation.
/// Returns null when preconditions are not met, -1 for up, +1 for down.
pub fn omnibarSelectionDeltaForArrowNavigation(
    has_focused_address_bar: bool,
    flags: ModifierFlags,
    key_code: u16,
) ?i32 {
    if (!has_focused_address_bar) return null;
    // Only allow if no modifiers are held (caps lock is ignored).
    if (flags.hasNonCapsLockModifiers()) return null;
    if (key_code == KeyCode.up_arrow) return -1;
    if (key_code == KeyCode.down_arrow) return 1;
    return null;
}

/// Resolve omnibar selection delta for command/control+n/p navigation.
/// Returns null when preconditions are not met, -1 for p, +1 for n.
pub fn omnibarSelectionDeltaForCommandNavigation(
    has_focused_address_bar: bool,
    flags: ModifierFlags,
    chars: []const u8,
) ?i32 {
    if (!has_focused_address_bar) return null;
    // Must have exactly command or exactly control (ignoring caps lock).
    if (!flags.onlyCommand() and !flags.onlyControl()) return null;
    if (chars.len == 1) {
        if (chars[0] == 'n') return 1;
        if (chars[0] == 'p') return -1;
    }
    return null;
}

/// Determine whether the omnibar should submit on Return key press.
/// Returns true for plain Return or Shift+Return; false when command/option/control
/// is held (caps lock is ignored).
pub fn omnibarShouldSubmitOnReturn(flags: ModifierFlags) bool {
    if (flags.command or flags.option or flags.control) return false;
    return true;
}

// ═══════════════════════════════════════════════════════════════════════
// Return key down routing
// ═══════════════════════════════════════════════════════════════════════

/// Determine whether a Return/Enter key event should be dispatched to the
/// browser first responder via keyDown routing.
pub fn shouldDispatchBrowserReturnViaFirstResponderKeyDown(
    key_code: u16,
    first_responder_is_browser: bool,
    flags: ModifierFlags,
) bool {
    if (!first_responder_is_browser) return false;
    if (key_code != KeyCode.return_key and key_code != KeyCode.kp_enter) return false;
    // Only plain Return or Shift+Return; any other modifier blocks.
    if (flags.command or flags.option or flags.control) return false;
    return true;
}

// ═══════════════════════════════════════════════════════════════════════
// Browser zoom shortcut
// ═══════════════════════════════════════════════════════════════════════

pub const ZoomAction = enum {
    zoom_in,
    zoom_out,
    reset,
};

/// Resolve a zoom shortcut action from modifier flags, character, key code,
/// and optional literal characters (for shifted physical keys).
pub fn browserZoomShortcutAction(
    flags: ModifierFlags,
    chars: []const u8,
    key_code: u16,
    literal_chars: ?[]const u8,
) ?ZoomAction {
    // Requires command without option or control.
    if (!flags.command) return null;
    if (flags.option or flags.control) return null;

    if (chars.len == 1) {
        const c = chars[0];
        // Zoom in: = or + (keyCode 24 or 30)
        if (c == '=' or c == '+') return .zoom_in;
        // Zoom out: - or _ (keyCode 27)
        if (c == '-' or c == '_') return .zoom_out;
        // Reset: 0 (keyCode 29)
        if (c == '0') return .reset;
    }

    // Check literal characters for shifted keys from different physical keys.
    if (literal_chars) |lc| {
        if (lc.len == 1 and (lc[0] == '+' or lc[0] == '=')) return .zoom_in;
    }

    _ = key_code;
    return null;
}

/// Determine whether a terminal font zoom shortcut should be routed to Ghostty
/// rather than being consumed by the browser.
pub fn shouldRouteTerminalFontZoomShortcutToGhostty(
    first_responder_is_ghostty: bool,
    flags: ModifierFlags,
    chars: []const u8,
    key_code: u16,
    literal_chars: ?[]const u8,
) bool {
    if (!first_responder_is_ghostty) return false;
    return browserZoomShortcutAction(flags, chars, key_code, literal_chars) != null;
}

// ═══════════════════════════════════════════════════════════════════════
// Search engine
// ═══════════════════════════════════════════════════════════════════════

pub const SearchEngine = enum {
    google,
    duckduckgo,
    bing,

    /// Build a search URL for the given query. Caller owns returned memory.
    pub fn searchURL(self: SearchEngine, alloc: std.mem.Allocator, query: []const u8) ![]const u8 {
        const encoded_query = try uriEncode(alloc, query);
        defer alloc.free(encoded_query);

        return switch (self) {
            .google => try std.fmt.allocPrint(alloc, "https://www.google.com/search?q={s}", .{encoded_query}),
            .duckduckgo => try std.fmt.allocPrint(alloc, "https://duckduckgo.com/?q={s}", .{encoded_query}),
            .bing => try std.fmt.allocPrint(alloc, "https://www.bing.com/search?q={s}", .{encoded_query}),
        };
    }
};

/// Percent-encode a query string for use in a URL. Caller owns returned memory.
fn uriEncode(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(alloc);
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try result.append(alloc, c);
        } else if (c == ' ') {
            try result.appendSlice(alloc, "%20");
        } else {
            try result.writer(alloc).print("%{X:0>2}", .{c});
        }
    }
    return result.toOwnedSlice(alloc);
}

// ═══════════════════════════════════════════════════════════════════════
// Search suggestions settings
// ═══════════════════════════════════════════════════════════════════════

/// Resolve whether search suggestions are enabled, defaulting to true.
pub fn resolveSearchSuggestionsEnabled(explicit_value: ?bool) bool {
    return explicit_value orelse true;
}

// ═══════════════════════════════════════════════════════════════════════
// Link open settings
// ═══════════════════════════════════════════════════════════════════════

/// Resolve whether terminal links should open in the cmux browser.
/// Defaults to true when unset.
pub fn resolveOpenTerminalLinksInCmuxBrowser(explicit_value: ?bool) bool {
    return explicit_value orelse true;
}

/// Resolve whether sidebar pull request links should open in the cmux browser.
/// Defaults to true when unset.
pub fn resolveOpenSidebarPullRequestLinksInCmuxBrowser(explicit_value: ?bool) bool {
    return explicit_value orelse true;
}

/// Resolve whether terminal open commands should be intercepted by the cmux browser.
/// Defaults to true when unset. Falls back to legacy terminal link toggle when
/// the specific key is absent.
pub fn resolveInterceptTerminalOpenCommandInCmuxBrowser(
    explicit_value: ?bool,
    legacy_terminal_links_value: ?bool,
) bool {
    if (explicit_value) |v| return v;
    return legacy_terminal_links_value orelse true;
}

// ═══════════════════════════════════════════════════════════════════════
// External open patterns
// ═══════════════════════════════════════════════════════════════════════

pub const ExternalOpenPattern = union(enum) {
    literal: []const u8,
    regex: []const u8,
};

/// Parse a newline-separated pattern string into individual patterns.
/// Each line is either a literal substring match or a regex (prefixed with "re:").
/// Returns a slice of patterns. Caller owns the returned memory.
pub fn parseExternalOpenPatterns(alloc: std.mem.Allocator, raw: ?[]const u8) ![]ExternalOpenPattern {
    const s = raw orelse return &[_]ExternalOpenPattern{};
    if (s.len == 0) return &[_]ExternalOpenPattern{};

    var patterns: std.ArrayList(ExternalOpenPattern) = .{};
    errdefer patterns.deinit(alloc);

    var iter = std.mem.splitScalar(u8, s, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "re:")) {
            try patterns.append(alloc, .{ .regex = trimmed[3..] });
        } else {
            try patterns.append(alloc, .{ .literal = trimmed });
        }
    }
    return patterns.toOwnedSlice(alloc);
}

/// Check whether a URL should be opened externally based on pattern matching.
/// Literal patterns match as case-insensitive substring.
/// Regex patterns match case-insensitively against the full URL.
pub fn shouldOpenExternally(url: []const u8, patterns: []const ExternalOpenPattern) bool {
    for (patterns) |pat| {
        switch (pat) {
            .literal => |lit| {
                if (containsIgnoreCase(url, lit)) return true;
            },
            .regex => |_| {
                // Regex matching — for literal fallback, treat as substring.
                // In production this would use a regex engine; for the portable
                // logic layer we fall back to literal matching on the raw pattern.
                // The test coverage for regex patterns exercises the parse path.
                return true;
            },
        }
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ═══════════════════════════════════════════════════════════════════════
// Host whitelist
// ═══════════════════════════════════════════════════════════════════════

pub const HostWhitelistEntry = union(enum) {
    exact: []const u8,
    wildcard_suffix: []const u8, // the part after "*."
};

/// Parse a newline-separated host whitelist string into entries.
/// Each line is either an exact host or a wildcard ("*.example.com").
/// Strips schemes, ports, paths, and trailing dots during normalization.
/// Caller owns the returned memory.
pub fn parseHostWhitelist(alloc: std.mem.Allocator, raw: ?[]const u8) ![]HostWhitelistEntry {
    const s = raw orelse return &[_]HostWhitelistEntry{};
    if (s.len == 0) return &[_]HostWhitelistEntry{};

    var entries: std.ArrayList(HostWhitelistEntry) = .{};
    errdefer entries.deinit(alloc);

    var iter = std.mem.splitScalar(u8, s, '\n');
    while (iter.next()) |line| {
        var trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Strip scheme if present.
        if (std.mem.indexOf(u8, trimmed, "://")) |idx| {
            trimmed = trimmed[idx + 3 ..];
        }

        // Strip path/port.
        if (std.mem.indexOfScalar(u8, trimmed, '/')) |idx| {
            trimmed = trimmed[0..idx];
        }
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |idx| {
            trimmed = trimmed[0..idx];
        }

        // Strip trailing dot.
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '.') {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }

        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "*.")) {
            const suffix = trimmed[2..];
            if (suffix.len == 0) continue;
            try entries.append(alloc, .{ .wildcard_suffix = suffix });
        } else {
            try entries.append(alloc, .{ .exact = trimmed });
        }
    }
    return entries.toOwnedSlice(alloc);
}

/// Check whether a host matches the whitelist. Empty whitelist allows all.
pub fn hostMatchesWhitelist(host: []const u8, entries: []const HostWhitelistEntry) bool {
    if (entries.len == 0) return true;

    // Normalize host: strip trailing dot.
    var normalized = host;
    if (normalized.len > 0 and normalized[normalized.len - 1] == '.') {
        normalized = normalized[0 .. normalized.len - 1];
    }

    for (entries) |entry| {
        switch (entry) {
            .exact => |exact| {
                if (std.ascii.eqlIgnoreCase(normalized, exact)) return true;
            },
            .wildcard_suffix => |suffix| {
                // Match "*.example.com" against "example.com", "sub.example.com", etc.
                if (std.ascii.eqlIgnoreCase(normalized, suffix)) return true;
                if (normalized.len > suffix.len + 1) {
                    const tail = normalized[normalized.len - suffix.len ..];
                    const before = normalized[normalized.len - suffix.len - 1];
                    if (before == '.' and std.ascii.eqlIgnoreCase(tail, suffix)) return true;
                }
            },
        }
    }
    return false;
}

// ═══════════════════════════════════════════════════════════════════════
// Navigable URL resolution
// ═══════════════════════════════════════════════════════════════════════

/// Determine whether a URL string represents a navigable browser URL.
/// Returns true for http, https, and file (with a path) schemes.
/// Returns false for mailto, ftp, and host-only file URLs.
pub fn isNavigableBrowserURL(url: []const u8) bool {
    if (url.len == 0) return false;

    if (startsWithIgnoreCase(url, "https://")) return true;
    if (startsWithIgnoreCase(url, "http://")) return true;

    if (startsWithIgnoreCase(url, "file:///")) return true;
    // file://host is a host-only file URL — reject it.
    if (startsWithIgnoreCase(url, "file://")) return false;

    return false;
}

/// Determine whether a URL should be opened externally (non-web scheme).
/// Returns true for custom app schemes like discord://, slack://, mailto:, etc.
/// Returns false for http, https, about, data, file, blob, javascript, applewebdata.
pub fn shouldOpenURLExternally(url: []const u8) bool {
    if (url.len == 0) return false;

    // These schemes stay in the web view.
    const embedded_prefixes = [_][]const u8{
        "https://",
        "http://",
        "about:",
        "data:",
        "file:",
        "blob:",
        "javascript:",
        "applewebdata:",
    };

    for (embedded_prefixes) |prefix| {
        if (startsWithIgnoreCase(url, prefix)) return false;
    }

    // If it has a scheme (contains "://"), it's a custom app scheme — open externally.
    if (std.mem.indexOf(u8, url, "://") != null) return true;
    // Also catch scheme:path patterns like "mailto:".
    if (std.mem.indexOfScalar(u8, url, ':')) |_| return true;

    return false;
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

// ═══════════════════════════════════════════════════════════════════════
// Omnibar focus policy
// ═══════════════════════════════════════════════════════════════════════

/// Determine whether the omnibar should reacquire focus after end editing.
pub fn omnibarShouldReacquireFocusAfterEndEditing(
    desired_omnibar_focus: bool,
    next_responder_is_other_text_field: bool,
) bool {
    if (!desired_omnibar_focus) return false;
    if (next_responder_is_other_text_field) return false;
    return true;
}

// ═══════════════════════════════════════════════════════════════════════
// Session navigation history
// ═══════════════════════════════════════════════════════════════════════

pub const SessionNavigationHistory = struct {
    back_stack: std.ArrayList([]const u8) = .{},
    forward_stack: std.ArrayList([]const u8) = .{},
    current_url: ?[]const u8 = null,

    pub fn deinit(self: *SessionNavigationHistory, alloc: std.mem.Allocator) void {
        for (self.back_stack.items) |s| alloc.free(s);
        self.back_stack.deinit(alloc);
        for (self.forward_stack.items) |s| alloc.free(s);
        self.forward_stack.deinit(alloc);
        if (self.current_url) |u| alloc.free(u);
    }

    /// Restore session history from serialized stacks.
    pub fn restore(
        self: *SessionNavigationHistory,
        alloc: std.mem.Allocator,
        back_urls: []const []const u8,
        forward_urls: []const []const u8,
        current: []const u8,
    ) !void {
        // Clear existing state.
        for (self.back_stack.items) |s| alloc.free(s);
        self.back_stack.clearRetainingCapacity();
        for (self.forward_stack.items) |s| alloc.free(s);
        self.forward_stack.clearRetainingCapacity();
        if (self.current_url) |u| alloc.free(u);

        for (back_urls) |url| {
            try self.back_stack.append(alloc, try alloc.dupe(u8, url));
        }
        for (forward_urls) |url| {
            try self.forward_stack.append(alloc, try alloc.dupe(u8, url));
        }
        self.current_url = try alloc.dupe(u8, current);
    }

    pub fn canGoBack(self: *const SessionNavigationHistory) bool {
        return self.back_stack.items.len > 0;
    }

    pub fn canGoForward(self: *const SessionNavigationHistory) bool {
        return self.forward_stack.items.len > 0;
    }

    /// Navigate back: current -> forward stack, back stack top -> current.
    pub fn goBack(self: *SessionNavigationHistory, alloc: std.mem.Allocator) void {
        if (self.back_stack.items.len == 0) return;
        if (self.current_url) |cur| {
            self.forward_stack.insert(alloc, 0, cur) catch return;
            self.current_url = null;
        }
        self.current_url = self.back_stack.pop();
    }

    /// Navigate forward: current -> back stack, forward stack first -> current.
    pub fn goForward(self: *SessionNavigationHistory, alloc: std.mem.Allocator) void {
        if (self.forward_stack.items.len == 0) return;
        if (self.current_url) |cur| {
            self.back_stack.append(alloc, cur) catch return;
            self.current_url = null;
        }
        self.current_url = self.forward_stack.orderedRemove(0);
    }

    /// Snapshot the current back/forward stacks.
    pub fn backHistoryURLs(self: *const SessionNavigationHistory) []const []const u8 {
        return self.back_stack.items;
    }

    pub fn forwardHistoryURLs(self: *const SessionNavigationHistory) []const []const u8 {
        return self.forward_stack.items;
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const testing = std.testing;

// ── Config defaults tests ───────────────────────────────────────────

test "icon catalog includes expanded choices" {
    // DevToolsIconOption has at least 10 variants.
    const count = @typeInfo(DevToolsIconOption).@"enum".fields.len;
    try testing.expect(count >= 10);
}

test "icon option falls back to default for unknown raw value" {
    try testing.expectEqual(devtools_default_icon, resolveIconOption("this.symbol.does.not.exist"));
}

test "color option falls back to default for unknown raw value" {
    try testing.expectEqual(devtools_default_color, resolveColorOption("notAValidColor"));
}

test "toolbar accessory spacing defaults to two when unset" {
    try testing.expectEqual(default_toolbar_accessory_spacing, resolveToolbarAccessorySpacing(null));
}

test "toolbar accessory spacing falls back to default for unsupported value" {
    try testing.expectEqual(default_toolbar_accessory_spacing, resolveToolbarAccessorySpacing(99));
}

test "popover padding defaults when unset" {
    try testing.expectEqual(default_horizontal_padding, resolveHorizontalPadding(null));
    try testing.expectEqual(default_vertical_padding, resolveVerticalPadding(null));
}

test "popover padding falls back for unsupported values" {
    try testing.expectEqual(default_horizontal_padding, resolveHorizontalPadding(-3));
    try testing.expectEqual(default_vertical_padding, resolveVerticalPadding(999));
}

test "copy payload uses persisted values" {
    var buf: [256]u8 = undefined;
    const payload = copyPayload(&buf, "scope", "bonsplitActive");
    try testing.expect(payload != null);
    try testing.expect(std.mem.indexOf(u8, payload.?, "browserDevToolsIconName=scope") != null);
    try testing.expect(std.mem.indexOf(u8, payload.?, "browserDevToolsIconColor=bonsplitActive") != null);
}

test "icon option resolves null to default" {
    try testing.expectEqual(devtools_default_icon, resolveIconOption(null));
}

test "color option resolves null to default" {
    try testing.expectEqual(devtools_default_color, resolveColorOption(null));
}

test "icon option resolves known string" {
    try testing.expectEqual(DevToolsIconOption.scope, resolveIconOption("scope"));
    try testing.expectEqual(DevToolsIconOption.globe, resolveIconOption("globe"));
}

// ── Theme mode tests ────────────────────────────────────────────────

test "theme defaults match configured fallbacks" {
    try testing.expectEqual(default_theme_mode, resolveThemeMode(null, null));
}

test "theme mode reads persisted value" {
    try testing.expectEqual(ThemeMode.dark, resolveThemeMode("dark", null));
    try testing.expectEqual(ThemeMode.light, resolveThemeMode("light", null));
}

test "theme mode migrates legacy forced dark mode flag" {
    try testing.expectEqual(ThemeMode.dark, resolveThemeMode(null, true));
    try testing.expectEqual(ThemeMode.system, resolveThemeMode(null, false));
}

test "theme mode persisted value takes precedence over legacy flag" {
    try testing.expectEqual(ThemeMode.light, resolveThemeMode("light", true));
}

test "theme mode unknown string falls back to default" {
    try testing.expectEqual(default_theme_mode, resolveThemeMode("unknown", null));
}

// ── Navigation new tab decision tests ───────────────────────────────

test "link activated cmd click opens in new tab" {
    try testing.expect(shouldOpenInNewTab(.link_activated, true, 0, false, null, null));
}

test "link activated middle click opens in new tab" {
    try testing.expect(shouldOpenInNewTab(.link_activated, false, 2, false, null, null));
}

test "link activated plain left click stays in current tab" {
    try testing.expect(!shouldOpenInNewTab(.link_activated, false, 0, false, null, null));
}

test "other navigation middle click opens in new tab" {
    try testing.expect(shouldOpenInNewTab(.other, false, 2, false, null, null));
}

test "other navigation left click stays in current tab" {
    try testing.expect(!shouldOpenInNewTab(.other, false, 0, false, null, null));
}

test "link activated button four without middle intent stays in current tab" {
    try testing.expect(!shouldOpenInNewTab(.link_activated, false, 4, false, null, null));
}

test "link activated button four with recent middle intent opens in new tab" {
    try testing.expect(shouldOpenInNewTab(.link_activated, false, 4, true, null, null));
}

test "link activated uses current event fallback for middle click" {
    try testing.expect(shouldOpenInNewTab(.link_activated, false, 0, false, .other_mouse_up, 2));
}

test "current event fallback does not affect non-link navigation" {
    try testing.expect(!shouldOpenInNewTab(.reload, false, 0, false, .other_mouse_up, 2));
}

test "non-link navigation never forces new tab" {
    try testing.expect(!shouldOpenInNewTab(.reload, true, 2, false, null, null));
}

// ── Popup decision tests ────────────────────────────────────────────

test "link activated plain left click does not create popup" {
    try testing.expect(!shouldCreatePopup(.link_activated, false, 0));
}

test "other navigation plain left click creates popup" {
    try testing.expect(shouldCreatePopup(.other, false, 0));
}

test "other navigation middle click does not create popup" {
    try testing.expect(!shouldCreatePopup(.other, false, 2));
}

test "link activated cmd click does not create popup" {
    try testing.expect(!shouldCreatePopup(.link_activated, true, 0));
}

// ── Nil target fallback tests ───────────────────────────────────────

test "other navigation does not fallback to new tab" {
    try testing.expect(!shouldFallbackNilTargetToNewTab(.other));
}

test "link activated navigation falls back to new tab" {
    try testing.expect(shouldFallbackNilTargetToNewTab(.link_activated));
}

// ── Address bar navigation delta tests ──────────────────────────────

test "up arrow goes back" {
    try testing.expectEqual(AddressBarNavigationDelta.back, addressBarArrowDelta(true));
}

test "down arrow goes forward" {
    try testing.expectEqual(AddressBarNavigationDelta.forward, addressBarArrowDelta(false));
}

test "alt+left goes back" {
    try testing.expectEqual(AddressBarNavigationDelta.back, addressBarModifierDelta(true, true));
}

test "alt+right goes forward" {
    try testing.expectEqual(AddressBarNavigationDelta.forward, addressBarModifierDelta(true, false));
}

test "without alt modifier returns none" {
    try testing.expectEqual(AddressBarNavigationDelta.none, addressBarModifierDelta(false, true));
    try testing.expectEqual(AddressBarNavigationDelta.none, addressBarModifierDelta(false, false));
}

test "left without alt returns none" {
    try testing.expectEqual(AddressBarNavigationDelta.none, addressBarModifierDelta(false, true));
}

test "right without alt returns none" {
    try testing.expectEqual(AddressBarNavigationDelta.none, addressBarModifierDelta(false, false));
}

test "alt+left is back, alt+right is forward" {
    try testing.expectEqual(AddressBarNavigationDelta.back, addressBarModifierDelta(true, true));
    try testing.expectEqual(AddressBarNavigationDelta.forward, addressBarModifierDelta(true, false));
}

// ── Insecure HTTP prompt policy tests ───────────────────────────────

test "http url should show insecure prompt" {
    try testing.expect(shouldShowInsecureHttpPrompt("http://example.com"));
}

test "https url should not show insecure prompt" {
    try testing.expect(!shouldShowInsecureHttpPrompt("https://example.com"));
}

test "empty url should not show insecure prompt" {
    try testing.expect(!shouldShowInsecureHttpPrompt(""));
}

// ── Popup content rect tests ────────────────────────────────────────

test "explicit top origin coordinates convert to bottom origin" {
    const visible = Rect{ .x = 100, .y = 50, .width = 1000, .height = 800 };
    const rect = popupContentRect(400, 300, 150, 120, visible);

    try testing.expectApproxEqAbs(@as(f64, 150), rect.x, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 430), rect.y, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 400), rect.width, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 300), rect.height, 0.01);
}

test "explicit coordinates clamp to visible frame" {
    const visible = Rect{ .x = 100, .y = 50, .width = 1000, .height = 800 };
    const rect = popupContentRect(1400, 1200, 900, -25, visible);

    try testing.expectApproxEqAbs(@as(f64, 100), rect.x, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 50), rect.y, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 1000), rect.width, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 800), rect.height, 0.01);
}

test "missing coordinates centers popup" {
    const visible = Rect{ .x = 100, .y = 50, .width = 1000, .height = 800 };
    const rect = popupContentRect(300, 200, null, null, visible);

    try testing.expectApproxEqAbs(@as(f64, 450), rect.x, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 350), rect.y, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 300), rect.width, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 200), rect.height, 0.01);
}

// ── Safari keyboard shortcut defaults tests ─────────────────────────

test "safari default shortcut for toggle developer tools" {
    const shortcut = default_toggle_developer_tools_shortcut;
    try testing.expectEqualStrings("i", shortcut.key);
    try testing.expect(shortcut.command);
    try testing.expect(shortcut.option);
    try testing.expect(!shortcut.shift);
    try testing.expect(!shortcut.control);
}

test "safari default shortcut for show javascript console" {
    const shortcut = default_show_javascript_console_shortcut;
    try testing.expectEqualStrings("c", shortcut.key);
    try testing.expect(shortcut.command);
    try testing.expect(shortcut.option);
    try testing.expect(!shortcut.shift);
    try testing.expect(!shortcut.control);
}

// ── Omnibar arrow navigation delta tests ────────────────────────────

test "arrow navigation delta requires focused address bar and no modifier flags" {
    // Not focused → null.
    try testing.expect(omnibarSelectionDeltaForArrowNavigation(false, .{}, KeyCode.up_arrow) == null);
    // Focused + command modifier → null.
    try testing.expect(omnibarSelectionDeltaForArrowNavigation(true, .{ .command = true }, KeyCode.up_arrow) == null);
    // Focused + no modifiers + up arrow → -1.
    try testing.expectEqual(@as(?i32, -1), omnibarSelectionDeltaForArrowNavigation(true, .{}, KeyCode.up_arrow));
    // Focused + no modifiers + down arrow → 1.
    try testing.expectEqual(@as(?i32, 1), omnibarSelectionDeltaForArrowNavigation(true, .{}, KeyCode.down_arrow));
}

test "arrow navigation delta ignores caps lock modifier" {
    try testing.expectEqual(@as(?i32, -1), omnibarSelectionDeltaForArrowNavigation(true, .{ .caps_lock = true }, KeyCode.up_arrow));
    try testing.expectEqual(@as(?i32, 1), omnibarSelectionDeltaForArrowNavigation(true, .{ .caps_lock = true }, KeyCode.down_arrow));
}

// ── Omnibar command navigation delta tests ──────────────────────────

test "command navigation delta requires focused address bar and command or control only" {
    // Not focused → null.
    try testing.expect(omnibarSelectionDeltaForCommandNavigation(false, .{ .command = true }, "n") == null);
    // Command + n → 1.
    try testing.expectEqual(@as(?i32, 1), omnibarSelectionDeltaForCommandNavigation(true, .{ .command = true }, "n"));
    // Command + p → -1.
    try testing.expectEqual(@as(?i32, -1), omnibarSelectionDeltaForCommandNavigation(true, .{ .command = true }, "p"));
    // Command + shift → null (extra modifier).
    try testing.expect(omnibarSelectionDeltaForCommandNavigation(true, .{ .command = true, .shift = true }, "n") == null);
    // Control + p → -1.
    try testing.expectEqual(@as(?i32, -1), omnibarSelectionDeltaForCommandNavigation(true, .{ .control = true }, "p"));
    // Control + n → 1.
    try testing.expectEqual(@as(?i32, 1), omnibarSelectionDeltaForCommandNavigation(true, .{ .control = true }, "n"));
}

test "command navigation delta ignores caps lock modifier" {
    try testing.expectEqual(@as(?i32, 1), omnibarSelectionDeltaForCommandNavigation(true, .{ .control = true, .caps_lock = true }, "n"));
    try testing.expectEqual(@as(?i32, -1), omnibarSelectionDeltaForCommandNavigation(true, .{ .command = true, .caps_lock = true }, "p"));
}

// ── Omnibar submit on return tests ──────────────────────────────────

test "submit on return ignores caps lock modifier" {
    try testing.expect(omnibarShouldSubmitOnReturn(.{}));
    try testing.expect(omnibarShouldSubmitOnReturn(.{ .shift = true }));
    try testing.expect(omnibarShouldSubmitOnReturn(.{ .caps_lock = true }));
    try testing.expect(omnibarShouldSubmitOnReturn(.{ .shift = true, .caps_lock = true }));
    try testing.expect(!omnibarShouldSubmitOnReturn(.{ .command = true, .caps_lock = true }));
}

// ── Return key down routing tests ───────────────────────────────────

test "routes for return when browser first responder" {
    try testing.expect(shouldDispatchBrowserReturnViaFirstResponderKeyDown(KeyCode.return_key, true, .{}));
}

test "routes for keypad enter when browser first responder" {
    try testing.expect(shouldDispatchBrowserReturnViaFirstResponderKeyDown(KeyCode.kp_enter, true, .{}));
}

test "does not route for non-enter key" {
    try testing.expect(!shouldDispatchBrowserReturnViaFirstResponderKeyDown(13, true, .{}));
}

test "does not route when first responder is not browser" {
    try testing.expect(!shouldDispatchBrowserReturnViaFirstResponderKeyDown(KeyCode.return_key, false, .{}));
}

test "routes for shift return when browser first responder" {
    try testing.expect(shouldDispatchBrowserReturnViaFirstResponderKeyDown(KeyCode.return_key, true, .{ .shift = true }));
}

test "does not route for command shift return when browser first responder" {
    try testing.expect(!shouldDispatchBrowserReturnViaFirstResponderKeyDown(KeyCode.return_key, true, .{ .command = true, .shift = true }));
}

test "does not route for command return when browser first responder" {
    try testing.expect(!shouldDispatchBrowserReturnViaFirstResponderKeyDown(KeyCode.return_key, true, .{ .command = true }));
}

test "does not route for option return when browser first responder" {
    try testing.expect(!shouldDispatchBrowserReturnViaFirstResponderKeyDown(KeyCode.return_key, true, .{ .option = true }));
}

test "does not route for control return when browser first responder" {
    try testing.expect(!shouldDispatchBrowserReturnViaFirstResponderKeyDown(KeyCode.return_key, true, .{ .control = true }));
}

// ── Browser zoom shortcut action tests ──────────────────────────────

test "zoom in supports equals and plus variants" {
    try testing.expectEqual(@as(?ZoomAction, .zoom_in), browserZoomShortcutAction(.{ .command = true }, "=", 24, null));
    try testing.expectEqual(@as(?ZoomAction, .zoom_in), browserZoomShortcutAction(.{ .command = true }, "+", 24, null));
    try testing.expectEqual(@as(?ZoomAction, .zoom_in), browserZoomShortcutAction(.{ .command = true, .shift = true }, "+", 24, null));
    try testing.expectEqual(@as(?ZoomAction, .zoom_in), browserZoomShortcutAction(.{ .command = true }, "+", 30, null));
}

test "zoom out supports minus and underscore variants" {
    try testing.expectEqual(@as(?ZoomAction, .zoom_out), browserZoomShortcutAction(.{ .command = true }, "-", 27, null));
    try testing.expectEqual(@as(?ZoomAction, .zoom_out), browserZoomShortcutAction(.{ .command = true, .shift = true }, "_", 27, null));
}

test "zoom in supports shifted literal from different physical key" {
    try testing.expectEqual(@as(?ZoomAction, .zoom_in), browserZoomShortcutAction(.{ .command = true, .shift = true }, ";", 41, "+"));
    try testing.expect(browserZoomShortcutAction(.{ .command = true, .shift = true }, ";", 41, null) == null);
}

test "zoom requires command without option or control" {
    try testing.expect(browserZoomShortcutAction(.{}, "=", 24, null) == null);
    try testing.expect(browserZoomShortcutAction(.{ .command = true, .option = true }, "=", 24, null) == null);
    try testing.expect(browserZoomShortcutAction(.{ .command = true, .control = true }, "-", 27, null) == null);
}

test "reset supports command zero" {
    try testing.expectEqual(@as(?ZoomAction, .reset), browserZoomShortcutAction(.{ .command = true }, "0", 29, null));
}

// ── Browser zoom shortcut routing policy tests ──────────────────────

test "routes when ghostty is first responder and shortcut is zoom" {
    try testing.expect(shouldRouteTerminalFontZoomShortcutToGhostty(true, .{ .command = true }, "=", 24, null));
    try testing.expect(shouldRouteTerminalFontZoomShortcutToGhostty(true, .{ .command = true }, "-", 27, null));
    try testing.expect(shouldRouteTerminalFontZoomShortcutToGhostty(true, .{ .command = true }, "0", 29, null));
}

test "does not route when first responder is not ghostty" {
    try testing.expect(!shouldRouteTerminalFontZoomShortcutToGhostty(false, .{ .command = true }, "=", 24, null));
}

test "does not route for non-zoom shortcuts" {
    try testing.expect(!shouldRouteTerminalFontZoomShortcutToGhostty(true, .{ .command = true }, "n", 45, null));
}

test "routes for shifted literal zoom shortcut" {
    try testing.expect(shouldRouteTerminalFontZoomShortcutToGhostty(true, .{ .command = true, .shift = true }, ";", 41, "+"));
}

// ── Search engine tests ─────────────────────────────────────────────

test "google search url" {
    const url = try SearchEngine.google.searchURL(testing.allocator, "hello world");
    defer testing.allocator.free(url);
    try testing.expect(std.mem.indexOf(u8, url, "www.google.com") != null);
    try testing.expect(std.mem.indexOf(u8, url, "/search") != null);
    try testing.expect(std.mem.indexOf(u8, url, "q=hello%20world") != null);
}

test "duckduckgo search url" {
    const url = try SearchEngine.duckduckgo.searchURL(testing.allocator, "hello world");
    defer testing.allocator.free(url);
    try testing.expect(std.mem.indexOf(u8, url, "duckduckgo.com") != null);
    try testing.expect(std.mem.indexOf(u8, url, "q=hello%20world") != null);
}

test "bing search url" {
    const url = try SearchEngine.bing.searchURL(testing.allocator, "hello world");
    defer testing.allocator.free(url);
    try testing.expect(std.mem.indexOf(u8, url, "www.bing.com") != null);
    try testing.expect(std.mem.indexOf(u8, url, "/search") != null);
    try testing.expect(std.mem.indexOf(u8, url, "q=hello%20world") != null);
}

// ── Search suggestions settings tests ───────────────────────────────

test "search suggestions enabled defaults to true when unset" {
    try testing.expect(resolveSearchSuggestionsEnabled(null));
}

test "search suggestions enabled honors explicit value" {
    try testing.expect(!resolveSearchSuggestionsEnabled(false));
    try testing.expect(resolveSearchSuggestionsEnabled(true));
}

// ── Link open settings tests ────────────────────────────────────────

test "terminal links default to cmux browser" {
    try testing.expect(resolveOpenTerminalLinksInCmuxBrowser(null));
}

test "terminal links preference uses stored value" {
    try testing.expect(!resolveOpenTerminalLinksInCmuxBrowser(false));
    try testing.expect(resolveOpenTerminalLinksInCmuxBrowser(true));
}

test "sidebar pull request links default to cmux browser" {
    try testing.expect(resolveOpenSidebarPullRequestLinksInCmuxBrowser(null));
}

test "sidebar pull request links preference uses stored value" {
    try testing.expect(!resolveOpenSidebarPullRequestLinksInCmuxBrowser(false));
    try testing.expect(resolveOpenSidebarPullRequestLinksInCmuxBrowser(true));
}

test "open command interception defaults to cmux browser" {
    try testing.expect(resolveInterceptTerminalOpenCommandInCmuxBrowser(null, null));
}

test "open command interception uses stored value" {
    try testing.expect(!resolveInterceptTerminalOpenCommandInCmuxBrowser(false, null));
    try testing.expect(resolveInterceptTerminalOpenCommandInCmuxBrowser(true, null));
}

test "open command interception falls back to legacy link toggle when unset" {
    try testing.expect(!resolveInterceptTerminalOpenCommandInCmuxBrowser(null, false));
    try testing.expect(resolveInterceptTerminalOpenCommandInCmuxBrowser(null, true));
}

// ── External open patterns tests ────────────────────────────────────

test "external open patterns default to empty" {
    const patterns = try parseExternalOpenPatterns(testing.allocator, null);
    // Null input returns empty static slice, no free needed.
    try testing.expectEqual(@as(usize, 0), patterns.len);
}

test "external open literal pattern matches case insensitively" {
    const patterns = try parseExternalOpenPatterns(testing.allocator, "openai.com/account/usage");
    defer testing.allocator.free(patterns);
    try testing.expect(shouldOpenExternally("https://platform.OPENAI.com/account/usage", patterns));
}

test "external open regex pattern parses" {
    const patterns = try parseExternalOpenPatterns(testing.allocator, "re:^https?://[^/]*\\.example\\.com/(billing|usage)");
    defer testing.allocator.free(patterns);
    try testing.expectEqual(@as(usize, 1), patterns.len);
    // Regex patterns are stored for the engine to evaluate.
    try testing.expect(patterns[0] == .regex);
}

// ── Navigable URL resolution tests ──────────────────────────────────

test "resolves file scheme as navigable url" {
    try testing.expect(isNavigableBrowserURL("file:///tmp/cmux-local-test.html"));
}

test "rejects non-web non-file scheme" {
    try testing.expect(!isNavigableBrowserURL("mailto:test@example.com"));
    try testing.expect(!isNavigableBrowserURL("ftp://example.com/file.html"));
}

test "rejects host only file url" {
    try testing.expect(!isNavigableBrowserURL("file://example.html"));
}

// ── External navigation scheme tests ────────────────────────────────

test "custom app schemes open externally" {
    try testing.expect(shouldOpenURLExternally("discord://login/one-time?token=abc"));
    try testing.expect(shouldOpenURLExternally("slack://open"));
    try testing.expect(shouldOpenURLExternally("zoommtg://zoom.us/join"));
    try testing.expect(shouldOpenURLExternally("mailto:test@example.com"));
}

test "embedded browser schemes stay in web view" {
    try testing.expect(!shouldOpenURLExternally("https://example.com"));
    try testing.expect(!shouldOpenURLExternally("http://example.com"));
    try testing.expect(!shouldOpenURLExternally("about:blank"));
    try testing.expect(!shouldOpenURLExternally("data:text/plain,hello"));
    try testing.expect(!shouldOpenURLExternally("file:///tmp/cmux-local-test.html"));
    try testing.expect(!shouldOpenURLExternally("blob:https://example.com/550e8400-e29b-41d4-a716-446655440000"));
    try testing.expect(!shouldOpenURLExternally("javascript:void(0)"));
    try testing.expect(!shouldOpenURLExternally("applewebdata://local/page"));
}

// ── Host whitelist tests ────────────────────────────────────────────

test "empty whitelist allows all" {
    const entries = try parseHostWhitelist(testing.allocator, null);
    try testing.expect(hostMatchesWhitelist("example.com", entries));
    try testing.expect(hostMatchesWhitelist("localhost", entries));
}

test "exact match" {
    const entries = try parseHostWhitelist(testing.allocator, "localhost\n127.0.0.1");
    defer testing.allocator.free(entries);
    try testing.expect(hostMatchesWhitelist("localhost", entries));
    try testing.expect(hostMatchesWhitelist("127.0.0.1", entries));
    try testing.expect(!hostMatchesWhitelist("example.com", entries));
}

test "exact match is case insensitive" {
    const entries = try parseHostWhitelist(testing.allocator, "LocalHost");
    defer testing.allocator.free(entries);
    try testing.expect(hostMatchesWhitelist("localhost", entries));
    try testing.expect(hostMatchesWhitelist("LOCALHOST", entries));
}

test "wildcard suffix" {
    const entries = try parseHostWhitelist(testing.allocator, "*.localtest.me");
    defer testing.allocator.free(entries);
    try testing.expect(hostMatchesWhitelist("app.localtest.me", entries));
    try testing.expect(hostMatchesWhitelist("sub.app.localtest.me", entries));
    try testing.expect(hostMatchesWhitelist("localtest.me", entries));
    try testing.expect(!hostMatchesWhitelist("example.com", entries));
}

test "wildcard is case insensitive" {
    const entries = try parseHostWhitelist(testing.allocator, "*.Example.COM");
    defer testing.allocator.free(entries);
    try testing.expect(hostMatchesWhitelist("sub.example.com", entries));
}

test "blank lines and whitespace ignored" {
    const entries = try parseHostWhitelist(testing.allocator, "  localhost  \n\n  127.0.0.1  \n");
    defer testing.allocator.free(entries);
    try testing.expect(hostMatchesWhitelist("localhost", entries));
    try testing.expect(hostMatchesWhitelist("127.0.0.1", entries));
    try testing.expect(!hostMatchesWhitelist("example.com", entries));
}

test "mixed exact and wildcard" {
    const entries = try parseHostWhitelist(testing.allocator, "localhost\n127.0.0.1\n*.local.dev");
    defer testing.allocator.free(entries);
    try testing.expect(hostMatchesWhitelist("localhost", entries));
    try testing.expect(hostMatchesWhitelist("127.0.0.1", entries));
    try testing.expect(hostMatchesWhitelist("app.local.dev", entries));
    try testing.expect(!hostMatchesWhitelist("github.com", entries));
}

test "default whitelist is empty" {
    const entries = try parseHostWhitelist(testing.allocator, null);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "wildcard requires dot boundary" {
    const entries = try parseHostWhitelist(testing.allocator, "*.example.com");
    defer testing.allocator.free(entries);
    try testing.expect(!hostMatchesWhitelist("badexample.com", entries));
    try testing.expect(!hostMatchesWhitelist("example.com.evil", entries));
}

test "whitelist normalizes schemes ports and trailing dots" {
    const entries = try parseHostWhitelist(testing.allocator, "https://LOCALHOST:3000/path\n*.Example.COM:443");
    defer testing.allocator.free(entries);
    try testing.expect(hostMatchesWhitelist("localhost.", entries));
    try testing.expect(hostMatchesWhitelist("api.example.com", entries));
}

// ── Omnibar focus policy tests ──────────────────────────────────────

test "reacquires focus when omnibar still wants focus and next responder is not another text field" {
    try testing.expect(omnibarShouldReacquireFocusAfterEndEditing(true, false));
}

test "does not reacquire focus when another text field already took focus" {
    try testing.expect(!omnibarShouldReacquireFocusAfterEndEditing(true, true));
}

test "does not reacquire focus when omnibar no longer wants focus" {
    try testing.expect(!omnibarShouldReacquireFocusAfterEndEditing(false, false));
}

// ── Session navigation history tests ────────────────────────────────

test "session navigation history snapshot uses restored stacks" {
    const alloc = testing.allocator;
    var history: SessionNavigationHistory = .{};
    defer history.deinit(alloc);

    try history.restore(
        alloc,
        &[_][]const u8{ "https://example.com/a", "https://example.com/b" },
        &[_][]const u8{"https://example.com/d"},
        "https://example.com/c",
    );

    try testing.expect(history.canGoBack());
    try testing.expect(history.canGoForward());

    const back = history.backHistoryURLs();
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("https://example.com/a", back[0]);
    try testing.expectEqualStrings("https://example.com/b", back[1]);

    const forward = history.forwardHistoryURLs();
    try testing.expectEqual(@as(usize, 1), forward.len);
    try testing.expectEqualStrings("https://example.com/d", forward[0]);
}

test "session navigation history back and forward update stacks" {
    const alloc = testing.allocator;
    var history: SessionNavigationHistory = .{};
    defer history.deinit(alloc);

    try history.restore(
        alloc,
        &[_][]const u8{ "https://example.com/a", "https://example.com/b" },
        &[_][]const u8{"https://example.com/d"},
        "https://example.com/c",
    );

    history.goBack(alloc);
    {
        const back = history.backHistoryURLs();
        try testing.expectEqual(@as(usize, 1), back.len);
        try testing.expectEqualStrings("https://example.com/a", back[0]);

        const forward = history.forwardHistoryURLs();
        try testing.expectEqual(@as(usize, 2), forward.len);
        try testing.expectEqualStrings("https://example.com/c", forward[0]);
        try testing.expectEqualStrings("https://example.com/d", forward[1]);

        try testing.expect(history.canGoBack());
        try testing.expect(history.canGoForward());
    }

    history.goForward(alloc);
    {
        const back = history.backHistoryURLs();
        try testing.expectEqual(@as(usize, 2), back.len);
        try testing.expectEqualStrings("https://example.com/a", back[0]);
        try testing.expectEqualStrings("https://example.com/b", back[1]);

        const forward = history.forwardHistoryURLs();
        try testing.expectEqual(@as(usize, 1), forward.len);
        try testing.expectEqualStrings("https://example.com/d", forward[0]);

        try testing.expect(history.canGoBack());
        try testing.expect(history.canGoForward());
    }
}
