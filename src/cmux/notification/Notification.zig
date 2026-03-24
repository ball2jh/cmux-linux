/// A terminal notification, matching the macOS `TerminalNotification` struct.
///
/// String fields (title, subtitle, body) are owned by the Store that manages
/// this notification — the Store is responsible for allocating and freeing them.
const Uuid = @import("../uuid.zig").Uuid;

pub const Notification = struct {
    id: Uuid,
    tab_id: Uuid,
    /// `null` means a workspace-level notification (not tied to a specific surface).
    surface_id: ?Uuid,
    title: []const u8,
    subtitle: []const u8,
    body: []const u8,
    /// Milliseconds since epoch (std.time.milliTimestamp()).
    created_at: i64,
    is_read: bool,
};
