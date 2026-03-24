const std = @import("std");
const Uuid = @import("../uuid.zig").Uuid;

/// The type of a panel within a workspace.
pub const PanelType = enum {
    terminal,
    browser,
    markdown,
};

/// A panel within a workspace. Each workspace contains one or more panels
/// arranged in a split tree. This is the data-model representation — it
/// does not hold GTK widget pointers. The GTK integration layer maintains
/// a separate Uuid → widget mapping.
///
/// Matches the macOS Panel protocol + TerminalPanel/BrowserPanel/MarkdownPanel.
pub const Panel = union(PanelType) {
    terminal: TerminalPanel,
    browser: BrowserPanel,
    markdown: MarkdownPanel,

    pub fn id(self: Panel) Uuid {
        return switch (self) {
            inline else => |p| p.id,
        };
    }

    pub fn panelType(self: Panel) PanelType {
        return std.meta.activeTag(self);
    }

    pub fn workspaceId(self: Panel) Uuid {
        return switch (self) {
            inline else => |p| p.workspace_id,
        };
    }

    /// Free all owned string memory for this panel.
    pub fn deinit(self: *Panel, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .terminal => |*p| p.deinit(allocator),
            .browser => |*p| p.deinit(allocator),
            .markdown => |*p| p.deinit(allocator),
        }
    }
};

pub const TerminalPanel = struct {
    id: Uuid,
    workspace_id: Uuid,
    title: []const u8 = "",
    directory: []const u8 = "",
    tty_name: ?[]const u8 = null,

    pub fn deinit(self: *TerminalPanel, allocator: std.mem.Allocator) void {
        freeStr(allocator, self.title);
        freeStr(allocator, self.directory);
        if (self.tty_name) |t| allocator.free(t);
    }
};

pub const BrowserPanel = struct {
    id: Uuid,
    workspace_id: Uuid,
    url: ?[]const u8 = null,
    profile_id: ?Uuid = null,
    page_title: []const u8 = "",
    is_loading: bool = false,
    page_zoom: f64 = 1.0,
    developer_tools_visible: bool = false,

    pub fn deinit(self: *BrowserPanel, allocator: std.mem.Allocator) void {
        if (self.url) |u| allocator.free(u);
        freeStr(allocator, self.page_title);
    }
};

pub const MarkdownPanel = struct {
    id: Uuid,
    workspace_id: Uuid,
    file_path: []const u8 = "",
    content: ?[]const u8 = null,
    is_file_unavailable: bool = false,

    pub fn deinit(self: *MarkdownPanel, allocator: std.mem.Allocator) void {
        freeStr(allocator, self.file_path);
        if (self.content) |c| allocator.free(c);
    }
};

fn freeStr(allocator: std.mem.Allocator, s: []const u8) void {
    if (s.len > 0) allocator.free(s);
}

// --- Tests ---

test "panel id dispatches to active variant" {
    const uuid = Uuid.generate();
    const panel = Panel{ .terminal = .{
        .id = uuid,
        .workspace_id = Uuid.nil,
    } };
    try std.testing.expect(panel.id().eql(uuid));
    try std.testing.expectEqual(PanelType.terminal, panel.panelType());
}

test "panel workspace_id dispatches to active variant" {
    const ws_id = Uuid.generate();
    const panel = Panel{ .browser = .{
        .id = Uuid.generate(),
        .workspace_id = ws_id,
    } };
    try std.testing.expect(panel.workspaceId().eql(ws_id));
    try std.testing.expectEqual(PanelType.browser, panel.panelType());
}
