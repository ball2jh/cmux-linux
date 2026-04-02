//! Claude Code hook handler for cmux.
//!
//! Implements the `cmux +claude-hook <subcommand>` CLI action that handles
//! lifecycle hooks fired by Claude Code. Connects to the running cmux socket
//! server and sends V1 commands to update sidebar status and notifications.
//!
//! Matches macOS runClaudeHook() in cmux.swift (line 11341).

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const json = std.json;

const socket_client = @import("socket_client.zig");
const sessions = @import("claude_hook_sessions.zig");

const log = std.log.scoped(.cmux_claude_hook);

/// Parsed fields from the JSON that Claude Code passes on stdin.
const HookInput = struct {
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    message: ?[]const u8 = null,
    body: ?[]const u8 = null,
    tool_input_file_path: ?[]const u8 = null,
    tool_input_command: ?[]const u8 = null,
    tool_input_pattern: ?[]const u8 = null,
    tool_input_description: ?[]const u8 = null,
};

pub fn run(alloc: Allocator) !u8 {
    // Parse CLI args
    var args_iter = try std.process.argsWithAllocator(alloc);
    defer args_iter.deinit();

    // Skip binary name
    _ = args_iter.next();

    // Skip the "+claude-hook" action
    _ = args_iter.next();

    // Get subcommand
    const subcommand = args_iter.next() orelse {
        printUsage();
        return 1;
    };

    // Parse remaining flags
    var explicit_socket: ?[]const u8 = null;
    var explicit_workspace: ?[]const u8 = null;
    var explicit_surface: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--socket=")) {
            explicit_socket = arg["--socket=".len..];
        } else if (std.mem.startsWith(u8, arg, "--workspace=")) {
            explicit_workspace = arg["--workspace=".len..];
        } else if (std.mem.startsWith(u8, arg, "--surface=")) {
            explicit_surface = arg["--surface=".len..];
        }
    }

    // Resolve workspace/surface from flags or environment
    const workspace_id = explicit_workspace orelse posix.getenv("CMUX_WORKSPACE_ID") orelse "";
    const surface_id = explicit_surface orelse posix.getenv("CMUX_SURFACE_ID") orelse "";

    // Resolve socket path
    var socket_buf: [posix.PATH_MAX]u8 = undefined;
    const socket_path = if (explicit_socket) |s| s else socket_client.resolveSocketPath(&socket_buf) catch {
        std.debug.print("Error: could not find cmux socket\n", .{});
        return 1;
    };

    // Dispatch subcommand
    if (std.mem.eql(u8, subcommand, "ping")) {
        return handlePing(alloc, socket_path);
    } else if (std.mem.eql(u8, subcommand, "session-start") or std.mem.eql(u8, subcommand, "active")) {
        return handleSessionStart(alloc, socket_path, workspace_id, surface_id);
    } else if (std.mem.eql(u8, subcommand, "stop") or std.mem.eql(u8, subcommand, "idle")) {
        return handleStop(alloc, socket_path, workspace_id, surface_id);
    } else if (std.mem.eql(u8, subcommand, "prompt-submit")) {
        return handlePromptSubmit(alloc, socket_path, workspace_id);
    } else if (std.mem.eql(u8, subcommand, "notification") or std.mem.eql(u8, subcommand, "notify")) {
        return handleNotification(alloc, socket_path, workspace_id, surface_id);
    } else if (std.mem.eql(u8, subcommand, "pre-tool-use")) {
        return handlePreToolUse(alloc, socket_path, workspace_id);
    } else if (std.mem.eql(u8, subcommand, "session-end")) {
        return handleSessionEnd(alloc, socket_path, workspace_id, surface_id);
    } else if (std.mem.eql(u8, subcommand, "help") or std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printUsage();
        return 0;
    } else {
        std.debug.print("Unknown claude-hook subcommand: {s}\n", .{subcommand});
        printUsage();
        return 1;
    }
}

// --- Subcommand handlers ---

fn handlePing(alloc: Allocator, socket_path: []const u8) !u8 {
    const response = socket_client.sendOneShot(alloc, socket_path, "ping") catch {
        return 1;
    };
    defer alloc.free(response);
    if (std.mem.eql(u8, response, "PONG")) {
        std.debug.print("OK\n", .{});
        return 0;
    }
    return 1;
}

fn handleSessionStart(alloc: Allocator, socket_path: []const u8, workspace_id: []const u8, surface_id: []const u8) !u8 {
    const input = readAndParseStdin(alloc);
    defer if (input.session_id) |s| alloc.free(s);

    // Get Claude PID from environment
    const claude_pid = posix.getenv("CMUX_CLAUDE_PID") orelse "";

    // Register in session store
    if (input.session_id) |sid| {
        var store = sessions.SessionStore.init(alloc);
        const pid_val: ?i32 = std.fmt.parseInt(i32, claude_pid, 10) catch null;
        store.upsert(.{
            .session_id = sid,
            .workspace_id = workspace_id,
            .surface_id = surface_id,
            .cwd = input.cwd,
            .pid = pid_val,
        }) catch |err| {
            log.warn("failed to upsert session: {}", .{err});
        };
    }

    // Register agent PID for stale-session detection
    if (claude_pid.len > 0 and workspace_id.len > 0) {
        const cmd = std.fmt.allocPrint(alloc, "set_agent_pid claude_code {s} --tab={s}", .{ claude_pid, workspace_id }) catch return 1;
        defer alloc.free(cmd);
        _ = sendCommand(alloc, socket_path, cmd);
    }

    std.debug.print("OK\n", .{});
    return 0;
}

fn handleStop(alloc: Allocator, socket_path: []const u8, workspace_id: []const u8, surface_id: []const u8) !u8 {
    const input = readAndParseStdin(alloc);
    defer freeHookInput(alloc, &input);

    // Resolve workspace/surface from session store if available
    var resolved_ws = workspace_id;
    var resolved_sf = surface_id;
    var session_record: ?sessions.SessionRecord = null;
    var store = sessions.SessionStore.init(alloc);

    if (input.session_id) |sid| {
        session_record = store.lookup(sid) catch null;
        if (session_record) |rec| {
            if (resolved_ws.len == 0) resolved_ws = rec.workspace_id;
            if (resolved_sf.len == 0) resolved_sf = rec.surface_id;
        }
    }
    defer if (session_record) |rec| store.freeRecord(rec);

    // Send completion notification
    if (resolved_ws.len > 0 and resolved_sf.len > 0) {
        const subtitle = "Completed";
        const body_text = if (input.message) |m| m else "Claude session completed";
        const payload = std.fmt.allocPrint(alloc, "notify_target {s} {s} Claude Code|{s}|{s}", .{ resolved_ws, resolved_sf, subtitle, sanitize(body_text) }) catch "";
        defer if (payload.len > 0) alloc.free(payload);
        if (payload.len > 0) _ = sendCommand(alloc, socket_path, payload);
    }

    // Set status to Idle
    if (resolved_ws.len > 0) {
        const cmd = std.fmt.allocPrint(alloc, "set_status claude_code Idle --icon=pause.circle.fill --color=#8E8E93 --tab={s}", .{resolved_ws}) catch "";
        defer if (cmd.len > 0) alloc.free(cmd);
        if (cmd.len > 0) _ = sendCommand(alloc, socket_path, cmd);
    }

    // Update session store with completion data
    if (input.session_id) |sid| {
        store.upsert(.{
            .session_id = sid,
            .workspace_id = resolved_ws,
            .surface_id = resolved_sf,
            .cwd = input.cwd,
            .last_subtitle = "Completed",
            .last_body = input.message,
        }) catch {};
    }

    std.debug.print("OK\n", .{});
    return 0;
}

fn handlePromptSubmit(alloc: Allocator, socket_path: []const u8, workspace_id: []const u8) !u8 {
    const input = readAndParseStdin(alloc);
    defer freeHookInput(alloc, &input);

    var resolved_ws = workspace_id;
    var store = sessions.SessionStore.init(alloc);

    if (input.session_id) |sid| {
        if (store.lookup(sid) catch null) |rec| {
            defer store.freeRecord(rec);
            if (resolved_ws.len == 0) resolved_ws = rec.workspace_id;
        }
    }

    if (resolved_ws.len > 0) {
        // Clear notifications
        const clear_cmd = std.fmt.allocPrint(alloc, "clear_notifications --tab={s}", .{resolved_ws}) catch "";
        defer if (clear_cmd.len > 0) alloc.free(clear_cmd);
        if (clear_cmd.len > 0) _ = sendCommand(alloc, socket_path, clear_cmd);

        // Set status to Running
        const status_cmd = std.fmt.allocPrint(alloc, "set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab={s}", .{resolved_ws}) catch "";
        defer if (status_cmd.len > 0) alloc.free(status_cmd);
        if (status_cmd.len > 0) _ = sendCommand(alloc, socket_path, status_cmd);
    }

    std.debug.print("OK\n", .{});
    return 0;
}

fn handleNotification(alloc: Allocator, socket_path: []const u8, workspace_id: []const u8, surface_id: []const u8) !u8 {
    const input = readAndParseStdin(alloc);
    defer freeHookInput(alloc, &input);

    var resolved_ws = workspace_id;
    var resolved_sf = surface_id;
    var store = sessions.SessionStore.init(alloc);
    var session_record: ?sessions.SessionRecord = null;

    if (input.session_id) |sid| {
        session_record = store.lookup(sid) catch null;
        if (session_record) |rec| {
            if (resolved_ws.len == 0) resolved_ws = rec.workspace_id;
            if (resolved_sf.len == 0) resolved_sf = rec.surface_id;
        }
    }
    defer if (session_record) |rec| store.freeRecord(rec);

    // Classify the notification
    const subtitle = classifyNotificationSubtitle(input.message orelse input.body orelse "");
    const body_text = sanitize(input.message orelse input.body orelse "Claude needs your input");

    // Send notification
    if (resolved_ws.len > 0 and resolved_sf.len > 0) {
        const cmd = std.fmt.allocPrint(alloc, "notify_target {s} {s} Claude Code|{s}|{s}", .{ resolved_ws, resolved_sf, subtitle, body_text }) catch "";
        defer if (cmd.len > 0) alloc.free(cmd);
        if (cmd.len > 0) _ = sendCommand(alloc, socket_path, cmd);
    }

    // Set status to "Needs input"
    if (resolved_ws.len > 0) {
        const cmd = std.fmt.allocPrint(alloc, "set_status claude_code Needs\\ input --icon=bell.fill --color=#4C8DFF --tab={s}", .{resolved_ws}) catch "";
        defer if (cmd.len > 0) alloc.free(cmd);
        if (cmd.len > 0) _ = sendCommand(alloc, socket_path, cmd);
    }

    // Update session store
    if (input.session_id) |sid| {
        store.upsert(.{
            .session_id = sid,
            .workspace_id = resolved_ws,
            .surface_id = resolved_sf,
            .cwd = input.cwd,
            .last_subtitle = subtitle,
            .last_body = body_text,
        }) catch {};
    }

    std.debug.print("OK\n", .{});
    return 0;
}

fn handlePreToolUse(alloc: Allocator, socket_path: []const u8, workspace_id: []const u8) !u8 {
    const input = readAndParseStdin(alloc);
    defer freeHookInput(alloc, &input);

    var resolved_ws = workspace_id;
    var store = sessions.SessionStore.init(alloc);

    if (input.session_id) |sid| {
        if (store.lookup(sid) catch null) |rec| {
            defer store.freeRecord(rec);
            if (resolved_ws.len == 0) resolved_ws = rec.workspace_id;
        }
    }

    if (resolved_ws.len > 0) {
        // Clear "Needs input" notifications
        const clear_cmd = std.fmt.allocPrint(alloc, "clear_notifications --tab={s}", .{resolved_ws}) catch "";
        defer if (clear_cmd.len > 0) alloc.free(clear_cmd);
        if (clear_cmd.len > 0) _ = sendCommand(alloc, socket_path, clear_cmd);

        // Determine status value — verbose tool description or just "Running"
        const status_value = describeToolUse(&input) orelse "Running";
        const status_cmd = std.fmt.allocPrint(alloc, "set_status claude_code {s} --icon=bolt.fill --color=#4C8DFF --tab={s}", .{ status_value, resolved_ws }) catch "";
        defer if (status_cmd.len > 0) alloc.free(status_cmd);
        if (status_cmd.len > 0) _ = sendCommand(alloc, socket_path, status_cmd);
    }

    std.debug.print("OK\n", .{});
    return 0;
}

fn handleSessionEnd(alloc: Allocator, socket_path: []const u8, workspace_id: []const u8, surface_id: []const u8) !u8 {
    const input = readAndParseStdin(alloc);
    defer freeHookInput(alloc, &input);

    var store = sessions.SessionStore.init(alloc);

    // Try to consume the session from the store
    const consumed = store.consume(input.session_id, if (workspace_id.len > 0) workspace_id else null, if (surface_id.len > 0) surface_id else null) catch null;

    if (consumed) |rec| {
        defer store.freeRecord(rec);

        // Clear status
        const clear_status = std.fmt.allocPrint(alloc, "clear_status claude_code --tab={s}", .{rec.workspace_id}) catch "";
        defer if (clear_status.len > 0) alloc.free(clear_status);
        if (clear_status.len > 0) _ = sendCommand(alloc, socket_path, clear_status);

        // Clear agent PID
        const clear_pid = std.fmt.allocPrint(alloc, "clear_agent_pid claude_code --tab={s}", .{rec.workspace_id}) catch "";
        defer if (clear_pid.len > 0) alloc.free(clear_pid);
        if (clear_pid.len > 0) _ = sendCommand(alloc, socket_path, clear_pid);

        // Clear notifications
        const clear_notif = std.fmt.allocPrint(alloc, "clear_notifications --tab={s}", .{rec.workspace_id}) catch "";
        defer if (clear_notif.len > 0) alloc.free(clear_notif);
        if (clear_notif.len > 0) _ = sendCommand(alloc, socket_path, clear_notif);
    }

    std.debug.print("OK\n", .{});
    return 0;
}

// --- Helpers ---

fn sendCommand(alloc: Allocator, socket_path: []const u8, command: []const u8) ?[]const u8 {
    return socket_client.sendOneShot(alloc, socket_path, command) catch |err| {
        log.warn("socket command failed: {}", .{err});
        return null;
    };
}

fn readAndParseStdin(alloc: Allocator) HookInput {
    const stdin_file: std.fs.File = .stdin();
    const content = stdin_file.readToEndAlloc(alloc, 1024 * 1024) catch return .{};
    defer alloc.free(content);

    if (content.len == 0) return .{};

    return parseHookInput(alloc, content);
}

fn parseHookInput(alloc: Allocator, content: []const u8) HookInput {
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{};

    const parsed = json.parseFromSlice(json.Value, alloc, trimmed, .{}) catch return .{};
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return .{},
    };

    var result: HookInput = .{};

    // Extract session_id from various locations (matches Mac's extractClaudeHookSessionId)
    result.session_id = dupeJsonStr(alloc, obj, "session_id") orelse
        dupeJsonStr(alloc, obj, "sessionId") orelse
        dupeNestedJsonStr(alloc, obj, "notification", "session_id") orelse
        dupeNestedJsonStr(alloc, obj, "data", "session_id");

    // Extract cwd
    result.cwd = dupeJsonStr(alloc, obj, "cwd") orelse
        dupeJsonStr(alloc, obj, "working_directory") orelse
        dupeJsonStr(alloc, obj, "workingDirectory");

    // Extract transcript path
    result.transcript_path = dupeJsonStr(alloc, obj, "transcript_path") orelse
        dupeJsonStr(alloc, obj, "transcriptPath");

    // Extract tool info
    result.tool_name = dupeJsonStr(alloc, obj, "tool_name");

    // Extract message/body from various locations
    result.message = dupeJsonStr(alloc, obj, "message") orelse
        dupeJsonStr(alloc, obj, "body") orelse
        dupeJsonStr(alloc, obj, "text") orelse
        dupeJsonStr(alloc, obj, "description") orelse
        dupeNestedJsonStr(alloc, obj, "notification", "message") orelse
        dupeNestedJsonStr(alloc, obj, "data", "message");

    result.body = dupeJsonStr(alloc, obj, "body") orelse
        dupeNestedJsonStr(alloc, obj, "notification", "body") orelse
        dupeNestedJsonStr(alloc, obj, "data", "body");

    // Extract tool_input fields
    if (obj.get("tool_input")) |ti| {
        if (ti == .object) {
            result.tool_input_file_path = dupeJsonStr(alloc, ti.object, "file_path");
            result.tool_input_command = dupeJsonStr(alloc, ti.object, "command");
            result.tool_input_pattern = dupeJsonStr(alloc, ti.object, "pattern");
            result.tool_input_description = dupeJsonStr(alloc, ti.object, "description");
        }
    }

    return result;
}

fn freeHookInput(alloc: Allocator, input: *const HookInput) void {
    if (input.session_id) |s| alloc.free(s);
    if (input.cwd) |s| alloc.free(s);
    if (input.transcript_path) |s| alloc.free(s);
    if (input.tool_name) |s| alloc.free(s);
    if (input.message) |s| alloc.free(s);
    if (input.body) |s| alloc.free(s);
    if (input.tool_input_file_path) |s| alloc.free(s);
    if (input.tool_input_command) |s| alloc.free(s);
    if (input.tool_input_pattern) |s| alloc.free(s);
    if (input.tool_input_description) |s| alloc.free(s);
}

fn dupeJsonStr(alloc: Allocator, obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    const str = switch (val) {
        .string => |s| s,
        else => return null,
    };
    const trimmed = std.mem.trim(u8, str, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return alloc.dupe(u8, trimmed) catch null;
}

fn dupeNestedJsonStr(alloc: Allocator, obj: json.ObjectMap, nested_key: []const u8, key: []const u8) ?[]const u8 {
    const nested = obj.get(nested_key) orelse return null;
    if (nested != .object) return null;
    return dupeJsonStr(alloc, nested.object, key);
}

/// Classify a notification into a subtitle category (matches Mac's classifyClaudeNotification).
fn classifyNotificationSubtitle(text: []const u8) []const u8 {
    // Simple keyword matching on the combined signal+message text
    if (containsCI(text, "permission") or containsCI(text, "approve") or containsCI(text, "approval")) return "Permission";
    if (containsCI(text, "error") or containsCI(text, "failed") or containsCI(text, "exception")) return "Error";
    if (containsCI(text, "complet") or containsCI(text, "finish") or containsCI(text, "done") or containsCI(text, "success")) return "Completed";
    if (containsCI(text, "idle") or containsCI(text, "wait") or containsCI(text, "input")) return "Waiting";
    return "Attention";
}

/// Describe a tool use for verbose status (matches Mac's describeToolUse).
fn describeToolUse(input: *const HookInput) ?[]const u8 {
    const tool = input.tool_name orelse return null;

    if (std.mem.eql(u8, tool, "Read")) return if (input.tool_input_file_path) |_| "Reading" else "Reading file";
    if (std.mem.eql(u8, tool, "Edit")) return if (input.tool_input_file_path) |_| "Editing" else "Editing file";
    if (std.mem.eql(u8, tool, "Write")) return if (input.tool_input_file_path) |_| "Writing" else "Writing file";
    if (std.mem.eql(u8, tool, "Bash")) return "Running command";
    if (std.mem.eql(u8, tool, "Glob")) return "Searching files";
    if (std.mem.eql(u8, tool, "Grep")) return "Searching code";
    if (std.mem.eql(u8, tool, "Agent")) return if (input.tool_input_description) |_| "Subagent" else "Subagent";
    if (std.mem.eql(u8, tool, "WebFetch")) return "Fetching URL";
    if (std.mem.eql(u8, tool, "WebSearch")) return "Web search";

    return "Running";
}

/// Replace pipe characters to avoid breaking the V1 notification payload format.
fn sanitize(text: []const u8) []const u8 {
    // For now, return as-is. The V1 protocol uses pipes as delimiters in
    // notify_target, but the text is the last field so pipes are safe there.
    // If we need stricter sanitization later, we can allocate and replace.
    return text;
}

/// Case-insensitive substring search.
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            if (std.ascii.toLower(hc) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: cmux +claude-hook <subcommand> [options]
        \\
        \\Subcommands:
        \\  ping            Test socket connectivity
        \\  session-start   Register a new Claude Code session
        \\  stop            Mark session as idle, send completion notification
        \\  prompt-submit   Clear notifications, set status to Running
        \\  notification    Send a notification, set status to Needs input
        \\  pre-tool-use    Clear Needs input, set status to Running
        \\  session-end     Clean up session state
        \\
        \\Options:
        \\  --socket=PATH       Explicit socket path
        \\  --workspace=UUID    Workspace ID override
        \\  --surface=UUID      Surface ID override
        \\
    , .{});
}

// --- Tests ---

test "parseHookInput basic" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"session_id": "abc-123", "cwd": "/home/user", "tool_name": "Read"}
    ;
    const result = parseHookInput(alloc, input_json);
    defer freeHookInput(alloc, &result);

    try std.testing.expectEqualStrings("abc-123", result.session_id.?);
    try std.testing.expectEqualStrings("/home/user", result.cwd.?);
    try std.testing.expectEqualStrings("Read", result.tool_name.?);
}

test "parseHookInput nested session_id" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"notification": {"session_id": "nested-id"}}
    ;
    const result = parseHookInput(alloc, input_json);
    defer freeHookInput(alloc, &result);

    try std.testing.expectEqualStrings("nested-id", result.session_id.?);
}

test "parseHookInput empty" {
    const alloc = std.testing.allocator;
    const result = parseHookInput(alloc, "");
    try std.testing.expect(result.session_id == null);
}

test "classifyNotificationSubtitle" {
    try std.testing.expectEqualStrings("Permission", classifyNotificationSubtitle("Needs permission to read file"));
    try std.testing.expectEqualStrings("Error", classifyNotificationSubtitle("Build failed"));
    try std.testing.expectEqualStrings("Completed", classifyNotificationSubtitle("Task completed successfully"));
    try std.testing.expectEqualStrings("Waiting", classifyNotificationSubtitle("Waiting for input"));
    try std.testing.expectEqualStrings("Attention", classifyNotificationSubtitle("Something happened"));
}

test "containsCI" {
    try std.testing.expect(containsCI("Hello World", "world"));
    try std.testing.expect(containsCI("PERMISSION needed", "permission"));
    try std.testing.expect(!containsCI("Hello", "xyz"));
}

test "describeToolUse" {
    var input: HookInput = .{ .tool_name = "Read" };
    try std.testing.expectEqualStrings("Reading file", describeToolUse(&input).?);
    input.tool_name = "Bash";
    try std.testing.expectEqualStrings("Running command", describeToolUse(&input).?);
    input.tool_name = null;
    try std.testing.expect(describeToolUse(&input) == null);
}
