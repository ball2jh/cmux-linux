//! Bidirectional UUID-to-short-handle map for V2 protocol refs.
//!
//! Provides stable, session-scoped short names (e.g. "workspace:1", "surface:3")
//! that clients can use instead of full UUIDs. Ordinals are monotonically
//! increasing per handle kind and are never reused within a session.
//!
//! Matches macOS TerminalController v2EnsureHandleRef / v2ResolveHandleRef
//! (lines 2967-2997).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Uuid = @import("uuid.zig").Uuid;

const RefMap = @This();

pub const HandleKind = enum {
    window,
    workspace,
    pane,
    surface,

    pub const all = [_]HandleKind{ .window, .workspace, .pane, .surface };

    pub fn label(self: HandleKind) []const u8 {
        return switch (self) {
            .window => "window",
            .workspace => "workspace",
            .pane => "pane",
            .surface => "surface",
        };
    }
};

const KindState = struct {
    next_ordinal: u32 = 1,
    ref_by_uuid: std.AutoArrayHashMapUnmanaged(Uuid, []const u8) = .{},
    uuid_by_ref: std.StringArrayHashMapUnmanaged(Uuid) = .{},

    fn deinit(self: *KindState, alloc: Allocator) void {
        // Free all allocated ref strings.
        for (self.ref_by_uuid.values()) |ref_str| {
            alloc.free(ref_str);
        }
        self.ref_by_uuid.deinit(alloc);
        self.uuid_by_ref.deinit(alloc);
    }
};

/// Per-kind state indexed by HandleKind.
kinds: [HandleKind.all.len]KindState,
alloc: Allocator,

pub fn init(alloc: Allocator) RefMap {
    var kinds: [HandleKind.all.len]KindState = undefined;
    for (&kinds) |*k| {
        k.* = .{};
    }
    return .{
        .kinds = kinds,
        .alloc = alloc,
    };
}

pub fn deinit(self: *RefMap) void {
    for (&self.kinds) |*k| {
        k.deinit(self.alloc);
    }
}

/// Ensure a ref exists for the given UUID. Returns the ref string
/// (e.g. "workspace:1"). Idempotent — returns the existing ref if
/// one was already allocated.
pub fn ensureRef(self: *RefMap, kind: HandleKind, uuid: Uuid) ![]const u8 {
    const k = &self.kinds[@intFromEnum(kind)];

    // Return existing ref if already mapped.
    if (k.ref_by_uuid.get(uuid)) |existing| {
        return existing;
    }

    // Allocate new ref string: "{kind}:{ordinal}"
    const ordinal = k.next_ordinal;
    const ref_str = try std.fmt.allocPrint(self.alloc, "{s}:{d}", .{ kind.label(), ordinal });
    errdefer self.alloc.free(ref_str);

    try k.ref_by_uuid.put(self.alloc, uuid, ref_str);
    errdefer _ = k.ref_by_uuid.swapRemove(uuid);

    try k.uuid_by_ref.put(self.alloc, ref_str, uuid);

    k.next_ordinal = ordinal + 1;
    return ref_str;
}

/// Look up the ref for a UUID without allocating. Returns null if no ref
/// has been allocated for this UUID.
pub fn getRef(self: *const RefMap, kind: HandleKind, uuid: Uuid) ?[]const u8 {
    return self.kinds[@intFromEnum(kind)].ref_by_uuid.get(uuid);
}

/// Resolve a ref string (e.g. "workspace:1") to a UUID.
/// Searches all handle kinds. Also handles the "tab:N" → "surface:N" alias.
/// Returns null if the ref is not found.
pub fn resolve(self: *const RefMap, ref_string: []const u8) ?Uuid {
    const trimmed = std.mem.trim(u8, ref_string, " \t");

    // Try all kinds directly.
    for (&self.kinds) |*k| {
        if (k.uuid_by_ref.get(trimmed)) |uuid| {
            return uuid;
        }
    }

    // Handle "tab:N" → "surface:N" alias (matches Mac .lowercased() behavior).
    const lower = blk: {
        var buf: [64]u8 = undefined;
        if (trimmed.len > buf.len) break :blk trimmed;
        for (trimmed, 0..) |c, i| {
            buf[i] = std.ascii.toLower(c);
        }
        break :blk buf[0..trimmed.len];
    };
    if (std.mem.startsWith(u8, lower, "tab:")) {
        const ordinal_part = lower["tab:".len..];
        const surface_ref = std.fmt.allocPrint(self.alloc, "surface:{s}", .{ordinal_part}) catch return null;
        defer self.alloc.free(surface_ref);
        return self.kinds[@intFromEnum(HandleKind.surface)].uuid_by_ref.get(surface_ref);
    }

    return null;
}

// --- Tests ---

test "ensureRef allocates sequential ordinals" {
    var map = RefMap.init(std.testing.allocator);
    defer map.deinit();

    const id1 = Uuid.generate();
    const id2 = Uuid.generate();

    const ref1 = try map.ensureRef(.workspace, id1);
    const ref2 = try map.ensureRef(.workspace, id2);

    try std.testing.expectEqualStrings("workspace:1", ref1);
    try std.testing.expectEqualStrings("workspace:2", ref2);
}

test "ensureRef is idempotent" {
    var map = RefMap.init(std.testing.allocator);
    defer map.deinit();

    const id = Uuid.generate();
    const ref1 = try map.ensureRef(.surface, id);
    const ref2 = try map.ensureRef(.surface, id);

    try std.testing.expectEqualStrings(ref1, ref2);
    try std.testing.expectEqual(ref1.ptr, ref2.ptr); // Same pointer.
}

test "resolve finds UUID by ref string" {
    var map = RefMap.init(std.testing.allocator);
    defer map.deinit();

    const id = Uuid.generate();
    _ = try map.ensureRef(.workspace, id);

    const resolved = map.resolve("workspace:1");
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.?.eql(id));
}

test "resolve returns null for unknown ref" {
    var map = RefMap.init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(map.resolve("workspace:99") == null);
    try std.testing.expect(map.resolve("nonsense") == null);
}

test "resolve handles tab alias" {
    var map = RefMap.init(std.testing.allocator);
    defer map.deinit();

    const id = Uuid.generate();
    _ = try map.ensureRef(.surface, id);

    // "tab:1" should resolve to the same UUID as "surface:1"
    const resolved = map.resolve("tab:1");
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.?.eql(id));
}

test "different kinds have independent ordinals" {
    var map = RefMap.init(std.testing.allocator);
    defer map.deinit();

    const ws_id = Uuid.generate();
    const surf_id = Uuid.generate();

    const ws_ref = try map.ensureRef(.workspace, ws_id);
    const surf_ref = try map.ensureRef(.surface, surf_id);

    try std.testing.expectEqualStrings("workspace:1", ws_ref);
    try std.testing.expectEqualStrings("surface:1", surf_ref);
}

test "getRef returns null when not allocated" {
    var map = RefMap.init(std.testing.allocator);
    defer map.deinit();

    const id = Uuid.generate();
    try std.testing.expect(map.getRef(.workspace, id) == null);

    _ = try map.ensureRef(.workspace, id);
    try std.testing.expect(map.getRef(.workspace, id) != null);
    try std.testing.expectEqualStrings("workspace:1", map.getRef(.workspace, id).?);
}
