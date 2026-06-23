const std = @import("std");
const Allocator = std.mem.Allocator;
const bson = @import("bson");
const schnell = @import("schnell");
const Ctx = @import("../ctx.zig").Ctx;

pub const AppLifecycleRequest = struct {
    action: []const u8 = "",
    app: []const u8 = "",
};

pub const AppLifecycleResponse = struct {
    success: bool = true,
    status: ?[]const u8 = null,
    port: ?u16 = null,
    pid: ?i32 = null,
    @"error": ?[]const u8 = null,
};

pub fn handle(ctx_ptr: ?*anyopaque, allocator: Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const body = try req.getBody(allocator, AppLifecycleRequest);

    if (body.app.len == 0) {
        try res.json(try std.json.Stringify.valueAlloc(allocator, AppLifecycleResponse{ .success = false, .@"error" = "App name is required" }, .{ .emit_null_optional_fields = false }));
        return;
    }

    const mgr = ctx.services.app_manager orelse {
        try res.json(try std.json.Stringify.valueAlloc(allocator, AppLifecycleResponse{ .success = false, .@"error" = "App manager not initialized" }, .{ .emit_null_optional_fields = false }));
        return;
    };

    if (std.mem.eql(u8, body.action, "start")) {
        mgr.start(body.app) catch |err| {
            try res.json(try std.json.Stringify.valueAlloc(allocator, AppLifecycleResponse{ .success = false, .@"error" = @errorName(err) }, .{ .emit_null_optional_fields = false }));
            return;
        };
    } else if (std.mem.eql(u8, body.action, "stop")) {
        mgr.stop(body.app) catch |err| {
            try res.json(try std.json.Stringify.valueAlloc(allocator, AppLifecycleResponse{ .success = false, .@"error" = @errorName(err) }, .{ .emit_null_optional_fields = false }));
            return;
        };
    } else if (std.mem.eql(u8, body.action, "restart")) {
        mgr.restart(body.app) catch |err| {
            try res.json(try std.json.Stringify.valueAlloc(allocator, AppLifecycleResponse{ .success = false, .@"error" = @errorName(err) }, .{ .emit_null_optional_fields = false }));
            return;
        };
    } else {
        try res.json(try std.json.Stringify.valueAlloc(allocator, AppLifecycleResponse{ .success = false, .@"error" = "Unknown action. Use: start, stop, restart" }, .{ .emit_null_optional_fields = false }));
        return;
    }

    var kind: []const u8 = "shell";
    if (ctx.services.storage) |storage| {
        if (storage.getApp(body.app) catch null) |found| {
            defer allocator.free(found.value);
            var doc = bson.BsonDocument.init(allocator, found.value, false) catch null;
            if (doc != null) {
                defer doc.?.deinit();
                if (doc.?.getString("kind") catch null) |k| kind = k;
            }
        }
    }
    const st = mgr.status(body.app, kind);
    try res.json(try std.json.Stringify.valueAlloc(allocator, AppLifecycleResponse{
        .success = true,
        .status = st.state,
        .port = if (st.port > 0) st.port else null,
        .pid = if (st.pid) |p| @intCast(p) else null,
    }, .{ .emit_null_optional_fields = false }));
}
