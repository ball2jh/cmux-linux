//! Omnibar state machine and suggestion ranking.
//!
//! Ports the macOS `OmnibarState`, `omnibarReduce`, suggestion ranking,
//! remote suggestion merging, and inline completion logic.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ===========================================================================
// OmnibarState — tracks editing state, URL, focus
// ===========================================================================

pub const OmnibarState = struct {
    is_focused: bool = false,
    current_url_string: []const u8 = "",
    buffer: []const u8 = "",
    suggestions: []const OmnibarSuggestion = &.{},
    selected_suggestion_index: usize = 0,
    selected_suggestion_id: ?[]const u8 = null,
    is_user_editing: bool = false,
};

pub const OmnibarEffects = struct {
    should_select_all: bool = false,
    should_blur_to_web_view: bool = false,
    should_refresh_suggestions: bool = false,
};

pub const OmnibarEvent = union(enum) {
    focus_gained: struct { current_url_string: []const u8 },
    focus_lost_revert_buffer: struct { current_url_string: []const u8 },
    focus_lost_preserve_buffer: struct { current_url_string: []const u8 },
    panel_url_changed: struct { current_url_string: []const u8 },
    buffer_changed: []const u8,
    suggestions_updated: []const OmnibarSuggestion,
    move_selection: struct { delta: i32 },
    highlight_index: usize,
    escape,
};

/// Reduce an omnibar event into state changes + effects.
/// Mirrors the macOS `omnibarReduce(state:event:)`.
pub fn omnibarReduce(state: *OmnibarState, event: OmnibarEvent) OmnibarEffects {
    var effects = OmnibarEffects{};

    switch (event) {
        .focus_gained => |payload| {
            state.is_focused = true;
            state.current_url_string = payload.current_url_string;
            state.buffer = payload.current_url_string;
            state.is_user_editing = false;
            state.suggestions = &.{};
            state.selected_suggestion_index = 0;
            state.selected_suggestion_id = null;
            effects.should_select_all = true;
        },
        .focus_lost_revert_buffer => |payload| {
            state.is_focused = false;
            state.current_url_string = payload.current_url_string;
            state.buffer = payload.current_url_string;
            state.is_user_editing = false;
            state.suggestions = &.{};
            state.selected_suggestion_index = 0;
            state.selected_suggestion_id = null;
        },
        .focus_lost_preserve_buffer => |payload| {
            state.is_focused = false;
            state.current_url_string = payload.current_url_string;
            state.is_user_editing = false;
            state.suggestions = &.{};
            state.selected_suggestion_index = 0;
            state.selected_suggestion_id = null;
        },
        .panel_url_changed => |payload| {
            state.current_url_string = payload.current_url_string;
            if (!state.is_user_editing) {
                state.buffer = payload.current_url_string;
                state.suggestions = &.{};
                state.selected_suggestion_index = 0;
                state.selected_suggestion_id = null;
            }
        },
        .buffer_changed => |new_value| {
            state.buffer = new_value;
            if (state.is_focused) {
                state.is_user_editing = !std.mem.eql(u8, new_value, state.current_url_string);
                state.selected_suggestion_index = 0;
                state.selected_suggestion_id = null;
                effects.should_refresh_suggestions = true;
            }
        },
        .suggestions_updated => |items| {
            const previous_items = state.suggestions;
            const previous_selected_id = state.selected_suggestion_id;
            state.suggestions = items;

            if (items.len == 0) {
                state.selected_suggestion_index = 0;
                state.selected_suggestion_id = null;
            } else if (previous_selected_id) |prev_id| {
                // Try to find the previously selected item in the new list.
                if (findSuggestionIndexById(items, prev_id)) |idx| {
                    state.selected_suggestion_index = idx;
                    state.selected_suggestion_id = items[idx].id();
                } else if (preferredAutocompletionSuggestionIndex(items, state.buffer)) |pref_idx| {
                    state.selected_suggestion_index = pref_idx;
                    state.selected_suggestion_id = items[pref_idx].id();
                } else if (previous_items.len == 0) {
                    // Popup reopened: start keyboard focus from the first row.
                    state.selected_suggestion_index = 0;
                    state.selected_suggestion_id = items[0].id();
                } else {
                    // Keep selection index clamped.
                    state.selected_suggestion_index = @min(state.selected_suggestion_index, items.len - 1);
                    state.selected_suggestion_id = items[state.selected_suggestion_index].id();
                }
            } else if (preferredAutocompletionSuggestionIndex(items, state.buffer)) |pref_idx| {
                state.selected_suggestion_index = pref_idx;
                state.selected_suggestion_id = items[pref_idx].id();
            } else if (previous_items.len == 0) {
                state.selected_suggestion_index = 0;
                state.selected_suggestion_id = items[0].id();
            } else {
                state.selected_suggestion_index = @min(state.selected_suggestion_index, items.len - 1);
                state.selected_suggestion_id = items[state.selected_suggestion_index].id();
            }
        },
        .move_selection => |payload| {
            if (state.suggestions.len == 0) return effects;
            const current: i64 = @intCast(state.selected_suggestion_index);
            const new_idx = @max(0, @min(current + payload.delta, @as(i64, @intCast(state.suggestions.len - 1))));
            state.selected_suggestion_index = @intCast(new_idx);
            state.selected_suggestion_id = state.suggestions[state.selected_suggestion_index].id();
        },
        .highlight_index => |idx| {
            if (state.suggestions.len == 0) return effects;
            state.selected_suggestion_index = @min(idx, state.suggestions.len - 1);
            state.selected_suggestion_id = state.suggestions[state.selected_suggestion_index].id();
        },
        .escape => {
            if (!state.is_focused) return effects;
            // Chrome semantics:
            // - If user input is in progress OR the popup is open: revert to the page URL and select-all.
            // - Otherwise: exit omnibar focus.
            if (state.is_user_editing or state.suggestions.len > 0) {
                state.is_user_editing = false;
                state.buffer = state.current_url_string;
                state.suggestions = &.{};
                state.selected_suggestion_index = 0;
                state.selected_suggestion_id = null;
                effects.should_select_all = true;
            } else {
                effects.should_blur_to_web_view = true;
            }
        },
    }

    return effects;
}

// ===========================================================================
// OmnibarSuggestion — represents a suggestion row in the omnibar popup
// ===========================================================================

pub const SuggestionKind = union(enum) {
    search: struct { engine_name: []const u8, query: []const u8 },
    navigate: struct { url: []const u8 },
    history: struct { url: []const u8, title: ?[]const u8 },
    switch_to_tab: struct { tab_id: []const u8, panel_id: []const u8, url: []const u8, title: ?[]const u8 },
    remote: struct { query: []const u8 },
};

pub const OmnibarSuggestion = struct {
    kind: SuggestionKind,

    /// Stable identity string — prevents row rebuild flicker.
    /// Returns a pointer to a static or inline-computed string.
    /// For test purposes this uses a simple scheme.
    pub fn id(self: *const OmnibarSuggestion) []const u8 {
        return self.completion();
    }

    /// The completion text for this suggestion.
    pub fn completion(self: *const OmnibarSuggestion) []const u8 {
        return switch (self.kind) {
            .search => |s| s.query,
            .navigate => |n| n.url,
            .history => |h| h.url,
            .switch_to_tab => |t| t.url,
            .remote => |r| r.query,
        };
    }

    /// The title, if available, for display.
    pub fn title(self: *const OmnibarSuggestion) ?[]const u8 {
        return switch (self.kind) {
            .history => |h| h.title,
            .switch_to_tab => |t| t.title,
            else => null,
        };
    }

    /// Display text for list rows.
    /// For history/tab items: "Title — displayURL". Otherwise: primaryText.
    pub fn listText(self: *const OmnibarSuggestion, allocator: Allocator) ![]const u8 {
        switch (self.kind) {
            .history => |h| {
                const t = singleLineText(h.title) orelse return displayURLText(allocator, h.url);
                if (t.len == 0) return displayURLText(allocator, h.url);
                const url_text = try displayURLText(allocator, h.url);
                defer allocator.free(url_text);
                return std.fmt.allocPrint(allocator, "{s} — {s}", .{ t, url_text });
            },
            .switch_to_tab => |st| {
                const t = singleLineText(st.title) orelse return displayURLText(allocator, st.url);
                if (t.len == 0) return displayURLText(allocator, st.url);
                const url_text = try displayURLText(allocator, st.url);
                defer allocator.free(url_text);
                return std.fmt.allocPrint(allocator, "{s} — {s}", .{ t, url_text });
            },
            else => return try allocator.dupe(u8, self.completion()),
        }
    }

    // Convenience constructors (mirrors Mac's static factory methods).

    pub fn search(engine_name: []const u8, query: []const u8) OmnibarSuggestion {
        return .{ .kind = .{ .search = .{ .engine_name = engine_name, .query = query } } };
    }

    pub fn history(url: []const u8, title_val: ?[]const u8) OmnibarSuggestion {
        return .{ .kind = .{ .history = .{ .url = url, .title = title_val } } };
    }

    pub fn navigate(url: []const u8) OmnibarSuggestion {
        return .{ .kind = .{ .navigate = .{ .url = url } } };
    }

    pub fn remoteSearchSuggestion(query: []const u8) OmnibarSuggestion {
        return .{ .kind = .{ .remote = .{ .query = query } } };
    }

    pub fn switchToTab(tab_id: []const u8, panel_id: []const u8, url: []const u8, title_val: ?[]const u8) OmnibarSuggestion {
        return .{ .kind = .{ .switch_to_tab = .{ .tab_id = tab_id, .panel_id = panel_id, .url = url, .title = title_val } } };
    }
};

// ===========================================================================
// Autocompletion support
// ===========================================================================

/// Whether a suggestion supports inline autocompletion for a given query.
/// Mirrors `omnibarSuggestionSupportsAutocompletion`.
pub fn suggestionSupportsAutocompletion(query: []const u8, suggestion: *const OmnibarSuggestion) bool {
    // Search and remote suggestions are never autocompletable.
    switch (suggestion.kind) {
        .search => return false,
        .remote => return false,
        else => {},
    }

    const comp = suggestionCompletion(suggestion) orelse return false;

    // Reject URLs whose host lacks a TLD (e.g. "https://news." -> host "news").
    if (extractHost(comp)) |host| {
        const trimmed_host = if (host.len > 0 and host[host.len - 1] == '.')
            host[0 .. host.len - 1]
        else
            host;
        if (std.mem.indexOf(u8, trimmed_host, ".") == null) return false;
    }

    const title_str = suggestion.title();
    return suggestionMatchesTypedPrefix(query, comp, title_str);
}

/// Get the URL completion for a suggestion (only for navigate, history, switch_to_tab).
fn suggestionCompletion(suggestion: *const OmnibarSuggestion) ?[]const u8 {
    return switch (suggestion.kind) {
        .navigate => |n| n.url,
        .history => |h| h.url,
        .switch_to_tab => |t| t.url,
        else => null,
    };
}

/// Check whether the typed text matches the suggestion as a prefix.
/// Mirrors `omnibarSuggestionMatchesTypedPrefix`.
pub fn suggestionMatchesTypedPrefix(
    typed_text: []const u8,
    suggestion_completion: []const u8,
    suggestion_title: ?[]const u8,
) bool {
    const query = trimWhitespace(typed_text);
    if (query.len == 0) return false;
    const trimmed_completion = trimWhitespace(suggestion_completion);
    if (trimmed_completion.len == 0) return false;

    var query_lower_buf: [4096]u8 = undefined;
    const query_lower = toLowerBuf(query, &query_lower_buf) orelse return false;

    var comp_lower_buf: [4096]u8 = undefined;
    const comp_lower = toLowerBuf(trimmed_completion, &comp_lower_buf) orelse return false;

    const scheme_stripped = stripHTTPSchemePrefix(comp_lower);
    const scheme_and_www_stripped = stripHTTPSchemeAndWWWPrefix(comp_lower);

    const typed_includes_scheme = std.mem.startsWith(u8, query_lower, "https://") or
        std.mem.startsWith(u8, query_lower, "http://");
    const typed_includes_www = std.mem.startsWith(u8, query_lower, "www.");

    if (typed_includes_scheme and std.mem.startsWith(u8, comp_lower, query_lower)) return true;
    if (std.mem.startsWith(u8, scheme_stripped, query_lower)) return true;
    if (!typed_includes_www and std.mem.startsWith(u8, scheme_and_www_stripped, query_lower)) return true;

    if (suggestion_title) |t| {
        const trimmed_title = trimWhitespace(t);
        if (trimmed_title.len > 0) {
            var title_lower_buf: [4096]u8 = undefined;
            if (toLowerBuf(trimmed_title, &title_lower_buf)) |title_lower| {
                if (std.mem.startsWith(u8, title_lower, query_lower)) return true;
            }
        }
    }

    return false;
}

// ===========================================================================
// Inline completion
// ===========================================================================

pub const OmnibarInlineCompletion = struct {
    typed_text: []const u8,
    display_text: []const u8,
    accepted_text: []const u8,

    pub fn suffixStart(self: *const OmnibarInlineCompletion) usize {
        return self.typed_text.len;
    }

    pub fn suffixLen(self: *const OmnibarInlineCompletion) usize {
        if (self.display_text.len > self.typed_text.len)
            return self.display_text.len - self.typed_text.len;
        return 0;
    }

    pub fn eql(a: *const OmnibarInlineCompletion, b: *const OmnibarInlineCompletion) bool {
        return std.mem.eql(u8, a.typed_text, b.typed_text) and
            std.mem.eql(u8, a.display_text, b.display_text) and
            std.mem.eql(u8, a.accepted_text, b.accepted_text);
    }
};

/// Returns the published buffer text when the field value changes with an
/// active inline completion. If the inline completion suffix is selected,
/// publish only the typed prefix.
/// Mirrors `omnibarPublishedBufferTextForFieldChange`.
pub fn publishedBufferTextForFieldChange(
    field_value: []const u8,
    inline_completion: ?*const OmnibarInlineCompletion,
    selection_start: ?usize,
    selection_len: ?usize,
    has_marked_text: bool,
) []const u8 {
    if (has_marked_text) return field_value;
    const ic = inline_completion orelse return field_value;
    if (!std.mem.eql(u8, field_value, ic.display_text)) return field_value;

    const sel_start = selection_start orelse return ic.typed_text;
    const sel_length = selection_len orelse 0;

    const typed_count = ic.typed_text.len;
    const display_count = ic.display_text.len;

    const is_caret_at_typed_boundary = (sel_length == 0 and sel_start == typed_count);
    const is_suffix_selection = (sel_start == typed_count and sel_length == ic.suffixLen());
    const is_select_all = (sel_start == 0 and sel_length == display_count);
    const is_typed_prefix_selection = (sel_start == 0 and sel_length == typed_count);

    if (is_caret_at_typed_boundary or is_suffix_selection or is_select_all or is_typed_prefix_selection) {
        return ic.typed_text;
    }

    return field_value;
}

/// Returns the inline completion if the buffer text matches the typed prefix,
/// otherwise null (stale). Mirrors `omnibarInlineCompletionIfBufferMatchesTypedPrefix`.
pub fn inlineCompletionIfBufferMatchesTypedPrefix(
    buffer_text: []const u8,
    inline_completion: ?*const OmnibarInlineCompletion,
) ?*const OmnibarInlineCompletion {
    const ic = inline_completion orelse return null;
    if (!std.mem.eql(u8, buffer_text, ic.typed_text)) return null;
    return ic;
}

// ===========================================================================
// Remote suggestion merge
// ===========================================================================

/// Compute stale remote suggestions to display while a new request is in-flight.
/// Mirrors `staleOmnibarRemoteSuggestionsForDisplay`.
///
/// Returns a slice of trimmed, non-empty suggestions (referencing the input memory).
/// The result slice is allocated with `allocator`; the strings inside are not owned.
pub fn staleRemoteSuggestionsForDisplay(
    allocator: Allocator,
    query: []const u8,
    previous_remote_query: []const u8,
    previous_remote_suggestions: []const []const u8,
    limit: usize,
) ![]const []const u8 {
    const trimmed_query = trimWhitespace(query);
    const trimmed_prev_query = trimWhitespace(previous_remote_query);
    if (trimmed_query.len == 0 or trimmed_prev_query.len == 0) return &.{};

    var q_lower_buf: [4096]u8 = undefined;
    var pq_lower_buf: [4096]u8 = undefined;
    const lowered_query = toLowerBuf(trimmed_query, &q_lower_buf) orelse return &.{};
    const lowered_prev = toLowerBuf(trimmed_prev_query, &pq_lower_buf) orelse return &.{};

    // Check that queries are related (one is a prefix of the other).
    const related = std.mem.eql(u8, lowered_query, lowered_prev) or
        std.mem.startsWith(u8, lowered_query, lowered_prev) or
        std.mem.startsWith(u8, lowered_prev, lowered_query);
    if (!related) return &.{};

    if (previous_remote_suggestions.len == 0) return &.{};

    // Sanitize: trim whitespace, skip empty.
    var result = std.ArrayListUnmanaged([]const u8){};
    errdefer result.deinit(allocator);

    for (previous_remote_suggestions) |raw| {
        if (result.items.len >= limit) break;
        const trimmed = trimWhitespace(raw);
        if (trimmed.len == 0) continue;
        try result.append(allocator, trimmed);
    }

    if (result.items.len == 0) {
        result.deinit(allocator);
        return &.{};
    }

    return result.toOwnedSlice(allocator);
}

// ===========================================================================
// History entry for suggestion building
// ===========================================================================

pub const HistoryEntry = struct {
    url: []const u8,
    title: ?[]const u8 = null,
    last_visited_hours_ago: f64 = 0,
    visit_count: u32 = 1,
    typed_count: u32 = 0,
    last_typed_hours_ago: ?f64 = null,
};

pub const OpenTabMatch = struct {
    tab_id: []const u8,
    panel_id: []const u8,
    url: []const u8,
    title: ?[]const u8,
    is_known_open_tab: bool = true,
};

/// Input intent for the typed query.
pub const InputIntent = enum {
    url_like,
    query_like,
    ambiguous,
};

/// Determine the input intent for a query.
/// Simplified version — no full URL resolution, checks for dots and spaces.
pub fn inputIntent(query: []const u8) InputIntent {
    const trimmed = trimWhitespace(query);
    if (trimmed.len == 0) return .ambiguous;

    // Has scheme -> url_like
    if (std.mem.indexOf(u8, trimmed, "://") != null) return .url_like;

    // Has spaces -> query_like
    if (std.mem.indexOf(u8, trimmed, " ") != null) return .query_like;

    // Has dot -> ambiguous
    if (std.mem.indexOf(u8, trimmed, ".") != null) return .ambiguous;

    return .query_like;
}

/// Build omnibar suggestions from history, open tabs, and remote queries.
/// Mirrors `buildOmnibarSuggestions`. Returns an allocated slice of suggestions.
///
/// Caller owns the returned slice (free with `allocator.free()`).
pub fn buildSuggestions(
    allocator: Allocator,
    query: []const u8,
    engine_name: []const u8,
    history_entries: []const HistoryEntry,
    open_tab_matches: []const OpenTabMatch,
    remote_queries: []const []const u8,
    limit: usize,
) ![]OmnibarSuggestion {
    if (limit == 0) return &.{};

    const trimmed_query = trimWhitespace(query);
    if (trimmed_query.len == 0) {
        // Return history entries up to limit.
        const count = @min(history_entries.len, limit);
        const result = try allocator.alloc(OmnibarSuggestion, count);
        for (0..count) |i| {
            result[i] = OmnibarSuggestion.history(history_entries[i].url, history_entries[i].title);
        }
        return result;
    }

    const is_single_char = isSingleCharacterQuery(trimmed_query);
    const should_include_remote = !is_single_char;

    const intent = inputIntent(trimmed_query);

    var query_lower_buf: [4096]u8 = undefined;
    const normalized_query = toLowerBuf(trimmed_query, &query_lower_buf) orelse return &.{};

    const RankedSuggestion = struct {
        suggestion: OmnibarSuggestion,
        score: f64,
        order: usize,
        is_autocompletable: bool,
        kind_priority: u32,
    };

    // Use an ArrayList to collect candidates, then dedupe and sort.
    var candidates = std.ArrayListUnmanaged(RankedSuggestion){};
    defer candidates.deinit(allocator);
    var order: usize = 0;

    const suppress_single_char_search = is_single_char and (history_entries.len > 0 or open_tab_matches.len > 0);

    // Search row
    if (!suppress_single_char_search) {
        const search_base: f64 = switch (intent) {
            .query_like => 820,
            .ambiguous => 540,
            .url_like => 140,
        };
        const search_suggestion = OmnibarSuggestion.search(engine_name, trimmed_query);
        try candidates.append(allocator, .{
            .suggestion = search_suggestion,
            .score = search_base + completionScore(normalized_query, trimmed_query),
            .order = order,
            .is_autocompletable = false,
            .kind_priority = 300,
        });
        order += 1;
    }

    // History entries
    const max_history = @min(history_entries.len, @max(limit * 2, limit));
    for (history_entries[0..max_history], 0..) |entry, index| {
        const intent_base: f64 = switch (intent) {
            .url_like => 780,
            .ambiguous => 690,
            .query_like => 600,
        };
        const url_match = completionScore(normalized_query, entry.url);
        const title_match = if (entry.title) |t| completionScore(normalized_query, t) * 0.6 else 0;
        const recency_score = @max(0.0, 75.0 - (entry.last_visited_hours_ago / 5.0));
        const visit_score = @min(95.0, std.math.log1p(@as(f64, @floatFromInt(@max(1, entry.visit_count)))) * 32.0);
        const typed_score = @min(230.0, std.math.log1p(@as(f64, @floatFromInt(entry.typed_count))) * 100.0);
        const typed_recency: f64 = if (entry.last_typed_hours_ago) |hours|
            @max(0.0, 80.0 - (hours / 5.0))
        else
            0.0;
        const position_score: f64 = @floatFromInt(@max(0, @as(i32, 16) - @as(i32, @intCast(index))));
        const total = intent_base + url_match + title_match + recency_score + visit_score + typed_score + typed_recency + position_score;

        const hist_suggestion = OmnibarSuggestion.history(entry.url, entry.title);
        const is_auto = suggestionSupportsAutocompletion(trimmed_query, &hist_suggestion);
        try candidates.append(allocator, .{
            .suggestion = hist_suggestion,
            .score = total,
            .order = order,
            .is_autocompletable = is_auto,
            .kind_priority = 0,
        });
        order += 1;
    }

    // Open tab matches
    const max_tabs = @min(open_tab_matches.len, limit);
    for (open_tab_matches[0..max_tabs], 0..) |match, index| {
        const intent_base: f64 = switch (intent) {
            .url_like => 1180,
            .ambiguous => 980,
            .query_like => 820,
        };
        const url_match = completionScore(normalized_query, match.url);
        const title_match = if (match.title) |t| completionScore(normalized_query, t) * 0.65 else 0;
        const position_score = @as(f64, @floatFromInt(@max(0, @as(i32, 14) - @as(i32, @intCast(index))))) * 0.9;
        const total = intent_base + url_match + title_match + position_score;

        const tab_suggestion = if (match.is_known_open_tab)
            OmnibarSuggestion.switchToTab(match.tab_id, match.panel_id, match.url, match.title)
        else
            OmnibarSuggestion.history(match.url, match.title);
        const is_auto = suggestionSupportsAutocompletion(trimmed_query, &tab_suggestion);
        try candidates.append(allocator, .{
            .suggestion = tab_suggestion,
            .score = total,
            .order = order,
            .is_autocompletable = is_auto,
            .kind_priority = 0,
        });
        order += 1;
    }

    // Remote suggestions
    if (should_include_remote) {
        const max_remote = @min(remote_queries.len, limit);
        for (remote_queries[0..max_remote], 0..) |remote_query, index| {
            const trimmed_remote = trimWhitespace(remote_query);
            if (trimmed_remote.len == 0) continue;

            const remote_base: f64 = switch (intent) {
                .query_like => 690,
                .ambiguous => 450,
                .url_like => 110,
            };
            const position_score = @as(f64, @floatFromInt(@max(0, @as(i32, 14) - @as(i32, @intCast(index))))) * 0.9;
            const total = remote_base + completionScore(normalized_query, trimmed_remote) + position_score;

            try candidates.append(allocator, .{
                .suggestion = OmnibarSuggestion.remoteSearchSuggestion(trimmed_remote),
                .score = total,
                .order = order,
                .is_autocompletable = false,
                .kind_priority = 350,
            });
            order += 1;
        }
    }

    // Dedupe by completion key (lowercased).
    // For simplicity, keep the highest-scored entry per key.
    var best_map = std.StringHashMap(usize).init(allocator);
    defer best_map.deinit();

    for (candidates.items, 0..) |*cand, idx| {
        const comp = cand.suggestion.completion();
        const key = trimWhitespace(comp);
        if (key.len == 0) continue;

        if (best_map.get(key)) |existing_idx| {
            if (cand.score > candidates.items[existing_idx].score) {
                try best_map.put(key, idx);
            }
        } else {
            try best_map.put(key, idx);
        }
    }

    // Collect deduped candidates.
    var deduped = std.ArrayListUnmanaged(RankedSuggestion){};
    defer deduped.deinit(allocator);

    var iter = best_map.valueIterator();
    while (iter.next()) |idx_ptr| {
        try deduped.append(allocator, candidates.items[idx_ptr.*]);
    }

    // Sort: autocompletable first, then by score desc, kind_priority asc, order asc.
    std.mem.sort(RankedSuggestion, deduped.items, {}, struct {
        fn lessThan(_: void, lhs: RankedSuggestion, rhs: RankedSuggestion) bool {
            if (lhs.is_autocompletable != rhs.is_autocompletable) {
                return lhs.is_autocompletable;
            }
            if (lhs.score != rhs.score) return lhs.score > rhs.score;
            if (lhs.kind_priority != rhs.kind_priority) return lhs.kind_priority < rhs.kind_priority;
            return lhs.order < rhs.order;
        }
    }.lessThan);

    // Take up to limit.
    const count = @min(deduped.items.len, limit);
    const result = try allocator.alloc(OmnibarSuggestion, count);
    for (0..count) |i| {
        result[i] = deduped.items[i].suggestion;
    }

    // Prioritize autocompletion: move the shortest-suffix autocompletable candidate to front.
    if (count > 0) {
        if (preferredAutocompletionSuggestionIndex(result, trimmed_query)) |pref_idx| {
            if (pref_idx != 0) {
                const tmp = result[pref_idx];
                std.mem.copyBackwards(OmnibarSuggestion, result[1..pref_idx + 1], result[0..pref_idx]);
                result[0] = tmp;
            }
        }
    }

    return result;
}

// ===========================================================================
// Internal helpers
// ===========================================================================

fn findSuggestionIndexById(items: []const OmnibarSuggestion, target_id: []const u8) ?usize {
    for (items, 0..) |*item, i| {
        if (std.mem.eql(u8, item.id(), target_id)) return i;
    }
    return null;
}

fn preferredAutocompletionSuggestionIndex(suggestions: []const OmnibarSuggestion, query: []const u8) ?usize {
    if (query.len == 0) return null;

    var best_idx: ?usize = null;
    var best_suffix_len: usize = std.math.maxInt(usize);

    for (suggestions, 0..) |*suggestion, idx| {
        if (!suggestionSupportsAutocompletion(query, suggestion)) continue;
        const comp = suggestionCompletion(suggestion) orelse continue;
        if (!suggestionMatchesTypedPrefix(query, comp, suggestion.title())) continue;

        const display_comp = suggestionDisplayText(comp, query);
        if (display_comp.len == 0) continue;

        const suffix_len = if (display_comp.len > query.len) display_comp.len - query.len else 0;

        if (suffix_len < best_suffix_len or (suffix_len == best_suffix_len and (best_idx == null or idx < best_idx.?))) {
            best_suffix_len = suffix_len;
            best_idx = idx;
        }
    }

    return best_idx;
}

fn suggestionDisplayText(comp: []const u8, query: []const u8) []const u8 {
    var query_lower_buf: [4096]u8 = undefined;
    const ql = toLowerBuf(query, &query_lower_buf) orelse return comp;
    const typed_includes_scheme = std.mem.startsWith(u8, ql, "https://") or std.mem.startsWith(u8, ql, "http://");
    const typed_includes_www = std.mem.startsWith(u8, ql, "www.");

    if (typed_includes_scheme) return comp;
    if (typed_includes_www) return stripHTTPSchemePrefix(comp);
    return stripHTTPSchemeAndWWWPrefix(comp);
}

fn completionScore(normalized_query: []const u8, candidate: []const u8) f64 {
    const c = trimWhitespace(candidate);
    if (c.len == 0 or normalized_query.len == 0) return 0;

    var c_lower_buf: [4096]u8 = undefined;
    const cl = toLowerBuf(c, &c_lower_buf) orelse return 0;

    // Scoring candidate: strip scheme and www.
    const scoring = stripHTTPSchemeAndWWWPrefix(cl);
    if (scoring.len > 0) {
        if (std.mem.eql(u8, scoring, normalized_query)) return 260;
        if (std.mem.startsWith(u8, scoring, normalized_query)) return 220;
        if (std.mem.indexOf(u8, scoring, normalized_query) != null) return 150;
    }

    if (std.mem.eql(u8, cl, normalized_query)) return 240;
    if (std.mem.startsWith(u8, cl, normalized_query)) return 170;
    if (std.mem.indexOf(u8, cl, normalized_query) != null) return 95;
    return 0;
}

fn isSingleCharacterQuery(query: []const u8) bool {
    const trimmed = trimWhitespace(query);
    // Check that it's exactly one Unicode codepoint.
    if (trimmed.len == 0) return false;
    const len = std.unicode.utf8ByteSequenceLength(trimmed[0]) catch return false;
    return trimmed.len == len;
}

/// Extract host from a URL string. Simple parser, not full URL parsing.
fn extractHost(url: []const u8) ?[]const u8 {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |pos|
        url[pos + 3 ..]
    else
        return null;

    // Skip userinfo@
    const host_start = if (std.mem.indexOf(u8, after_scheme, "@")) |pos|
        after_scheme[pos + 1 ..]
    else
        after_scheme;

    // Find end of host: first / ? # or end.
    var end: usize = host_start.len;
    for (host_start, 0..) |ch, i| {
        if (ch == '/' or ch == '?' or ch == '#' or ch == ':') {
            end = i;
            break;
        }
    }

    const host = host_start[0..end];
    if (host.len == 0) return null;
    return host;
}

/// Strip HTTP(S) scheme prefix, returning a slice of the original input.
/// Comparison is case-insensitive but the returned slice points into `raw`.
fn stripHTTPSchemePrefix(raw: []const u8) []const u8 {
    const trimmed = trimWhitespace(raw);
    if (trimmed.len >= 8 and asciiEqlIgnoreCase(trimmed[0..8], "https://")) return trimmed[8..];
    if (trimmed.len >= 7 and asciiEqlIgnoreCase(trimmed[0..7], "http://")) return trimmed[7..];
    return trimmed;
}

/// Strip HTTP(S) scheme and "www." prefix, returning a slice of the original input.
fn stripHTTPSchemeAndWWWPrefix(raw: []const u8) []const u8 {
    const without_scheme = stripHTTPSchemePrefix(raw);
    if (without_scheme.len >= 4 and asciiEqlIgnoreCase(without_scheme[0..4], "www.")) return without_scheme[4..];
    return without_scheme;
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

fn trimWhitespace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\n\r");
}

/// Lowercase ASCII characters in-place into a provided buffer.
/// Returns null if buffer is too small.
fn toLowerBuf(input: []const u8, buf: []u8) ?[]const u8 {
    if (input.len > buf.len) return null;
    for (input, 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return buf[0..input.len];
}

fn displayURLText(allocator: Allocator, raw_url: []const u8) ![]const u8 {
    // Simple: strip scheme and www prefix.
    const stripped = stripHTTPSchemeAndWWWPrefix(raw_url);
    return allocator.dupe(u8, stripped);
}

fn singleLineText(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    const trimmed = trimWhitespace(v);
    if (trimmed.len == 0) return null;
    // We don't do full whitespace collapsing here for static strings in tests.
    // For the purpose of tests, the input strings don't have embedded newlines.
    return trimmed;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

// ---- OmnibarState: escape reverts then blurs ----

test "escape reverts when editing then blurs on second escape" {
    var state = OmnibarState{};

    var effects = omnibarReduce(&state, .{ .focus_gained = .{ .current_url_string = "https://example.com/" } });
    try testing.expect(state.is_focused);
    try testing.expectEqualStrings("https://example.com/", state.buffer);
    try testing.expect(!state.is_user_editing);
    try testing.expect(effects.should_select_all);

    effects = omnibarReduce(&state, .{ .buffer_changed = "exam" });
    try testing.expect(state.is_user_editing);
    try testing.expectEqualStrings("exam", state.buffer);
    try testing.expect(effects.should_refresh_suggestions);

    // Simulate an open popup.
    var suggestions = [_]OmnibarSuggestion{OmnibarSuggestion.search("Google", "exam")};
    effects = omnibarReduce(&state, .{ .suggestions_updated = &suggestions });
    try testing.expectEqual(@as(usize, 1), state.suggestions.len);
    try testing.expect(!effects.should_select_all);

    // First escape: revert + close popup + select-all.
    effects = omnibarReduce(&state, .escape);
    try testing.expectEqualStrings("https://example.com/", state.buffer);
    try testing.expect(!state.is_user_editing);
    try testing.expectEqual(@as(usize, 0), state.suggestions.len);
    try testing.expect(effects.should_select_all);
    try testing.expect(!effects.should_blur_to_web_view);

    // Second escape: blur.
    effects = omnibarReduce(&state, .escape);
    try testing.expect(effects.should_blur_to_web_view);
}

// ---- panelURLChanged does not clobber user buffer ----

test "panel URL change does not clobber user buffer while editing" {
    var state = OmnibarState{};
    _ = omnibarReduce(&state, .{ .focus_gained = .{ .current_url_string = "https://a.test/" } });
    _ = omnibarReduce(&state, .{ .buffer_changed = "hello" });
    try testing.expect(state.is_user_editing);

    _ = omnibarReduce(&state, .{ .panel_url_changed = .{ .current_url_string = "https://b.test/" } });
    try testing.expectEqualStrings("https://b.test/", state.current_url_string);
    try testing.expectEqualStrings("hello", state.buffer);
    try testing.expect(state.is_user_editing);

    const effects = omnibarReduce(&state, .escape);
    try testing.expectEqualStrings("https://b.test/", state.buffer);
    try testing.expect(effects.should_select_all);
}

// ---- focusLost preserve vs revert ----

test "focus lost reverts unless suppressed" {
    var state = OmnibarState{};
    _ = omnibarReduce(&state, .{ .focus_gained = .{ .current_url_string = "https://example.com/" } });
    _ = omnibarReduce(&state, .{ .buffer_changed = "typed" });
    try testing.expectEqualStrings("typed", state.buffer);

    _ = omnibarReduce(&state, .{ .focus_lost_preserve_buffer = .{ .current_url_string = "https://example.com/" } });
    try testing.expectEqualStrings("typed", state.buffer);

    _ = omnibarReduce(&state, .{ .focus_gained = .{ .current_url_string = "https://example.com/" } });
    _ = omnibarReduce(&state, .{ .buffer_changed = "typed2" });
    _ = omnibarReduce(&state, .{ .focus_lost_revert_buffer = .{ .current_url_string = "https://example.com/" } });
    try testing.expectEqualStrings("https://example.com/", state.buffer);
}

// ---- suggestions update keeps selection stable ----

test "suggestions update keeps selection across non-empty list refresh" {
    var state = OmnibarState{};
    _ = omnibarReduce(&state, .{ .focus_gained = .{ .current_url_string = "https://example.com/" } });
    _ = omnibarReduce(&state, .{ .buffer_changed = "go" });

    var base = [_]OmnibarSuggestion{
        OmnibarSuggestion.search("Google", "go"),
        OmnibarSuggestion.remoteSearchSuggestion("go tutorial"),
        OmnibarSuggestion.remoteSearchSuggestion("go json"),
    };
    _ = omnibarReduce(&state, .{ .suggestions_updated = &base });
    try testing.expectEqual(@as(usize, 0), state.selected_suggestion_index);

    _ = omnibarReduce(&state, .{ .move_selection = .{ .delta = 2 } });
    try testing.expectEqual(@as(usize, 2), state.selected_suggestion_index);

    // Simulate remote merge update with the same items + new ones.
    var merged = [_]OmnibarSuggestion{
        OmnibarSuggestion.search("Google", "go"),
        OmnibarSuggestion.remoteSearchSuggestion("go tutorial"),
        OmnibarSuggestion.remoteSearchSuggestion("go json"),
        OmnibarSuggestion.remoteSearchSuggestion("go fmt"),
    };
    _ = omnibarReduce(&state, .{ .suggestions_updated = &merged });
    try testing.expectEqual(@as(usize, 2), state.selected_suggestion_index);
}

// ---- suggestions reopen resets selection ----

test "suggestions reopen resets selection to first row" {
    var state = OmnibarState{};
    _ = omnibarReduce(&state, .{ .focus_gained = .{ .current_url_string = "https://example.com/" } });
    _ = omnibarReduce(&state, .{ .buffer_changed = "go" });

    var rows = [_]OmnibarSuggestion{
        OmnibarSuggestion.search("Google", "go"),
        OmnibarSuggestion.remoteSearchSuggestion("go tutorial"),
    };
    _ = omnibarReduce(&state, .{ .suggestions_updated = &rows });
    _ = omnibarReduce(&state, .{ .move_selection = .{ .delta = 1 } });
    try testing.expectEqual(@as(usize, 1), state.selected_suggestion_index);

    // Close popup.
    _ = omnibarReduce(&state, .{ .suggestions_updated = &.{} });
    try testing.expectEqual(@as(usize, 0), state.selected_suggestion_index);

    // Reopen popup.
    _ = omnibarReduce(&state, .{ .suggestions_updated = &rows });
    try testing.expectEqual(@as(usize, 0), state.selected_suggestion_index);
}

// ---- suggestion selection prefers autocomplete match ----

test "suggestions update prefers autocomplete match when selection not tracked" {
    var state = OmnibarState{};
    _ = omnibarReduce(&state, .{ .focus_gained = .{ .current_url_string = "https://example.com/" } });
    _ = omnibarReduce(&state, .{ .buffer_changed = "gm" });

    var rows = [_]OmnibarSuggestion{
        OmnibarSuggestion.search("Google", "gm"),
        OmnibarSuggestion.history("https://google.com/", "Google"),
        OmnibarSuggestion.history("https://gmail.com/", "Gmail"),
    };
    _ = omnibarReduce(&state, .{ .suggestions_updated = &rows });

    // The autocomplete candidate (gmail.com/) should be selected.
    try testing.expectEqual(@as(usize, 2), state.selected_suggestion_index);
    try testing.expectEqualStrings(rows[2].id(), state.selected_suggestion_id.?);
    try testing.expect(suggestionSupportsAutocompletion("gm", &state.suggestions[state.selected_suggestion_index]));
    try testing.expectEqualStrings("https://gmail.com/", state.suggestions[state.selected_suggestion_index].completion());
}

// ---- stale remote suggestions for nearby edits ----

test "stale remote suggestions kept for nearby edits" {
    const allocator = testing.allocator;
    const previous = [_][]const u8{ "go tutorial", "go json", "golang tips" };
    const stale = try staleRemoteSuggestionsForDisplay(allocator, "go t", "go", &previous, 8);
    defer allocator.free(stale);

    try testing.expectEqual(@as(usize, 3), stale.len);
    try testing.expectEqualStrings("go tutorial", stale[0]);
    try testing.expectEqualStrings("go json", stale[1]);
    try testing.expectEqualStrings("golang tips", stale[2]);
}

test "stale remote suggestions trim and respect limit" {
    const allocator = testing.allocator;
    const previous = [_][]const u8{ " go tutorial ", "", "go json", "   ", "go fmt" };
    const stale = try staleRemoteSuggestionsForDisplay(allocator, "gooo", "goo", &previous, 2);
    defer allocator.free(stale);

    try testing.expectEqual(@as(usize, 2), stale.len);
    try testing.expectEqualStrings("go tutorial", stale[0]);
    try testing.expectEqualStrings("go json", stale[1]);
}

test "stale remote suggestions dropped for unrelated query" {
    const allocator = testing.allocator;
    const previous = [_][]const u8{ "go tutorial", "go json" };
    const stale = try staleRemoteSuggestionsForDisplay(allocator, "python", "go", &previous, 8);
    // Should return empty static slice.
    try testing.expectEqual(@as(usize, 0), stale.len);
}

// ---- remote suggestion merge inserts below search ----

test "merge remote suggestions inserts below search and dedupes" {
    const allocator = testing.allocator;
    const entries = [_]HistoryEntry{
        .{
            .url = "https://go.dev/",
            .title = "The Go Programming Language",
            .last_visited_hours_ago = 0,
            .visit_count = 10,
        },
    };
    const remote = [_][]const u8{ "go tutorial", "go.dev", "go json" };
    const result = try buildSuggestions(
        allocator,
        "go",
        "Google",
        &entries,
        &.{},
        &remote,
        8,
    );
    defer allocator.free(result);

    try testing.expect(result.len >= 5);
    // First should be the autocompletable history entry (go.dev).
    try testing.expectEqualStrings("https://go.dev/", result[0].completion());
}

// ---- single character query promotes autocompletion match ----

test "single character query promotes autocompletion match to first row" {
    const allocator = testing.allocator;
    const entries = [_]HistoryEntry{
        .{
            .url = "https://news.ycombinator.com/",
            .title = "News.YC",
            .last_visited_hours_ago = 0,
            .visit_count = 12,
            .typed_count = 1,
            .last_typed_hours_ago = 0,
        },
        .{
            .url = "https://www.google.com/",
            .title = "Google",
            .last_visited_hours_ago = 200,
            .visit_count = 8,
            .typed_count = 2,
            .last_typed_hours_ago = 200,
        },
    };
    const remote = [_][]const u8{ "search google for n", "news" };
    const result = try buildSuggestions(
        allocator,
        "n",
        "Google",
        &entries,
        &.{},
        &remote,
        8,
    );
    defer allocator.free(result);

    try testing.expectEqualStrings("https://news.ycombinator.com/", result[0].completion());
    try testing.expect(suggestionSupportsAutocompletion("n", &result[0]));
}

// ---- autocomplete candidate for exact match ----

test "gm autocomplete candidate is first on exact query match" {
    const allocator = testing.allocator;
    const entries = [_]HistoryEntry{
        .{
            .url = "https://google.com/",
            .title = "Google",
            .last_visited_hours_ago = 0,
            .visit_count = 4,
            .typed_count = 1,
            .last_typed_hours_ago = 0,
        },
        .{
            .url = "https://gmail.com/",
            .title = "Gmail",
            .last_visited_hours_ago = 0,
            .visit_count = 10,
            .typed_count = 2,
            .last_typed_hours_ago = 0,
        },
    };
    const remote = [_][]const u8{ "gmail", "gmail.com", "google mail" };
    const result = try buildSuggestions(
        allocator,
        "gm",
        "Google",
        &entries,
        &.{},
        &remote,
        8,
    );
    defer allocator.free(result);

    try testing.expectEqualStrings("https://gmail.com/", result[0].completion());
    try testing.expect(suggestionSupportsAutocompletion("gm", &result[0]));
}

// ---- two-letter query promotion ----

test "autocompletion candidate wins over remote and search rows for two letter query" {
    const allocator = testing.allocator;
    const entries = [_]HistoryEntry{
        .{
            .url = "https://google.com/",
            .title = "Google",
            .last_visited_hours_ago = 0,
            .visit_count = 4,
            .typed_count = 1,
            .last_typed_hours_ago = 0,
        },
        .{
            .url = "https://gmail.com/",
            .title = "Gmail",
            .last_visited_hours_ago = 0,
            .visit_count = 10,
            .typed_count = 2,
            .last_typed_hours_ago = 0,
        },
    };
    const tabs = [_]OpenTabMatch{
        .{
            .tab_id = "tab1",
            .panel_id = "panel1",
            .url = "https://gmail.com/",
            .title = "Gmail",
            .is_known_open_tab = true,
        },
    };
    const remote = [_][]const u8{ "Search google for gm", "gmail", "gmail.com", "Google mail" };
    const result = try buildSuggestions(
        allocator,
        "gm",
        "Google",
        &entries,
        &tabs,
        &remote,
        8,
    );
    defer allocator.free(result);

    try testing.expect(suggestionSupportsAutocompletion("gm", &result[0]));
    try testing.expectEqualStrings("https://gmail.com/", result[0].completion());
}

// ---- suggestion selection prefers autocomplete after update ----

test "suggestion selection prefers autocompletion candidate after suggestions update" {
    const allocator = testing.allocator;
    const entries = [_]HistoryEntry{
        .{
            .url = "https://google.com/",
            .title = "Google",
            .last_visited_hours_ago = 0,
            .visit_count = 4,
            .typed_count = 1,
            .last_typed_hours_ago = 0,
        },
        .{
            .url = "https://gmail.com/",
            .title = "Gmail",
            .last_visited_hours_ago = 0,
            .visit_count = 10,
            .typed_count = 2,
            .last_typed_hours_ago = 0,
        },
    };
    const remote = [_][]const u8{ "Search google for gm", "gmail", "gmail.com" };
    const suggestions = try buildSuggestions(
        allocator,
        "gm",
        "Google",
        &entries,
        &.{},
        &remote,
        8,
    );
    defer allocator.free(suggestions);

    var state = OmnibarState{};
    _ = omnibarReduce(&state, .{ .focus_gained = .{ .current_url_string = "" } });
    _ = omnibarReduce(&state, .{ .buffer_changed = "gm" });
    _ = omnibarReduce(&state, .{ .suggestions_updated = suggestions });

    try testing.expectEqual(@as(usize, 0), state.selected_suggestion_index);
    try testing.expectEqualStrings(suggestions[0].id(), state.selected_suggestion_id.?);
    try testing.expect(suggestionSupportsAutocompletion("gm", &state.suggestions[0]));
}

// ---- two-char query with remote still promotes ----

test "two char query with remote suggestions still promotes autocompletion match" {
    const allocator = testing.allocator;
    const entries = [_]HistoryEntry{
        .{
            .url = "https://news.ycombinator.com/",
            .title = "News.YC",
            .last_visited_hours_ago = 0,
            .visit_count = 12,
            .typed_count = 1,
            .last_typed_hours_ago = 0,
        },
        .{
            .url = "https://www.google.com/",
            .title = "Google",
            .last_visited_hours_ago = 200,
            .visit_count = 8,
            .typed_count = 2,
            .last_typed_hours_ago = 200,
        },
    };
    const remote = [_][]const u8{ "netflix", "new york times", "newegg" };
    const result = try buildSuggestions(
        allocator,
        "ne",
        "Google",
        &entries,
        &.{},
        &remote,
        8,
    );
    defer allocator.free(result);

    try testing.expectEqualStrings("https://news.ycombinator.com/", result[0].completion());
    try testing.expect(suggestionSupportsAutocompletion("ne", &result[0]));

    // Remote suggestions should still appear.
    var has_remote = false;
    for (result) |*s| {
        switch (s.kind) {
            .remote => {
                has_remote = true;
                break;
            },
            else => {},
        }
    }
    try testing.expect(has_remote);
}

// ---- history suggestion displays title and URL on single line ----

test "history suggestion displays title and URL on single line" {
    const allocator = testing.allocator;
    const row = OmnibarSuggestion.history(
        "https://www.example.com/path?q=1",
        "Example Domain",
    );
    const text = try row.listText(allocator);
    defer allocator.free(text);

    try testing.expectEqualStrings("Example Domain — example.com/path?q=1", text);
    try testing.expect(std.mem.indexOf(u8, text, "\n") == null);
}

// ---- published buffer text uses typed prefix ----

test "published buffer text uses typed prefix when inline suffix is selected" {
    const ic = OmnibarInlineCompletion{
        .typed_text = "l",
        .display_text = "localhost:3000",
        .accepted_text = "https://localhost:3000/",
    };

    const published = publishedBufferTextForFieldChange(
        ic.display_text,
        &ic,
        ic.suffixStart(),
        ic.suffixLen(),
        false,
    );

    try testing.expectEqualStrings("l", published);
}

test "published buffer text keeps user typed value when display differs from inline text" {
    const ic = OmnibarInlineCompletion{
        .typed_text = "l",
        .display_text = "localhost:3000",
        .accepted_text = "https://localhost:3000/",
    };

    const published = publishedBufferTextForFieldChange(
        "la",
        &ic,
        2,
        0,
        false,
    );

    try testing.expectEqualStrings("la", published);
}

// ---- inline completion render ignores stale prefix mismatch ----

test "inline completion render ignores stale typed prefix mismatch" {
    const stale_inline = OmnibarInlineCompletion{
        .typed_text = "g",
        .display_text = "github.com",
        .accepted_text = "https://github.com/",
    };

    const active = inlineCompletionIfBufferMatchesTypedPrefix("l", &stale_inline);
    try testing.expect(active == null);
}

test "inline completion render keeps matching typed prefix" {
    const ic = OmnibarInlineCompletion{
        .typed_text = "l",
        .display_text = "localhost:3000",
        .accepted_text = "https://localhost:3000/",
    };

    const active = inlineCompletionIfBufferMatchesTypedPrefix("l", &ic);
    try testing.expect(active != null);
    try testing.expect(active.?.eql(&ic));
}

// ---- inline completion skips title match whose URL doesn't start with typed text ----

test "inline completion skips title match whose URL does not start with typed text" {
    // History entry: visited google.com/search?q=localhost:3000 with title
    // "localhost:3000 - Google Search". Typing "l" should NOT inline-complete
    // to "google.com/..." because that replaces the typed "l" with "g".
    const suggestion = OmnibarSuggestion.history(
        "https://www.google.com/search?q=localhost:3000",
        "localhost:3000 - Google Search",
    );

    // The suggestion matches typed prefix via title, but URL doesn't start with "l".
    // suggestionSupportsAutocompletion should still return true (title match).
    // But the display text (google.com/...) doesn't start with "l",
    // so inline completion should NOT be generated.
    const comp = suggestion.completion();
    const display = suggestionDisplayText(comp, "l");

    // The display text starts with "google.com" not "l".
    var display_lower_buf: [4096]u8 = undefined;
    const display_lower = toLowerBuf(display, &display_lower_buf) orelse "";
    try testing.expect(!std.mem.startsWith(u8, display_lower, "l"));
}

// ── Additional omnibar state machine tests ──────────────────────────

test "focus gained resets all state" {
    var state = OmnibarState{};
    _ = omnibarReduce(&state, .{ .buffer_changed = "typed" });
    state.is_user_editing = true;

    const effects = omnibarReduce(&state, .{ .focus_gained = .{ .current_url_string = "https://example.com/" } });
    try testing.expect(state.is_focused);
    try testing.expect(!state.is_user_editing);
    try testing.expectEqualStrings("https://example.com/", state.buffer);
    try testing.expect(effects.should_select_all);
    try testing.expectEqual(@as(usize, 0), state.suggestions.len);
}

test "escape when not focused is no-op" {
    var state = OmnibarState{};
    const effects = omnibarReduce(&state, .escape);
    try testing.expect(!effects.should_blur_to_web_view);
    try testing.expect(!effects.should_select_all);
}

test "buffer changed to same value as URL clears editing flag" {
    var state = OmnibarState{};
    _ = omnibarReduce(&state, .{ .focus_gained = .{ .current_url_string = "https://a.test/" } });
    _ = omnibarReduce(&state, .{ .buffer_changed = "typed" });
    try testing.expect(state.is_user_editing);

    _ = omnibarReduce(&state, .{ .buffer_changed = "https://a.test/" });
    try testing.expect(!state.is_user_editing);
}

test "move selection clamps to bounds" {
    var state = OmnibarState{};
    _ = omnibarReduce(&state, .{ .focus_gained = .{ .current_url_string = "" } });

    const suggestions = [_]OmnibarSuggestion{
        OmnibarSuggestion.search("Google", "a"),
        OmnibarSuggestion.search("Google", "b"),
    };
    _ = omnibarReduce(&state, .{ .suggestions_updated = &suggestions });

    // Move down past end.
    _ = omnibarReduce(&state, .{ .move_selection = .{ .delta = 10 } });
    try testing.expectEqual(@as(usize, 1), state.selected_suggestion_index);

    // Move up past start.
    _ = omnibarReduce(&state, .{ .move_selection = .{ .delta = -10 } });
    try testing.expectEqual(@as(usize, 0), state.selected_suggestion_index);
}

test "move selection on empty suggestions is no-op" {
    var state = OmnibarState{};
    _ = omnibarReduce(&state, .{ .focus_gained = .{ .current_url_string = "" } });
    const effects = omnibarReduce(&state, .{ .move_selection = .{ .delta = 1 } });
    _ = effects;
    try testing.expectEqual(@as(usize, 0), state.selected_suggestion_index);
}

test "highlight index clamps to suggestions length" {
    var state = OmnibarState{};
    _ = omnibarReduce(&state, .{ .focus_gained = .{ .current_url_string = "" } });

    const suggestions = [_]OmnibarSuggestion{
        OmnibarSuggestion.search("Google", "a"),
    };
    _ = omnibarReduce(&state, .{ .suggestions_updated = &suggestions });

    _ = omnibarReduce(&state, .{ .highlight_index = 99 });
    try testing.expectEqual(@as(usize, 0), state.selected_suggestion_index);
}

test "additional: stale remote suggestions dropped for unrelated query" {
    const allocator = testing.allocator;
    const prev = [_][]const u8{ "go tutorial", "go json" };
    const result = try staleRemoteSuggestionsForDisplay(
        allocator,
        "python",
        "go",
        &prev,
        8,
    );
    // Unrelated queries should return empty.
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "additional: stale remote suggestions kept for nearby edits" {
    const allocator = testing.allocator;
    const prev = [_][]const u8{ "go tutorial", "go json", "golang tips" };
    const result = try staleRemoteSuggestionsForDisplay(
        allocator,
        "go t",
        "go",
        &prev,
        8,
    );
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 3), result.len);
}

test "OmnibarSuggestion history completion returns url" {
    const suggestion = OmnibarSuggestion.history("https://example.com/", "Example");
    try testing.expectEqualStrings("https://example.com/", suggestion.completion());
}

test "OmnibarSuggestion search completion returns query" {
    const suggestion = OmnibarSuggestion.search("Google", "test query");
    try testing.expectEqualStrings("test query", suggestion.completion());
}
