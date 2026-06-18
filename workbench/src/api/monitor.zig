const std = @import("std");
const bson = @import("bson");
const schnell = @import("schnell");
const types = @import("../model/types.zig");
const MonitorResponse = @import("../model/responses/monitor.zig").MonitorResponse;
const StatsResponse = @import("../model/responses/monitor.zig").StatsResponse;
const GcResponse = @import("../model/responses/monitor.zig").GcResponse;
const StatsRequest = @import("../model/requests/monitor.zig").StatsRequest;
const GcRequest = @import("../model/requests/monitor.zig").GcRequest;
const WbStorage = @import("../tasks/storage.zig").WbStorage;
const planck = @import("planck");
const service_manager_mod = @import("../tasks/service_manager.zig");
const Ctx = @import("../ctx.zig").Ctx;
const json = @import("json.zig");

pub const MonitorParams = struct {
    service: ?[]const u8 = null,
    db: ?[]const u8 = null,
};

pub fn handleMonitor(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const services = ctx.services;
    const params = req.getParams(MonitorParams);

    var resolved_service: ?[]const u8 = params.service;
    if (resolved_service == null) {
        for (services.databases) |entry| {
            if (!std.mem.eql(u8, entry.name, "systemdb")) {
                resolved_service = entry.name;
                break;
            }
        }
    }
    const service_name = resolved_service orelse {
        try res.json(try json.serialize(allocator, MonitorResponse{ .success = true }));
        return;
    };

    if (services.deploying) {
        try res.json(try json.serialize(allocator, MonitorResponse{ .success = true }));
        return;
    }

    const conn = services.pool.acquire(service_name) catch {
        try res.json(try json.serialize(allocator, MonitorResponse{ .success = true }));
        return;
    };
    var broken = false;
    defer services.pool.release(service_name, broken);

    var current_json: ?[]const u8 = null;
    var vlogs_json: ?[]const u8 = null;

    if (conn.client.adminStats(.AllStats)) |stats_bson| {
        current_json = bson.toJson(allocator, stats_bson) catch null;
        allocator.free(stats_bson);
    } else |_| {
        broken = true;
    }

    if (conn.client.adminListVlogs()) |vlogs_bson| {
        vlogs_json = bson.toJsonArray(allocator, vlogs_bson) catch null;
        allocator.free(vlogs_bson);
    } else |_| {
        broken = true;
    }

    var history: std.ArrayList(types.StatsSnapshot) = .empty;
    defer history.deinit(allocator);

    var stats_to_free: ?[]WbStorage.Document = null;
    defer if (stats_to_free) |d| services.storage.?.freeDocuments(d);

    if (services.storage) |storage| {
        const docs = storage.list(WbStorage.STORE_STATS) catch null;
        if (docs) |stat_docs| {
            stats_to_free = stat_docs;
            for (stat_docs) |doc| {
                var bdoc = bson.BsonDocument.init(allocator, doc.value, false) catch continue;
                defer bdoc.deinit();

                const svc = (bdoc.getString("service") catch null) orelse continue;
                if (!std.mem.eql(u8, svc, service_name)) continue;

                var ts: i64 = 0;
                if (bdoc.getField("ts") catch null) |tv| {
                    switch (tv) {
                        .int64 => |t| ts = t,
                        .datetime => |t| ts = t,
                        else => {},
                    }
                }
                const data_json = blk: {
                    if (bdoc.getField("data") catch null) |dv| {
                        switch (dv) {
                            .binary => |b| break :blk bson.toJson(allocator, b.data) catch "{}",
                            else => {},
                        }
                    }
                    break :blk "{}";
                };
                try history.append(allocator, .{ .ts = ts, .data = data_json });
            }
        }
    }

    var cpu_percent: f64 = 0;
    var rss_mb: f64 = 0;
    var cpu_time_us: u64 = 0;

    if (services.service_manager) |svc_mgr| {
        const app_name = for (services.databases) |entry| {
            if (std.mem.eql(u8, entry.name, service_name)) break entry.app;
        } else "";
        if (svc_mgr.status(app_name, service_name) catch null) |st| {
            if (st.pid) |pid| {
                const pm = service_manager_mod.getProcessMetrics(pid);
                rss_mb = @as(f64, @floatFromInt(pm.rss_bytes)) / (1024.0 * 1024.0);
                cpu_time_us = pm.cpu_time_us;
            }
        }
    }

    if (services.scheduler) |sched| {
        if (sched.getServiceMetrics(service_name)) |m| {
            cpu_percent = m.cpu_percent;
            if (m.rss_bytes > 0) {
                rss_mb = @as(f64, @floatFromInt(m.rss_bytes)) / (1024.0 * 1024.0);
            }
            cpu_time_us = m.prev_cpu_time_us;
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"success\":true,\"history\":");
    const history_json = try json.serialize(allocator, history.items);
    defer allocator.free(history_json);
    try buf.appendSlice(allocator, history_json);

    try buf.appendSlice(allocator, ",\"current\":");
    if (current_json) |c| {
        try buf.appendSlice(allocator, c);
    } else {
        try buf.appendSlice(allocator, "null");
    }

    try buf.appendSlice(allocator, ",\"vlogs\":");
    if (vlogs_json) |v| {
        try buf.appendSlice(allocator, v);
    } else {
        try buf.appendSlice(allocator, "[]");
    }

    var num_buf: [32]u8 = undefined;
    try buf.appendSlice(allocator, ",\"cpu_percent\":");
    const cpu_str = std.fmt.bufPrint(&num_buf, "{d:.2}", .{cpu_percent}) catch "0";
    try buf.appendSlice(allocator, cpu_str);

    try buf.appendSlice(allocator, ",\"rss_mb\":");
    const rss_str = std.fmt.bufPrint(&num_buf, "{d:.2}", .{rss_mb}) catch "0";
    try buf.appendSlice(allocator, rss_str);

    try buf.appendSlice(allocator, ",\"cpu_time_us\":");
    const cpu_t_str = std.fmt.bufPrint(&num_buf, "{d}", .{cpu_time_us}) catch "0";
    try buf.appendSlice(allocator, cpu_t_str);

    try buf.appendSlice(allocator, ",\"process_history\":[]}");

    const owned = try allocator.dupe(u8, buf.items);
    try res.json(owned);
}

pub fn handleStats(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const services = ctx.services;
    const body = req.getParams(StatsRequest);

    var snapshots: std.ArrayList(types.StatsSnapshot) = .empty;
    defer snapshots.deinit(allocator);

    var stats_to_free: ?[]WbStorage.Document = null;
    defer if (stats_to_free) |d| services.storage.?.freeDocuments(d);

    if (services.storage) |storage| {
        const docs = storage.list(WbStorage.STORE_STATS) catch null;
        if (docs) |stat_docs| {
            stats_to_free = stat_docs;
            const limit = std.fmt.parseInt(i32, body.limit, 10) catch 60;
            var count: i32 = 0;
            for (stat_docs) |doc| {
                if (count >= limit) break;
                var bdoc = bson.BsonDocument.init(allocator, doc.value, false) catch continue;
                defer bdoc.deinit();
                const svc = (bdoc.getString("service") catch null) orelse continue;
                if (!std.mem.eql(u8, svc, body.service)) continue;

                var ts: i64 = 0;
                if (bdoc.getField("ts") catch null) |tv| {
                    switch (tv) {
                        .int64 => |t| ts = t,
                        .datetime => |t| ts = t,
                        else => {},
                    }
                }
                const data_json = blk: {
                    if (bdoc.getField("data") catch null) |dv| {
                        switch (dv) {
                            .binary => |b| break :blk bson.toJson(allocator, b.data) catch "{}",
                            else => {},
                        }
                    }
                    break :blk "{}";
                };
                try snapshots.append(allocator, .{ .ts = ts, .data = data_json });
                count += 1;
            }
        }
    }

    const out = try json.serialize(allocator, StatsResponse{ .success = true, .snapshots = snapshots.items });
    try res.json(out);
}

pub fn handleGc(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const body = try req.getBody(allocator, GcRequest);

    const service_name = body.service orelse {
        try res.json(try json.serialize(allocator, GcResponse{ .success = false, .@"error" = "Service is required" }));
        return;
    };
    if (body.vlogs.len == 0) {
        try res.json(try json.serialize(allocator, GcResponse{ .success = false, .@"error" = "Vlog IDs required" }));
        return;
    }

    const conn = ctx.services.pool.acquire(service_name) catch {
        try res.json(try json.serialize(allocator, GcResponse{ .success = false, .@"error" = "Not connected" }));
        return;
    };
    defer ctx.services.pool.release(service_name, false);

    _ = conn.client.adminCollect(body.vlogs) catch {
        try res.json(try json.serialize(allocator, GcResponse{ .success = false, .@"error" = "GC failed" }));
        return;
    };

    try res.json(try json.serialize(allocator, GcResponse{ .success = true }));
}
