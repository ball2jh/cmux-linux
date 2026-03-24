//! cmux socket protocol: V1 (text) and V2 (JSON) parsers and encoders.

pub const v1 = @import("v1.zig");
pub const v2 = @import("v2.zig");

/// Returns true if the line looks like a V2 JSON request (starts with '{').
/// Matches macOS detection at TerminalController.swift line 1638.
pub fn isV2(line: []const u8) bool {
    const trimmed = @import("std").mem.trimLeft(u8, line, &@import("std").ascii.whitespace);
    return trimmed.len > 0 and trimmed[0] == '{';
}

test {
    _ = v1;
    _ = v2;
}

test "isV2 detection" {
    const std = @import("std");
    try std.testing.expect(isV2("{\"method\":\"ping\"}"));
    try std.testing.expect(isV2("  {\"method\":\"ping\"}"));
    try std.testing.expect(!isV2("ping"));
    try std.testing.expect(!isV2(""));
}
