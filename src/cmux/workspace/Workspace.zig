const std = @import("std");
const Allocator = std.mem.Allocator;
const Uuid = @import("../uuid.zig").Uuid;
const sidebar = @import("sidebar.zig");
const remote = @import("remote.zig");
const Panel = @import("Panel.zig").Panel;
const PanelType = @import("Panel.zig").PanelType;
const snap = @import("snapshot.zig");

const Workspace = @This();

/// Reason for an attention flash on a workspace panel.
/// Matches macOS WorkspaceAttentionFlashReason.
pub const AttentionFlashReason = enum {
    navigation,
    notification_arrival,
    notification_dismiss,
    manual_unread_dismiss,
    debug,
};

/// Unique workspace identifier.
id: Uuid,

/// Title set by the terminal process (e.g., OSC 2).
process_title: []const u8,

/// User-provided custom title override.
custom_title: ?[]const u8,

/// Whether this workspace is pinned (protected from close).
is_pinned: bool,

/// Hex color string (e.g., "#C0392B") for sidebar display.
custom_color: ?[]const u8,

/// Current working directory for this workspace.
current_directory: []const u8,

/// Port ordinal for CMUX_PORT environment variable range.
port_ordinal: u32,

// --- Panel storage ---

panels: std.ArrayHashMapUnmanaged(Uuid, Panel, Uuid.ArrayHashContext, true),

// --- Per-panel metadata maps ---

panel_directories: std.ArrayHashMapUnmanaged(Uuid, []const u8, Uuid.ArrayHashContext, true),
panel_titles: std.ArrayHashMapUnmanaged(Uuid, []const u8, Uuid.ArrayHashContext, true),
panel_custom_titles: std.ArrayHashMapUnmanaged(Uuid, []const u8, Uuid.ArrayHashContext, true),
pinned_panel_ids: std.ArrayHashMapUnmanaged(Uuid, void, Uuid.ArrayHashContext, true),
manual_unread_panel_ids: std.ArrayHashMapUnmanaged(Uuid, void, Uuid.ArrayHashContext, true),
panel_git_branches: std.ArrayHashMapUnmanaged(Uuid, sidebar.GitBranchState, Uuid.ArrayHashContext, true),
panel_pull_requests: std.ArrayHashMapUnmanaged(Uuid, sidebar.PullRequestState, Uuid.ArrayHashContext, true),
surface_listening_ports: std.ArrayHashMapUnmanaged(Uuid, []const u16, Uuid.ArrayHashContext, true),
surface_tty_names: std.ArrayHashMapUnmanaged(Uuid, []const u8, Uuid.ArrayHashContext, true),
panel_shell_activity: std.ArrayHashMapUnmanaged(Uuid, sidebar.ShellActivityState, Uuid.ArrayHashContext, true),

// --- Workspace-level sidebar metadata ---

status_entries: std.StringArrayHashMapUnmanaged(sidebar.StatusEntry),
metadata_blocks: std.StringArrayHashMapUnmanaged(sidebar.MetadataBlock),
log_entries: std.ArrayListUnmanaged(sidebar.LogEntry),
progress: ?sidebar.ProgressState,
git_branch: ?sidebar.GitBranchState,
pull_request: ?sidebar.PullRequestState,

// --- Workspace-level aggregates ---

/// Aggregate listening ports across all panels.
listening_ports: []const u16,

/// Preferred browser profile for new browser panels.
preferred_browser_profile_id: ?Uuid,

// --- Remote connection state ---

remote_state: remote.RemoteState,

/// Count of active remote terminal sessions.
active_remote_terminal_session_count: u32,

// --- Tmux attention flash state ---

tmux_workspace_flash_panel_id: ?Uuid,
tmux_workspace_flash_reason: ?AttentionFlashReason,
tmux_workspace_flash_token: u64,

// --- Agent tracking ---

agent_pids: std.StringArrayHashMapUnmanaged(std.posix.pid_t),

// --- Focus ---

focused_panel_id: ?Uuid,

// --- Session restore (transient, consumed once by GTK layer) ---

/// Scrollback replay file path for the first terminal panel, set during restore.
/// Consumed and cleared by the GTK layer when creating the surface.
restore_scrollback_path: ?[]const u8 = null,

// --- Allocator ---

allocator: Allocator,

// -----------------------------------------------------------------------
// Initialization
// -----------------------------------------------------------------------

pub const InitOptions = struct {
    title: []const u8 = "Terminal",
    working_directory: []const u8 = "",
    port_ordinal: u32 = 0,
    id: ?Uuid = null,
};

pub fn init(allocator: Allocator, opts: InitOptions) !Workspace {
    return .{
        .id = opts.id orelse Uuid.generate(),
        .process_title = try dupeStr(allocator, opts.title),
        .custom_title = null,
        .is_pinned = false,
        .custom_color = null,
        .current_directory = try dupeStr(allocator, opts.working_directory),
        .port_ordinal = opts.port_ordinal,
        .panels = .{},
        .panel_directories = .{},
        .panel_titles = .{},
        .panel_custom_titles = .{},
        .pinned_panel_ids = .{},
        .manual_unread_panel_ids = .{},
        .panel_git_branches = .{},
        .panel_pull_requests = .{},
        .surface_listening_ports = .{},
        .surface_tty_names = .{},
        .panel_shell_activity = .{},
        .status_entries = .{},
        .metadata_blocks = .{},
        .log_entries = .{},
        .progress = null,
        .git_branch = null,
        .pull_request = null,
        .listening_ports = &.{},
        .preferred_browser_profile_id = null,
        .remote_state = remote.RemoteState.empty,
        .active_remote_terminal_session_count = 0,
        .tmux_workspace_flash_panel_id = null,
        .tmux_workspace_flash_reason = null,
        .tmux_workspace_flash_token = 0,
        .agent_pids = .{},
        .focused_panel_id = null,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Workspace) void {
    const alloc = self.allocator;

    // Free owned strings
    freeStr(alloc, self.process_title);
    if (self.custom_title) |s| alloc.free(s);
    if (self.custom_color) |s| alloc.free(s);
    freeStr(alloc, self.current_directory);

    // Free panels
    {
        var it = self.panels.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(alloc);
        }
        self.panels.deinit(alloc);
    }

    // Free per-panel string maps
    freeStringValueMap(alloc, &self.panel_directories);
    freeStringValueMap(alloc, &self.panel_titles);
    freeStringValueMap(alloc, &self.panel_custom_titles);
    self.pinned_panel_ids.deinit(alloc);
    self.manual_unread_panel_ids.deinit(alloc);

    // Free per-panel git branches (branch string inside)
    {
        var it = self.panel_git_branches.iterator();
        while (it.next()) |entry| {
            freeStr(alloc, entry.value_ptr.branch);
        }
        self.panel_git_branches.deinit(alloc);
    }

    // Free per-panel pull requests (multiple strings inside)
    {
        var it = self.panel_pull_requests.iterator();
        while (it.next()) |entry| {
            freePullRequestState(alloc, entry.value_ptr);
        }
        self.panel_pull_requests.deinit(alloc);
    }

    // Free per-panel listening ports
    {
        var it = self.surface_listening_ports.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.len > 0) alloc.free(entry.value_ptr.*);
        }
        self.surface_listening_ports.deinit(alloc);
    }

    // Free per-panel tty names
    freeStringValueMap(alloc, &self.surface_tty_names);

    // Free per-panel shell activity (no owned strings, just deinit the map)
    self.panel_shell_activity.deinit(alloc);

    // Free workspace-level listening ports
    if (self.listening_ports.len > 0) alloc.free(self.listening_ports);

    // Free sidebar status entries
    {
        var it = self.status_entries.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            freeStatusEntry(alloc, entry.value_ptr);
        }
        self.status_entries.deinit(alloc);
    }

    // Free sidebar metadata blocks
    {
        var it = self.metadata_blocks.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            freeMetadataBlock(alloc, entry.value_ptr);
        }
        self.metadata_blocks.deinit(alloc);
    }

    // Free log entries
    for (self.log_entries.items) |*entry| {
        freeLogEntry(alloc, entry);
    }
    self.log_entries.deinit(alloc);

    // Free workspace-level sidebar state
    if (self.progress) |*p| {
        if (p.label) |s| alloc.free(s);
    }
    if (self.git_branch) |*g| {
        freeStr(alloc, g.branch);
    }
    if (self.pull_request) |*pr| {
        freePullRequestState(alloc, pr);
    }

    // Free agent pids
    {
        var it = self.agent_pids.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }
        self.agent_pids.deinit(alloc);
    }
}

// -----------------------------------------------------------------------
// Title
// -----------------------------------------------------------------------

/// Returns the display title: custom_title if set, otherwise process_title.
pub fn displayTitle(self: *const Workspace) []const u8 {
    return self.custom_title orelse self.process_title;
}

pub fn setProcessTitle(self: *Workspace, title: []const u8) !void {
    const new = try dupeStr(self.allocator, title);
    freeStr(self.allocator, self.process_title);
    self.process_title = new;
}

pub fn setCustomTitle(self: *Workspace, title: ?[]const u8) !void {
    if (self.custom_title) |old| self.allocator.free(old);
    self.custom_title = if (title) |t|
        try self.allocator.dupe(u8, t)
    else
        null;
}

// -----------------------------------------------------------------------
// Directory
// -----------------------------------------------------------------------

pub fn setCwd(self: *Workspace, dir: []const u8) !void {
    const new = try dupeStr(self.allocator, dir);
    freeStr(self.allocator, self.current_directory);
    self.current_directory = new;
}

// -----------------------------------------------------------------------
// Color / Pin
// -----------------------------------------------------------------------

pub fn setCustomColor(self: *Workspace, hex: ?[]const u8) !void {
    if (self.custom_color) |old| self.allocator.free(old);
    self.custom_color = if (hex) |h|
        try self.allocator.dupe(u8, h)
    else
        null;
}

pub fn setPinned(self: *Workspace, pinned: bool) void {
    self.is_pinned = pinned;
}

// -----------------------------------------------------------------------
// Panel lifecycle
// -----------------------------------------------------------------------

pub fn addPanel(self: *Workspace, panel: Panel) !void {
    try self.panels.put(self.allocator, panel.id(), panel);
}

pub fn removePanel(self: *Workspace, panel_id: Uuid) void {
    const alloc = self.allocator;

    // Remove from main panel map (and deinit the panel)
    if (self.panels.fetchSwapRemove(panel_id)) |kv| {
        var p = kv.value;
        p.deinit(alloc);
    }

    // Clean up all per-panel metadata
    removeAndFreeStr(alloc, &self.panel_directories, panel_id);
    removeAndFreeStr(alloc, &self.panel_titles, panel_id);
    removeAndFreeStr(alloc, &self.panel_custom_titles, panel_id);
    _ = self.pinned_panel_ids.swapRemove(panel_id);
    _ = self.manual_unread_panel_ids.swapRemove(panel_id);

    if (self.panel_git_branches.fetchSwapRemove(panel_id)) |kv| {
        freeStr(alloc, kv.value.branch);
    }
    if (self.panel_pull_requests.fetchSwapRemove(panel_id)) |kv| {
        var pr = kv.value;
        freePullRequestState(alloc, &pr);
    }
    if (self.surface_listening_ports.fetchSwapRemove(panel_id)) |kv| {
        if (kv.value.len > 0) alloc.free(kv.value);
    }
    removeAndFreeStr(alloc, &self.surface_tty_names, panel_id);
    _ = self.panel_shell_activity.swapRemove(panel_id);

    // Clear focus if this was the focused panel
    if (self.focused_panel_id) |fid| {
        if (fid.eql(panel_id)) self.focused_panel_id = null;
    }
}

pub fn panelById(self: *Workspace, panel_id: Uuid) ?*Panel {
    return self.panels.getPtr(panel_id);
}

pub fn panelCount(self: *const Workspace) usize {
    return self.panels.count();
}

/// Move a panel to a new index in the ordered panel map.
/// Used by the pane tab bar drag reorder.
pub fn movePanelToIndex(self: *Workspace, panel_id: Uuid, new_index: usize) void {
    const keys = self.panels.keys();
    const current_idx = for (keys, 0..) |k, i| {
        if (k.eql(panel_id)) break i;
    } else return;

    if (current_idx == new_index) return;
    const target = @min(new_index, self.panels.count() -| 1);

    // Extract the entry, reinsert at the target position.
    // ArrayHashMap doesn't have a direct reorder API, so we
    // rebuild by removing and reinserting.
    const panel = self.panels.get(panel_id) orelse return;

    // Collect all entries in order.
    var buf: [256]struct { id: Uuid, panel: Panel } = undefined;
    var count: usize = 0;
    var it = self.panels.iterator();
    while (it.next()) |entry| {
        if (count < buf.len) {
            buf[count] = .{ .id = entry.key_ptr.*, .panel = entry.value_ptr.* };
            count += 1;
        }
    }

    // Clear and rebuild in new order.
    // Note: we cannot call deinit on the removed panels since we're
    // reinserting them (ownership transfer).
    self.panels.clearRetainingCapacity();

    var inserted = false;
    var src: usize = 0;
    var dst: usize = 0;
    while (src < count) : (src += 1) {
        if (buf[src].id.eql(panel_id)) continue; // skip dragged
        if (dst == target and !inserted) {
            self.panels.put(self.allocator, panel_id, panel) catch {};
            inserted = true;
            dst += 1;
        }
        self.panels.put(self.allocator, buf[src].id, buf[src].panel) catch {};
        dst += 1;
    }
    if (!inserted) {
        self.panels.put(self.allocator, panel_id, panel) catch {};
    }
}

// -----------------------------------------------------------------------
// Panel metadata
// -----------------------------------------------------------------------

pub fn setPanelDirectory(self: *Workspace, panel_id: Uuid, dir: []const u8) !void {
    try putOwnedStr(self.allocator, &self.panel_directories, panel_id, dir);
}

pub fn setPanelTitle(self: *Workspace, panel_id: Uuid, title: []const u8) !void {
    try putOwnedStr(self.allocator, &self.panel_titles, panel_id, title);
}

pub fn setPanelCustomTitle(self: *Workspace, panel_id: Uuid, title: ?[]const u8) !void {
    if (title) |t| {
        try putOwnedStr(self.allocator, &self.panel_custom_titles, panel_id, t);
    } else {
        removeAndFreeStr(self.allocator, &self.panel_custom_titles, panel_id);
    }
}

pub fn setPanelPinned(self: *Workspace, panel_id: Uuid, pinned: bool) !void {
    if (pinned) {
        try self.pinned_panel_ids.put(self.allocator, panel_id, {});
    } else {
        _ = self.pinned_panel_ids.swapRemove(panel_id);
    }
}

pub fn setPanelUnread(self: *Workspace, panel_id: Uuid, unread: bool) !void {
    if (unread) {
        try self.manual_unread_panel_ids.put(self.allocator, panel_id, {});
    } else {
        _ = self.manual_unread_panel_ids.swapRemove(panel_id);
    }
}

pub fn setPanelGitBranch(self: *Workspace, panel_id: Uuid, branch: ?sidebar.GitBranchState) !void {
    if (branch) |b| {
        const owned_branch = try self.allocator.dupe(u8, b.branch);
        if (self.panel_git_branches.fetchSwapRemove(panel_id)) |old| {
            freeStr(self.allocator, old.value.branch);
        }
        try self.panel_git_branches.put(self.allocator, panel_id, .{
            .branch = owned_branch,
            .is_dirty = b.is_dirty,
        });
    } else {
        if (self.panel_git_branches.fetchSwapRemove(panel_id)) |old| {
            freeStr(self.allocator, old.value.branch);
        }
    }
}

pub fn setPanelPullRequest(self: *Workspace, panel_id: Uuid, pr: ?sidebar.PullRequestState) !void {
    if (pr) |p| {
        const owned = try dupeOwnedPullRequest(self.allocator, p);
        if (self.panel_pull_requests.fetchSwapRemove(panel_id)) |old| {
            var old_pr = old.value;
            freePullRequestState(self.allocator, &old_pr);
        }
        try self.panel_pull_requests.put(self.allocator, panel_id, owned);
    } else {
        if (self.panel_pull_requests.fetchSwapRemove(panel_id)) |old| {
            var old_pr = old.value;
            freePullRequestState(self.allocator, &old_pr);
        }
    }
}

pub fn setPanelListeningPorts(self: *Workspace, panel_id: Uuid, ports: []const u16) !void {
    const owned = try self.allocator.dupe(u16, ports);
    if (self.surface_listening_ports.fetchSwapRemove(panel_id)) |old| {
        if (old.value.len > 0) self.allocator.free(old.value);
    }
    try self.surface_listening_ports.put(self.allocator, panel_id, owned);
}

pub fn setPanelTtyName(self: *Workspace, panel_id: Uuid, name: ?[]const u8) !void {
    if (name) |n| {
        try putOwnedStr(self.allocator, &self.surface_tty_names, panel_id, n);
    } else {
        removeAndFreeStr(self.allocator, &self.surface_tty_names, panel_id);
    }
}

pub fn setPanelShellActivity(self: *Workspace, panel_id: Uuid, state: sidebar.ShellActivityState) !void {
    try self.panel_shell_activity.put(self.allocator, panel_id, state);
}

// -----------------------------------------------------------------------
// Workspace-level aggregates
// -----------------------------------------------------------------------

pub fn setListeningPorts(self: *Workspace, ports: []const u16) !void {
    const owned = try self.allocator.dupe(u16, ports);
    if (self.listening_ports.len > 0) self.allocator.free(self.listening_ports);
    self.listening_ports = owned;
}

pub fn setPreferredBrowserProfileId(self: *Workspace, profile_id: ?Uuid) void {
    self.preferred_browser_profile_id = profile_id;
}

pub fn setActiveRemoteTerminalSessionCount(self: *Workspace, count: u32) void {
    self.active_remote_terminal_session_count = count;
}

// -----------------------------------------------------------------------
// Remote connection lifecycle
// -----------------------------------------------------------------------

/// Returns true if this workspace has a remote configuration.
pub fn isRemoteWorkspace(self: *const Workspace) bool {
    return self.remote_state.configuration != null;
}

/// Configure (or reconfigure) the remote connection for this workspace.
/// Stores the configuration and sets state to connecting if auto_connect is true.
/// Matches macOS Workspace.configureRemoteConnection (Workspace.swift line 6443).
pub fn configureRemoteConnection(self: *Workspace, config: remote.Configuration, auto_connect: bool) void {
    // Store the new configuration (slices are arena/caller-owned).
    self.remote_state.configuration = config;

    // Reset connection state.
    self.remote_state.connection_detail = null;
    self.remote_state.daemon_status = .{};
    self.remote_state.detected_ports = &.{};
    self.remote_state.forwarded_ports = &.{};
    self.remote_state.port_conflicts = &.{};
    self.remote_state.heartbeat_count = 0;
    self.remote_state.last_heartbeat_at = null;

    if (auto_connect) {
        self.remote_state.connection_state = .connecting;
        // TODO: Phase 5 — start SessionController here.
    } else {
        self.remote_state.connection_state = .disconnected;
    }
}

/// Reconnect an already-configured remote workspace.
/// Matches macOS Workspace.reconnectRemoteConnection (Workspace.swift line 6468).
pub fn reconnectRemoteConnection(self: *Workspace) void {
    const config = self.remote_state.configuration orelse return;
    self.configureRemoteConnection(config, true);
}

/// Disconnect the remote connection. Optionally clears the configuration.
/// Matches macOS Workspace.disconnectRemoteConnection (Workspace.swift line 6475).
pub fn disconnectRemoteConnection(self: *Workspace, clear_configuration: bool) void {
    // TODO: Phase 5 — stop SessionController here.

    self.remote_state.connection_state = .disconnected;
    self.remote_state.connection_detail = null;
    self.remote_state.daemon_status = .{};
    self.remote_state.detected_ports = &.{};
    self.remote_state.forwarded_ports = &.{};
    self.remote_state.port_conflicts = &.{};
    self.remote_state.heartbeat_count = 0;
    self.remote_state.last_heartbeat_at = null;

    // Always clear session count (matches Mac lines 6611-6612).
    self.active_remote_terminal_session_count = 0;

    if (clear_configuration) {
        self.remote_state.configuration = null;
    }
}

/// Signal that a remote terminal session has ended.
/// Decrements the active session count if the relay port matches.
/// Matches macOS Workspace.markRemoteTerminalSessionEnded (Workspace.swift line 6489).
pub fn markRemoteTerminalSessionEnded(self: *Workspace, surface_id: Uuid, relay_port: ?u16) void {
    _ = surface_id; // Surface tracking is per-ID in Mac; simplified here for Phase 1.

    // Guard: relay_port must be present, config must exist, and ports must match.
    // Matches Mac's flat guard: relay_port > 0 && config?.relay_port == relay_port.
    const rp = relay_port orelse return;
    const config = self.remote_state.configuration orelse return;
    const crp = config.relay_port orelse return;
    if (rp != crp) return;

    if (self.active_remote_terminal_session_count > 0) {
        self.active_remote_terminal_session_count -= 1;
    }

    // TODO: Phase 5 — if count drops to zero and no browser panels,
    // consider auto-disconnect.
}

// -----------------------------------------------------------------------
// Attention flash
// -----------------------------------------------------------------------

pub fn triggerFlash(self: *Workspace, panel_id: Uuid, reason: AttentionFlashReason) void {
    self.tmux_workspace_flash_panel_id = panel_id;
    self.tmux_workspace_flash_reason = reason;
    self.tmux_workspace_flash_token +%= 1;
}

pub fn clearFlash(self: *Workspace) void {
    self.tmux_workspace_flash_panel_id = null;
    self.tmux_workspace_flash_reason = null;
}

// -----------------------------------------------------------------------
// Sidebar metadata — workspace level
// -----------------------------------------------------------------------

pub fn setStatus(self: *Workspace, key: []const u8, entry: sidebar.StatusEntry) !void {
    // If key already exists, free old entry
    if (self.status_entries.getPtr(key)) |old| {
        freeStatusEntry(self.allocator, old);
    }

    const owned_key = try self.allocator.dupe(u8, key);
    const owned_entry = try dupeOwnedStatusEntry(self.allocator, entry);

    // If the key was new, the old getPtr would have been null
    // Use fetchPut to handle both insert and update
    const result = try self.status_entries.fetchPut(self.allocator, owned_key, owned_entry);
    if (result) |old| {
        // Key already existed — free the duplicate key we just made
        self.allocator.free(owned_key);
        // Old entry was already freed above via getPtr
        _ = old;
    }
}

pub fn clearStatus(self: *Workspace, key: []const u8) void {
    if (self.status_entries.fetchSwapRemove(key)) |kv| {
        self.allocator.free(kv.key);
        var entry = kv.value;
        freeStatusEntry(self.allocator, &entry);
    }
}

pub fn setMetadataBlock(self: *Workspace, key: []const u8, block: sidebar.MetadataBlock) !void {
    if (self.metadata_blocks.getPtr(key)) |old| {
        freeMetadataBlock(self.allocator, old);
    }

    const owned_key = try self.allocator.dupe(u8, key);
    const owned_block = sidebar.MetadataBlock{
        .key = try self.allocator.dupe(u8, block.key),
        .markdown = try self.allocator.dupe(u8, block.markdown),
        .priority = block.priority,
        .timestamp = block.timestamp,
    };

    const result = try self.metadata_blocks.fetchPut(self.allocator, owned_key, owned_block);
    if (result) |old| {
        self.allocator.free(owned_key);
        _ = old;
    }
}

pub fn clearMetadataBlock(self: *Workspace, key: []const u8) void {
    if (self.metadata_blocks.fetchSwapRemove(key)) |kv| {
        self.allocator.free(kv.key);
        var block = kv.value;
        freeMetadataBlock(self.allocator, &block);
    }
}

pub fn appendLog(self: *Workspace, entry: sidebar.LogEntry) !void {
    try self.log_entries.append(self.allocator, .{
        .message = try self.allocator.dupe(u8, entry.message),
        .level = entry.level,
        .source = if (entry.source) |s| try self.allocator.dupe(u8, s) else null,
        .timestamp = entry.timestamp,
    });
}

pub fn clearLogs(self: *Workspace) void {
    for (self.log_entries.items) |*entry| {
        freeLogEntry(self.allocator, entry);
    }
    self.log_entries.clearRetainingCapacity();
}

pub fn setProgress(self: *Workspace, p: ?sidebar.ProgressState) !void {
    // Free old label
    if (self.progress) |*old| {
        if (old.label) |s| self.allocator.free(s);
    }
    if (p) |new| {
        self.progress = .{
            .value = new.value,
            .label = if (new.label) |s| try self.allocator.dupe(u8, s) else null,
        };
    } else {
        self.progress = null;
    }
}

pub fn setGitBranch(self: *Workspace, branch: ?sidebar.GitBranchState) !void {
    if (self.git_branch) |*old| {
        freeStr(self.allocator, old.branch);
    }
    if (branch) |b| {
        self.git_branch = .{
            .branch = try self.allocator.dupe(u8, b.branch),
            .is_dirty = b.is_dirty,
        };
    } else {
        self.git_branch = null;
    }
}

pub fn setPullRequest(self: *Workspace, pr: ?sidebar.PullRequestState) !void {
    if (self.pull_request) |*old| {
        freePullRequestState(self.allocator, old);
    }
    if (pr) |p| {
        self.pull_request = try dupeOwnedPullRequest(self.allocator, p);
    } else {
        self.pull_request = null;
    }
}

// -----------------------------------------------------------------------
// Agent PIDs
// -----------------------------------------------------------------------

pub fn setAgentPid(self: *Workspace, key: []const u8, pid: std.posix.pid_t) !void {
    const owned_key = try self.allocator.dupe(u8, key);
    const result = try self.agent_pids.fetchPut(self.allocator, owned_key, pid);
    if (result) |old| {
        self.allocator.free(owned_key);
        _ = old;
    }
}

pub fn clearAgentPid(self: *Workspace, key: []const u8) void {
    if (self.agent_pids.fetchSwapRemove(key)) |kv| {
        self.allocator.free(kv.key);
    }
}

// -----------------------------------------------------------------------
// Reset
// -----------------------------------------------------------------------

/// Clear all sidebar state (status, metadata blocks, logs, progress, git, PR).
pub fn resetSidebar(self: *Workspace) void {
    // Status entries
    {
        var it = self.status_entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeStatusEntry(self.allocator, entry.value_ptr);
        }
        self.status_entries.clearRetainingCapacity();
    }

    // Metadata blocks
    {
        var it = self.metadata_blocks.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeMetadataBlock(self.allocator, entry.value_ptr);
        }
        self.metadata_blocks.clearRetainingCapacity();
    }

    // Logs
    self.clearLogs();

    // Progress
    if (self.progress) |*p| {
        if (p.label) |s| self.allocator.free(s);
    }
    self.progress = null;

    // Git branch
    if (self.git_branch) |*g| {
        freeStr(self.allocator, g.branch);
    }
    self.git_branch = null;

    // Pull request
    if (self.pull_request) |*pr| {
        freePullRequestState(self.allocator, pr);
    }
    self.pull_request = null;
}

// -----------------------------------------------------------------------
// Focus
// -----------------------------------------------------------------------

pub fn setFocusedPanel(self: *Workspace, panel_id: ?Uuid) void {
    self.focused_panel_id = panel_id;
}

// -----------------------------------------------------------------------
// Session persistence — snapshot building
// -----------------------------------------------------------------------

/// Callback for reading terminal scrollback. Takes allocator and panel/surface UUID,
/// returns owned text or null. Allows snapshot building without GTK dependency.
pub const ScrollbackReader = struct {
    ctx: ?*anyopaque = null,
    readFn: ?*const fn (ctx: *anyopaque, alloc: Allocator, surface_id: Uuid) ?[]const u8 = null,

    pub fn read(self: ScrollbackReader, alloc: Allocator, surface_id: Uuid) ?[]const u8 {
        if (self.readFn) |f| if (self.ctx) |c| return f(c, alloc, surface_id);
        return null;
    }
};

/// Build a serializable snapshot of this workspace's state.
/// All string data is duped into the provided allocator.
pub fn sessionSnapshot(self: *const Workspace, alloc: Allocator, include_scrollback: bool, scrollback_reader: ScrollbackReader) !snap.WorkspaceSnapshot {
    const policy = @import("../persistence/policy.zig");

    // Build panel snapshots
    const panel_keys = self.panels.keys();
    const panel_count = @min(panel_keys.len, policy.max_panels_per_workspace);
    const panel_snapshots = try alloc.alloc(snap.PanelSnapshot, panel_count);
    errdefer alloc.free(panel_snapshots);

    for (panel_keys[0..panel_count], 0..) |pid, i| {
        const panel = self.panels.get(pid).?;
        panel_snapshots[i] = .{
            .id = pid,
            .panel_type = panel.panelType(),
            .title = if (self.panel_titles.get(pid)) |t| try alloc.dupe(u8, t) else null,
            .custom_title = if (self.panel_custom_titles.get(pid)) |t| try alloc.dupe(u8, t) else null,
            .directory = if (self.panel_directories.get(pid)) |d| try alloc.dupe(u8, d) else null,
            .is_pinned = self.pinned_panel_ids.contains(pid),
            .is_manually_unread = self.manual_unread_panel_ids.contains(pid),
            .git_branch = if (self.panel_git_branches.get(pid)) |g| snap.GitBranchSnapshot{
                .branch = try alloc.dupe(u8, g.branch),
                .is_dirty = g.is_dirty,
            } else null,
            .listening_ports = if (self.surface_listening_ports.get(pid)) |p|
                try alloc.dupe(u16, p)
            else
                &.{},
            .tty_name = if (self.surface_tty_names.get(pid)) |t| try alloc.dupe(u8, t) else null,
            .terminal = switch (panel) {
                .terminal => |t| blk: {
                    // Capture scrollback if requested and reader available
                    var scrollback: ?[]const u8 = null;
                    if (include_scrollback) {
                        if (scrollback_reader.read(alloc, pid)) |raw| {
                            scrollback = policy.truncatedScrollback(alloc, raw) catch null;
                            alloc.free(raw);
                        }
                    }
                    break :blk snap.TerminalPanelSnapshot{
                        .working_directory = if (t.directory.len > 0) try alloc.dupe(u8, t.directory) else null,
                        .scrollback = scrollback,
                    };
                },
                else => null,
            },
            .browser = switch (panel) {
                .browser => |b| snap.BrowserPanelSnapshot{
                    .url_string = if (b.url) |u| try alloc.dupe(u8, u) else null,
                    .profile_id = b.profile_id,
                    .page_zoom = b.page_zoom,
                    .developer_tools_visible = b.developer_tools_visible,
                },
                else => null,
            },
            .markdown = switch (panel) {
                .markdown => |m| snap.MarkdownPanelSnapshot{
                    .file_path = try alloc.dupe(u8, m.file_path),
                },
                else => null,
            },
        };
    }

    // Build status entry snapshots
    const status_keys = self.status_entries.keys();
    const status_snapshots = try alloc.alloc(snap.StatusEntrySnapshot, status_keys.len);
    errdefer alloc.free(status_snapshots);

    for (status_keys, 0..) |key, i| {
        const entry = self.status_entries.get(key).?;
        status_snapshots[i] = .{
            .key = try alloc.dupe(u8, key),
            .value = try alloc.dupe(u8, entry.value),
            .icon = if (entry.icon) |ic| try alloc.dupe(u8, ic) else null,
            .color = if (entry.color) |c| try alloc.dupe(u8, c) else null,
            .timestamp = @floatFromInt(entry.timestamp),
        };
    }

    // Build log entry snapshots
    const log_snapshots = try alloc.alloc(snap.LogEntrySnapshot, self.log_entries.items.len);
    errdefer alloc.free(log_snapshots);

    for (self.log_entries.items, 0..) |entry, i| {
        log_snapshots[i] = .{
            .message = try alloc.dupe(u8, entry.message),
            .level = try alloc.dupe(u8, @tagName(entry.level)),
            .source = if (entry.source) |s| try alloc.dupe(u8, s) else null,
            .timestamp = @floatFromInt(entry.timestamp),
        };
    }

    return .{
        .process_title = try alloc.dupe(u8, self.process_title),
        .custom_title = if (self.custom_title) |t| try alloc.dupe(u8, t) else null,
        .custom_color = if (self.custom_color) |c| try alloc.dupe(u8, c) else null,
        .is_pinned = self.is_pinned,
        .current_directory = try alloc.dupe(u8, self.current_directory),
        .focused_panel_id = self.focused_panel_id,
        .panels = panel_snapshots,
        .status_entries = status_snapshots,
        .log_entries = log_snapshots,
        .progress = if (self.progress) |p| snap.ProgressSnapshot{
            .value = p.value,
            .label = if (p.label) |l| try alloc.dupe(u8, l) else null,
        } else null,
        .git_branch = if (self.git_branch) |g| snap.GitBranchSnapshot{
            .branch = try alloc.dupe(u8, g.branch),
            .is_dirty = g.is_dirty,
        } else null,
    };
}

/// Restore workspace-level state from a snapshot.
/// Panels are created from the snapshot; layout restoration is deferred
/// until the GTK split tree integration is in place.
pub fn restoreFromSnapshot(self: *Workspace, ws_snap: snap.WorkspaceSnapshot) !void {
    const alloc = self.allocator;

    // Apply workspace-level fields
    freeStr(alloc, self.process_title);
    self.process_title = try dupeStr(alloc, ws_snap.process_title);

    if (self.custom_title) |t| alloc.free(t);
    self.custom_title = if (ws_snap.custom_title) |t| try alloc.dupe(u8, t) else null;

    if (self.custom_color) |c| alloc.free(c);
    self.custom_color = if (ws_snap.custom_color) |c| try alloc.dupe(u8, c) else null;

    self.is_pinned = ws_snap.is_pinned;

    freeStr(alloc, self.current_directory);
    self.current_directory = try dupeStr(alloc, ws_snap.current_directory);

    // Restore panels
    for (ws_snap.panels) |panel_snap| {
        const panel: Panel = switch (panel_snap.panel_type) {
            .terminal => .{ .terminal = .{
                .id = panel_snap.id,
                .workspace_id = self.id,
                .title = try dupeStr(alloc, panel_snap.title orelse ""),
                .directory = try dupeStr(alloc, panel_snap.directory orelse ""),
                .tty_name = if (panel_snap.tty_name) |t| try alloc.dupe(u8, t) else null,
            } },
            .browser => .{ .browser = .{
                .id = panel_snap.id,
                .workspace_id = self.id,
                .url = if (panel_snap.browser) |b| if (b.url_string) |u| try alloc.dupe(u8, u) else null else null,
                .profile_id = if (panel_snap.browser) |b| b.profile_id else null,
                .page_zoom = if (panel_snap.browser) |b| b.page_zoom else 1.0,
                .developer_tools_visible = if (panel_snap.browser) |b| b.developer_tools_visible else false,
            } },
            .markdown => .{ .markdown = .{
                .id = panel_snap.id,
                .workspace_id = self.id,
                .file_path = try dupeStr(alloc, if (panel_snap.markdown) |m| m.file_path else ""),
            } },
        };
        try self.addPanel(panel);

        // Restore per-panel metadata
        if (panel_snap.title) |t| try self.setPanelTitle(panel_snap.id, t);
        if (panel_snap.custom_title) |t| try self.setPanelCustomTitle(panel_snap.id, t);
        if (panel_snap.directory) |d| try self.setPanelDirectory(panel_snap.id, d);
        if (panel_snap.is_pinned) try self.setPanelPinned(panel_snap.id, true);
        if (panel_snap.is_manually_unread) try self.setPanelUnread(panel_snap.id, true);
        if (panel_snap.git_branch) |g| try self.setPanelGitBranch(panel_snap.id, .{
            .branch = try alloc.dupe(u8, g.branch),
            .is_dirty = g.is_dirty,
        });
    }

    // Prepare scrollback replay for the first terminal panel (if available).
    const scrollback_replay = @import("../persistence/scrollback_replay.zig");
    for (ws_snap.panels) |panel_snap| {
        if (panel_snap.panel_type == .terminal) {
            if (panel_snap.terminal) |term| {
                if (term.scrollback) |sb| {
                    if (scrollback_replay.replayEnvironment(alloc, sb, null) catch null) |replay| {
                        self.restore_scrollback_path = replay.path;
                    }
                    break;
                }
            }
        }
    }

    // Status entries and agent PIDs are ephemeral — don't restore them.
    // Restore log entries
    for (self.log_entries.items) |*entry| {
        freeLogEntry(alloc, entry);
    }
    self.log_entries.clearRetainingCapacity();
    for (ws_snap.log_entries) |entry| {
        try self.appendLog(.{
            .message = try alloc.dupe(u8, entry.message),
            .level = std.meta.stringToEnum(sidebar.LogLevel, entry.level) orelse .info,
            .source = if (entry.source) |s| try alloc.dupe(u8, s) else null,
            .timestamp = @intFromFloat(entry.timestamp),
        });
    }

    // Restore progress
    if (ws_snap.progress) |p| {
        try self.setProgress(.{
            .value = p.value,
            .label = if (p.label) |l| try alloc.dupe(u8, l) else null,
        });
    }

    // Restore git branch
    if (ws_snap.git_branch) |g| {
        try self.setGitBranch(.{
            .branch = try alloc.dupe(u8, g.branch),
            .is_dirty = g.is_dirty,
        });
    }

    // Restore focused panel
    self.focused_panel_id = ws_snap.focused_panel_id;
}

// -----------------------------------------------------------------------
// Private helpers
// -----------------------------------------------------------------------

fn dupeStr(alloc: Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return "";
    return try alloc.dupe(u8, s);
}

fn freeStr(alloc: Allocator, s: []const u8) void {
    if (s.len > 0) alloc.free(s);
}

fn putOwnedStr(
    alloc: Allocator,
    map: *std.ArrayHashMapUnmanaged(Uuid, []const u8, Uuid.ArrayHashContext, true),
    key: Uuid,
    value: []const u8,
) !void {
    const owned = try dupeStr(alloc, value);
    if (map.fetchSwapRemove(key)) |old| {
        freeStr(alloc, old.value);
    }
    try map.put(alloc, key, owned);
}

fn removeAndFreeStr(
    alloc: Allocator,
    map: *std.ArrayHashMapUnmanaged(Uuid, []const u8, Uuid.ArrayHashContext, true),
    key: Uuid,
) void {
    if (map.fetchSwapRemove(key)) |old| {
        freeStr(alloc, old.value);
    }
}

fn freeStringValueMap(
    alloc: Allocator,
    map: *std.ArrayHashMapUnmanaged(Uuid, []const u8, Uuid.ArrayHashContext, true),
) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        freeStr(alloc, entry.value_ptr.*);
    }
    map.deinit(alloc);
}

fn freeStatusEntry(alloc: Allocator, entry: *sidebar.StatusEntry) void {
    freeStr(alloc, entry.key);
    freeStr(alloc, entry.value);
    if (entry.icon) |s| alloc.free(s);
    if (entry.color) |s| alloc.free(s);
    if (entry.url) |s| alloc.free(s);
}

fn freeMetadataBlock(alloc: Allocator, block: *sidebar.MetadataBlock) void {
    freeStr(alloc, block.key);
    freeStr(alloc, block.markdown);
}

fn freeLogEntry(alloc: Allocator, entry: *sidebar.LogEntry) void {
    freeStr(alloc, entry.message);
    if (entry.source) |s| alloc.free(s);
}

fn freePullRequestState(alloc: Allocator, pr: *sidebar.PullRequestState) void {
    freeStr(alloc, pr.label);
    freeStr(alloc, pr.url);
    if (pr.branch) |s| alloc.free(s);
}

fn dupeOwnedPullRequest(alloc: Allocator, pr: sidebar.PullRequestState) !sidebar.PullRequestState {
    return .{
        .number = pr.number,
        .label = try alloc.dupe(u8, pr.label),
        .url = try alloc.dupe(u8, pr.url),
        .status = pr.status,
        .branch = if (pr.branch) |s| try alloc.dupe(u8, s) else null,
        .checks = pr.checks,
    };
}

fn dupeOwnedStatusEntry(alloc: Allocator, entry: sidebar.StatusEntry) !sidebar.StatusEntry {
    return .{
        .key = try alloc.dupe(u8, entry.key),
        .value = try alloc.dupe(u8, entry.value),
        .icon = if (entry.icon) |s| try alloc.dupe(u8, s) else null,
        .color = if (entry.color) |s| try alloc.dupe(u8, s) else null,
        .url = if (entry.url) |s| try alloc.dupe(u8, s) else null,
        .priority = entry.priority,
        .format = entry.format,
        .timestamp = entry.timestamp,
    };
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "init and deinit" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{
        .title = "My Workspace",
        .working_directory = "/home/user",
        .port_ordinal = 0,
    });
    defer ws.deinit();

    try std.testing.expect(!ws.id.isNil());
    try std.testing.expectEqualStrings("My Workspace", ws.displayTitle());
    try std.testing.expectEqualStrings("/home/user", ws.current_directory);
    try std.testing.expect(!ws.is_pinned);
    try std.testing.expect(ws.custom_color == null);
    try std.testing.expect(ws.custom_title == null);
}

test "display title prefers custom title" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{ .title = "bash" });
    defer ws.deinit();

    try std.testing.expectEqualStrings("bash", ws.displayTitle());

    try ws.setCustomTitle("My Project");
    try std.testing.expectEqualStrings("My Project", ws.displayTitle());

    try ws.setCustomTitle(null);
    try std.testing.expectEqualStrings("bash", ws.displayTitle());
}

test "set and update cwd" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{ .working_directory = "/tmp" });
    defer ws.deinit();

    try ws.setCwd("/home/user/projects");
    try std.testing.expectEqualStrings("/home/user/projects", ws.current_directory);
}

test "panel add and remove" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const panel_id = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{
        .id = panel_id,
        .workspace_id = ws.id,
    } });
    try std.testing.expectEqual(@as(usize, 1), ws.panelCount());
    try std.testing.expect(ws.panelById(panel_id) != null);

    ws.removePanel(panel_id);
    try std.testing.expectEqual(@as(usize, 0), ws.panelCount());
    try std.testing.expect(ws.panelById(panel_id) == null);
}

test "panel metadata lifecycle" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid, .workspace_id = ws.id } });

    try ws.setPanelDirectory(pid, "/home/user");
    try ws.setPanelTitle(pid, "vim");
    try ws.setPanelGitBranch(pid, .{ .branch = "main", .is_dirty = true });

    try std.testing.expectEqualStrings("/home/user", ws.panel_directories.get(pid).?);
    try std.testing.expectEqualStrings("vim", ws.panel_titles.get(pid).?);
    try std.testing.expectEqualStrings("main", ws.panel_git_branches.get(pid).?.branch);
    try std.testing.expect(ws.panel_git_branches.get(pid).?.is_dirty);

    // Removing panel should clean up all metadata
    ws.removePanel(pid);
    try std.testing.expect(ws.panel_directories.get(pid) == null);
    try std.testing.expect(ws.panel_titles.get(pid) == null);
    try std.testing.expect(ws.panel_git_branches.get(pid) == null);
}

test "sidebar status set and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try ws.setStatus("shell", .{
        .key = "shell",
        .value = "prompt",
        .priority = 1,
    });
    try std.testing.expectEqualStrings("prompt", ws.status_entries.get("shell").?.value);

    // Update existing
    try ws.setStatus("shell", .{
        .key = "shell",
        .value = "running",
        .priority = 1,
    });
    try std.testing.expectEqualStrings("running", ws.status_entries.get("shell").?.value);

    ws.clearStatus("shell");
    try std.testing.expect(ws.status_entries.get("shell") == null);
}

test "sidebar log append and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try ws.appendLog(.{ .message = "hello", .level = .info });
    try ws.appendLog(.{ .message = "world", .level = .warning });
    try std.testing.expectEqual(@as(usize, 2), ws.log_entries.items.len);

    ws.clearLogs();
    try std.testing.expectEqual(@as(usize, 0), ws.log_entries.items.len);
}

test "sidebar reset clears everything" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try ws.setStatus("key", .{ .key = "key", .value = "val" });
    try ws.appendLog(.{ .message = "log" });
    try ws.setProgress(.{ .value = 0.5, .label = "halfway" });
    try ws.setGitBranch(.{ .branch = "main" });

    ws.resetSidebar();

    try std.testing.expectEqual(@as(usize, 0), ws.status_entries.count());
    try std.testing.expectEqual(@as(usize, 0), ws.log_entries.items.len);
    try std.testing.expect(ws.progress == null);
    try std.testing.expect(ws.git_branch == null);
}

test "focused panel clears on remove" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid, .workspace_id = ws.id } });
    ws.setFocusedPanel(pid);
    try std.testing.expect(ws.focused_panel_id != null);

    ws.removePanel(pid);
    try std.testing.expect(ws.focused_panel_id == null);
}

// -----------------------------------------------------------------------
// Tests ported from macOS WorkspaceUnitTests.swift
// -----------------------------------------------------------------------

test "Workspace: set and clear custom color" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try std.testing.expect(ws.custom_color == null);

    try ws.setCustomColor("#C0392B");
    try std.testing.expectEqualStrings("#C0392B", ws.custom_color.?);

    // Update to a different color
    try ws.setCustomColor("#2ECC71");
    try std.testing.expectEqualStrings("#2ECC71", ws.custom_color.?);

    // Clear
    try ws.setCustomColor(null);
    try std.testing.expect(ws.custom_color == null);
}

test "Workspace: set and toggle pinned" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try std.testing.expect(!ws.is_pinned);

    ws.setPinned(true);
    try std.testing.expect(ws.is_pinned);

    ws.setPinned(false);
    try std.testing.expect(!ws.is_pinned);
}

test "Workspace: process title update" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{ .title = "bash" });
    defer ws.deinit();

    try std.testing.expectEqualStrings("bash", ws.process_title);

    try ws.setProcessTitle("vim");
    try std.testing.expectEqualStrings("vim", ws.process_title);
    // display title should follow process title when no custom title
    try std.testing.expectEqualStrings("vim", ws.displayTitle());

    // custom title takes precedence
    try ws.setCustomTitle("override");
    try std.testing.expectEqualStrings("override", ws.displayTitle());
    // process title still updated underneath
    try ws.setProcessTitle("zsh");
    try std.testing.expectEqualStrings("override", ws.displayTitle());

    // removing custom title reveals updated process title
    try ws.setCustomTitle(null);
    try std.testing.expectEqualStrings("zsh", ws.displayTitle());
}

test "Workspace: panel custom title set and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid, .workspace_id = ws.id } });

    try std.testing.expect(ws.panel_custom_titles.get(pid) == null);

    try ws.setPanelCustomTitle(pid, "My Panel");
    try std.testing.expectEqualStrings("My Panel", ws.panel_custom_titles.get(pid).?);

    // Update
    try ws.setPanelCustomTitle(pid, "Renamed");
    try std.testing.expectEqualStrings("Renamed", ws.panel_custom_titles.get(pid).?);

    // Clear
    try ws.setPanelCustomTitle(pid, null);
    try std.testing.expect(ws.panel_custom_titles.get(pid) == null);
}

test "Workspace: panel pinned set and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid, .workspace_id = ws.id } });

    try std.testing.expect(ws.pinned_panel_ids.get(pid) == null);

    try ws.setPanelPinned(pid, true);
    try std.testing.expect(ws.pinned_panel_ids.get(pid) != null);

    try ws.setPanelPinned(pid, false);
    try std.testing.expect(ws.pinned_panel_ids.get(pid) == null);
}

test "Workspace: panel unread set and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid, .workspace_id = ws.id } });

    try std.testing.expect(ws.manual_unread_panel_ids.get(pid) == null);

    try ws.setPanelUnread(pid, true);
    try std.testing.expect(ws.manual_unread_panel_ids.get(pid) != null);

    try ws.setPanelUnread(pid, false);
    try std.testing.expect(ws.manual_unread_panel_ids.get(pid) == null);
}

test "Workspace: panel git branch set update and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid, .workspace_id = ws.id } });

    try ws.setPanelGitBranch(pid, .{ .branch = "main", .is_dirty = false });
    try std.testing.expectEqualStrings("main", ws.panel_git_branches.get(pid).?.branch);
    try std.testing.expect(!ws.panel_git_branches.get(pid).?.is_dirty);

    // Update
    try ws.setPanelGitBranch(pid, .{ .branch = "feature/bugfix", .is_dirty = true });
    try std.testing.expectEqualStrings("feature/bugfix", ws.panel_git_branches.get(pid).?.branch);
    try std.testing.expect(ws.panel_git_branches.get(pid).?.is_dirty);

    // Clear
    try ws.setPanelGitBranch(pid, null);
    try std.testing.expect(ws.panel_git_branches.get(pid) == null);
}

test "Workspace: panel pull request set and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid, .workspace_id = ws.id } });

    try ws.setPanelPullRequest(pid, .{
        .number = 1629,
        .label = "PR",
        .url = "https://github.com/example/repo/pull/1629",
        .status = .open,
    });
    const pr = ws.panel_pull_requests.get(pid).?;
    try std.testing.expectEqual(@as(u32, 1629), pr.number);
    try std.testing.expectEqualStrings("PR", pr.label);
    try std.testing.expectEqual(sidebar.PullRequestStatus.open, pr.status);

    // Clear
    try ws.setPanelPullRequest(pid, null);
    try std.testing.expect(ws.panel_pull_requests.get(pid) == null);
}

test "Workspace: panel listening ports set and update" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid, .workspace_id = ws.id } });

    try ws.setPanelListeningPorts(pid, &.{ 8080, 3000 });
    const ports = ws.surface_listening_ports.get(pid).?;
    try std.testing.expectEqual(@as(usize, 2), ports.len);
    try std.testing.expectEqual(@as(u16, 8080), ports[0]);
    try std.testing.expectEqual(@as(u16, 3000), ports[1]);

    // Update
    try ws.setPanelListeningPorts(pid, &.{9090});
    const updated = ws.surface_listening_ports.get(pid).?;
    try std.testing.expectEqual(@as(usize, 1), updated.len);
    try std.testing.expectEqual(@as(u16, 9090), updated[0]);
}

test "Workspace: panel tty name set and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid, .workspace_id = ws.id } });

    try ws.setPanelTtyName(pid, "/dev/pts/1");
    try std.testing.expectEqualStrings("/dev/pts/1", ws.surface_tty_names.get(pid).?);

    try ws.setPanelTtyName(pid, null);
    try std.testing.expect(ws.surface_tty_names.get(pid) == null);
}

test "Workspace: panel shell activity" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid, .workspace_id = ws.id } });

    try ws.setPanelShellActivity(pid, .prompt_idle);
    try std.testing.expectEqual(sidebar.ShellActivityState.prompt_idle, ws.panel_shell_activity.get(pid).?);

    try ws.setPanelShellActivity(pid, .command_running);
    try std.testing.expectEqual(sidebar.ShellActivityState.command_running, ws.panel_shell_activity.get(pid).?);
}

test "Workspace: attention flash trigger and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid, .workspace_id = ws.id } });

    try std.testing.expect(ws.tmux_workspace_flash_panel_id == null);
    try std.testing.expect(ws.tmux_workspace_flash_reason == null);
    try std.testing.expectEqual(@as(u64, 0), ws.tmux_workspace_flash_token);

    ws.triggerFlash(pid, .navigation);
    try std.testing.expect(ws.tmux_workspace_flash_panel_id != null);
    try std.testing.expect(ws.tmux_workspace_flash_panel_id.?.eql(pid));
    try std.testing.expectEqual(AttentionFlashReason.navigation, ws.tmux_workspace_flash_reason.?);
    try std.testing.expectEqual(@as(u64, 1), ws.tmux_workspace_flash_token);

    // Second flash increments token
    ws.triggerFlash(pid, .notification_arrival);
    try std.testing.expectEqual(@as(u64, 2), ws.tmux_workspace_flash_token);
    try std.testing.expectEqual(AttentionFlashReason.notification_arrival, ws.tmux_workspace_flash_reason.?);

    ws.clearFlash();
    try std.testing.expect(ws.tmux_workspace_flash_panel_id == null);
    try std.testing.expect(ws.tmux_workspace_flash_reason == null);
    // Token is NOT cleared by clearFlash
    try std.testing.expectEqual(@as(u64, 2), ws.tmux_workspace_flash_token);
}

test "Workspace: workspace-level git branch set and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try std.testing.expect(ws.git_branch == null);

    try ws.setGitBranch(.{ .branch = "main", .is_dirty = false });
    try std.testing.expectEqualStrings("main", ws.git_branch.?.branch);
    try std.testing.expect(!ws.git_branch.?.is_dirty);

    // Update
    try ws.setGitBranch(.{ .branch = "feature/sidebar", .is_dirty = true });
    try std.testing.expectEqualStrings("feature/sidebar", ws.git_branch.?.branch);
    try std.testing.expect(ws.git_branch.?.is_dirty);

    // Clear
    try ws.setGitBranch(null);
    try std.testing.expect(ws.git_branch == null);
}

test "Workspace: workspace-level pull request set and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try std.testing.expect(ws.pull_request == null);

    try ws.setPullRequest(.{
        .number = 42,
        .label = "feat: new sidebar",
        .url = "https://github.com/example/repo/pull/42",
        .status = .open,
        .branch = "feature/sidebar",
    });
    try std.testing.expectEqual(@as(u32, 42), ws.pull_request.?.number);
    try std.testing.expectEqualStrings("feat: new sidebar", ws.pull_request.?.label);
    try std.testing.expectEqualStrings("feature/sidebar", ws.pull_request.?.branch.?);

    // Clear
    try ws.setPullRequest(null);
    try std.testing.expect(ws.pull_request == null);
}

test "Workspace: workspace-level progress set and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try std.testing.expect(ws.progress == null);

    try ws.setProgress(.{ .value = 0.5, .label = "Building..." });
    try std.testing.expect(ws.progress != null);
    try std.testing.expectEqual(@as(f64, 0.5), ws.progress.?.value);
    try std.testing.expectEqualStrings("Building...", ws.progress.?.label.?);

    // Update
    try ws.setProgress(.{ .value = 1.0, .label = null });
    try std.testing.expectEqual(@as(f64, 1.0), ws.progress.?.value);
    try std.testing.expect(ws.progress.?.label == null);

    // Clear
    try ws.setProgress(null);
    try std.testing.expect(ws.progress == null);
}

test "Workspace: workspace-level listening ports" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try std.testing.expectEqual(@as(usize, 0), ws.listening_ports.len);

    try ws.setListeningPorts(&.{ 8080, 3000, 5173 });
    try std.testing.expectEqual(@as(usize, 3), ws.listening_ports.len);
    try std.testing.expectEqual(@as(u16, 8080), ws.listening_ports[0]);
    try std.testing.expectEqual(@as(u16, 3000), ws.listening_ports[1]);
    try std.testing.expectEqual(@as(u16, 5173), ws.listening_ports[2]);

    // Replace
    try ws.setListeningPorts(&.{9090});
    try std.testing.expectEqual(@as(usize, 1), ws.listening_ports.len);
}

test "Workspace: agent PIDs set and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try ws.setAgentPid("claude", 12345);
    try std.testing.expectEqual(@as(std.posix.pid_t, 12345), ws.agent_pids.get("claude").?);

    // Update
    try ws.setAgentPid("claude", 67890);
    try std.testing.expectEqual(@as(std.posix.pid_t, 67890), ws.agent_pids.get("claude").?);

    ws.clearAgentPid("claude");
    try std.testing.expect(ws.agent_pids.get("claude") == null);
}

test "Workspace: metadata block set and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try ws.setMetadataBlock("readme", .{
        .key = "readme",
        .markdown = "# Hello",
        .priority = 5,
    });
    try std.testing.expectEqualStrings("# Hello", ws.metadata_blocks.get("readme").?.markdown);

    // Update
    try ws.setMetadataBlock("readme", .{
        .key = "readme",
        .markdown = "# Updated",
        .priority = 10,
    });
    try std.testing.expectEqualStrings("# Updated", ws.metadata_blocks.get("readme").?.markdown);

    ws.clearMetadataBlock("readme");
    try std.testing.expect(ws.metadata_blocks.get("readme") == null);
}

test "Workspace: log entry with source field" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try ws.appendLog(.{ .message = "started", .level = .info, .source = "build" });
    try ws.appendLog(.{ .message = "warning!", .level = .warning, .source = null });

    try std.testing.expectEqual(@as(usize, 2), ws.log_entries.items.len);
    try std.testing.expectEqualStrings("started", ws.log_entries.items[0].message);
    try std.testing.expectEqualStrings("build", ws.log_entries.items[0].source.?);
    try std.testing.expect(ws.log_entries.items[1].source == null);
}

test "Workspace: removing panel cleans all metadata maps" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid, .workspace_id = ws.id } });

    // Populate every per-panel metadata map
    try ws.setPanelDirectory(pid, "/home/user");
    try ws.setPanelTitle(pid, "vim");
    try ws.setPanelCustomTitle(pid, "My Panel");
    try ws.setPanelPinned(pid, true);
    try ws.setPanelUnread(pid, true);
    try ws.setPanelGitBranch(pid, .{ .branch = "main", .is_dirty = false });
    try ws.setPanelPullRequest(pid, .{
        .number = 1,
        .label = "PR",
        .url = "https://example.com/pr/1",
    });
    try ws.setPanelListeningPorts(pid, &.{8080});
    try ws.setPanelTtyName(pid, "/dev/pts/0");
    try ws.setPanelShellActivity(pid, .command_running);
    ws.setFocusedPanel(pid);

    // Verify everything was set
    try std.testing.expect(ws.panel_directories.get(pid) != null);
    try std.testing.expect(ws.panel_titles.get(pid) != null);
    try std.testing.expect(ws.panel_custom_titles.get(pid) != null);
    try std.testing.expect(ws.pinned_panel_ids.get(pid) != null);
    try std.testing.expect(ws.manual_unread_panel_ids.get(pid) != null);
    try std.testing.expect(ws.panel_git_branches.get(pid) != null);
    try std.testing.expect(ws.panel_pull_requests.get(pid) != null);
    try std.testing.expect(ws.surface_listening_ports.get(pid) != null);
    try std.testing.expect(ws.surface_tty_names.get(pid) != null);
    try std.testing.expect(ws.panel_shell_activity.get(pid) != null);
    try std.testing.expect(ws.focused_panel_id != null);

    // Remove should clean everything
    ws.removePanel(pid);
    try std.testing.expect(ws.panel_directories.get(pid) == null);
    try std.testing.expect(ws.panel_titles.get(pid) == null);
    try std.testing.expect(ws.panel_custom_titles.get(pid) == null);
    try std.testing.expect(ws.pinned_panel_ids.get(pid) == null);
    try std.testing.expect(ws.manual_unread_panel_ids.get(pid) == null);
    try std.testing.expect(ws.panel_git_branches.get(pid) == null);
    try std.testing.expect(ws.panel_pull_requests.get(pid) == null);
    try std.testing.expect(ws.surface_listening_ports.get(pid) == null);
    try std.testing.expect(ws.surface_tty_names.get(pid) == null);
    try std.testing.expect(ws.panel_shell_activity.get(pid) == null);
    try std.testing.expect(ws.focused_panel_id == null);
}

test "Workspace: preferred browser profile ID set and clear" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try std.testing.expect(ws.preferred_browser_profile_id == null);

    const profile_id = Uuid.generate();
    ws.setPreferredBrowserProfileId(profile_id);
    try std.testing.expect(ws.preferred_browser_profile_id != null);
    try std.testing.expect(ws.preferred_browser_profile_id.?.eql(profile_id));

    ws.setPreferredBrowserProfileId(null);
    try std.testing.expect(ws.preferred_browser_profile_id == null);
}

test "Workspace: active remote terminal session count" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try std.testing.expectEqual(@as(u32, 0), ws.active_remote_terminal_session_count);

    ws.setActiveRemoteTerminalSessionCount(3);
    try std.testing.expectEqual(@as(u32, 3), ws.active_remote_terminal_session_count);
}

test "Workspace: sidebar reset also clears pull request" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try ws.setStatus("key", .{ .key = "key", .value = "val" });
    try ws.appendLog(.{ .message = "log" });
    try ws.setProgress(.{ .value = 0.5, .label = "halfway" });
    try ws.setGitBranch(.{ .branch = "main" });
    try ws.setPullRequest(.{
        .number = 99,
        .label = "PR",
        .url = "https://example.com/pr/99",
        .status = .merged,
    });
    try ws.setMetadataBlock("info", .{
        .key = "info",
        .markdown = "# Info",
    });

    ws.resetSidebar();

    try std.testing.expectEqual(@as(usize, 0), ws.status_entries.count());
    try std.testing.expectEqual(@as(usize, 0), ws.log_entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), ws.metadata_blocks.count());
    try std.testing.expect(ws.progress == null);
    try std.testing.expect(ws.git_branch == null);
    try std.testing.expect(ws.pull_request == null);
}

test "Workspace: init with explicit ID" {
    const alloc = std.testing.allocator;
    const explicit_id = Uuid.generate();
    var ws = try init(alloc, .{
        .id = explicit_id,
        .title = "explicit",
    });
    defer ws.deinit();

    try std.testing.expect(ws.id.eql(explicit_id));
}

test "Workspace: multiple panels independent metadata" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid1 = Uuid.generate();
    const pid2 = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid1, .workspace_id = ws.id } });
    try ws.addPanel(.{ .terminal = .{ .id = pid2, .workspace_id = ws.id } });

    try ws.setPanelDirectory(pid1, "/home/user/project-a");
    try ws.setPanelDirectory(pid2, "/home/user/project-b");
    try ws.setPanelGitBranch(pid1, .{ .branch = "main", .is_dirty = false });
    try ws.setPanelGitBranch(pid2, .{ .branch = "feature/b", .is_dirty = true });

    try std.testing.expectEqualStrings("/home/user/project-a", ws.panel_directories.get(pid1).?);
    try std.testing.expectEqualStrings("/home/user/project-b", ws.panel_directories.get(pid2).?);
    try std.testing.expectEqualStrings("main", ws.panel_git_branches.get(pid1).?.branch);
    try std.testing.expectEqualStrings("feature/b", ws.panel_git_branches.get(pid2).?.branch);

    // Remove first panel, second still intact
    ws.removePanel(pid1);
    try std.testing.expect(ws.panel_directories.get(pid1) == null);
    try std.testing.expectEqualStrings("/home/user/project-b", ws.panel_directories.get(pid2).?);
    try std.testing.expectEqualStrings("feature/b", ws.panel_git_branches.get(pid2).?.branch);
}

test "Workspace: focused panel not cleared when different panel removed" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    const pid1 = Uuid.generate();
    const pid2 = Uuid.generate();
    try ws.addPanel(.{ .terminal = .{ .id = pid1, .workspace_id = ws.id } });
    try ws.addPanel(.{ .terminal = .{ .id = pid2, .workspace_id = ws.id } });
    ws.setFocusedPanel(pid1);

    // Removing pid2 should NOT clear focus (pid1 is focused)
    ws.removePanel(pid2);
    try std.testing.expect(ws.focused_panel_id != null);
    try std.testing.expect(ws.focused_panel_id.?.eql(pid1));
}

test "Workspace: status entry with all optional fields" {
    const alloc = std.testing.allocator;
    var ws = try init(alloc, .{});
    defer ws.deinit();

    try ws.setStatus("deploy", .{
        .key = "deploy",
        .value = "running",
        .icon = "rocket",
        .color = "#FF0000",
        .url = "https://example.com/deploy",
        .priority = 10,
        .format = .markdown,
        .timestamp = 1700000000,
    });

    const entry = ws.status_entries.get("deploy").?;
    try std.testing.expectEqualStrings("deploy", entry.key);
    try std.testing.expectEqualStrings("running", entry.value);
    try std.testing.expectEqualStrings("rocket", entry.icon.?);
    try std.testing.expectEqualStrings("#FF0000", entry.color.?);
    try std.testing.expectEqualStrings("https://example.com/deploy", entry.url.?);
    try std.testing.expectEqual(@as(i32, 10), entry.priority);
    try std.testing.expectEqual(sidebar.MetadataFormat.markdown, entry.format);
}
