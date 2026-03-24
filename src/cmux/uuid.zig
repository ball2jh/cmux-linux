const std = @import("std");

/// A 128-bit UUID v4 (random) identifier.
///
/// Used as the primary identifier for workspaces and panels,
/// matching the macOS reference implementation's UUID format.
pub const Uuid = struct {
    bytes: [16]u8,

    pub const nil: Uuid = .{ .bytes = .{0} ** 16 };

    /// Generate a v4 (random) UUID.
    pub fn generate() Uuid {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);

        // Set version 4 (bits 4-7 of byte 6)
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        // Set variant 1 (bits 6-7 of byte 8)
        bytes[8] = (bytes[8] & 0x3f) | 0x80;

        return .{ .bytes = bytes };
    }

    /// Parse a UUID from the standard "8-4-4-4-12" hex string.
    /// Accepts both uppercase and lowercase hex digits.
    pub fn parse(str: []const u8) error{InvalidUuid}!Uuid {
        if (str.len != 36) return error.InvalidUuid;

        // Validate dash positions
        if (str[8] != '-' or str[13] != '-' or str[18] != '-' or str[23] != '-')
            return error.InvalidUuid;

        var bytes: [16]u8 = undefined;
        var byte_idx: usize = 0;

        for (str, 0..) |ch, i| {
            if (i == 8 or i == 13 or i == 18 or i == 23) continue;

            const nibble: u8 = hexToNibble(ch) orelse return error.InvalidUuid;
            if (byte_idx % 2 == 0) {
                bytes[byte_idx / 2] = nibble << 4;
            } else {
                bytes[byte_idx / 2] |= nibble;
            }
            byte_idx += 1;
        }

        return .{ .bytes = bytes };
    }

    /// Format as lowercase "8-4-4-4-12" hex string.
    pub fn format(self: Uuid) [36]u8 {
        const hex = "0123456789abcdef";
        var buf: [36]u8 = undefined;
        var out: usize = 0;

        for (self.bytes, 0..) |byte, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                buf[out] = '-';
                out += 1;
            }
            buf[out] = hex[byte >> 4];
            buf[out + 1] = hex[byte & 0x0f];
            out += 2;
        }

        return buf;
    }

    /// Format for use with std.fmt (e.g., `std.log.info("{}", .{uuid})`).
    pub fn fmtString(self: Uuid, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const str = self.format();
        try writer.writeAll(&str);
    }

    pub const formatFn = fmtString;

    pub fn eql(a: Uuid, b: Uuid) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn isNil(self: Uuid) bool {
        return eql(self, nil);
    }

    /// Format into a provided buffer. Returns the 36-byte formatted slice.
    pub fn formatBuf(self: Uuid, buf: *[36]u8) []const u8 {
        buf.* = self.format();
        return buf;
    }

    /// Hash context for use as regular HashMap key (u64 hash, 2-arg eql).
    pub const HashContext = struct {
        pub fn hash(_: HashContext, uuid: Uuid) u64 {
            return std.hash.Wyhash.hash(0, &uuid.bytes);
        }

        pub fn eql(_: HashContext, a: Uuid, b: Uuid) bool {
            return Uuid.eql(a, b);
        }
    };

    /// Hash context for use as ArrayHashMap key (u32 hash, 3-arg eql).
    pub const ArrayHashContext = struct {
        pub fn hash(_: ArrayHashContext, uuid: Uuid) u32 {
            const h = std.hash.Wyhash.hash(0, &uuid.bytes);
            return @truncate(h);
        }

        pub fn eql(_: ArrayHashContext, a: Uuid, b: Uuid, _: usize) bool {
            return Uuid.eql(a, b);
        }
    };

    /// Order comparison for sorting.
    pub fn order(a: Uuid, b: Uuid) std.math.Order {
        return std.mem.order(u8, &a.bytes, &b.bytes);
    }

    // --- JSON serialization ---

    /// Serialize as a "8-4-4-4-12" hex string for std.json.
    pub fn jsonStringify(self: Uuid, jws: anytype) !void {
        const str = self.format();
        try jws.write(&str);
    }

    /// Deserialize from a "8-4-4-4-12" hex string for std.json.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Uuid {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const slice = switch (token) {
            .string => |s| s,
            .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        defer switch (token) {
            .allocated_string => |s| allocator.free(s),
            else => {},
        };
        return Uuid.parse(slice) catch return error.UnexpectedToken;
    }

    fn hexToNibble(ch: u8) ?u8 {
        return switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => null,
        };
    }
};

// --- Tests ---

test "generate produces valid v4 uuid" {
    const uuid = Uuid.generate();

    // Version should be 4
    try std.testing.expectEqual(@as(u4, 4), @as(u4, @truncate(uuid.bytes[6] >> 4)));

    // Variant should be 0b10xx
    try std.testing.expect(uuid.bytes[8] & 0xc0 == 0x80);

    // Should not be nil
    try std.testing.expect(!uuid.isNil());
}

test "nil is all zeros" {
    for (Uuid.nil.bytes) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
    try std.testing.expect(Uuid.nil.isNil());
}

test "parse and format round-trip" {
    const input = "550e8400-e29b-41d4-a716-446655440000";
    const uuid = try Uuid.parse(input);
    const output = uuid.format();
    try std.testing.expectEqualStrings(input, &output);
}

test "parse accepts uppercase" {
    const lower = "550e8400-e29b-41d4-a716-446655440000";
    const upper = "550E8400-E29B-41D4-A716-446655440000";
    const a = try Uuid.parse(lower);
    const b = try Uuid.parse(upper);
    try std.testing.expect(a.eql(b));
}

test "parse rejects invalid input" {
    try std.testing.expectError(error.InvalidUuid, Uuid.parse("not-a-uuid"));
    try std.testing.expectError(error.InvalidUuid, Uuid.parse("550e8400-e29b-41d4-a716-44665544000")); // too short
    try std.testing.expectError(error.InvalidUuid, Uuid.parse("550e8400xe29b-41d4-a716-446655440000")); // wrong separator
    try std.testing.expectError(error.InvalidUuid, Uuid.parse("550e8400-e29b-41d4-a716-44665544000g")); // invalid hex
}

test "generate produces unique values" {
    const a = Uuid.generate();
    const b = Uuid.generate();
    try std.testing.expect(!a.eql(b));
}

test "hash context works for array hash map" {
    var map = std.ArrayHashMapUnmanaged(Uuid, u32, Uuid.ArrayHashContext, true){};
    defer map.deinit(std.testing.allocator);

    const uuid = Uuid.generate();
    try map.put(std.testing.allocator, uuid, 42);
    try std.testing.expectEqual(@as(u32, 42), map.get(uuid).?);
}

test "json round-trip" {
    const json = std.json;
    const alloc = std.testing.allocator;

    const uuid = try Uuid.parse("550e8400-e29b-41d4-a716-446655440000");

    // Serialize
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    json.Stringify.value(uuid, .{}, &out.writer) catch |err| return err;
    try std.testing.expectEqualStrings("\"550e8400-e29b-41d4-a716-446655440000\"", out.written());

    // Deserialize
    const parsed = try json.parseFromSlice(Uuid, alloc, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(uuid.eql(parsed.value));
}

test "json round-trip nil uuid" {
    const json = std.json;
    const alloc = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    json.Stringify.value(Uuid.nil, .{}, &out.writer) catch |err| return err;
    try std.testing.expectEqualStrings("\"00000000-0000-0000-0000-000000000000\"", out.written());

    const parsed = try json.parseFromSlice(Uuid, alloc, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.isNil());
}
