const std = @import("std");
const schnell = @import("schnell");
const types = @import("../model/types.zig");
const AdminRequest = @import("../model/requests/admin.zig").AdminRequest;
const AdminResponse = @import("../model/responses/admin.zig").AdminResponse;
const AppServices = @import("../tasks/services.zig").AppServices;
const ServiceConn = @import("../tasks/connection_pool.zig").ServiceConn;
const paths_mod = @import("../tasks/paths.zig");
const WbStorage = @import("../tasks/storage.zig").WbStorage;
const planck = @import("planck");
const Ctx = @import("../ctx.zig").Ctx;
const json = @import("json.zig");
const utils = @import("utils");
const backup_orch = @import("../tasks/backup_orch.zig");
const Io = std.Io;
const Dir = Io.Dir;

const log = std.log.scoped(.api_admin);

pub fn handle(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const body = try req.getBody(allocator, AdminRequest);
    const services = ctx.services;

    const out = if (std.mem.eql(u8, body.action, "list-users"))
        try listUsers(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "create-user"))
        try createUser(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "delete-user"))
        try deleteUser(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "update-user"))
        try updateUser(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "regenerate-key"))
        try regenerateKey(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "list-backups"))
        try listBackups(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "create-backup"))
        try createBackup(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "delete-backup"))
        try deleteBackup(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "verify-backup"))
        try verifyBackup(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "ensure-from-restore"))
        try ensureFromRestore(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "register-app-shell"))
        try registerAppShell(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "ensure-backup-schedule"))
        try ensureBackupSchedule(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "get-config"))
        try getConfig(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "set-config"))
        try setConfig(services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "set-mode") or
        std.mem.eql(u8, body.action, "promote") or
        std.mem.eql(u8, body.action, "demote"))
        try json.serialize(allocator, AdminResponse{ .success = true })
    else
        try json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Unknown admin action" });

    try res.json(out);
}

const Acquired = struct { conn: *ServiceConn, service: []const u8 };

fn acquireConn(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) !union(enum) {
    ok: Acquired,
    err: []const u8,
} {
    const service_name = body.service orelse
        return .{ .err = try json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Service is required" }) };
    const conn = services.pool.acquire(service_name) catch
        return .{ .err = try json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Not connected" }) };
    return .{ .ok = .{ .conn = conn, .service = service_name } };
}

fn listUsers(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    const acq = switch (try acquireConn(services, allocator, body)) {
        .ok => |a| a,
        .err => |e| return e,
    };
    const conn = acq.conn;
    defer services.pool.release(acq.service, false);
    const data = conn.client.list(.User, null) catch {
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Failed to list users" });
    };
    const json_str = planck.bson.toJsonArray(allocator, data) catch "[]";
    return json.serialize(allocator, AdminResponse{ .success = true, .data = json_str });
}

fn createUser(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    if (body.username.len == 0) return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Username is required" });

    const acq = switch (try acquireConn(services, allocator, body)) {
        .ok => |a| a,
        .err => |e| return e,
    };
    const conn = acq.conn;
    defer services.pool.release(acq.service, false);

    const role = std.fmt.parseInt(u8, body.role, 10) catch 2;

    const key = if (body.key.len > 0)
        conn.client.adminCreateUserWithKey(body.username, role, body.key) catch {
            return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Failed to create user" });
        }
    else
        conn.client.adminCreateUser(body.username, role) catch {
            return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Failed to create user" });
        };
    defer allocator.free(key);

    log.info("created user '{s}'", .{body.username});
    return json.serialize(allocator, AdminResponse{ .success = true, .key = key });
}

fn deleteUser(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    const acq = switch (try acquireConn(services, allocator, body)) {
        .ok => |a| a,
        .err => |e| return e,
    };
    const conn = acq.conn;
    defer services.pool.release(acq.service, false);
    conn.client.drop(.User, body.username) catch {
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Failed to delete user" });
    };
    return json.serialize(allocator, AdminResponse{ .success = true });
}

fn updateUser(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    if (body.username.len == 0) return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Username is required" });
    if (body.role.len == 0) return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Role is required" });

    const acq = switch (try acquireConn(services, allocator, body)) {
        .ok => |a| a,
        .err => |e| return e,
    };
    const conn = acq.conn;
    defer services.pool.release(acq.service, false);

    const role = std.fmt.parseInt(u8, body.role, 10) catch {
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Invalid role" });
    };

    conn.client.adminUpdateUser(body.username, role) catch {
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Failed to update user" });
    };

    return json.serialize(allocator, AdminResponse{ .success = true });
}

fn regenerateKey(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    if (body.username.len == 0) return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Username is required" });

    const acq = switch (try acquireConn(services, allocator, body)) {
        .ok => |a| a,
        .err => |e| return e,
    };
    const conn = acq.conn;
    defer services.pool.release(acq.service, false);

    const key = conn.client.adminRegenerateKey(body.username) catch {
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Failed to regenerate key" });
    };
    defer allocator.free(key);

    return json.serialize(allocator, AdminResponse{ .success = true, .key = key });
}

fn getConfig(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    const acq = switch (try acquireConn(services, allocator, body)) {
        .ok => |a| a,
        .err => |e| return e,
    };
    const conn = acq.conn;
    defer services.pool.release(acq.service, false);
    const config_bson = conn.client.adminGetConfig() catch {
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Failed to get config" });
    };
    defer allocator.free(config_bson);
    const config_json = planck.bson.toJson(allocator, config_bson) catch {
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Failed to parse config" });
    };
    return json.serialize(allocator, AdminResponse{ .success = true, .data = config_json });
}

fn setConfig(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    const acq = switch (try acquireConn(services, allocator, body)) {
        .ok => |a| a,
        .err => |e| return e,
    };
    const conn = acq.conn;
    defer services.pool.release(acq.service, false);
    conn.client.adminSetConfig(body.config) catch {
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Failed to set config" });
    };
    return json.serialize(allocator, AdminResponse{ .success = true });
}

fn createBackup(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    var app_name: []const u8 = body.app;
    var resolved_app: ?[]u8 = null;
    defer if (resolved_app) |s| allocator.free(s);

    if (app_name.len == 0) {
        const svc = body.service orelse return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "App name is required" });
        if (svc.len == 0) return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "App name is required" });
        const found = (findAppForService(services, allocator, svc) catch null) orelse {
            return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "App not found for service" });
        };
        resolved_app = found;
        app_name = found;
    }

    const result = backup_orch.backupApp(services, allocator, app_name, body.backup_path, .manual) catch |err| {
        log.err("createBackup '{s}' failed: {}", .{ app_name, err });
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = @errorName(err) });
    };
    defer allocator.free(result.output_path);
    const reply = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"bytes\":{d},\"services\":{d}}}", .{ result.output_path, result.bytes, result.services_captured });
    defer allocator.free(reply);
    return json.serialize(allocator, AdminResponse{ .success = true, .data = reply });
}

fn findAppForService(services: *AppServices, allocator: std.mem.Allocator, service_name: []const u8) !?[]u8 {
    const storage = services.storage orelse return error.StorageUnavailable;
    const app_docs = try storage.listApps();
    defer storage.freeDocuments(app_docs);

    for (app_docs) |app_doc| {
        var adoc = planck.bson.BsonDocument.init(allocator, app_doc.value, false) catch continue;
        defer adoc.deinit();
        const arr = (adoc.getArray("services") catch null) orelse continue;
        const count = arr.len() catch 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const val = (arr.get(i) catch null) orelse continue;
            const sd = switch (val) {
                .document => |d| d.data,
                else => continue,
            };
            var sdoc = planck.bson.BsonDocument.init(allocator, sd, false) catch continue;
            defer sdoc.deinit();
            const sn = (sdoc.getString("name") catch null) orelse continue;
            if (std.mem.eql(u8, sn, service_name)) {
                const an = (adoc.getString("name") catch null) orelse continue;
                return try allocator.dupe(u8, an);
            }
        }
    }
    return null;
}

fn listBackups(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    const storage = services.storage orelse return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Sysdb storage unavailable" });

    const docs = if (body.app.len > 0)
        try storage.listByField(WbStorage.STORE_BACKUPS, "app", body.app)
    else
        try storage.list(WbStorage.STORE_BACKUPS);
    defer storage.freeDocuments(docs);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeByte('[');
    var first = true;
    for (docs) |doc| {
        if (!first) try buf.writer.writeByte(',');
        first = false;
        const j = planck.bson.toJson(allocator, doc.value) catch continue;
        defer allocator.free(j);
        try buf.writer.writeAll(j);
    }
    try buf.writer.writeByte(']');

    const out = try allocator.dupe(u8, buf.written());
    defer allocator.free(out);
    return json.serialize(allocator, AdminResponse{ .success = true, .data = out });
}

fn deleteBackup(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    if (body.backup_path.len == 0) return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "backup_path is required" });
    const storage = services.storage orelse return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Sysdb storage unavailable" });

    const found = (storage.findByField(WbStorage.STORE_BACKUPS, "backup_path", body.backup_path) catch null) orelse {
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Backup not found in sysdb" });
    };
    defer allocator.free(found.value);

    storage.delete(WbStorage.STORE_BACKUPS, found.key) catch {};
    storage.flush();
    Dir.cwd().deleteFile(services.io, body.backup_path) catch {};
    return json.serialize(allocator, AdminResponse{ .success = true });
}

fn verifyBackup(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    if (body.backup_path.len == 0) return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "backup_path is required" });
    _ = services;
    var file = Dir.openFile(.cwd(), undefined, body.backup_path, .{ .mode = .read_only }) catch {
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Backup file not readable" });
    };
    file.close(undefined);
    return json.serialize(allocator, AdminResponse{ .success = true });
}

fn registerAppShell(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    if (body.app.len == 0) return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "App name is required" });
    const mgr = services.app_manager orelse return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "AppManager not initialized" });
    mgr.registerAppFromRestore(body.app) catch |err| {
        log.err("register-app-shell '{s}' failed: {}", .{ body.app, err });
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = @errorName(err) });
    };
    return json.serialize(allocator, AdminResponse{ .success = true });
}

fn ensureBackupSchedule(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    if (body.app.len == 0) return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "App name is required" });
    const storage = services.storage orelse return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Storage not initialized" });

    const existing = storage.list(WbStorage.STORE_SCHEDULES) catch null;
    if (existing) |docs| {
        defer storage.freeDocuments(docs);
        for (docs) |doc| {
            var d = planck.bson.BsonDocument.init(allocator, doc.value, false) catch continue;
            defer d.deinit();
            const task_type = (d.getString("task_type") catch null) orelse continue;
            if (!std.mem.eql(u8, task_type, "backup")) continue;
            const app_field = (d.getString("app") catch null) orelse "";
            const svc_field = (d.getString("service") catch null) orelse "";
            if (std.mem.eql(u8, app_field, body.app) or std.mem.eql(u8, svc_field, body.app)) {
                return json.serialize(allocator, AdminResponse{ .success = true });
            }
        }
    }

    const name = try std.fmt.allocPrint(allocator, "{s}-backup", .{body.app});
    defer allocator.free(name);

    var doc = planck.bson.BsonDocument.empty(allocator);
    defer doc.deinit();
    try doc.putString("name", name);
    try doc.putString("app", body.app);
    try doc.putString("service", body.app);
    try doc.putString("task_type", "backup");
    try doc.putString("cron_expr", "0 2 * * *");
    try doc.putBool("enabled", true);
    try doc.putString("backup_path", "");
    try doc.putString("description", "Daily backup at 02:00 (auto-created on restore)");

    _ = storage.put(WbStorage.STORE_SCHEDULES, doc.toBytes()) catch |err| {
        log.err("ensure-backup-schedule '{s}' put failed: {}", .{ body.app, err });
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = @errorName(err) });
    };
    storage.flush();
    log.info("ensure-backup-schedule: created '{s}-backup' (daily 02:00)", .{body.app});
    return json.serialize(allocator, AdminResponse{ .success = true });
}

fn ensureFromRestore(services: *AppServices, allocator: std.mem.Allocator, body: *const AdminRequest) ![]const u8 {
    if (body.app.len == 0) return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "App name is required" });
    const service_name = body.service orelse return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Service is required" });
    const storage = services.storage orelse return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Sysdb storage unavailable" });

    const app_dir = try std.fmt.allocPrint(allocator, "{s}/apps/{s}", .{ services.wb_config.data_dir, body.app });
    defer allocator.free(app_dir);
    if (try storage.getApp(body.app)) |existing| {
        allocator.free(existing.value);
    } else {
        _ = storage.putApp(body.app, "", app_dir, "shell") catch |err| {
            log.warn("ensure-from-restore: putApp '{s}': {}", .{ body.app, err });
            return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Failed to register app" });
        };
    }

    if (try storage.getApp(body.app)) |a_doc| {
        defer allocator.free(a_doc.value);
        var adoc = try planck.bson.BsonDocument.init(allocator, a_doc.value, false);
        defer adoc.deinit();
        if (try adoc.getArray("services")) |arr| {
            const c = try arr.len();
            var i: usize = 0;
            while (i < c) : (i += 1) {
                const v = (try arr.get(i)) orelse continue;
                const sd = switch (v) {
                    .document => |d| d.data,
                    else => continue,
                };
                var s = try planck.bson.BsonDocument.init(allocator, sd, false);
                defer s.deinit();
                if (try s.getString("name")) |n| {
                    if (std.mem.eql(u8, n, service_name)) {
                        return json.serialize(allocator, AdminResponse{ .success = true });
                    }
                }
            }
        }
    }

    var sdoc = planck.bson.BsonDocument.empty(allocator);
    defer sdoc.deinit();
    try sdoc.putString("name", service_name);
    try sdoc.putString("admin_uid", if (body.username.len > 0) body.username else "admin");
    try sdoc.putString("admin_key", body.key);
    try sdoc.putString("description", body.description);
    const port_i32 = std.fmt.parseInt(i32, body.role, 10) catch 0;
    const wasm_port_i32 = std.fmt.parseInt(i32, body.mode, 10) catch 0;
    try sdoc.putInt32("port", port_i32);
    try sdoc.putInt32("wasm_port", wasm_port_i32);
    try sdoc.putString("status", "running");

    storage.addServiceToApp(body.app, sdoc.toBytes()) catch |err| {
        log.warn("ensure-from-restore: addServiceToApp '{s}/{s}': {}", .{ body.app, service_name, err });
        return json.serialize(allocator, AdminResponse{ .success = false, .@"error" = "Failed to register service" });
    };
    services.loadDeployedServices(allocator) catch {};

    return json.serialize(allocator, AdminResponse{ .success = true });
}
