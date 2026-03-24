/// Remote connection state types for workspace remote sessions.
///
/// These types track SSH tunnels, remote daemon status, and port forwarding
/// for workspaces connected to remote machines. Matches the macOS reference
/// types: WorkspaceRemoteConfiguration, WorkspaceRemoteConnectionState, etc.
///
/// String fields are unowned slices — the Workspace that contains these
/// types is responsible for allocating and freeing the backing memory.

pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    @"error",
};

pub const DaemonState = enum {
    unavailable,
    bootstrapping,
    ready,
    @"error",
};

pub const DaemonStatus = struct {
    state: DaemonState = .unavailable,
    detail: ?[]const u8 = null,
    version: ?[]const u8 = null,
    name: ?[]const u8 = null,
    capabilities: []const []const u8 = &.{},
    remote_path: ?[]const u8 = null,
};

pub const Configuration = struct {
    destination: []const u8,
    port: ?u16 = null,
    identity_file: ?[]const u8 = null,
    ssh_options: []const []const u8 = &.{},
    local_proxy_port: ?u16 = null,
    relay_port: ?u16 = null,
    relay_id: ?[]const u8 = null,
    relay_token: ?[]const u8 = null,
    local_socket_path: ?[]const u8 = null,
    terminal_startup_command: ?[]const u8 = null,
};

pub const RemoteState = struct {
    configuration: ?Configuration = null,
    connection_state: ConnectionState = .disconnected,
    connection_detail: ?[]const u8 = null,
    daemon_status: DaemonStatus = .{},
    detected_ports: []const u16 = &.{},
    forwarded_ports: []const u16 = &.{},
    port_conflicts: []const u16 = &.{},
    heartbeat_count: u32 = 0,
    last_heartbeat_at: ?i64 = null,

    pub const empty: RemoteState = .{};
};
