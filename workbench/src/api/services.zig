const std = @import("std");
const bson = @import("bson");
const schnell = @import("schnell");
const types = @import("../model/types.zig");
const ListServicesResponse = @import("../model/responses/services.zig").ListServicesResponse;
const WbStorage = @import("../tasks/storage.zig").WbStorage;
const ServiceKind = @import("../tasks/services.zig").ServiceKind;
const Ctx = @import("../ctx.zig").Ctx;

pub fn handle(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, _: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const services = ctx.services;

    var svc_list: std.ArrayList(types.ServiceStatus) = .empty;
    defer svc_list.deinit(allocator);

    const storage = services.storage orelse {
        const empty = try std.json.Stringify.valueAlloc(allocator, @as([]const types.ServiceStatus, &.{}), .{ .emit_null_optional_fields = false });
        try res.json(empty);
        return;
    };

    var apps_to_free: ?[]WbStorage.Document = null;
    defer if (apps_to_free) |d| storage.freeDocuments(d);

    if (storage.listApps()) |app_docs| {
        apps_to_free = app_docs;
        for (app_docs) |app_doc| {
            var adoc = bson.BsonDocument.init(allocator, app_doc.value, false) catch continue;
            defer adoc.deinit();
            const app_name = (adoc.getString("name") catch null) orelse continue;
            const arr = (adoc.getArray("services") catch null) orelse continue;
            const count = arr.len() catch 0;

            for (0..count) |si| {
                const val = (arr.get(si) catch null) orelse continue;
                const sd = switch (val) {
                    .document => |d| d.data,
                    else => continue,
                };
                var svc_doc = bson.BsonDocument.init(allocator, sd, false) catch continue;
                defer svc_doc.deinit();

                const svc_storage_name = (svc_doc.getString("name") catch null) orelse continue;
                var status: types.ServiceStatus = .{
                    .name = svc_storage_name,
                    .service_name = (svc_doc.getString("service_name") catch null) orelse svc_storage_name,
                    .description = (svc_doc.getString("description") catch null) orelse "",
                    .admin_uid = (svc_doc.getString("admin_uid") catch null) orelse "",
                    .admin_key = (svc_doc.getString("admin_key") catch null) orelse "",
                    .kind = (svc_doc.getString("kind") catch null) orelse ServiceKind.wasm.toBsonStr(),
                    .app = app_name,
                };
                if (svc_doc.getField("port") catch null) |pv| {
                    switch (pv) {
                        .int32 => |p| status.port = p,
                        else => {},
                    }
                }
                if (services.service_manager) |mgr| {
                    if (mgr.status(app_name, status.name) catch null) |ps| {
                        status.pid = ps.pid orelse 0;
                        status.status = @tagName(ps.state);
                        if (ps.state == .running) {
                            if (services.scheduler) |sched| {
                                if (sched.getServiceMetrics(status.name)) |m| {
                                    status.cpu_percent = m.cpu_percent;
                                    status.rss_mb = @as(f64, @floatFromInt(m.rss_bytes)) / (1024.0 * 1024.0);
                                }
                            }
                        }
                    }
                }
                try svc_list.append(allocator, status);
            }
        }
    } else |_| {}

    const body = try std.json.Stringify.valueAlloc(allocator, svc_list.items, .{ .emit_null_optional_fields = false });
    try res.json(body);
}
