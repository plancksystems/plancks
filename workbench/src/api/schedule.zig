const std = @import("std");
const bson = @import("bson");
const schnell = @import("schnell");
const types = @import("../model/types.zig");
const ScheduleRequest = @import("../model/requests/schedule.zig").ScheduleRequest;
const ListSchedulesResponse = @import("../model/responses/schedule.zig").ListSchedulesResponse;
const ScheduleActionResponse = @import("../model/responses/schedule.zig").ScheduleActionResponse;
const AppServices = @import("../tasks/services.zig").AppServices;
const WbStorage = @import("../tasks/storage.zig").WbStorage;
const Ctx = @import("../ctx.zig").Ctx;

pub fn handleList(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, _: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const storage = ctx.services.storage orelse {
        try res.json(try std.json.Stringify.valueAlloc(allocator, ListSchedulesResponse{ .success = true }, .{ .emit_null_optional_fields = false }));
        return;
    };

    var schedules: std.ArrayList(types.Schedule) = .empty;
    defer schedules.deinit(allocator);

    var docs_to_free: ?[]WbStorage.Document = null;
    defer if (docs_to_free) |d| storage.freeDocuments(d);

    const docs = storage.list(WbStorage.STORE_SCHEDULES) catch null;
    if (docs) |sched_docs| {
        docs_to_free = sched_docs;
        for (sched_docs) |doc| {
            var decoder = bson.Decoder.init(allocator, doc.value);
            const sched = decoder.decode(types.Schedule) catch continue;
            try schedules.append(allocator, sched);
        }
    }

    const out = try std.json.Stringify.valueAlloc(allocator, ListSchedulesResponse{ .success = true, .schedules = schedules.items }, .{ .emit_null_optional_fields = false });
    try res.json(out);
}

pub fn handleAction(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const body = try req.getBody(allocator, ScheduleRequest);

    const out = if (std.mem.eql(u8, body.action, "create"))
        try createSchedule(ctx.services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "update"))
        try updateSchedule(ctx.services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "delete"))
        try deleteSchedule(ctx.services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "toggle"))
        try toggleSchedule(ctx.services, allocator, &body)
    else
        try std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = false, .@"error" = "Unknown action" }, .{ .emit_null_optional_fields = false });

    try res.json(out);
}

fn createSchedule(services: *AppServices, allocator: std.mem.Allocator, body: *const ScheduleRequest) ![]const u8 {
    if (body.name.len == 0) return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = false, .@"error" = "Name is required" }, .{ .emit_null_optional_fields = false });

    const is_backup = std.mem.eql(u8, body.task_type, "backup");
    if (is_backup) {
        if (body.app.len == 0) return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = false, .@"error" = "App is required for backup tasks" }, .{ .emit_null_optional_fields = false });
    } else {
        if (body.service.len == 0) return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = false, .@"error" = "Service is required for this task type" }, .{ .emit_null_optional_fields = false });
    }
    const storage = services.storage orelse return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = false, .@"error" = "Storage not initialized" }, .{ .emit_null_optional_fields = false });

    var doc = bson.BsonDocument.empty(allocator);
    defer doc.deinit();
    try doc.putString("name", body.name);
    if (is_backup) {
        try doc.putString("app", body.app);
    } else {
        try doc.putString("service", body.service);
    }
    try doc.putString("task_type", body.task_type);
    try doc.putString("cron_expr", body.cron_expr);
    try doc.putBool("enabled", std.mem.eql(u8, body.enabled, "true"));
    if (body.backup_path.len > 0) try doc.putString("backup_path", body.backup_path);
    if (body.description.len > 0) try doc.putString("description", body.description);
    if (body.manifest.len > 0) try doc.putString("manifest", body.manifest);

    _ = try storage.put(WbStorage.STORE_SCHEDULES, doc.toBytes());
    storage.flush();
    return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = true }, .{ .emit_null_optional_fields = false });
}

fn updateSchedule(services: *AppServices, allocator: std.mem.Allocator, body: *const ScheduleRequest) ![]const u8 {
    const storage = services.storage orelse return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = false, .@"error" = "Storage not initialized" }, .{ .emit_null_optional_fields = false });
    const found = (storage.findByField(WbStorage.STORE_SCHEDULES, "name", body.name) catch null) orelse {
        return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = false, .@"error" = "Schedule not found" }, .{ .emit_null_optional_fields = false });
    };
    defer allocator.free(found.value);

    const is_backup = std.mem.eql(u8, body.task_type, "backup");

    var doc = bson.BsonDocument.empty(allocator);
    defer doc.deinit();
    try doc.putString("name", body.name);
    if (is_backup) {
        try doc.putString("app", body.app);
    } else {
        try doc.putString("service", body.service);
    }
    try doc.putString("task_type", if (body.task_type.len > 0) body.task_type else "");
    try doc.putString("cron_expr", if (body.cron_expr.len > 0) body.cron_expr else "");
    try doc.putBool("enabled", std.mem.eql(u8, body.enabled, "true"));
    if (body.backup_path.len > 0) try doc.putString("backup_path", body.backup_path);
    if (body.description.len > 0) try doc.putString("description", body.description);
    if (body.manifest.len > 0) try doc.putString("manifest", body.manifest);

    storage.delete(WbStorage.STORE_SCHEDULES, found.key) catch {};
    _ = try storage.put(WbStorage.STORE_SCHEDULES, doc.toBytes());
    storage.flush();
    return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = true }, .{ .emit_null_optional_fields = false });
}

fn deleteSchedule(services: *AppServices, allocator: std.mem.Allocator, body: *const ScheduleRequest) ![]const u8 {
    const storage = services.storage orelse return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = false, .@"error" = "Storage not initialized" }, .{ .emit_null_optional_fields = false });
    if (storage.findByField(WbStorage.STORE_SCHEDULES, "name", body.name) catch null) |found| {
        defer allocator.free(found.value);
        storage.delete(WbStorage.STORE_SCHEDULES, found.key) catch {};
        storage.flush();
    }
    return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = true }, .{ .emit_null_optional_fields = false });
}

fn toggleSchedule(services: *AppServices, allocator: std.mem.Allocator, body: *const ScheduleRequest) ![]const u8 {
    const storage = services.storage orelse return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = false, .@"error" = "Storage not initialized" }, .{ .emit_null_optional_fields = false });
    const found = (storage.findByField(WbStorage.STORE_SCHEDULES, "name", body.name) catch null) orelse {
        return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = false, .@"error" = "Schedule not found" }, .{ .emit_null_optional_fields = false });
    };
    defer allocator.free(found.value);

    var doc = bson.BsonDocument.init(allocator, found.value, false) catch {
        return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = false, .@"error" = "Parse error" }, .{ .emit_null_optional_fields = false });
    };
    const enabled = (doc.getBool("enabled") catch null) orelse true;
    try doc.putBool("enabled", !enabled);

    storage.delete(WbStorage.STORE_SCHEDULES, found.key) catch {};
    _ = try storage.put(WbStorage.STORE_SCHEDULES, doc.toBytes());
    storage.flush();
    return std.json.Stringify.valueAlloc(allocator, ScheduleActionResponse{ .success = true }, .{ .emit_null_optional_fields = false });
}
