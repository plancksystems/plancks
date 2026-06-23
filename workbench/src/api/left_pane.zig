const std = @import("std");
const bson = @import("bson");
const planck = @import("planck");
const schnell = @import("schnell");
const proto = planck.proto;
const types = @import("../model/types.zig");
const LeftPaneResponse = @import("../model/responses/left_pane.zig").LeftPaneResponse;
const Ctx = @import("../ctx.zig").Ctx;

pub const LeftPaneRequest = struct {
    service: ?[]const u8 = null,
};

pub fn handle(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const services = ctx.services;

    const params = req.getParams(LeftPaneRequest);
    const service_name = params.service orelse {
        const empty = try std.json.Stringify.valueAlloc(allocator, LeftPaneResponse{ .success = true }, .{ .emit_null_optional_fields = false });
        try res.json(empty);
        return;
    };

    const conn = services.pool.acquire(service_name) catch {
        const empty = try std.json.Stringify.valueAlloc(allocator, LeftPaneResponse{ .success = true }, .{ .emit_null_optional_fields = false });
        try res.json(empty);
        return;
    };
    defer services.pool.release(service_name, false);

    var stores: std.ArrayList(types.StoreInfo) = .empty;
    defer stores.deinit(allocator);

    const store_data = conn.client.list(.Store, null) catch null;
    if (store_data) |data| {
        const StoreList = struct { stores: []const proto.Store };
        var decoder = bson.Decoder.init(allocator, data);
        const store_result = decoder.decode(StoreList) catch null;
        if (store_result) |result| {
            defer allocator.free(result.stores);

            const is_systemdb = std.mem.eql(u8, service_name, "systemdb");
            for (result.stores) |store| {
                if (!is_systemdb and std.mem.startsWith(u8, store.ns, "sys")) continue;

                var indexes: std.ArrayList(types.IndexInfo) = .empty;

                const idx_data = conn.client.list(.Index, store.ns) catch null;
                if (idx_data) |idata| {
                    const IndexList = struct { indexes: []const proto.Index };
                    var idx_decoder = bson.Decoder.init(allocator, idata);
                    const idx_result = idx_decoder.decode(IndexList) catch null;
                    if (idx_result) |iresult| {
                        defer allocator.free(iresult.indexes);
                        for (iresult.indexes) |idx| {
                            try indexes.append(allocator, .{
                                .ns = idx.ns,
                                .field = idx.field,
                                .field_type = @tagName(idx.field_type),
                                .unique = idx.unique,
                                .short = if (std.mem.lastIndexOfScalar(u8, idx.ns, '.')) |dot| idx.ns[dot + 1 ..] else idx.ns,
                            });
                        }
                    }
                }

                try stores.append(allocator, .{
                    .ns = store.ns,
                    .short = store.ns,
                    .description = store.description,
                    .indexes = try indexes.toOwnedSlice(allocator),
                });
            }
        }
    }

    var svc_list: std.ArrayList(types.ServiceStatus) = .empty;
    defer svc_list.deinit(allocator);

    for (services.databases) |entry| {
        var status: types.ServiceStatus = .{
            .name = entry.name,
            .port = @intCast(entry.port),
            .app = entry.app,
        };
        if (services.service_manager) |mgr| {
            if (mgr.status(entry.app, entry.name) catch null) |ps| {
                status.pid = ps.pid orelse 0;
                status.status = @tagName(ps.state);
            }
        }
        try svc_list.append(allocator, status);
    }

    const body = try std.json.Stringify.valueAlloc(allocator, LeftPaneResponse{
        .success = true,
        .stores = stores.items,
        .services = svc_list.items,
    }, .{ .emit_null_optional_fields = false });
    try res.json(body);
}
