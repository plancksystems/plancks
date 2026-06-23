const std = @import("std");
const bson = @import("bson");
const schnell = @import("schnell");
const ConnectRequest = @import("../model/requests/connect.zig").ConnectRequest;
const DisconnectRequest = @import("../model/requests/connect.zig").DisconnectRequest;
const ConnectResponse = @import("../model/responses/connect.zig").ConnectResponse;
const DisconnectResponse = @import("../model/responses/connect.zig").DisconnectResponse;
const AppServices = @import("../tasks/services.zig").AppServices;
const WbStorage = @import("../tasks/storage.zig").WbStorage;
const Ctx = @import("../ctx.zig").Ctx;

const log = std.log.scoped(.api_connect);

pub fn handleConnect(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const body = try req.getBody(allocator, ConnectRequest);

    if (body.service) |service_name| {
        const result_body = try doConnect(ctx.services, allocator, service_name, body.uid, body.key);
        try res.json(result_body);
        return;
    }

    if (body.db) |idx| {
        const i: usize = @intCast(idx);
        if (i < ctx.services.databases.len) {
            const result_body = try doConnect(
                ctx.services,
                allocator,
                ctx.services.databases[i].name,
                body.uid,
                body.key,
            );
            try res.json(result_body);
            return;
        }
    }

    const out = try std.json.Stringify.valueAlloc(allocator, ConnectResponse{
        .success = false,
        .@"error" = "Service name is required",
    }, .{ .emit_null_optional_fields = false });
    try res.json(out);
}

fn doConnect(services: *AppServices, allocator: std.mem.Allocator, service_name: []const u8, uid: []const u8, key: []const u8) ![]const u8 {
    var effective_uid = uid;
    var effective_key = key;

    if (effective_uid.len == 0 or effective_key.len == 0) {
        if (services.storage) |storage| {
            const app_docs = storage.listApps() catch null;
            defer if (app_docs) |d| storage.freeDocuments(d);
            outer: for (app_docs orelse &.{}) |app_doc| {
                var bdoc = bson.BsonDocument.init(allocator, app_doc.value, false) catch continue;
                defer bdoc.deinit();
                const services_arr = (bdoc.getArray("services") catch null) orelse continue;
                const count = services_arr.len() catch 0;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const val = (services_arr.get(i) catch null) orelse continue;
                    const sd = switch (val) {
                        .document => |d| d.data,
                        else => continue,
                    };
                    var svc = bson.BsonDocument.init(allocator, sd, false) catch continue;
                    defer svc.deinit();
                    const name = (svc.getString("name") catch null) orelse continue;
                    if (!std.mem.eql(u8, name, service_name)) continue;
                    if (svc.getString("admin_uid") catch null) |u| effective_uid = u;
                    if (svc.getString("admin_key") catch null) |k| effective_key = k;
                    break :outer;
                }
            }
        }
    }

    const idx = for (services.databases, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, service_name)) break i;
    } else null;

    if (idx == null) {
        return std.json.Stringify.valueAlloc(allocator, ConnectResponse{
            .success = false,
            .@"error" = "Service not found",
        }, .{ .emit_null_optional_fields = false });
    }

    const result = services.connectDb(idx.?, effective_uid, effective_key) catch {
        return std.json.Stringify.valueAlloc(allocator, ConnectResponse{
            .success = false,
            .@"error" = "Connection failed",
        }, .{ .emit_null_optional_fields = false });
    };

    return std.json.Stringify.valueAlloc(allocator, ConnectResponse{ .success = true, .role = result.role }, .{ .emit_null_optional_fields = false });
}

pub fn handleDisconnect(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const body = try req.getBody(allocator, DisconnectRequest);

    if (body.service) |name| {
        ctx.services.disconnectByName(name);
    } else if (body.db) |idx| {
        ctx.services.disconnectDb(@intCast(idx));
    }

    const out = try std.json.Stringify.valueAlloc(allocator, DisconnectResponse{ .success = true }, .{ .emit_null_optional_fields = false });
    try res.json(out);
}
