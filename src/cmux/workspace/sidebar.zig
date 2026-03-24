/// Sidebar metadata types for workspace status display.
///
/// These types store sidebar information reported by shell integration,
/// agents, and socket commands. They match the macOS reference types:
/// SidebarStatusEntry, SidebarMetadataBlock, SidebarLogEntry, etc.
///
/// String fields are unowned slices — the Workspace that contains these
/// types is responsible for allocating and freeing the backing memory.

pub const MetadataFormat = enum {
    plain,
    markdown,
};

pub const StatusEntry = struct {
    key: []const u8,
    value: []const u8,
    icon: ?[]const u8 = null,
    color: ?[]const u8 = null,
    url: ?[]const u8 = null,
    priority: i32 = 0,
    format: MetadataFormat = .plain,
    timestamp: i64 = 0,
};

pub const MetadataBlock = struct {
    key: []const u8,
    markdown: []const u8,
    priority: i32 = 0,
    timestamp: i64 = 0,
};

pub const LogLevel = enum {
    info,
    progress,
    success,
    warning,
    @"error",
};

pub const LogEntry = struct {
    message: []const u8,
    level: LogLevel = .info,
    source: ?[]const u8 = null,
    timestamp: i64 = 0,
};

pub const ProgressState = struct {
    value: f64,
    label: ?[]const u8 = null,
};

pub const GitBranchState = struct {
    branch: []const u8,
    is_dirty: bool = false,
};

pub const PullRequestStatus = enum {
    open,
    merged,
    closed,
};

pub const PullRequestChecksStatus = enum {
    pass,
    fail,
    pending,
};

pub const PullRequestState = struct {
    number: u32,
    label: []const u8,
    url: []const u8,
    status: PullRequestStatus = .open,
    branch: ?[]const u8 = null,
    checks: ?PullRequestChecksStatus = null,
};

pub const ShellActivityState = enum {
    unknown,
    prompt_idle,
    command_running,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const std = @import("std");

// Ported from macOS cmuxTests/SidebarOrderingTests.swift

test "Sidebar: metadata format enum values" {
    try std.testing.expect(MetadataFormat.plain != MetadataFormat.markdown);
    try std.testing.expectEqual(MetadataFormat.plain, MetadataFormat.plain);
}

test "Sidebar: status entry defaults" {
    // Corresponds to TerminalControllerSidebarDedupeTests — verifying that
    // a StatusEntry with only required fields has expected defaults.
    const entry = StatusEntry{ .key = "agent", .value = "idle" };
    try std.testing.expectEqualStrings("agent", entry.key);
    try std.testing.expectEqualStrings("idle", entry.value);
    try std.testing.expect(entry.icon == null);
    try std.testing.expect(entry.color == null);
    try std.testing.expect(entry.url == null);
    try std.testing.expectEqual(@as(i32, 0), entry.priority);
    try std.testing.expectEqual(MetadataFormat.plain, entry.format);
    try std.testing.expectEqual(@as(i64, 0), entry.timestamp);
}

test "Sidebar: status entry with all optional fields" {
    // Corresponds to testShouldReplaceStatusEntryReturnsFalseForUnchangedPayload
    const entry = StatusEntry{
        .key = "agent",
        .value = "idle",
        .icon = "bolt",
        .color = "#ffffff",
        .url = "https://example.com",
        .priority = 5,
        .format = .markdown,
        .timestamp = 123,
    };
    try std.testing.expectEqualStrings("bolt", entry.icon.?);
    try std.testing.expectEqualStrings("#ffffff", entry.color.?);
    try std.testing.expectEqualStrings("https://example.com", entry.url.?);
    try std.testing.expectEqual(@as(i32, 5), entry.priority);
    try std.testing.expectEqual(MetadataFormat.markdown, entry.format);
    try std.testing.expectEqual(@as(i64, 123), entry.timestamp);
}

test "Sidebar: metadata block defaults" {
    const block = MetadataBlock{ .key = "notes", .markdown = "# Hello" };
    try std.testing.expectEqualStrings("notes", block.key);
    try std.testing.expectEqualStrings("# Hello", block.markdown);
    try std.testing.expectEqual(@as(i32, 0), block.priority);
    try std.testing.expectEqual(@as(i64, 0), block.timestamp);
}

test "Sidebar: log level enum coverage" {
    // Ensure all five log levels exist and are distinct.
    const levels = [_]LogLevel{ .info, .progress, .success, .warning, .@"error" };
    for (levels, 0..) |level, i| {
        for (levels[i + 1 ..]) |other| {
            try std.testing.expect(level != other);
        }
    }
}

test "Sidebar: log entry defaults" {
    const entry = LogEntry{ .message = "hello world" };
    try std.testing.expectEqualStrings("hello world", entry.message);
    try std.testing.expectEqual(LogLevel.info, entry.level);
    try std.testing.expect(entry.source == null);
    try std.testing.expectEqual(@as(i64, 0), entry.timestamp);
}

test "Sidebar: log entry with all fields" {
    const entry = LogEntry{
        .message = "deploy started",
        .level = .warning,
        .source = "ci",
        .timestamp = 1700000000,
    };
    try std.testing.expectEqual(LogLevel.warning, entry.level);
    try std.testing.expectEqualStrings("ci", entry.source.?);
    try std.testing.expectEqual(@as(i64, 1700000000), entry.timestamp);
}

test "Sidebar: progress state defaults" {
    // Corresponds to testShouldReplaceProgressReturnsFalseForUnchangedPayload
    const p = ProgressState{ .value = 0.42 };
    try std.testing.expectEqual(@as(f64, 0.42), p.value);
    try std.testing.expect(p.label == null);
}

test "Sidebar: progress state with label" {
    const p = ProgressState{ .value = 0.75, .label = "indexing" };
    try std.testing.expectEqual(@as(f64, 0.75), p.value);
    try std.testing.expectEqualStrings("indexing", p.label.?);
}

test "Sidebar: git branch state defaults" {
    // Corresponds to testShouldReplaceGitBranchReturnsFalseForUnchangedPayload
    const g = GitBranchState{ .branch = "main" };
    try std.testing.expectEqualStrings("main", g.branch);
    try std.testing.expect(!g.is_dirty);
}

test "Sidebar: git branch state dirty" {
    const g = GitBranchState{ .branch = "feature", .is_dirty = true };
    try std.testing.expectEqualStrings("feature", g.branch);
    try std.testing.expect(g.is_dirty);
}

test "Sidebar: pull request status enum coverage" {
    const statuses = [_]PullRequestStatus{ .open, .merged, .closed };
    for (statuses, 0..) |s, i| {
        for (statuses[i + 1 ..]) |other| {
            try std.testing.expect(s != other);
        }
    }
}

test "Sidebar: pull request checks status enum coverage" {
    const checks = [_]PullRequestChecksStatus{ .pass, .fail, .pending };
    for (checks, 0..) |c, i| {
        for (checks[i + 1 ..]) |other| {
            try std.testing.expect(c != other);
        }
    }
}

test "Sidebar: pull request state defaults" {
    const pr = PullRequestState{
        .number = 42,
        .label = "PR",
        .url = "https://github.com/manaflow-ai/cmux/pull/42",
    };
    try std.testing.expectEqual(@as(u32, 42), pr.number);
    try std.testing.expectEqualStrings("PR", pr.label);
    try std.testing.expectEqualStrings("https://github.com/manaflow-ai/cmux/pull/42", pr.url);
    try std.testing.expectEqual(PullRequestStatus.open, pr.status);
    try std.testing.expect(pr.branch == null);
    try std.testing.expect(pr.checks == null);
}

test "Sidebar: pull request state with all fields" {
    // Corresponds to testOrderedUniquePullRequestsPrefersEntryWithChecksWhenStatusesMatch
    const pr = PullRequestState{
        .number = 42,
        .label = "PR",
        .url = "https://github.com/manaflow-ai/cmux/pull/42",
        .status = .merged,
        .branch = "feature/sidebar-pr",
        .checks = .pass,
    };
    try std.testing.expectEqual(PullRequestStatus.merged, pr.status);
    try std.testing.expectEqualStrings("feature/sidebar-pr", pr.branch.?);
    try std.testing.expectEqual(PullRequestChecksStatus.pass, pr.checks.?);
}

test "Sidebar: pull request same number different labels are distinct" {
    // Corresponds to testOrderedUniquePullRequestsTreatsSameNumberDifferentLabelsAsDistinct
    const pr1 = PullRequestState{
        .number = 42,
        .label = "PR",
        .url = "https://github.com/manaflow-ai/cmux/pull/42",
    };
    const pr2 = PullRequestState{
        .number = 42,
        .label = "MR",
        .url = "https://gitlab.com/manaflow/cmux/-/merge_requests/42",
    };
    // Same number but different labels — should not be considered equal.
    try std.testing.expect(!std.mem.eql(u8, pr1.label, pr2.label));
    try std.testing.expectEqual(pr1.number, pr2.number);
}

test "Sidebar: shell activity state enum coverage" {
    const states = [_]ShellActivityState{ .unknown, .prompt_idle, .command_running };
    for (states, 0..) |s, i| {
        for (states[i + 1 ..]) |other| {
            try std.testing.expect(s != other);
        }
    }
}

// TODO: Port SidebarActiveForegroundColorTests — requires
// sidebarActiveForegroundNSColor equivalent (GTK/Adwaita color API).

// TODO: Port SidebarBranchLayoutSettingsTests — requires
// SidebarBranchLayoutSettings with GSettings/dconf backend.

// TODO: Port SidebarActiveTabIndicatorSettingsTests — requires
// SidebarActiveTabIndicatorSettings with GSettings/dconf backend.

// TODO: Port SidebarRemoteErrorCopySupportTests — requires
// SidebarRemoteErrorCopySupport.menuLabel/clipboardText (error
// formatting for clipboard, not yet implemented).

// TODO: Port SidebarBranchOrderingTests (orderedUniqueBranches,
// orderedUniqueBranchDirectoryEntries, orderedUniquePullRequests) —
// requires SidebarBranchOrdering module with panel-ordered
// deduplication logic (not yet implemented in Zig).

// TODO: Port SidebarDropPlannerTests (indicator, targetIndex, pinned
// boundary snapping, pointer edge suppression) — requires
// SidebarDropPlanner with drag-and-drop indicator resolution
// (not yet implemented in Zig).

// TODO: Port SidebarDragAutoScrollPlannerTests — requires
// SidebarDragAutoScrollPlanner with edge-proximity scroll logic
// (not yet implemented in Zig).

// TODO: Port TerminalControllerSidebarDedupeTests
// (shouldReplaceStatusEntry, shouldReplaceProgress,
// shouldReplaceGitBranch, shouldReplacePorts, explicitSocketScope,
// normalizeReportedDirectory) — requires TerminalController
// sidebar dedup helpers (not yet implemented in Zig).

// TODO: Port testUpdatePanelPullRequestPreservesExistingChecksWhenUpdateOmitsThem,
// testUpdatePanelGitBranchClearsFocusedPullRequestWhenBranchChanges,
// testSidebarPullRequestsHideBranchMismatches — requires Workspace
// pull-request lifecycle methods with branch-mismatch filtering
// (not yet implemented in Zig).
