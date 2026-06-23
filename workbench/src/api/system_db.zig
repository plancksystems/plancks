const std = @import("std");
const build_options = @import("build_options");
const schnell = @import("schnell");
const SystemDbConnectRequest = @import("../model/requests/system_db.zig").SystemDbConnectRequest;
const StatusResponse = @import("../model/responses/system_db.zig").SystemDbStatusResponse;
const ConnectResponse = @import("../model/responses/system_db.zig").SystemDbConnectResponse;
const LogoutResponse = @import("../model/responses/system_db.zig").SystemDbLogoutResponse;
const Ctx = @import("../ctx.zig").Ctx;

const log = std.log.scoped(.api_system_db);

pub fn handleStatus(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, _: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const body = try std.json.Stringify.valueAlloc(allocator, StatusResponse{
        .connected = ctx.connected.*,
        .version = build_options.version,
    }, .{ .emit_null_optional_fields = false });
    try res.json(body);
}

pub fn handleConnect(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const body = try req.getBody(allocator, SystemDbConnectRequest);

    if (body.key.len == 0) {
        const out = try std.json.Stringify.valueAlloc(allocator, ConnectResponse{
            .success = false,
            .@"error" = "Admin key is required",
        }, .{ .emit_null_optional_fields = false });
        try res.json(out);
        return;
    }

    const services = ctx.services;
    _ = services.connectSystemDb(allocator, body.uid, body.key) catch |err| {
        const msg = switch (err) {
            error.InvalidResponse => "Authentication failed. Check your admin key.",
            else => "Connection to system DB failed. Is it running?",
        };
        const out = try std.json.Stringify.valueAlloc(allocator, ConnectResponse{
            .success = false,
            .@"error" = msg,
        }, .{ .emit_null_optional_fields = false });
        try res.json(out);
        return;
    };

    services.saveCredentials(body.uid, body.key) catch |err| {
        log.warn("failed to save credentials: {}", .{err});
    };

    services.loadDeployedServices(allocator) catch |err| {
        log.warn("failed to load deployed services: {}", .{err});
    };

    ctx.connected.* = true;
    log.info("connected to system DB as '{s}'", .{body.uid});
    const out = try std.json.Stringify.valueAlloc(allocator, ConnectResponse{ .success = true }, .{ .emit_null_optional_fields = false });
    try res.json(out);
}

pub fn handleLogout(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, _: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    ctx.services.disconnectAll();
    ctx.connected.* = false;
    log.info("user logged out - all connections closed", .{});
    const out = try std.json.Stringify.valueAlloc(allocator, LogoutResponse{ .success = true }, .{ .emit_null_optional_fields = false });
    try res.json(out);
}
