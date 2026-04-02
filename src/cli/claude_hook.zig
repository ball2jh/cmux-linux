const std = @import("std");
const Allocator = std.mem.Allocator;

const claude_hook = @import("../cmux/claude_hook.zig");

pub const Options = struct {};

/// The `claude-hook` command handles Claude Code lifecycle hooks.
/// Invoked by the claude wrapper script when running inside a cmux terminal.
pub fn run(alloc: Allocator) !u8 {
    return claude_hook.run(alloc);
}
