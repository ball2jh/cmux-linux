//! Daemon manifest schema, platform detection, and SHA-256 verification.
//!
//! The manifest describes available cmuxd-remote binaries for each
//! platform (OS/arch combination) with download URLs and SHA-256 digests.
//! It is embedded in the binary at build time or loaded from a JSON file.
//!
//! Matches macOS WorkspaceRemoteDaemonManifest (Workspace.swift).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const log = std.log.scoped(.cmux_daemon_manifest);

pub const DaemonManifest = @This();

pub const Entry = struct {
    go_os: []const u8,
    go_arch: []const u8,
    asset_name: []const u8,
    download_url: []const u8,
    sha256: []const u8,
};

schema_version: u32,
app_version: []const u8,
release_tag: []const u8,
release_url: []const u8,
checksums_asset_name: []const u8,
checksums_url: []const u8,
entries: []const Entry,

/// Find a manifest entry for a specific OS/arch combination.
pub fn findEntry(self: *const DaemonManifest, go_os: []const u8, go_arch: []const u8) ?*const Entry {
    for (self.entries) |*entry| {
        if (std.mem.eql(u8, entry.go_os, go_os) and std.mem.eql(u8, entry.go_arch, go_arch)) {
            return entry;
        }
    }
    return null;
}

/// Parse a manifest from a JSON string. All strings are owned by the arena.
pub fn parseJson(arena: Allocator, json_str: []const u8) !DaemonManifest {
    const parsed = try json.parseFromSliceLeaky(json.Value, arena, json_str, .{
        .allocate = .alloc_if_needed,
    });

    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.InvalidManifest,
    };

    const entries_val = obj.get("entries") orelse return error.InvalidManifest;
    const entries_arr = switch (entries_val) {
        .array => |a| a,
        else => return error.InvalidManifest,
    };

    const entries = try arena.alloc(Entry, entries_arr.items.len);
    for (entries_arr.items, 0..) |item, i| {
        const e = switch (item) {
            .object => |o| o,
            else => return error.InvalidManifest,
        };
        entries[i] = .{
            .go_os = getStr(e, "goOS") orelse return error.InvalidManifest,
            .go_arch = getStr(e, "goArch") orelse return error.InvalidManifest,
            .asset_name = getStr(e, "assetName") orelse return error.InvalidManifest,
            .download_url = getStr(e, "downloadURL") orelse return error.InvalidManifest,
            .sha256 = getStr(e, "sha256") orelse return error.InvalidManifest,
        };
    }

    return .{
        .schema_version = @intCast(getInt(obj, "schemaVersion") orelse return error.InvalidManifest),
        .app_version = getStr(obj, "appVersion") orelse return error.InvalidManifest,
        .release_tag = getStr(obj, "releaseTag") orelse return error.InvalidManifest,
        .release_url = getStr(obj, "releaseURL") orelse return error.InvalidManifest,
        .checksums_asset_name = getStr(obj, "checksumsAssetName") orelse return error.InvalidManifest,
        .checksums_url = getStr(obj, "checksumsURL") orelse return error.InvalidManifest,
        .entries = entries,
    };
}

// -----------------------------------------------------------------------
// Platform detection
// -----------------------------------------------------------------------

pub const RemotePlatform = struct {
    go_os: []const u8,
    go_arch: []const u8,
};

/// Map raw `uname -s` output to Go GOOS value.
pub fn mapUnameOS(raw: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "linux")) return "linux";
    if (std.ascii.eqlIgnoreCase(raw, "darwin")) return "darwin";
    if (std.ascii.eqlIgnoreCase(raw, "freebsd")) return "freebsd";
    return null;
}

/// Map raw `uname -m` output to Go GOARCH value.
pub fn mapUnameArch(raw: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "x86_64") or std.ascii.eqlIgnoreCase(raw, "amd64")) return "amd64";
    if (std.ascii.eqlIgnoreCase(raw, "aarch64") or std.ascii.eqlIgnoreCase(raw, "arm64")) return "arm64";
    if (std.ascii.eqlIgnoreCase(raw, "armv7l")) return "arm";
    return null;
}

/// Build the shell probe script that detects remote OS, arch, and binary existence.
/// `version` is the expected daemon version string (e.g., "0.1.0").
pub fn probeScript(buf: []u8, version: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.print(
        \\cmux_uname_os="$(uname -s)"
        \\cmux_uname_arch="$(uname -m)"
        \\printf '%s%s\n' '__CMUX_REMOTE_OS__=' "$cmux_uname_os"
        \\printf '%s%s\n' '__CMUX_REMOTE_ARCH__=' "$cmux_uname_arch"
        \\case "$(printf '%s' "$cmux_uname_os" | tr '[:upper:]' '[:lower:]')" in
        \\  linux|darwin|freebsd) cmux_go_os="$(printf '%s' "$cmux_uname_os" | tr '[:upper:]' '[:lower:]')" ;;
        \\  *) exit 70 ;;
        \\esac
        \\case "$(printf '%s' "$cmux_uname_arch" | tr '[:upper:]' '[:lower:]')" in
        \\  x86_64|amd64) cmux_go_arch=amd64 ;;
        \\  aarch64|arm64) cmux_go_arch=arm64 ;;
        \\  armv7l) cmux_go_arch=arm ;;
        \\  *) exit 71 ;;
        \\esac
        \\cmux_remote_path="$HOME/.cmux/bin/cmuxd-remote/{s}/${{cmux_go_os}}-${{cmux_go_arch}}/cmuxd-remote"
        \\if [ -x "$cmux_remote_path" ]; then
        \\  printf '%syes\n' '__CMUX_REMOTE_EXISTS__='
        \\else
        \\  printf '%sno\n' '__CMUX_REMOTE_EXISTS__='
        \\fi
    , .{version});
    return fbs.getWritten();
}

/// Parse the output of the probe script.
pub const ProbeResult = struct {
    os: []const u8,
    arch: []const u8,
    binary_exists: bool,
};

pub fn parseProbeOutput(output: []const u8) ?ProbeResult {
    var os: ?[]const u8 = null;
    var arch: ?[]const u8 = null;
    var exists: bool = false;

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "__CMUX_REMOTE_OS__=")) {
            os = std.mem.trim(u8, line["__CMUX_REMOTE_OS__=".len..], " \t\r");
        } else if (std.mem.startsWith(u8, line, "__CMUX_REMOTE_ARCH__=")) {
            arch = std.mem.trim(u8, line["__CMUX_REMOTE_ARCH__=".len..], " \t\r");
        } else if (std.mem.startsWith(u8, line, "__CMUX_REMOTE_EXISTS__=")) {
            const val = std.mem.trim(u8, line["__CMUX_REMOTE_EXISTS__=".len..], " \t\r");
            exists = std.mem.eql(u8, val, "yes");
        }
    }

    if (os == null or arch == null) return null;
    return .{
        .os = os.?,
        .arch = arch.?,
        .binary_exists = exists,
    };
}

// -----------------------------------------------------------------------
// SHA-256 verification
// -----------------------------------------------------------------------

/// Verify a file's SHA-256 hash against an expected hex digest.
pub fn verifySha256(file_path: []const u8, expected_hex: []const u8) !bool {
    if (expected_hex.len != 64) return error.InvalidDigest;

    var file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    const digest = hasher.finalResult();
    var actual_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&actual_hex, "{}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;

    return std.mem.eql(u8, &actual_hex, expected_hex);
}

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

fn getStr(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(obj: json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "mapUnameOS" {
    try std.testing.expectEqualStrings("linux", mapUnameOS("Linux").?);
    try std.testing.expectEqualStrings("darwin", mapUnameOS("Darwin").?);
    try std.testing.expectEqualStrings("freebsd", mapUnameOS("FreeBSD").?);
    try std.testing.expect(mapUnameOS("Windows") == null);
}

test "mapUnameArch" {
    try std.testing.expectEqualStrings("amd64", mapUnameArch("x86_64").?);
    try std.testing.expectEqualStrings("arm64", mapUnameArch("aarch64").?);
    try std.testing.expectEqualStrings("arm64", mapUnameArch("arm64").?);
    try std.testing.expectEqualStrings("arm", mapUnameArch("armv7l").?);
    try std.testing.expect(mapUnameArch("riscv64") == null);
}

test "parseProbeOutput" {
    const output =
        \\__CMUX_REMOTE_OS__=Linux
        \\__CMUX_REMOTE_ARCH__=x86_64
        \\__CMUX_REMOTE_EXISTS__=yes
    ;
    const result = parseProbeOutput(output).?;
    try std.testing.expectEqualStrings("Linux", result.os);
    try std.testing.expectEqualStrings("x86_64", result.arch);
    try std.testing.expect(result.binary_exists);
}

test "parseProbeOutput missing marker" {
    const output = "some random output\n";
    try std.testing.expect(parseProbeOutput(output) == null);
}

test "parseManifest" {
    const manifest_json =
        \\{
        \\  "schemaVersion": 1,
        \\  "appVersion": "0.1.0",
        \\  "releaseTag": "v0.1.0",
        \\  "releaseURL": "https://github.com/example/releases/tag/v0.1.0",
        \\  "checksumsAssetName": "checksums.txt",
        \\  "checksumsURL": "https://github.com/example/releases/download/v0.1.0/checksums.txt",
        \\  "entries": [
        \\    {
        \\      "goOS": "linux",
        \\      "goArch": "amd64",
        \\      "assetName": "cmuxd-remote-linux-amd64",
        \\      "downloadURL": "https://github.com/example/releases/download/v0.1.0/cmuxd-remote-linux-amd64",
        \\      "sha256": "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        \\    }
        \\  ]
        \\}
    ;

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const manifest = try DaemonManifest.parseJson(arena, manifest_json);
    try std.testing.expectEqual(@as(u32, 1), manifest.schema_version);
    try std.testing.expectEqualStrings("0.1.0", manifest.app_version);
    try std.testing.expectEqual(@as(usize, 1), manifest.entries.len);

    const entry = manifest.findEntry("linux", "amd64").?;
    try std.testing.expectEqualStrings("cmuxd-remote-linux-amd64", entry.asset_name);

    try std.testing.expect(manifest.findEntry("windows", "amd64") == null);
}
