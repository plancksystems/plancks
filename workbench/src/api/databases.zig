const std = @import("std");
const schnell = @import("schnell");
const types = @import("../model/types.zig");
const ListDatabasesResponse = @import("../model/responses/databases.zig").ListDatabasesResponse;
const Ctx = @import("../ctx.zig").Ctx;

pub fn handle(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, _: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const services = ctx.services;

    var db_list: std.ArrayList(types.DbStatus) = .empty;
    defer db_list.deinit(allocator);

    for (services.databases) |entry| {
        const connected = services.pool.isRegistered(entry.name);
        try db_list.append(allocator, .{
            .name = entry.name,
            .label = entry.label,
            .connected = connected,
            .role = if (connected) services.pool.getRole(entry.name) else "",
            .uid = if (connected) services.pool.getUid(entry.name) else "",
            .wasm_port = @intCast(entry.wasm_port),
        });
    }

    const body = try std.json.Stringify.valueAlloc(allocator, db_list.items, .{ .emit_null_optional_fields = false });
    try res.json(body);
}
