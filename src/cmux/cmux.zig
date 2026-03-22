// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2025 cmux-linux contributors
//
// cmux module: AI coding agent terminal features built on Ghostty.
// This module provides the socket control API, notification system,
// workspace management, browser panel, and session persistence that
// differentiate cmux from a standard Ghostty build.

const build_config = @import("../build_config.zig");

pub const socket = @import("socket/server.zig");
pub const handler_v1 = @import("socket/handler_v1.zig");

test {
    if (comptime build_config.cmux) {
        _ = socket;
        _ = handler_v1;
    }
}
