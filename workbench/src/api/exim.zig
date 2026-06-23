const std = @import("std");
const bson = @import("bson");
const schnell = @import("schnell");
const EximRequest = @import("../model/requests/exim.zig").EximRequest;
const EximResponse = @import("../model/responses/exim.zig").EximResponse;
const AppServices = @import("../tasks/services.zig").AppServices;
const WbStorage = @import("../tasks/storage.zig").WbStorage;
const Ctx = @import("../ctx.zig").Ctx;

pub fn handleExport(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const body = try req.getBody(allocator, EximRequest);
    const services = ctx.services;

    if (body.manifest.len == 0) {
        try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = false, .@"error" = "Manifest is required" }, .{ .emit_null_optional_fields = false }));
        return;
    }

    if (body.cron_expr.len > 0) {
        const storage = services.storage orelse {
            try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = false, .@"error" = "Storage not initialized" }, .{ .emit_null_optional_fields = false }));
            return;
        };
        var doc = bson.BsonDocument.empty(allocator);
        defer doc.deinit();
        try doc.putString("name", body.name);
        try doc.putString("service", body.service orelse "");
        try doc.putString("task_type", "export");
        try doc.putString("cron_expr", body.cron_expr);
        try doc.putBool("enabled", true);
        try doc.putString("manifest", body.manifest);
        if (body.description.len > 0) try doc.putString("description", body.description);
        _ = try storage.put(WbStorage.STORE_SCHEDULES, doc.toBytes());
        storage.flush();
        try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = true, .scheduled = true }, .{ .emit_null_optional_fields = false }));
        return;
    }

    const service_name = body.service orelse {
        try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = false, .@"error" = "Service is required" }, .{ .emit_null_optional_fields = false }));
        return;
    };
    const conn = services.pool.acquire(service_name) catch {
        try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = false, .@"error" = "Not connected" }, .{ .emit_null_optional_fields = false }));
        return;
    };
    defer services.pool.release(service_name, false);
    const result = conn.client.adminExportManifest(body.manifest, null) catch {
        try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = false, .@"error" = "Export failed" }, .{ .emit_null_optional_fields = false }));
        return;
    };
    try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = true, .message = result }, .{ .emit_null_optional_fields = false }));
}

pub fn handleImport(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const body = try req.getBody(allocator, EximRequest);
    const services = ctx.services;

    if (body.manifest.len == 0) {
        try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = false, .@"error" = "Manifest is required" }, .{ .emit_null_optional_fields = false }));
        return;
    }

    if (body.cron_expr.len > 0) {
        const storage = services.storage orelse {
            try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = false, .@"error" = "Storage not initialized" }, .{ .emit_null_optional_fields = false }));
            return;
        };
        var doc = bson.BsonDocument.empty(allocator);
        defer doc.deinit();
        try doc.putString("name", body.name);
        try doc.putString("service", body.service orelse "");
        try doc.putString("task_type", "import");
        try doc.putString("cron_expr", body.cron_expr);
        try doc.putBool("enabled", true);
        try doc.putString("manifest", body.manifest);
        _ = try storage.put(WbStorage.STORE_SCHEDULES, doc.toBytes());
        storage.flush();
        try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = true, .scheduled = true }, .{ .emit_null_optional_fields = false }));
        return;
    }

    const service_name = body.service orelse {
        try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = false, .@"error" = "Service is required" }, .{ .emit_null_optional_fields = false }));
        return;
    };
    const conn = services.pool.acquire(service_name) catch {
        try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = false, .@"error" = "Not connected" }, .{ .emit_null_optional_fields = false }));
        return;
    };
    defer services.pool.release(service_name, false);
    const result = conn.client.adminImportManifest(body.manifest) catch {
        try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = false, .@"error" = "Import failed" }, .{ .emit_null_optional_fields = false }));
        return;
    };
    try res.json(try std.json.Stringify.valueAlloc(allocator, EximResponse{ .success = true, .message = result }, .{ .emit_null_optional_fields = false }));
}
