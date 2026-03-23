// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2025 cmux-linux contributors
//
// Git branch detection for cmux workspace sidebar.
// Runs `git rev-parse --abbrev-ref HEAD` in each workspace's
// working directory to show the current branch name.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.cmux_git);

/// Get the current git branch name for a given directory path.
/// Returns null if not a git repo or git is not installed.
pub fn getBranch(alloc: Allocator, cwd: []const u8) ?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
        .cwd = cwd,
        .max_output_bytes = 256,
    }) catch return null;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term.Exited != 0) return null;

    const trimmed = std.mem.trim(u8, result.stdout, &[_]u8{ '\n', '\r', ' ' });
    if (trimmed.len == 0) return null;

    return alloc.dupe(u8, trimmed) catch null;
}

/// Cached branch info per directory.
var cached_branches: std.StringHashMapUnmanaged([]const u8) = .empty;
var cache_alloc: ?Allocator = null;

pub fn initGlobal(alloc: Allocator) void {
    cache_alloc = alloc;
}

pub fn deinitGlobal() void {
    const alloc = cache_alloc orelse return;
    var it = cached_branches.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        alloc.free(entry.value_ptr.*);
    }
    cached_branches.deinit(alloc);
    cache_alloc = null;
}

/// Get branch for a directory, using cache.
pub fn getCachedBranch(cwd: []const u8) ?[]const u8 {
    return cached_branches.get(cwd);
}

/// Refresh branch cache for a directory.
pub fn refreshBranch(cwd: []const u8) void {
    const alloc = cache_alloc orelse return;
    const branch = getBranch(alloc, cwd) orelse return;

    // Remove old entry if exists
    if (cached_branches.fetchRemove(cwd)) |old| {
        alloc.free(old.key);
        alloc.free(old.value);
    }

    const key = alloc.dupe(u8, cwd) catch {
        alloc.free(branch);
        return;
    };
    cached_branches.put(alloc, key, branch) catch {
        alloc.free(key);
        alloc.free(branch);
    };
}
