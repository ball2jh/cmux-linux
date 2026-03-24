const std = @import("std");
const Uuid = @import("../uuid.zig").Uuid;
const PanelType = @import("Panel.zig").PanelType;

/// Session persistence snapshot types.
///
/// These types capture the full serializable state of workspaces for
/// save/restore. Each snapshot owns its string data (allocated from
/// a provided allocator) and must be freed with `deinit`.
///
/// Matches macOS SessionPersistence.swift: SessionWorkspaceSnapshot,
/// SessionPanelSnapshot, SessionWorkspaceLayoutSnapshot, etc.

// --- Leaf snapshot types ---

pub const StatusEntrySnapshot = struct {
    key: []const u8,
    value: []const u8,
    icon: ?[]const u8 = null,
    color: ?[]const u8 = null,
    timestamp: f64 = 0,
};

pub const LogEntrySnapshot = struct {
    message: []const u8,
    level: []const u8 = "info",
    source: ?[]const u8 = null,
    timestamp: f64 = 0,
};

pub const ProgressSnapshot = struct {
    value: f64,
    label: ?[]const u8 = null,
};

pub const GitBranchSnapshot = struct {
    branch: []const u8,
    is_dirty: bool = false,
};

// --- Panel snapshots ---

pub const TerminalPanelSnapshot = struct {
    working_directory: ?[]const u8 = null,
    scrollback: ?[]const u8 = null,
};

pub const BrowserPanelSnapshot = struct {
    url_string: ?[]const u8 = null,
    profile_id: ?Uuid = null,
    should_render_web_view: bool = true,
    page_zoom: f64 = 1.0,
    developer_tools_visible: bool = false,
    back_history_url_strings: []const []const u8 = &.{},
    forward_history_url_strings: []const []const u8 = &.{},
};

pub const MarkdownPanelSnapshot = struct {
    file_path: []const u8,
};

pub const PanelSnapshot = struct {
    id: Uuid,
    panel_type: PanelType,
    title: ?[]const u8 = null,
    custom_title: ?[]const u8 = null,
    directory: ?[]const u8 = null,
    is_pinned: bool = false,
    is_manually_unread: bool = false,
    git_branch: ?GitBranchSnapshot = null,
    listening_ports: []const u16 = &.{},
    tty_name: ?[]const u8 = null,
    terminal: ?TerminalPanelSnapshot = null,
    browser: ?BrowserPanelSnapshot = null,
    markdown: ?MarkdownPanelSnapshot = null,
};

// --- Layout snapshots ---

pub const SplitOrientation = enum {
    horizontal,
    vertical,
};

pub const PaneLayoutSnapshot = struct {
    panel_ids: []const Uuid = &.{},
    selected_panel_id: ?Uuid = null,
};

pub const SplitLayoutSnapshot = struct {
    orientation: SplitOrientation,
    divider_position: f64,
    first: *LayoutSnapshot,
    second: *LayoutSnapshot,
};

pub const LayoutSnapshot = union(enum) {
    pane: PaneLayoutSnapshot,
    split: SplitLayoutSnapshot,
};

// --- Top-level snapshots ---

pub const WorkspaceSnapshot = struct {
    process_title: []const u8 = "",
    custom_title: ?[]const u8 = null,
    custom_color: ?[]const u8 = null,
    is_pinned: bool = false,
    current_directory: []const u8 = "",
    focused_panel_id: ?Uuid = null,
    layout: ?LayoutSnapshot = null,
    panels: []const PanelSnapshot = &.{},
    status_entries: []const StatusEntrySnapshot = &.{},
    log_entries: []const LogEntrySnapshot = &.{},
    progress: ?ProgressSnapshot = null,
    git_branch: ?GitBranchSnapshot = null,
};

pub const TabManagerSnapshot = struct {
    selected_workspace_index: ?usize = null,
    workspaces: []const WorkspaceSnapshot = &.{},
};

// --- Window / app-level snapshots ---

pub const SessionSidebarSelection = enum {
    tabs,
    notifications,
};

pub const SessionSidebarSnapshot = struct {
    is_visible: bool = true,
    selection: SessionSidebarSelection = .tabs,
    width: ?f64 = null,
};

pub const SessionRectSnapshot = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const SessionDisplaySnapshot = struct {
    display_id: ?u32 = null,
    frame: ?SessionRectSnapshot = null,
    visible_frame: ?SessionRectSnapshot = null,
};

pub const SessionWindowSnapshot = struct {
    frame: ?SessionRectSnapshot = null,
    display: ?SessionDisplaySnapshot = null,
    tab_manager: TabManagerSnapshot = .{},
    sidebar: SessionSidebarSnapshot = .{},
};

pub const AppSessionSnapshot = struct {
    pub const current_version: u32 = 1;

    version: u32 = current_version,
    created_at: f64 = 0,
    windows: []const SessionWindowSnapshot = &.{},
};

// --- Memory management ---

/// Free all owned memory in a LayoutSnapshot tree recursively.
pub fn freeLayout(allocator: std.mem.Allocator, layout: *LayoutSnapshot) void {
    switch (layout.*) {
        .pane => |pane| {
            if (pane.panel_ids.len > 0) allocator.free(pane.panel_ids);
        },
        .split => |split| {
            freeLayout(allocator, split.first);
            allocator.destroy(split.first);
            freeLayout(allocator, split.second);
            allocator.destroy(split.second);
        },
    }
}

/// Free all owned memory in a WorkspaceSnapshot.
pub fn freeWorkspaceSnapshot(allocator: std.mem.Allocator, snap: *WorkspaceSnapshot) void {
    freeStr(allocator, snap.process_title);
    if (snap.custom_title) |s| allocator.free(s);
    if (snap.custom_color) |s| allocator.free(s);
    freeStr(allocator, snap.current_directory);

    if (snap.layout) |*layout| freeLayout(allocator, layout);

    for (snap.panels) |*panel| {
        freePanelSnapshot(allocator, @constCast(panel));
    }
    if (snap.panels.len > 0) allocator.free(snap.panels);

    for (snap.status_entries) |*entry| {
        freeStatusEntrySnapshot(allocator, @constCast(entry));
    }
    if (snap.status_entries.len > 0) allocator.free(snap.status_entries);

    for (snap.log_entries) |*entry| {
        freeLogEntrySnapshot(allocator, @constCast(entry));
    }
    if (snap.log_entries.len > 0) allocator.free(snap.log_entries);

    if (snap.progress) |*p| {
        if (p.label) |s| allocator.free(s);
    }
    if (snap.git_branch) |*g| {
        allocator.free(g.branch);
    }
}

fn freePanelSnapshot(allocator: std.mem.Allocator, panel: *PanelSnapshot) void {
    if (panel.title) |s| allocator.free(s);
    if (panel.custom_title) |s| allocator.free(s);
    if (panel.directory) |s| allocator.free(s);
    if (panel.tty_name) |s| allocator.free(s);
    if (panel.listening_ports.len > 0) allocator.free(panel.listening_ports);
    if (panel.git_branch) |*g| allocator.free(g.branch);

    if (panel.terminal) |*t| {
        if (t.working_directory) |s| allocator.free(s);
        if (t.scrollback) |s| allocator.free(s);
    }
    if (panel.browser) |*b| {
        if (b.url_string) |s| allocator.free(s);
        for (b.back_history_url_strings) |s| allocator.free(s);
        if (b.back_history_url_strings.len > 0) allocator.free(b.back_history_url_strings);
        for (b.forward_history_url_strings) |s| allocator.free(s);
        if (b.forward_history_url_strings.len > 0) allocator.free(b.forward_history_url_strings);
    }
    if (panel.markdown) |*m| {
        freeStr(allocator, m.file_path);
    }
}

fn freeStatusEntrySnapshot(allocator: std.mem.Allocator, entry: *StatusEntrySnapshot) void {
    freeStr(allocator, entry.key);
    freeStr(allocator, entry.value);
    if (entry.icon) |s| allocator.free(s);
    if (entry.color) |s| allocator.free(s);
}

fn freeLogEntrySnapshot(allocator: std.mem.Allocator, entry: *LogEntrySnapshot) void {
    freeStr(allocator, entry.message);
    freeStr(allocator, entry.level);
    if (entry.source) |s| allocator.free(s);
}

/// Free all owned memory in a SessionWindowSnapshot.
fn freeWindowSnapshot(allocator: std.mem.Allocator, win: *SessionWindowSnapshot) void {
    for (win.tab_manager.workspaces) |*ws| {
        freeWorkspaceSnapshot(allocator, @constCast(ws));
    }
    if (win.tab_manager.workspaces.len > 0) allocator.free(win.tab_manager.workspaces);
}

/// Free all owned memory in an AppSessionSnapshot.
pub fn freeAppSessionSnapshot(allocator: std.mem.Allocator, snap: *AppSessionSnapshot) void {
    for (snap.windows) |*win| {
        freeWindowSnapshot(allocator, @constCast(win));
    }
    if (snap.windows.len > 0) allocator.free(snap.windows);
}

fn freeStr(allocator: std.mem.Allocator, s: []const u8) void {
    if (s.len > 0) allocator.free(s);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Ported from macOS cmuxTests/SessionPersistenceTests.swift

test "Snapshot: workspace snapshot defaults match expected initial values" {
    // Corresponds to makeSnapshot() helper — verifying default fields on a
    // freshly-constructed WorkspaceSnapshot match the macOS defaults.
    const snap_ws = WorkspaceSnapshot{};
    try std.testing.expectEqualStrings("", snap_ws.process_title);
    try std.testing.expect(snap_ws.custom_title == null);
    try std.testing.expect(snap_ws.custom_color == null);
    try std.testing.expect(!snap_ws.is_pinned);
    try std.testing.expectEqualStrings("", snap_ws.current_directory);
    try std.testing.expect(snap_ws.focused_panel_id == null);
    try std.testing.expect(snap_ws.layout == null);
    try std.testing.expectEqual(@as(usize, 0), snap_ws.panels.len);
    try std.testing.expectEqual(@as(usize, 0), snap_ws.status_entries.len);
    try std.testing.expectEqual(@as(usize, 0), snap_ws.log_entries.len);
    try std.testing.expect(snap_ws.progress == null);
    try std.testing.expect(snap_ws.git_branch == null);
}

test "Snapshot: workspace snapshot preserves custom color" {
    // Corresponds to testSaveAndLoadRoundTripPreservesWorkspaceCustomColor
    const alloc = std.testing.allocator;
    const color = try alloc.dupe(u8, "#C0392B");
    var snap_ws = WorkspaceSnapshot{
        .process_title = try alloc.dupe(u8, "Terminal"),
        .custom_title = try alloc.dupe(u8, "Restored"),
        .custom_color = color,
        .is_pinned = true,
        .current_directory = try alloc.dupe(u8, "/tmp"),
    };
    defer freeWorkspaceSnapshot(alloc, &snap_ws);

    try std.testing.expectEqualStrings("#C0392B", snap_ws.custom_color.?);
}

test "Snapshot: workspace snapshot custom color nil when absent" {
    // Corresponds to testWorkspaceCustomColorDecodeSupportsMissingLegacyField
    const snap_ws = WorkspaceSnapshot{};
    try std.testing.expect(snap_ws.custom_color == null);
}

test "Snapshot: browser panel snapshot defaults when optional fields missing" {
    // Corresponds to testSessionBrowserPanelSnapshotHistoryDecodesWhenKeysAreMissing
    const browser = BrowserPanelSnapshot{};
    try std.testing.expect(browser.url_string == null);
    try std.testing.expect(browser.profile_id == null);
    try std.testing.expect(browser.should_render_web_view);
    try std.testing.expectEqual(@as(f64, 1.0), browser.page_zoom);
    try std.testing.expect(!browser.developer_tools_visible);
    try std.testing.expectEqual(@as(usize, 0), browser.back_history_url_strings.len);
    try std.testing.expectEqual(@as(usize, 0), browser.forward_history_url_strings.len);
}

test "Snapshot: browser panel snapshot preserves all fields" {
    // Corresponds to testSessionBrowserPanelSnapshotHistoryRoundTrip
    const alloc = std.testing.allocator;
    const profile_id = try Uuid.parse("8f03a658-5a84-428b-ad03-5a6d04692f64");

    const back = try alloc.alloc([]const u8, 2);
    defer alloc.free(back);
    back[0] = try alloc.dupe(u8, "https://example.com/a");
    back[1] = try alloc.dupe(u8, "https://example.com/b");
    defer alloc.free(back[0]);
    defer alloc.free(back[1]);

    const fwd = try alloc.alloc([]const u8, 1);
    defer alloc.free(fwd);
    fwd[0] = try alloc.dupe(u8, "https://example.com/d");
    defer alloc.free(fwd[0]);

    const url = try alloc.dupe(u8, "https://example.com/current");
    defer alloc.free(url);

    const browser = BrowserPanelSnapshot{
        .url_string = url,
        .profile_id = profile_id,
        .should_render_web_view = true,
        .page_zoom = 1.2,
        .developer_tools_visible = true,
        .back_history_url_strings = back,
        .forward_history_url_strings = fwd,
    };

    try std.testing.expectEqualStrings("https://example.com/current", browser.url_string.?);
    try std.testing.expect(browser.profile_id.?.eql(profile_id));
    try std.testing.expectEqual(@as(usize, 2), browser.back_history_url_strings.len);
    try std.testing.expectEqualStrings("https://example.com/a", browser.back_history_url_strings[0]);
    try std.testing.expectEqualStrings("https://example.com/b", browser.back_history_url_strings[1]);
    try std.testing.expectEqual(@as(usize, 1), browser.forward_history_url_strings.len);
    try std.testing.expectEqualStrings("https://example.com/d", browser.forward_history_url_strings[0]);
    try std.testing.expectEqual(@as(f64, 1.2), browser.page_zoom);
    try std.testing.expect(browser.developer_tools_visible);
}

test "Snapshot: panel snapshot with markdown panel type" {
    // Corresponds to testWorkspaceSessionSnapshotRestoresMarkdownPanel
    const panel_id = Uuid.generate();
    const panel = PanelSnapshot{
        .id = panel_id,
        .panel_type = .markdown,
        .custom_title = "Readme",
        .markdown = .{ .file_path = "/tmp/note.md" },
    };

    try std.testing.expect(panel.id.eql(panel_id));
    try std.testing.expectEqual(PanelType.markdown, panel.panel_type);
    try std.testing.expectEqualStrings("Readme", panel.custom_title.?);
    try std.testing.expectEqualStrings("/tmp/note.md", panel.markdown.?.file_path);
    try std.testing.expect(panel.terminal == null);
    try std.testing.expect(panel.browser == null);
}

test "Snapshot: panel snapshot defaults" {
    const panel = PanelSnapshot{
        .id = Uuid.nil,
        .panel_type = .terminal,
    };

    try std.testing.expect(!panel.is_pinned);
    try std.testing.expect(!panel.is_manually_unread);
    try std.testing.expect(panel.title == null);
    try std.testing.expect(panel.custom_title == null);
    try std.testing.expect(panel.directory == null);
    try std.testing.expect(panel.git_branch == null);
    try std.testing.expectEqual(@as(usize, 0), panel.listening_ports.len);
    try std.testing.expect(panel.tty_name == null);
    try std.testing.expect(panel.terminal == null);
    try std.testing.expect(panel.browser == null);
    try std.testing.expect(panel.markdown == null);
}

test "Snapshot: terminal panel snapshot defaults" {
    const term = TerminalPanelSnapshot{};
    try std.testing.expect(term.working_directory == null);
    try std.testing.expect(term.scrollback == null);
}

test "Snapshot: progress snapshot construction" {
    const p = ProgressSnapshot{ .value = 0.75, .label = "indexing" };
    try std.testing.expectEqual(@as(f64, 0.75), p.value);
    try std.testing.expectEqualStrings("indexing", p.label.?);

    const p2 = ProgressSnapshot{ .value = 0.0 };
    try std.testing.expect(p2.label == null);
}

test "Snapshot: git branch snapshot defaults" {
    const g = GitBranchSnapshot{ .branch = "main" };
    try std.testing.expectEqualStrings("main", g.branch);
    try std.testing.expect(!g.is_dirty);

    const g2 = GitBranchSnapshot{ .branch = "feature", .is_dirty = true };
    try std.testing.expect(g2.is_dirty);
}

test "Snapshot: status entry snapshot defaults" {
    const entry = StatusEntrySnapshot{ .key = "agent", .value = "idle" };
    try std.testing.expect(entry.icon == null);
    try std.testing.expect(entry.color == null);
    try std.testing.expectEqual(@as(f64, 0), entry.timestamp);
}

test "Snapshot: log entry snapshot defaults" {
    const entry = LogEntrySnapshot{ .message = "hello" };
    try std.testing.expectEqualStrings("info", entry.level);
    try std.testing.expect(entry.source == null);
    try std.testing.expectEqual(@as(f64, 0), entry.timestamp);
}

test "Snapshot: split orientation enum values" {
    try std.testing.expect(SplitOrientation.horizontal != SplitOrientation.vertical);
}

test "Snapshot: pane layout defaults" {
    const pane = PaneLayoutSnapshot{};
    try std.testing.expectEqual(@as(usize, 0), pane.panel_ids.len);
    try std.testing.expect(pane.selected_panel_id == null);
}

test "Snapshot: tab manager snapshot defaults" {
    const tm = TabManagerSnapshot{};
    try std.testing.expect(tm.selected_workspace_index == null);
    try std.testing.expectEqual(@as(usize, 0), tm.workspaces.len);
}

test "Snapshot: tab manager snapshot with workspace" {
    // Corresponds to the structure built in makeSnapshot()
    const snap_ws = WorkspaceSnapshot{
        .process_title = "Terminal",
        .custom_title = "Restored",
        .is_pinned = true,
        .current_directory = "/tmp",
    };
    const workspaces = [_]WorkspaceSnapshot{snap_ws};
    const tm = TabManagerSnapshot{
        .selected_workspace_index = 0,
        .workspaces = &workspaces,
    };

    try std.testing.expectEqual(@as(?usize, 0), tm.selected_workspace_index);
    try std.testing.expectEqual(@as(usize, 1), tm.workspaces.len);
    try std.testing.expectEqualStrings("Terminal", tm.workspaces[0].process_title);
    try std.testing.expectEqualStrings("Restored", tm.workspaces[0].custom_title.?);
    try std.testing.expect(tm.workspaces[0].is_pinned);
}

test "Snapshot: freeWorkspaceSnapshot fully populated" {
    // Tests that freeing a snapshot with all fields populated does not leak.
    // Corresponds to the full makeSnapshot() + save/load round-trip tests —
    // ensuring memory management is correct.
    const alloc = std.testing.allocator;

    const ports = try alloc.alloc(u16, 2);
    ports[0] = 3000;
    ports[1] = 8080;

    const panels = try alloc.alloc(PanelSnapshot, 1);
    panels[0] = .{
        .id = Uuid.generate(),
        .panel_type = .terminal,
        .title = try alloc.dupe(u8, "bash"),
        .custom_title = try alloc.dupe(u8, "Dev"),
        .directory = try alloc.dupe(u8, "/home/user"),
        .is_pinned = true,
        .tty_name = try alloc.dupe(u8, "/dev/pts/0"),
        .listening_ports = ports,
        .git_branch = .{ .branch = try alloc.dupe(u8, "main"), .is_dirty = true },
        .terminal = .{
            .working_directory = try alloc.dupe(u8, "/home/user"),
            .scrollback = try alloc.dupe(u8, "$ echo hello\nhello\n"),
        },
    };

    const status = try alloc.alloc(StatusEntrySnapshot, 1);
    status[0] = .{
        .key = try alloc.dupe(u8, "agent"),
        .value = try alloc.dupe(u8, "idle"),
        .icon = try alloc.dupe(u8, "bolt"),
        .color = try alloc.dupe(u8, "#ffffff"),
    };

    const logs = try alloc.alloc(LogEntrySnapshot, 1);
    logs[0] = .{
        .message = try alloc.dupe(u8, "started"),
        .level = try alloc.dupe(u8, "info"),
        .source = try alloc.dupe(u8, "shell"),
    };

    var snap_ws = WorkspaceSnapshot{
        .process_title = try alloc.dupe(u8, "Terminal"),
        .custom_title = try alloc.dupe(u8, "My WS"),
        .custom_color = try alloc.dupe(u8, "#C0392B"),
        .is_pinned = true,
        .current_directory = try alloc.dupe(u8, "/tmp"),
        .focused_panel_id = panels[0].id,
        .panels = panels,
        .status_entries = status,
        .log_entries = logs,
        .progress = .{ .value = 0.5, .label = try alloc.dupe(u8, "halfway") },
        .git_branch = .{ .branch = try alloc.dupe(u8, "develop") },
    };

    // If freeWorkspaceSnapshot leaks, std.testing.allocator will catch it.
    freeWorkspaceSnapshot(alloc, &snap_ws);
}

test "Snapshot: freeWorkspaceSnapshot with browser panel and history" {
    const alloc = std.testing.allocator;

    const back = try alloc.alloc([]const u8, 2);
    back[0] = try alloc.dupe(u8, "https://example.com/a");
    back[1] = try alloc.dupe(u8, "https://example.com/b");

    const fwd = try alloc.alloc([]const u8, 1);
    fwd[0] = try alloc.dupe(u8, "https://example.com/d");

    const panels = try alloc.alloc(PanelSnapshot, 1);
    panels[0] = .{
        .id = Uuid.generate(),
        .panel_type = .browser,
        .browser = .{
            .url_string = try alloc.dupe(u8, "https://example.com/current"),
            .page_zoom = 1.2,
            .developer_tools_visible = true,
            .back_history_url_strings = back,
            .forward_history_url_strings = fwd,
        },
    };

    var snap_ws = WorkspaceSnapshot{
        .panels = panels,
    };
    freeWorkspaceSnapshot(alloc, &snap_ws);
}

test "Snapshot: freeWorkspaceSnapshot with markdown panel" {
    // Corresponds to testWorkspaceSessionSnapshotRestoresMarkdownPanel —
    // verifying that the markdown panel's file_path is properly freed.
    const alloc = std.testing.allocator;

    const panels = try alloc.alloc(PanelSnapshot, 1);
    panels[0] = .{
        .id = Uuid.generate(),
        .panel_type = .markdown,
        .custom_title = try alloc.dupe(u8, "Readme"),
        .markdown = .{ .file_path = try alloc.dupe(u8, "/tmp/note.md") },
    };

    var snap_ws = WorkspaceSnapshot{
        .custom_title = try alloc.dupe(u8, "Docs"),
        .panels = panels,
    };
    freeWorkspaceSnapshot(alloc, &snap_ws);
}

test "Snapshot: freeLayout pane with empty panel_ids" {
    var layout = LayoutSnapshot{ .pane = .{} };
    // Should not crash — empty slice is not freed.
    freeLayout(std.testing.allocator, &layout);
}

test "Snapshot: freeLayout pane with allocated panel_ids" {
    const alloc = std.testing.allocator;
    const ids = try alloc.alloc(Uuid, 2);
    ids[0] = Uuid.generate();
    ids[1] = Uuid.generate();

    var layout = LayoutSnapshot{ .pane = .{
        .panel_ids = ids,
        .selected_panel_id = ids[0],
    } };
    freeLayout(alloc, &layout);
}

test "Snapshot: freeLayout nested split tree" {
    const alloc = std.testing.allocator;

    // Build a split tree: split(pane, split(pane, pane))
    const leaf1_ids = try alloc.alloc(Uuid, 1);
    leaf1_ids[0] = Uuid.generate();
    const leaf2_ids = try alloc.alloc(Uuid, 1);
    leaf2_ids[0] = Uuid.generate();

    const leaf1 = try alloc.create(LayoutSnapshot);
    leaf1.* = .{ .pane = .{ .panel_ids = leaf1_ids } };

    const leaf2 = try alloc.create(LayoutSnapshot);
    leaf2.* = .{ .pane = .{ .panel_ids = leaf2_ids } };

    const inner_split = try alloc.create(LayoutSnapshot);
    inner_split.* = .{ .split = .{
        .orientation = .vertical,
        .divider_position = 0.5,
        .first = leaf1,
        .second = leaf2,
    } };

    const leaf3_ids = try alloc.alloc(Uuid, 1);
    leaf3_ids[0] = Uuid.generate();

    const leaf3 = try alloc.create(LayoutSnapshot);
    leaf3.* = .{ .pane = .{ .panel_ids = leaf3_ids } };

    var root = LayoutSnapshot{ .split = .{
        .orientation = .horizontal,
        .divider_position = 0.3,
        .first = leaf3,
        .second = inner_split,
    } };

    freeLayout(alloc, &root);
    // freeLayout recursively destroys all heap-allocated children
    // (leaf1, leaf2, leaf3, inner_split). No manual destroy needed.
}

test "Snapshot: freeWorkspaceSnapshot with pane layout" {
    const alloc = std.testing.allocator;

    const ids = try alloc.alloc(Uuid, 1);
    ids[0] = Uuid.generate();

    var snap_ws = WorkspaceSnapshot{
        .layout = .{ .pane = .{ .panel_ids = ids, .selected_panel_id = ids[0] } },
    };
    freeWorkspaceSnapshot(alloc, &snap_ws);
}

test "Snapshot: JSON round-trip for WorkspaceSnapshot" {
    const alloc = std.testing.allocator;

    const panel_id = try Uuid.parse("8f03a658-5a84-428b-ad03-5a6d04692f64");
    const panels = try alloc.alloc(PanelSnapshot, 1);
    panels[0] = .{
        .id = panel_id,
        .panel_type = .terminal,
        .title = "bash",
        .terminal = .{ .working_directory = "/home/user" },
    };

    const ws = WorkspaceSnapshot{
        .process_title = "Terminal",
        .custom_title = "Dev",
        .is_pinned = true,
        .current_directory = "/home/user",
        .focused_panel_id = panel_id,
        .panels = panels,
    };

    // Serialize
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(ws, .{ .emit_null_optional_fields = false }, &out.writer) catch |err| return err;

    // Deserialize
    const parsed = try std.json.parseFromSlice(WorkspaceSnapshot, alloc, out.written(), .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const restored = parsed.value;
    try std.testing.expectEqualStrings("Terminal", restored.process_title);
    try std.testing.expectEqualStrings("Dev", restored.custom_title.?);
    try std.testing.expect(restored.is_pinned);
    try std.testing.expectEqualStrings("/home/user", restored.current_directory);
    try std.testing.expect(restored.focused_panel_id.?.eql(panel_id));
    try std.testing.expectEqual(@as(usize, 1), restored.panels.len);
    try std.testing.expect(restored.panels[0].id.eql(panel_id));
    try std.testing.expectEqual(PanelType.terminal, restored.panels[0].panel_type);
    try std.testing.expectEqualStrings("bash", restored.panels[0].title.?);
    try std.testing.expectEqualStrings("/home/user", restored.panels[0].terminal.?.working_directory.?);

    // Free the manually-allocated panels slice (not owned by parsed)
    alloc.free(panels);
}

test "Snapshot: JSON round-trip for LayoutSnapshot with split" {
    const alloc = std.testing.allocator;

    const id1 = Uuid.generate();
    const id2 = Uuid.generate();

    // Build a split layout: split(pane([id1]), pane([id2]))
    const first = try alloc.create(LayoutSnapshot);
    first.* = .{ .pane = .{ .panel_ids = try alloc.dupe(Uuid, &.{id1}), .selected_panel_id = id1 } };
    const second = try alloc.create(LayoutSnapshot);
    second.* = .{ .pane = .{ .panel_ids = try alloc.dupe(Uuid, &.{id2}) } };

    const layout = LayoutSnapshot{
        .split = .{
            .orientation = .horizontal,
            .divider_position = 0.4,
            .first = first,
            .second = second,
        },
    };

    // Serialize
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(layout, .{ .emit_null_optional_fields = false }, &out.writer) catch |err| return err;

    // Deserialize
    const parsed = try std.json.parseFromSlice(LayoutSnapshot, alloc, out.written(), .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const restored = parsed.value;
    try std.testing.expect(restored == .split);
    try std.testing.expectEqual(SplitOrientation.horizontal, restored.split.orientation);
    try std.testing.expectEqual(@as(f64, 0.4), restored.split.divider_position);
    try std.testing.expect(restored.split.first.* == .pane);
    try std.testing.expectEqual(@as(usize, 1), restored.split.first.pane.panel_ids.len);
    try std.testing.expect(restored.split.first.pane.panel_ids[0].eql(id1));
    try std.testing.expect(restored.split.second.* == .pane);
    try std.testing.expectEqual(@as(usize, 1), restored.split.second.pane.panel_ids.len);
    try std.testing.expect(restored.split.second.pane.panel_ids[0].eql(id2));

    // Free the manually-allocated layout nodes
    alloc.free(first.pane.panel_ids);
    alloc.destroy(first);
    alloc.free(second.pane.panel_ids);
    alloc.destroy(second);
}

test "Snapshot: JSON round-trip for TabManagerSnapshot" {
    const alloc = std.testing.allocator;

    const workspaces = try alloc.alloc(WorkspaceSnapshot, 2);
    workspaces[0] = .{
        .process_title = "Terminal",
        .current_directory = "/home/user",
    };
    workspaces[1] = .{
        .process_title = "Server",
        .custom_title = "Backend",
        .current_directory = "/srv/app",
    };

    const tm = TabManagerSnapshot{
        .selected_workspace_index = 1,
        .workspaces = workspaces,
    };

    // Serialize
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(tm, .{ .emit_null_optional_fields = false }, &out.writer) catch |err| return err;

    // Deserialize
    const parsed = try std.json.parseFromSlice(TabManagerSnapshot, alloc, out.written(), .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const restored = parsed.value;
    try std.testing.expectEqual(@as(?usize, 1), restored.selected_workspace_index);
    try std.testing.expectEqual(@as(usize, 2), restored.workspaces.len);
    try std.testing.expectEqualStrings("Terminal", restored.workspaces[0].process_title);
    try std.testing.expectEqualStrings("Server", restored.workspaces[1].process_title);
    try std.testing.expectEqualStrings("Backend", restored.workspaces[1].custom_title.?);

    alloc.free(workspaces);
}

test "Snapshot: AppSessionSnapshot defaults" {
    const snap_app = AppSessionSnapshot{};
    try std.testing.expectEqual(AppSessionSnapshot.current_version, snap_app.version);
    try std.testing.expectEqual(@as(f64, 0), snap_app.created_at);
    try std.testing.expectEqual(@as(usize, 0), snap_app.windows.len);
}

test "Snapshot: SessionWindowSnapshot defaults" {
    const win = SessionWindowSnapshot{};
    try std.testing.expect(win.frame == null);
    try std.testing.expect(win.display == null);
    try std.testing.expect(win.sidebar.is_visible);
    try std.testing.expectEqual(SessionSidebarSelection.tabs, win.sidebar.selection);
    try std.testing.expect(win.sidebar.width == null);
    try std.testing.expectEqual(@as(usize, 0), win.tab_manager.workspaces.len);
}

test "Snapshot: JSON round-trip for AppSessionSnapshot" {
    const alloc = std.testing.allocator;

    const workspaces = try alloc.alloc(WorkspaceSnapshot, 1);
    workspaces[0] = .{
        .process_title = "Terminal",
        .current_directory = "/home/user",
    };

    const windows = try alloc.alloc(SessionWindowSnapshot, 1);
    windows[0] = .{
        .frame = .{ .x = 100, .y = 200, .width = 800, .height = 600 },
        .tab_manager = .{
            .selected_workspace_index = 0,
            .workspaces = workspaces,
        },
        .sidebar = .{
            .is_visible = true,
            .selection = .tabs,
            .width = 220,
        },
    };

    const snap_app = AppSessionSnapshot{
        .version = AppSessionSnapshot.current_version,
        .created_at = 1700000000.0,
        .windows = windows,
    };

    // Serialize
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(snap_app, .{ .emit_null_optional_fields = false }, &out.writer) catch |err| return err;

    // Deserialize
    const parsed = try std.json.parseFromSlice(AppSessionSnapshot, alloc, out.written(), .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const restored = parsed.value;
    try std.testing.expectEqual(AppSessionSnapshot.current_version, restored.version);
    try std.testing.expectEqual(@as(f64, 1700000000.0), restored.created_at);
    try std.testing.expectEqual(@as(usize, 1), restored.windows.len);
    try std.testing.expectEqual(@as(f64, 100), restored.windows[0].frame.?.x);
    try std.testing.expectEqual(@as(f64, 800), restored.windows[0].frame.?.width);
    try std.testing.expect(restored.windows[0].sidebar.is_visible);
    try std.testing.expectEqual(@as(f64, 220), restored.windows[0].sidebar.width.?);
    try std.testing.expectEqualStrings("Terminal", restored.windows[0].tab_manager.workspaces[0].process_title);

    alloc.free(workspaces);
    alloc.free(windows);
}

test "Snapshot: freeAppSessionSnapshot fully populated" {
    const alloc = std.testing.allocator;

    const panels = try alloc.alloc(PanelSnapshot, 1);
    panels[0] = .{
        .id = Uuid.generate(),
        .panel_type = .terminal,
        .title = try alloc.dupe(u8, "bash"),
        .terminal = .{ .working_directory = try alloc.dupe(u8, "/home") },
    };

    const workspaces = try alloc.alloc(WorkspaceSnapshot, 1);
    workspaces[0] = .{
        .process_title = try alloc.dupe(u8, "Terminal"),
        .current_directory = try alloc.dupe(u8, "/home"),
        .panels = panels,
    };

    const windows = try alloc.alloc(SessionWindowSnapshot, 1);
    windows[0] = .{
        .tab_manager = .{
            .selected_workspace_index = 0,
            .workspaces = workspaces,
        },
    };

    var snap_app = AppSessionSnapshot{
        .version = AppSessionSnapshot.current_version,
        .created_at = 1700000000.0,
        .windows = windows,
    };

    freeAppSessionSnapshot(alloc, &snap_app);
}

// TODO: Port testSaveAndLoadRoundTripWithCustomSnapshotPath — requires
// SessionPersistenceStore.save/load (JSON file persistence, not yet
// implemented in Zig).

// TODO: Port testSaveSkipsRewritingIdenticalSnapshotData — requires
// SessionPersistenceStore with inode-based identity check.

// TODO: Port testLoadRejectsSchemaVersionMismatch — requires
// SessionPersistenceStore with version validation.

// TODO: Port testDefaultSnapshotPathSanitizesBundleIdentifier — requires
// SessionPersistenceStore.defaultSnapshotFileURL (path sanitization).

// TODO: Port testRestorePolicySkipsWhenLaunchHasExplicitArguments,
// testRestorePolicyAllowsFinderStyleLaunchArgumentsOnly,
// testRestorePolicySkipsWhenRunningUnderXCTest — requires
// SessionRestorePolicy (launch-argument filtering, not yet implemented).

// TODO: Port testSidebarWidthSanitizationClampsToPolicyRange — requires
// SessionPersistencePolicy.sanitizedSidebarWidth.

// TODO: Port testScrollbackReplayEnvironmentWritesReplayFile,
// testScrollbackReplayEnvironmentSkipsWhitespaceOnlyContent,
// testScrollbackReplayEnvironmentPreservesANSIColorSequences — requires
// SessionScrollbackReplayStore (replay file writer, not yet implemented).

// TODO: Port testTruncatedScrollbackAvoidsLeadingPartialANSICSISequence —
// requires SessionPersistencePolicy.truncatedScrollback.

// TODO: Port testNormalizedExportedScreenPath*,
// testShouldRemoveExportedScreen* — requires TerminalController
// screen-export path normalization (macOS-specific file URL handling).

// TODO: Port testResolvedWindowFrame*, testResolvedStartupPrimaryWindowFrame* —
// requires AppDelegate display geometry resolution (GTK equivalent needed).

// TODO: Port testResolvedSnapshotTerminalScrollback* — requires
// Workspace.resolvedSnapshotTerminalScrollback.

// TODO: Port testWindowUnregisterSnapshotPersistencePolicy,
// testShouldSkipSessionSaveDuringStartupRestorePolicy,
// testSessionAutosaveTickPolicy*, testUnchangedAutosaveFingerprint*,
// testSessionSnapshotSynchronousWritePolicy — requires AppDelegate
// session lifecycle policies (not yet implemented).
