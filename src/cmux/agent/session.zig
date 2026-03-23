// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 cmux-linux contributors
//
// Agent session store for cmux.
// Tracks Claude Code (and other agent) sessions with their lifecycle
// states: start, idle, active, end. Sessions are persisted to disk
// at ~/.config/cmux/claude-hook-sessions.json with flock-based locking.
//
// Compatible with the macOS cmux claude-hook protocol.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.cmux_agent);

/// Maximum age for a session record before auto-pruning (7 days).
const max_age_seconds: i64 = 7 * 24 * 60 * 60; // 604800

/// A single agent session record.
pub const SessionRecord = struct {
    session_id: []const u8,
    workspace_id: []const u8,
    surface_id: []const u8,
    cwd: ?[]const u8 = null,
    pid: ?i32 = null,
    last_subtitle: ?[]const u8 = null,
    last_body: ?[]const u8 = null,
    started_at: i64,
    updated_at: i64,
};

/// Thread-safe agent session store with file persistence.
pub const SessionStore = struct {
    alloc: Allocator,
    sessions: std.StringHashMapUnmanaged(SessionRecord) = .empty,
    mutex: std.Thread.Mutex = .{},
    file_path: []const u8,

    pub fn init(alloc: Allocator) !SessionStore {
        const path = blk: {
            if (std.posix.getenv("CMUX_CLAUDE_HOOK_STATE_PATH")) |p| {
                break :blk try alloc.dupe(u8, p);
            }
            const home = std.posix.getenv("HOME") orelse return error.NoHome;
            break :blk try std.fmt.allocPrint(alloc, "{s}/.config/cmux/claude-hook-sessions.json", .{home});
        };

        var store = SessionStore{
            .alloc = alloc,
            .file_path = path,
        };

        // Try to load existing sessions from disk
        store.loadFromDisk();

        return store;
    }

    pub fn deinit(self: *SessionStore) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.freeRecord(entry.value_ptr);
            self.alloc.free(entry.key_ptr.*);
        }
        self.sessions.deinit(self.alloc);
        self.alloc.free(self.file_path);
    }

    /// Look up a session by ID. Returns a copy of the record.
    /// Prunes expired sessions before lookup.
    pub fn lookup(self: *SessionStore, session_id: []const u8) ?SessionRecord {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.pruneExpiredLocked();

        const trimmed = std.mem.trim(u8, session_id, &[_]u8{ ' ', '\t', '\n', '\r' });
        if (trimmed.len == 0) return null;

        return self.sessions.get(trimmed);
    }

    /// Create or update a session record.
    /// On update: preserves started_at, updates other fields if provided.
    pub fn upsert(
        self: *SessionStore,
        session_id: []const u8,
        workspace_id: []const u8,
        surface_id: []const u8,
        cwd: ?[]const u8,
        pid: ?i32,
        last_subtitle: ?[]const u8,
        last_body: ?[]const u8,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const trimmed = std.mem.trim(u8, session_id, &[_]u8{ ' ', '\t', '\n', '\r' });
        if (trimmed.len == 0) return;

        const now = std.time.timestamp();

        if (self.sessions.getPtr(trimmed)) |existing| {
            // Update existing — always update workspace_id
            self.alloc.free(existing.workspace_id);
            existing.workspace_id = self.alloc.dupe(u8, workspace_id) catch return;

            // Update surface_id if non-empty
            if (surface_id.len > 0) {
                self.alloc.free(existing.surface_id);
                existing.surface_id = self.alloc.dupe(u8, surface_id) catch return;
            }

            // Update optional fields if provided
            if (cwd) |c| {
                if (existing.cwd) |old| self.alloc.free(old);
                existing.cwd = self.alloc.dupe(u8, c) catch null;
            }
            if (pid) |p| existing.pid = p;
            if (last_subtitle) |s| {
                if (existing.last_subtitle) |old| self.alloc.free(old);
                existing.last_subtitle = self.alloc.dupe(u8, s) catch null;
            }
            if (last_body) |b| {
                if (existing.last_body) |old| self.alloc.free(old);
                existing.last_body = self.alloc.dupe(u8, b) catch null;
            }

            existing.updated_at = now;
        } else {
            // Create new record
            const key = self.alloc.dupe(u8, trimmed) catch return;
            const record = SessionRecord{
                .session_id = self.alloc.dupe(u8, trimmed) catch {
                    self.alloc.free(key);
                    return;
                },
                .workspace_id = self.alloc.dupe(u8, workspace_id) catch {
                    self.alloc.free(key);
                    return;
                },
                .surface_id = self.alloc.dupe(u8, surface_id) catch {
                    self.alloc.free(key);
                    return;
                },
                .cwd = if (cwd) |c| self.alloc.dupe(u8, c) catch null else null,
                .pid = pid,
                .last_subtitle = if (last_subtitle) |s| self.alloc.dupe(u8, s) catch null else null,
                .last_body = if (last_body) |b| self.alloc.dupe(u8, b) catch null else null,
                .started_at = now,
                .updated_at = now,
            };
            self.sessions.put(self.alloc, key, record) catch {
                self.alloc.free(key);
                return;
            };
        }

        self.saveToDiskLocked();
    }

    /// Remove and return a session. Tries sessionId first, then falls back
    /// to fuzzy matching by surfaceId (most recent) or workspaceId (unique match).
    pub fn consume(
        self: *SessionStore,
        session_id: ?[]const u8,
        workspace_id: ?[]const u8,
        surface_id: ?[]const u8,
    ) ?SessionRecord {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.pruneExpiredLocked();

        // Try exact sessionId match first
        if (session_id) |sid| {
            const trimmed = std.mem.trim(u8, sid, &[_]u8{ ' ', '\t', '\n', '\r' });
            if (trimmed.len > 0) {
                if (self.removeSession(trimmed)) |record| {
                    self.saveToDiskLocked();
                    return record;
                }
            }
        }

        // Fallback: match by surfaceId (return most recently updated)
        if (surface_id) |sid| {
            if (sid.len > 0) {
                var best_key: ?[]const u8 = null;
                var best_time: i64 = 0;
                var it = self.sessions.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.value_ptr.surface_id, sid)) {
                        if (entry.value_ptr.updated_at > best_time) {
                            best_time = entry.value_ptr.updated_at;
                            best_key = entry.key_ptr.*;
                        }
                    }
                }
                if (best_key) |key| {
                    // Dupe the key since removeSession frees it
                    const key_copy = self.alloc.dupe(u8, key) catch return null;
                    defer self.alloc.free(key_copy);
                    if (self.removeSession(key_copy)) |record| {
                        self.saveToDiskLocked();
                        return record;
                    }
                }
            }
        }

        // Fallback: match by workspaceId (only if unique match)
        if (workspace_id) |wid| {
            if (wid.len > 0) {
                var match_key: ?[]const u8 = null;
                var match_count: usize = 0;
                var it = self.sessions.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.value_ptr.workspace_id, wid)) {
                        match_count += 1;
                        match_key = entry.key_ptr.*;
                    }
                }
                if (match_count == 1) {
                    if (match_key) |key| {
                        const key_copy = self.alloc.dupe(u8, key) catch return null;
                        defer self.alloc.free(key_copy);
                        if (self.removeSession(key_copy)) |record| {
                            self.saveToDiskLocked();
                            return record;
                        }
                    }
                }
            }
        }

        return null;
    }

    // --- Internal helpers ---

    /// Remove a session by key and return its record (caller does NOT own the strings;
    /// the record's strings remain valid until the caller frees them).
    fn removeSession(self: *SessionStore, key: []const u8) ?SessionRecord {
        const kv = self.sessions.fetchRemove(key) orelse return null;
        // Free the hash map key but keep the record's strings alive for the caller
        self.alloc.free(kv.key);
        return kv.value;
    }

    /// Free all owned strings in a session record.
    pub fn freeRecord(self: *SessionStore, record: *SessionRecord) void {
        self.alloc.free(record.session_id);
        self.alloc.free(record.workspace_id);
        self.alloc.free(record.surface_id);
        if (record.cwd) |c| self.alloc.free(c);
        if (record.last_subtitle) |s| self.alloc.free(s);
        if (record.last_body) |b| self.alloc.free(b);
    }

    /// Free a consumed record that was returned by consume().
    pub fn freeConsumed(self: *SessionStore, record: *SessionRecord) void {
        self.freeRecord(record);
    }

    /// Remove sessions older than 7 days. Must be called with mutex held.
    fn pruneExpiredLocked(self: *SessionStore) void {
        const now = std.time.timestamp();
        const cutoff = now - max_age_seconds;

        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (to_remove.items) |key| self.alloc.free(key);
            to_remove.deinit(self.alloc);
        }

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.updated_at < cutoff) {
                to_remove.append(self.alloc, self.alloc.dupe(u8, entry.key_ptr.*) catch continue) catch continue;
            }
        }

        if (to_remove.items.len == 0) return;

        for (to_remove.items) |key| {
            if (self.sessions.fetchRemove(key)) |kv| {
                self.alloc.free(kv.key);
                var rec = kv.value;
                self.freeRecord(&rec);
            }
        }

        log.debug("pruned {} expired sessions", .{to_remove.items.len});
    }

    // --- File persistence ---

    /// Save sessions to disk with atomic write. Must be called with mutex held.
    fn saveToDiskLocked(self: *SessionStore) void {
        self.ensureDir() catch |err| {
            log.warn("failed to create session dir: {}", .{err});
            return;
        };

        // Build JSON
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.alloc);
        var writer = buf.writer(self.alloc);

        writer.writeAll("{\"version\":1,\"sessions\":{") catch return;

        var first = true;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (!first) writer.writeAll(",") catch return;
            first = false;

            writer.writeAll("\"") catch return;
            writeJsonEscaped(writer, entry.key_ptr.*);
            writer.writeAll("\":{") catch return;

            writer.writeAll("\"sessionId\":\"") catch return;
            writeJsonEscaped(writer, entry.value_ptr.session_id);
            writer.writeAll("\",\"workspaceId\":\"") catch return;
            writeJsonEscaped(writer, entry.value_ptr.workspace_id);
            writer.writeAll("\",\"surfaceId\":\"") catch return;
            writeJsonEscaped(writer, entry.value_ptr.surface_id);
            writer.writeAll("\"") catch return;

            if (entry.value_ptr.cwd) |c| {
                writer.writeAll(",\"cwd\":\"") catch return;
                writeJsonEscaped(writer, c);
                writer.writeAll("\"") catch return;
            }
            if (entry.value_ptr.pid) |p| {
                writer.print(",\"pid\":{d}", .{p}) catch return;
            }
            if (entry.value_ptr.last_subtitle) |s| {
                writer.writeAll(",\"lastSubtitle\":\"") catch return;
                writeJsonEscaped(writer, s);
                writer.writeAll("\"") catch return;
            }
            if (entry.value_ptr.last_body) |b| {
                writer.writeAll(",\"lastBody\":\"") catch return;
                writeJsonEscaped(writer, b);
                writer.writeAll("\"") catch return;
            }

            writer.print(",\"startedAt\":{d},\"updatedAt\":{d}", .{
                entry.value_ptr.started_at,
                entry.value_ptr.updated_at,
            }) catch return;

            writer.writeAll("}") catch return;
        }

        writer.writeAll("}}\n") catch return;

        // Atomic write: tmp file + rename
        const tmp_path = std.fmt.allocPrint(self.alloc, "{s}.tmp", .{self.file_path}) catch return;
        defer self.alloc.free(tmp_path);

        const file = std.fs.createFileAbsolute(tmp_path, .{}) catch |err| {
            log.warn("failed to create session tmp file: {}", .{err});
            return;
        };
        file.writeAll(buf.items) catch |err| {
            log.warn("failed to write session data: {}", .{err});
            file.close();
            return;
        };
        file.close();

        std.fs.renameAbsolute(tmp_path, self.file_path) catch |err| {
            log.warn("failed to rename session file: {}", .{err});
            return;
        };

        log.debug("agent sessions saved ({d} bytes, {d} sessions)", .{
            buf.items.len,
            self.sessions.count(),
        });
    }

    /// Load sessions from disk. Non-fatal if file doesn't exist.
    fn loadFromDisk(self: *SessionStore) void {
        const file = std.fs.openFileAbsolute(self.file_path, .{}) catch return;
        defer file.close();

        const data = file.readToEndAlloc(self.alloc, 1024 * 1024) catch return;
        defer self.alloc.free(data);

        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{
            .allocate = .alloc_always,
        }) catch |err| {
            log.warn("failed to parse agent session file: {}", .{err});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        const sessions_val = root.object.get("sessions") orelse return;
        if (sessions_val != .object) return;

        var it = sessions_val.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (val != .object) continue;

            const record = SessionRecord{
                .session_id = self.alloc.dupe(u8, getJsonStr(val.object, "sessionId") orelse continue) catch continue,
                .workspace_id = self.alloc.dupe(u8, getJsonStr(val.object, "workspaceId") orelse continue) catch continue,
                .surface_id = self.alloc.dupe(u8, getJsonStr(val.object, "surfaceId") orelse "") catch continue,
                .cwd = if (getJsonStr(val.object, "cwd")) |c| self.alloc.dupe(u8, c) catch null else null,
                .pid = if (val.object.get("pid")) |p| switch (p) {
                    .integer => |i| @as(?i32, @intCast(@max(0, @min(std.math.maxInt(i32), i)))),
                    else => null,
                } else null,
                .last_subtitle = if (getJsonStr(val.object, "lastSubtitle")) |s| self.alloc.dupe(u8, s) catch null else null,
                .last_body = if (getJsonStr(val.object, "lastBody")) |b| self.alloc.dupe(u8, b) catch null else null,
                .started_at = getJsonInt(val.object, "startedAt") orelse std.time.timestamp(),
                .updated_at = getJsonInt(val.object, "updatedAt") orelse std.time.timestamp(),
            };

            const key_copy = self.alloc.dupe(u8, key) catch continue;
            self.sessions.put(self.alloc, key_copy, record) catch {
                self.alloc.free(key_copy);
                continue;
            };
        }

        log.info("loaded {d} agent sessions from {s}", .{ self.sessions.count(), self.file_path });
    }

    fn ensureDir(self: *SessionStore) !void {
        // Extract directory from file path
        const dir_end = std.mem.lastIndexOf(u8, self.file_path, "/") orelse return;
        const dir_path = self.file_path[0..dir_end];
        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
};

// --- JSON helpers ---

fn getJsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getJsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

fn writeJsonEscaped(writer: anytype, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => writer.writeAll("\\\"") catch return,
            '\\' => writer.writeAll("\\\\") catch return,
            '\n' => writer.writeAll("\\n") catch return,
            '\r' => writer.writeAll("\\r") catch return,
            '\t' => writer.writeAll("\\t") catch return,
            else => writer.writeByte(c) catch return,
        }
    }
}

// --- Input parsing (claude-hook JSON extraction) ---

/// Parsed fields extracted from claude-hook JSON input.
pub const ParsedInput = struct {
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    event_type: ?[]const u8 = null,
    message: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_description: ?[]const u8 = null,
};

/// Parse claude-hook JSON input, extracting session_id, cwd, etc.
/// Checks top-level, then nested "notification", "data", "session", "context" objects.
pub fn parseClaudeHookInput(alloc: Allocator, json_str: []const u8) ParsedInput {
    if (json_str.len == 0) return .{};

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_str, .{
        .allocate = .alloc_always,
    }) catch return .{};
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return .{};

    var result = ParsedInput{};

    // Extract session_id (check multiple keys and nested objects)
    result.session_id = extractField(root.object, &.{ "session_id", "sessionId" });
    if (result.session_id == null) {
        for ([_][]const u8{ "notification", "data", "session", "context" }) |nested_key| {
            if (root.object.get(nested_key)) |nested| {
                if (nested == .object) {
                    result.session_id = extractField(nested.object, &.{ "session_id", "sessionId", "id" });
                    if (result.session_id != null) break;
                }
            }
        }
    }

    // Extract cwd
    result.cwd = extractField(root.object, &.{ "cwd", "working_directory", "workingDirectory", "project_dir", "projectDir" });
    if (result.cwd == null) {
        for ([_][]const u8{ "notification", "data", "context" }) |nested_key| {
            if (root.object.get(nested_key)) |nested| {
                if (nested == .object) {
                    result.cwd = extractField(nested.object, &.{ "cwd", "working_directory", "workingDirectory" });
                    if (result.cwd != null) break;
                }
            }
        }
    }

    // Extract transcript_path
    result.transcript_path = extractField(root.object, &.{ "transcript_path", "transcriptPath" });

    // Extract event type and message (for notification subcommand)
    result.event_type = extractField(root.object, &.{ "event", "event_type", "type" });
    if (result.event_type == null) {
        if (root.object.get("notification")) |nested| {
            if (nested == .object) {
                result.event_type = extractField(nested.object, &.{ "event", "event_type", "type" });
            }
        }
    }

    result.message = extractField(root.object, &.{ "message", "body", "text" });
    if (result.message == null) {
        if (root.object.get("notification")) |nested| {
            if (nested == .object) {
                result.message = extractField(nested.object, &.{ "message", "body", "text" });
            }
        }
    }

    // Extract tool info (for pre-tool-use)
    result.tool_name = extractField(root.object, &.{ "tool_name", "toolName", "tool" });
    result.tool_description = extractField(root.object, &.{ "tool_description", "description" });

    return result;
}

fn extractField(obj: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (getJsonStr(obj, key)) |v| {
            if (v.len > 0) return v;
        }
    }
    return null;
}

/// Classify a notification event type for status display.
pub const EventClass = enum {
    permission,
    @"error",
    completed,
    waiting,
    attention,
};

pub fn classifyEvent(event_type: ?[]const u8, message: ?[]const u8) EventClass {
    const text = event_type orelse message orelse return .attention;
    const lower = text; // Already lowercase in most cases; simple contains check

    if (containsAny(lower, &.{ "permission", "approve" })) return .permission;
    if (containsAny(lower, &.{ "error", "failed", "exception" })) return .@"error";
    if (containsAny(lower, &.{ "complete", "finish", "done", "success" })) return .completed;
    if (containsAny(lower, &.{ "idle", "wait", "input" })) return .waiting;

    return .attention;
}

fn containsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

// --- Global singleton ---

var global_store: ?*SessionStore = null;

pub fn initGlobal(alloc: Allocator) !void {
    const store = try alloc.create(SessionStore);
    store.* = try SessionStore.init(alloc);
    global_store = store;
    log.info("agent session store initialized", .{});
}

pub fn deinitGlobal(alloc: Allocator) void {
    if (global_store) |store| {
        store.deinit();
        alloc.destroy(store);
        global_store = null;
    }
}

pub fn getGlobal() ?*SessionStore {
    return global_store;
}
