pub const Uuid = @import("uuid.zig").Uuid;
pub const notification = @import("notification/main.zig");
pub const workspace = @import("workspace/main.zig");
pub const persistence = @import("persistence/main.zig");
pub const debug = @import("debug/main.zig");
pub const remote = @import("remote/main.zig");

// Socket server infrastructure.
pub const Server = @import("Server.zig");
pub const window_ops = @import("window_ops.zig");
pub const access = @import("access.zig");
pub const socket_path = @import("socket_path.zig");
pub const protocol = @import("protocol.zig");
pub const dispatch = @import("dispatch.zig");
pub const accept_loop = @import("accept_loop.zig");
pub const client_handler = @import("client_handler.zig");

// Config.
pub const GhosttyConfig = @import("GhosttyConfig.zig");
pub const color_utils = @import("color_utils.zig");

// UI test observability harness.
pub const ui_test_harness = @import("ui_test_harness.zig");
pub const render_diagnostics = @import("render_diagnostics.zig");

// Terminal image transfer.
pub const image_transfer = @import("image_transfer.zig");
pub const url_resolve = @import("url_resolve.zig");

// Utilities.
pub const sidebar_drop_planner = @import("sidebar_drop_planner.zig");
pub const sidebar_path = @import("sidebar_path.zig");
pub const password_store = @import("password_store.zig");
pub const command_palette_search = @import("command_palette_search.zig");
pub const shortcut = @import("shortcut.zig");
pub const shortcut_routing = @import("shortcut_routing.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
