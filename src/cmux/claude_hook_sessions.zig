//! Persistent session state store for Claude Code hook integration.
//!
//! Stores session→workspace/surface mappings in a JSON file so that hook
//! invocations can resolve which workspace/surface a Claude Code session
//! belongs to. Matches macOS ClaudeHookSessionStore (cmux.swift line 338).
//!
//! File location: $XDG_CONFIG_HOME/cmux/claude-hook-sessions.json
//! (or $HOME/.config/cmux/claude-hook-sessions.json)

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const json = std.json;
const fs = std.fs;

const log = std.log.scoped(.cmux_claude_hook_sessions);

/// Maximum age of a session record before it's pruned (7 days).
const max_age_seconds: i64 = 60 * 60 * 24 * 7;

pub const SessionRecord = struct {
    session_id: []const u8,
    workspace_id: []const u8,
    surface_id: []const u8,
    cwd: ?[]const u8 = null,
    pid: ?i32 = null,
    last_subtitle: ?[]const u8 = null,
    last_body: ?[]const u8 = null,
    created_at: i64 = 0,
    updated_at: i64 = 0,
};

/// JSON-serializable wrapper.
const StoreFile = struct {
    version: u32 = 1,
    sessions: []SessionRecord = &.{},
};

pub const SessionStore = struct {
    alloc: Allocator,
    path_buf: [posix.PATH_MAX]u8 = undefined,
    path_len: usize = 0,

    pub fn init(alloc: Allocator) SessionStore {
        var store = SessionStore{ .alloc = alloc };
        // Resolve state file path
        if (resolvePath(&store.path_buf)) |path| {
            store.path_len = path.len;
        } else |_| {
            log.warn("failed to resolve claude hook sessions path", .{});
        }
        return store;
    }

    fn statePath(self: *const SessionStore) ?[]const u8 {
        if (self.path_len == 0) return null;
        return self.path_buf[0..self.path_len];
    }

    /// Look up a session by ID.
    pub fn lookup(self: *SessionStore, session_id: []const u8) !?SessionRecord {
        const records = try self.load();
        defer self.freeRecords(records);

        for (records) |rec| {
            if (std.mem.eql(u8, rec.session_id, session_id)) {
                return try self.dupeRecord(rec);
            }
        }
        return null;
    }

    /// Insert or update a session record.
    pub fn upsert(self: *SessionStore, record: SessionRecord) !void {
        var records = try self.load();
        defer self.freeRecords(records);

        const now = std.time.timestamp();

        // Find existing record
        var found = false;
        for (records) |*rec| {
            if (std.mem.eql(u8, rec.session_id, record.session_id)) {
                // Update existing
                if (record.workspace_id.len > 0) {
                    self.alloc.free(rec.workspace_id);
                    rec.workspace_id = try self.alloc.dupe(u8, record.workspace_id);
                }
                if (record.surface_id.len > 0) {
                    self.alloc.free(rec.surface_id);
                    rec.surface_id = try self.alloc.dupe(u8, record.surface_id);
                }
                if (record.cwd) |cwd| {
                    if (rec.cwd) |old| self.alloc.free(old);
                    rec.cwd = try self.alloc.dupe(u8, cwd);
                }
                if (record.pid) |pid| rec.pid = pid;
                if (record.last_subtitle) |sub| {
                    if (rec.last_subtitle) |old| self.alloc.free(old);
                    rec.last_subtitle = try self.alloc.dupe(u8, sub);
                }
                if (record.last_body) |body| {
                    if (rec.last_body) |old| self.alloc.free(old);
                    rec.last_body = try self.alloc.dupe(u8, body);
                }
                rec.updated_at = now;
                found = true;
                break;
            }
        }

        if (!found) {
            // Add new record
            var new_records = try self.alloc.alloc(SessionRecord, records.len + 1);
            @memcpy(new_records[0..records.len], records);
            new_records[records.len] = .{
                .session_id = try self.alloc.dupe(u8, record.session_id),
                .workspace_id = try self.alloc.dupe(u8, record.workspace_id),
                .surface_id = try self.alloc.dupe(u8, record.surface_id),
                .cwd = if (record.cwd) |c| try self.alloc.dupe(u8, c) else null,
                .pid = record.pid,
                .last_subtitle = if (record.last_subtitle) |s| try self.alloc.dupe(u8, s) else null,
                .last_body = if (record.last_body) |b| try self.alloc.dupe(u8, b) else null,
                .created_at = now,
                .updated_at = now,
            };
            // We don't free the old records array since elements are still referenced
            // in the new array. Instead, we just save and let the caller handle cleanup.
            self.alloc.free(records);
            records = new_records;
        }

        // Prune expired records
        const pruned = try self.prune(records);
        defer if (pruned.ptr != records.ptr) self.alloc.free(pruned);

        try self.save(pruned);
    }

    /// Remove and return a session record.
    pub fn consume(self: *SessionStore, session_id: ?[]const u8, workspace_id: ?[]const u8, surface_id: ?[]const u8) !?SessionRecord {
        var records = try self.load();
        defer self.freeRecords(records);

        // Try exact session_id match first
        if (session_id) |sid| {
            for (records, 0..) |rec, i| {
                if (std.mem.eql(u8, rec.session_id, sid)) {
                    const result = try self.dupeRecord(rec);
                    // Remove from list by shifting
                    var remaining = try self.alloc.alloc(SessionRecord, records.len - 1);
                    @memcpy(remaining[0..i], records[0..i]);
                    if (i < records.len - 1) {
                        @memcpy(remaining[i..], records[i + 1 ..]);
                    }
                    try self.save(remaining);
                    self.alloc.free(remaining);
                    return result;
                }
            }
        }

        // Fallback: match by surface_id (most specific)
        if (surface_id) |sf| {
            var best: ?usize = null;
            var best_time: i64 = 0;
            for (records, 0..) |rec, i| {
                if (std.mem.eql(u8, rec.surface_id, sf) and rec.updated_at > best_time) {
                    best = i;
                    best_time = rec.updated_at;
                }
            }
            if (best) |i| {
                const result = try self.dupeRecord(records[i]);
                var remaining = try self.alloc.alloc(SessionRecord, records.len - 1);
                @memcpy(remaining[0..i], records[0..i]);
                if (i < records.len - 1) {
                    @memcpy(remaining[i..], records[i + 1 ..]);
                }
                try self.save(remaining);
                self.alloc.free(remaining);
                return result;
            }
        }

        // Fallback: match by workspace_id (only if exactly one match)
        if (workspace_id) |ws| {
            var matches: usize = 0;
            var match_idx: usize = 0;
            for (records, 0..) |rec, i| {
                if (std.mem.eql(u8, rec.workspace_id, ws)) {
                    matches += 1;
                    match_idx = i;
                }
            }
            if (matches == 1) {
                const result = try self.dupeRecord(records[match_idx]);
                var remaining = try self.alloc.alloc(SessionRecord, records.len - 1);
                @memcpy(remaining[0..match_idx], records[0..match_idx]);
                if (match_idx < records.len - 1) {
                    @memcpy(remaining[match_idx..], records[match_idx + 1 ..]);
                }
                try self.save(remaining);
                self.alloc.free(remaining);
                return result;
            }
        }

        return null;
    }

    /// Free a record that was returned from lookup/consume.
    pub fn freeRecord(self: *SessionStore, rec: SessionRecord) void {
        self.alloc.free(rec.session_id);
        self.alloc.free(rec.workspace_id);
        self.alloc.free(rec.surface_id);
        if (rec.cwd) |c| self.alloc.free(c);
        if (rec.last_subtitle) |s| self.alloc.free(s);
        if (rec.last_body) |b| self.alloc.free(b);
    }

    // --- Internal ---

    fn dupeRecord(self: *SessionStore, rec: SessionRecord) !SessionRecord {
        return .{
            .session_id = try self.alloc.dupe(u8, rec.session_id),
            .workspace_id = try self.alloc.dupe(u8, rec.workspace_id),
            .surface_id = try self.alloc.dupe(u8, rec.surface_id),
            .cwd = if (rec.cwd) |c| try self.alloc.dupe(u8, c) else null,
            .pid = rec.pid,
            .last_subtitle = if (rec.last_subtitle) |s| try self.alloc.dupe(u8, s) else null,
            .last_body = if (rec.last_body) |b| try self.alloc.dupe(u8, b) else null,
            .created_at = rec.created_at,
            .updated_at = rec.updated_at,
        };
    }

    fn load(self: *SessionStore) ![]SessionRecord {
        const path = self.statePath() orelse return &.{};

        const file = fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return try self.alloc.alloc(SessionRecord, 0),
            else => return err,
        };
        defer file.close();

        // Lock for reading
        _ = std.posix.flock(file.handle, std.posix.LOCK.SH) catch {};
        defer _ = std.posix.flock(file.handle, std.posix.LOCK.UN) catch {};

        const content = file.readToEndAlloc(self.alloc, 1024 * 1024) catch |err| {
            log.warn("failed to read sessions file: {}", .{err});
            return try self.alloc.alloc(SessionRecord, 0);
        };
        defer self.alloc.free(content);

        if (content.len == 0) return try self.alloc.alloc(SessionRecord, 0);

        const parsed = json.parseFromSlice(StoreFile, self.alloc, content, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            log.warn("failed to parse sessions file", .{});
            return try self.alloc.alloc(SessionRecord, 0);
        };
        defer parsed.deinit();

        // Deep-copy the records since parsed will be freed
        var records = try self.alloc.alloc(SessionRecord, parsed.value.sessions.len);
        for (parsed.value.sessions, 0..) |rec, i| {
            records[i] = try self.dupeRecord(rec);
        }
        return records;
    }

    fn save(self: *SessionStore, records: []const SessionRecord) !void {
        const path = self.statePath() orelse return;

        // Ensure parent directory exists
        if (std.fs.path.dirname(path)) |parent| {
            std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        const file = try fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
        defer file.close();

        // Lock for writing
        _ = std.posix.flock(file.handle, std.posix.LOCK.EX) catch {};
        defer _ = std.posix.flock(file.handle, std.posix.LOCK.UN) catch {};

        const store = StoreFile{
            .version = 1,
            .sessions = @constCast(records),
        };

        // Serialize to a buffer, then write to file
        const serialized = json.Stringify.valueAlloc(self.alloc, store, .{}) catch |err| {
            log.warn("failed to serialize sessions: {}", .{err});
            return;
        };
        defer self.alloc.free(serialized);
        file.writeAll(serialized) catch |err| {
            log.warn("failed to write sessions file: {}", .{err});
        };
    }

    fn prune(self: *SessionStore, records: []SessionRecord) ![]SessionRecord {
        const now = std.time.timestamp();
        const cutoff = now - max_age_seconds;

        var count: usize = 0;
        for (records) |rec| {
            if (rec.updated_at >= cutoff) count += 1;
        }
        if (count == records.len) return records;

        var result = try self.alloc.alloc(SessionRecord, count);
        var idx: usize = 0;
        for (records) |rec| {
            if (rec.updated_at >= cutoff) {
                result[idx] = rec;
                idx += 1;
            } else {
                // Free pruned record strings
                self.alloc.free(rec.session_id);
                self.alloc.free(rec.workspace_id);
                self.alloc.free(rec.surface_id);
                if (rec.cwd) |c| self.alloc.free(c);
                if (rec.last_subtitle) |s| self.alloc.free(s);
                if (rec.last_body) |b| self.alloc.free(b);
            }
        }
        return result;
    }

    fn freeRecords(self: *SessionStore, records: []SessionRecord) void {
        for (records) |rec| {
            self.alloc.free(rec.session_id);
            self.alloc.free(rec.workspace_id);
            self.alloc.free(rec.surface_id);
            if (rec.cwd) |c| self.alloc.free(c);
            if (rec.last_subtitle) |s| self.alloc.free(s);
            if (rec.last_body) |b| self.alloc.free(b);
        }
        self.alloc.free(records);
    }
};

/// Resolve the sessions file path.
fn resolvePath(buf: *[posix.PATH_MAX]u8) ![]const u8 {
    // Check env override
    if (posix.getenv("CMUX_CLAUDE_HOOK_STATE_PATH")) |env| {
        if (env.len > 0 and env.len < buf.len) {
            @memcpy(buf[0..env.len], env);
            return buf[0..env.len];
        }
    }

    // XDG config home
    const config_base = posix.getenv("XDG_CONFIG_HOME");
    if (config_base) |base| {
        if (base.len > 0) {
            return std.fmt.bufPrint(buf, "{s}/cmux/claude-hook-sessions.json", .{base});
        }
    }

    // Fall back to $HOME/.config
    const home = posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.bufPrint(buf, "{s}/.config/cmux/claude-hook-sessions.json", .{home});
}

// --- Tests ---

test "SessionStore init does not crash" {
    var store = SessionStore.init(std.testing.allocator);
    _ = store.statePath();
}

test "resolvePath from HOME" {
    var buf: [posix.PATH_MAX]u8 = undefined;
    const path = resolvePath(&buf) catch return;
    try std.testing.expect(std.mem.endsWith(u8, path, "claude-hook-sessions.json"));
}
