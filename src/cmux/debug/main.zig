//! Debug module — diagnostic commands for testing and introspection.
//!
//! Provides debug.* socket commands matching the macOS reference.
//! `debug.terminals` is available in all builds; everything else is
//! gated behind `build_config.is_debug` (comptime, stripped in release).

pub const commands = @import("commands.zig");
pub const counters = @import("counters.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
