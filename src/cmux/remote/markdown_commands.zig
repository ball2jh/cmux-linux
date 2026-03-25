//! V2 socket command handlers for markdown.* methods.
//!
//! Mirrors Mac's v2MarkdownOpen handler. Opens a markdown panel
//! in a split alongside an existing terminal surface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const v2 = @import("../v2.zig");
const Server = @import("../Server.zig");
const Uuid = @import("../uuid.zig").Uuid;
const dispatch = @import("../dispatch.zig");
const window_ops_mod = @import("../window_ops.zig");
const client_handler = @import("../client_handler.zig");

const log = std.log.scoped(.cmux_markdown_commands);

/// All markdown.* method names for system.capabilities registration.
pub const method_names = [_][]const u8{
    "markdown.open",
};

/// Dispatch a markdown.* method to the appropriate handler.
pub fn dispatchMarkdown(
    server: *Server,
    arena: Allocator,
    writer: *client_handler.ResponseWriter,
    req: v2.Request,
) void {
    const m = req.method;
    if (std.mem.eql(u8, m, "markdown.open")) return handleOpen(server, arena, writer, req);
    v2.writeError(writer, arena, req.id, v2.ErrorCode.method_not_found, "Unknown markdown method") catch {};
}

// ── markdown.open ────────────────────────────────────────────

const SyncMarkdownOpenCtx = struct {
    ops: window_ops_mod.WindowOps,
    ws_id: Uuid,
    path: [*:0]const u8,
    direction: window_ops_mod.Direction,
    result: ?window_ops_mod.MarkdownSplitResult = null,
};

fn syncMarkdownOpen(data: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SyncMarkdownOpenCtx = @ptrCast(@alignCast(data orelse return 0));
    ctx.result = ctx.ops.markdownOpenSplit(ctx.ws_id, ctx.path, ctx.direction);
    return 0;
}

fn handleOpen(server: *Server, arena: Allocator, writer: *client_handler.ResponseWriter, req: v2.Request) void {
    const ops = server.window_ops orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "No window ops") catch {};
        return;
    };

    // Resolve workspace
    const ws_id = resolveWorkspaceId(server, req.params) orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.not_found, "Workspace not found") catch {};
        return;
    };

    // Required: path
    const path_str = jsonStr(req.params.get("path"));
    if (path_str.len == 0) {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Missing path") catch {};
        return;
    }

    // Expand ~ to home dir
    const expanded = if (path_str.len > 0 and path_str[0] == '~') blk: {
        const home = std.posix.getenv("HOME") orelse {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "Cannot resolve ~") catch {};
            return;
        };
        break :blk std.fmt.allocPrint(arena, "{s}{s}", .{ home, path_str[1..] }) catch {
            v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
            return;
        };
    } else path_str;

    // Null-terminate the path for C APIs
    const path_z = arena.allocSentinel(u8, expanded.len, 0) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "OOM") catch {};
        return;
    };
    @memcpy(path_z[0..expanded.len], expanded);

    // Validate file exists
    std.fs.cwd().access(path_z, .{}) catch {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.invalid_params, "File not found") catch {};
        return;
    };

    // Optional: direction (default "right")
    const dir_str = jsonStr(req.params.get("direction"));
    const direction = if (dir_str.len > 0) window_ops_mod.Direction.parse(dir_str) orelse .right else .right;

    // Dispatch to main thread
    var ctx = SyncMarkdownOpenCtx{ .ops = ops, .ws_id = ws_id, .path = path_z, .direction = direction };
    dispatch.syncOnMainThread(&syncMarkdownOpen, @ptrCast(&ctx));

    const result = ctx.result orelse {
        v2.writeError(writer, arena, req.id, v2.ErrorCode.internal_error, "Failed to open markdown panel") catch {};
        return;
    };

    // Build response matching Mac shape
    var resp = json.ObjectMap.init(arena);
    resp.put("workspace_id", jsonUuid(arena, result.workspace_id)) catch {};
    resp.put("workspace_ref", server.v2Ref(.workspace, result.workspace_id)) catch {};
    resp.put("panel_id", jsonUuid(arena, result.panel_id)) catch {};
    resp.put("type", .{ .string = "markdown" }) catch {};
    resp.put("path", .{ .string = expanded }) catch {};
    v2.writeOk(writer, arena, req.id, .{ .object = resp }) catch {};
}

// ── Helpers (duplicated from browser_commands — keep minimal) ─

fn resolveWorkspaceId(server: *Server, params: json.ObjectMap) ?Uuid {
    if (server.v2UUID(params, "workspace_id")) |id| return id;
    // Fall back to selected workspace
    const mgr = server.workspace_manager orelse return null;
    return mgr.selected_id;
}

fn jsonStr(val: ?json.Value) []const u8 {
    return if (val) |v| switch (v) { .string => |s| s, else => "" } else "";
}

fn jsonUuid(arena: Allocator, id: Uuid) json.Value {
    const fmt = id.format();
    return .{ .string = arena.dupe(u8, &fmt) catch "" };
}
