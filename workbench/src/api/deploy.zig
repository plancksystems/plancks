const std = @import("std");
const bson = @import("bson");
const schnell = @import("schnell");
const Yaml = @import("yaml").Yaml;
const DeployRequest = @import("../model/requests/deploy.zig").DeployRequest;
const DeployResponse = @import("../model/responses/deploy.zig").DeployResponse;
const services_mod = @import("../tasks/services.zig");
const AppServices = services_mod.AppServices;
const ServiceKind = services_mod.ServiceKind;
const WbStorage = @import("../tasks/storage.zig").WbStorage;
const Paths = @import("../tasks/paths.zig").Paths;
const Ctx = @import("../ctx.zig").Ctx;
const json = @import("json.zig");
const ServiceStatus = @import("../tasks/service_manager.zig").ServiceStatus;
const ServiceManager = @import("../tasks/service_manager.zig").ServiceManager;

const log = std.log.scoped(.api_deploy);

pub fn handle(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const body = try req.getBody(allocator, DeployRequest);

    const out = if (std.mem.eql(u8, body.action, "deploy"))
        try deploy(ctx.services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "undeploy"))
        try undeploy(ctx.services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "start"))
        try startStop(ctx.services, allocator, &body, true)
    else if (std.mem.eql(u8, body.action, "stop"))
        try startStop(ctx.services, allocator, &body, false)
    else if (std.mem.eql(u8, body.action, "restart"))
        try restart(ctx.services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "update-wasm"))
        try updateWasm(ctx.services, allocator, &body)
    else
        try json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Unknown action" });

    try res.json(out);
}

fn deploy(services: *AppServices, allocator: std.mem.Allocator, body: *const DeployRequest) ![]const u8 {
    if (body.kind.len > 0 and ServiceKind.fromBsonStr(body.kind) == .sse) {
        return deploySseHub(services, allocator, body);
    }

    services.deploying = true;
    defer services.deploying = false;

    if (body.app.len == 0) return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "App name is required" });
    if (body.name.len == 0) return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Service name is required" });
    if (body.config_yaml.len == 0) return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "db.yaml (config_yaml) is required" });
    if (body.service_yaml.len == 0) return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "service.yaml is required" });

    const storage = services.storage orelse return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Storage not initialized" });
    const svc_mgr = services.service_manager orelse return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Service manager not initialized" });

    const service_already_existed = serviceExistsInApp(storage, allocator, body.app, body.name);

    if (try storage.getApp(body.app)) |d| {
        allocator.free(d.value);
    } else {
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "App not found" });
    }

    const parsed = parseDeployPorts(allocator, body.config_yaml, body.service_yaml);

    svc_mgr.deploy(body.app, body.name, body.config_yaml, body.service_yaml) catch |err| {
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = @errorName(err) });
    };

    writeServiceCredentials(allocator, svc_mgr, body.app, body.name, body.admin_uid, body.admin_key) catch |err| {
        log.warn("failed to write .credentials for '{s}/{s}': {}", .{ body.app, body.name, err });
    };

    if (!service_already_existed) {
        var doc = bson.BsonDocument.empty(allocator);
        defer doc.deinit();
        try doc.putString("name", body.name);
        const display_name = if (body.service_name.len > 0) body.service_name else body.name;
        try doc.putString("service_name", display_name);
        try doc.putString("kind", ServiceKind.wasm.toBsonStr());
        try doc.putString("admin_uid", body.admin_uid);
        try doc.putString("admin_key", body.admin_key);
        try doc.putString("description", body.description);
        try doc.putInt32("port", @intCast(parsed.port));
        try doc.putInt32("wasm_port", @intCast(parsed.wasm_port));
        try doc.putString("status", "running");

        try storage.addServiceToApp(body.app, doc.toBytes());

        if (services.scheduler) |sched| {
            sched.watchServiceWithApp(body.app, body.name) catch {};
        }

        createBackupSchedule(allocator, storage, services, body.name) catch |err| {
            log.warn("failed to create backup schedule for '{s}': {}", .{ body.name, err });
        };
    } else {
        if (services.scheduler) |sched| sched.resetStatsBackoff(body.name);
    }

    services.loadDeployedServices(allocator) catch {};

    log.info(
        "deployed '{s}' under '{s}' on port {d} http:{d} ({s})",
        .{ body.name, body.app, parsed.port, parsed.wasm_port, if (service_already_existed) "re-provisioned" else "created" },
    );

    return json.serialize(allocator, DeployResponse{ .success = true });
}

fn deploySseHub(services: *AppServices, allocator: std.mem.Allocator, body: *const DeployRequest) ![]const u8 {
    services.deploying = true;
    defer services.deploying = false;

    if (body.app.len == 0) return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "App name is required" });
    if (body.name.len == 0) return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Service name is required" });
    if (body.service_yaml.len == 0) return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "sse.yaml (service_yaml) is required" });
    if (body.binary_data.len == 0) return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "binary_data is required" });

    const storage = services.storage orelse return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Storage not initialized" });
    const svc_mgr = services.service_manager orelse return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Service manager not initialized" });

    if (try storage.getApp(body.app)) |d| {
        allocator.free(d.value);
    } else {
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "App not found" });
    }

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(body.binary_data) catch {
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Invalid base64 encoding for binary_data" });
    };
    const binary = allocator.alloc(u8, decoded_len) catch {
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "OOM decoding binary_data" });
    };
    defer allocator.free(binary);
    decoder.decode(binary, body.binary_data) catch {
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Failed to decode base64 binary_data" });
    };

    svc_mgr.deploySseService(body.app, body.name, body.service_yaml, binary) catch |err| {
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = @errorName(err) });
    };

    const service_already_existed = serviceExistsInApp(storage, allocator, body.app, body.name);
    if (!service_already_existed) {
        var doc = bson.BsonDocument.empty(allocator);
        defer doc.deinit();
        try doc.putString("name", body.name);
        const display_name = if (body.service_name.len > 0) body.service_name else body.name;
        try doc.putString("service_name", display_name);
        try doc.putString("kind", ServiceKind.sse.toBsonStr());
        try doc.putString("description", body.description);
        try doc.putString("status", "running");
        try storage.addServiceToApp(body.app, doc.toBytes());
    }

    services.loadDeployedServices(allocator) catch {};

    log.info(
        "deployed sse '{s}' under '{s}' ({s}, binary={d} bytes)",
        .{ body.name, body.app, if (service_already_existed) "re-provisioned" else "created", binary.len },
    );

    return json.serialize(allocator, DeployResponse{ .success = true });
}

fn undeploy(services: *AppServices, allocator: std.mem.Allocator, body: *const DeployRequest) ![]const u8 {
    if (body.name.len == 0) return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Service name is required" });

    const storage = services.storage orelse return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Storage not initialized" });
    const svc_mgr = services.service_manager orelse return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Service manager not initialized" });

    services.pool.unregister(body.name);

    const app_name = if (body.app.len > 0) body.app else "";
    if (app_name.len > 0) storage.removeServiceFromApp(app_name, body.name) catch {};

    svc_mgr.undeploy(app_name, body.name) catch |err| {
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = @errorName(err) });
    };

    disableBackupSchedule(allocator, storage, body.name);

    services.loadDeployedServices(allocator) catch {};

    return json.serialize(allocator, DeployResponse{ .success = true });
}

fn startStop(services: *AppServices, allocator: std.mem.Allocator, body: *const DeployRequest, start: bool) ![]const u8 {
    const svc_mgr = services.service_manager orelse return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Service manager not initialized" });

    const app_name = resolveAppForService(services, body.name);

    if (start) {
        svc_mgr.start(app_name, body.name) catch |err| {
            log.err("start failed for '{s}' (app='{s}'): {}", .{ body.name, app_name, err });
            return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = @errorName(err) });
        };

        const svc_port = services.getPortForService(body.name);
        if (svc_port > 0) {
            services.waitForPort("127.0.0.1", svc_port, 10) catch {
                const st = svc_mgr.status(app_name, body.name) catch ServiceStatus{ .state = .stopped, .pid = null, .exit_code = null };
                if (st.state == .stopped) {
                    log.err("service '{s}' crashed immediately after start", .{body.name});
                    return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Service crashed immediately after start - check service logs" });
                }
                return json.serialize(allocator, DeployResponse{ .success = true, .@"error" = "Service started but not responding on port yet" });
            };
        }
    } else {
        services.disconnectByName(body.name);
        svc_mgr.stop(app_name, body.name) catch |err| {
            log.err("stop failed for '{s}' (app='{s}'): {}", .{ body.name, app_name, err });
            return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = @errorName(err) });
        };
    }
    return json.serialize(allocator, DeployResponse{ .success = true });
}

fn restart(services: *AppServices, allocator: std.mem.Allocator, body: *const DeployRequest) ![]const u8 {
    const svc_mgr = services.service_manager orelse return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Service manager not initialized" });

    const app_name = resolveAppForService(services, body.name);

    services.disconnectByName(body.name);

    svc_mgr.restart(app_name, body.name) catch |err| {
        log.err("restart failed for '{s}' (app='{s}'): {}", .{ body.name, app_name, err });
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = @errorName(err) });
    };

    const svc_port = services.getPortForService(body.name);
    if (svc_port > 0) {
        services.waitForPort("127.0.0.1", svc_port, 10) catch {
            return json.serialize(allocator, DeployResponse{ .success = true, .@"error" = "Service restarted but not responding - may have crashed" });
        };
    }

    return json.serialize(allocator, DeployResponse{ .success = true });
}

fn updateWasm(services: *AppServices, allocator: std.mem.Allocator, body: *const DeployRequest) ![]const u8 {
    services.deploying = true;
    defer services.deploying = false;

    if (body.name.len == 0) return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Service name is required" });
    if (body.wasm_data.len == 0) return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "WASM data is required" });

    const svc_mgr = services.service_manager orelse return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Service manager not initialized" });

    const base_name = if (std.mem.indexOf(u8, body.name, ".db.")) |idx| body.name[0..idx] else body.name;

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(body.wasm_data) catch {
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Invalid base64 encoding" });
    };
    const wasm_data = allocator.alloc(u8, decoded_len) catch {
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Allocation failed" });
    };
    defer allocator.free(wasm_data);
    decoder.decode(wasm_data, body.wasm_data) catch {
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Failed to decode base64" });
    };

    if (wasm_data.len < 4 or !std.mem.eql(u8, wasm_data[0..4], "\x00asm")) {
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Invalid WASM binary" });
    }

    const app_name = if (body.app.len > 0) body.app else "";
    const p = Paths{ .data_dir = svc_mgr.data_dir };

    const wasm_dir = try p.serviceWasmDir(allocator, app_name, body.name);
    defer allocator.free(wasm_dir);
    std.Io.Dir.createDirPath(.cwd(), svc_mgr.io, wasm_dir) catch {};

    const wasm_path = try p.serviceWasm(allocator, app_name, body.name);
    defer allocator.free(wasm_path);

    std.Io.Dir.writeFile(.cwd(), svc_mgr.io, .{ .sub_path = wasm_path, .data = wasm_data }) catch {
        return json.serialize(allocator, DeployResponse{ .success = false, .@"error" = "Failed to write WASM module" });
    };

    const svc_dir = try p.serviceDir(allocator, app_name, body.name);
    defer allocator.free(svc_dir);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/service.yaml", .{svc_dir});
    defer allocator.free(config_path);

    const existing_yaml = std.Io.Dir.readFileAlloc(.cwd(), svc_mgr.io, config_path, allocator, .unlimited) catch null;
    if (existing_yaml) |yaml| {
        defer allocator.free(yaml);
        if (std.mem.indexOf(u8, yaml, "wasm:") != null and std.mem.indexOf(u8, yaml, "enabled: false") != null) {
            var updated: std.ArrayList(u8) = .empty;
            defer updated.deinit(allocator);
            var yaml_lines = std.mem.splitScalar(u8, yaml, '\n');
            while (yaml_lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (std.mem.startsWith(u8, trimmed, "enabled:") and std.mem.indexOf(u8, yaml[0 .. @intFromPtr(line.ptr) - @intFromPtr(yaml.ptr)], "wasm:") != null) {
                    if (updated.items.len > 0) try updated.append(allocator, '\n');
                    try updated.appendSlice(allocator, "  enabled: true");
                    continue;
                }
                if (updated.items.len > 0) try updated.append(allocator, '\n');
                try updated.appendSlice(allocator, line);
            }
            std.Io.Dir.writeFile(.cwd(), svc_mgr.io, .{ .sub_path = config_path, .data = updated.items }) catch {};
        }
    }

    log.info("updated WASM 'planck.{s}.wasm' ({d} bytes)", .{ base_name, wasm_data.len });

    services.disconnectByName(body.name);
    svc_mgr.restart(app_name, body.name) catch |err| {
        log.warn("restart after WASM update failed for '{s}': {}", .{ body.name, err });
    };

    if (services.scheduler) |sched| sched.resetStatsBackoff(body.name);

    return json.serialize(allocator, DeployResponse{ .success = true });
}

fn writeServiceCredentials(allocator: std.mem.Allocator, svc_mgr: *ServiceManager, app: []const u8, name: []const u8, uid: []const u8, key: []const u8) !void {
    if (uid.len == 0 or key.len == 0) return;
    const p = Paths{ .data_dir = svc_mgr.data_dir };
    const svc_dir = try p.serviceDir(allocator, app, name);
    defer allocator.free(svc_dir);

    const path = try std.fmt.allocPrint(allocator, "{s}/.credentials", .{svc_dir});
    defer allocator.free(path);

    const content = try std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ uid, key });
    defer allocator.free(content);

    try std.Io.Dir.writeFile(.cwd(), svc_mgr.io, .{ .sub_path = path, .data = content });
}

fn resolveAppForService(services: *AppServices, service_name: []const u8) []const u8 {
    for (services.databases) |entry| {
        if (std.mem.eql(u8, entry.name, service_name)) {
            return entry.app;
        }
    }
    return "";
}

fn serviceExistsInApp(storage: *WbStorage, allocator: std.mem.Allocator, app: []const u8, name: []const u8) bool {
    const app_doc = (storage.getApp(app) catch return false) orelse return false;
    defer allocator.free(app_doc.value);
    var adoc = bson.BsonDocument.init(allocator, app_doc.value, false) catch return false;
    defer adoc.deinit();
    const arr = (adoc.getArray("services") catch null) orelse return false;
    const count = arr.len() catch 0;
    for (0..count) |i| {
        const val = (arr.get(i) catch null) orelse continue;
        const sd = switch (val) {
            .document => |d| d.data,
            else => continue,
        };
        var sdoc = bson.BsonDocument.init(allocator, sd, false) catch continue;
        defer sdoc.deinit();
        const sname = (sdoc.getString("name") catch null) orelse continue;
        if (std.mem.eql(u8, sname, name)) return true;
    }
    return false;
}

fn createBackupSchedule(allocator: std.mem.Allocator, storage: *WbStorage, services: *AppServices, service_name: []const u8) !void {
    const schedule_name = try std.fmt.allocPrint(allocator, "{s}-backup", .{service_name});
    defer allocator.free(schedule_name);

    if (try storage.findByField(WbStorage.STORE_SCHEDULES, "name", schedule_name)) |existing| {
        allocator.free(existing.value);
        return;
    }

    const data_dir = services.wb_config.data_dir;
    const backup_path = try std.fmt.allocPrint(allocator, "{s}/backups/{s}/", .{ data_dir, service_name });
    defer allocator.free(backup_path);

    var doc = bson.BsonDocument.empty(allocator);
    defer doc.deinit();

    try doc.putString("name", schedule_name);
    try doc.putString("service", service_name);
    try doc.putString("task_type", "backup");
    try doc.putString("cron_expr", "0 2 * * *");
    try doc.putBool("enabled", true);
    try doc.putString("backup_path", backup_path);
    try doc.putString("description", "Auto-created backup");

    _ = try storage.put(WbStorage.STORE_SCHEDULES, doc.toBytes());
    storage.flush();
    log.info("created backup schedule for '{s}'", .{service_name});
}

fn disableBackupSchedule(allocator: std.mem.Allocator, storage: *WbStorage, service_name: []const u8) void {
    const schedule_name = std.fmt.allocPrint(allocator, "{s}-backup", .{service_name}) catch return;
    defer allocator.free(schedule_name);

    const found = (storage.findByField(WbStorage.STORE_SCHEDULES, "name", schedule_name) catch return) orelse return;
    defer allocator.free(found.value);

    var doc = bson.BsonDocument.init(allocator, found.value, false) catch return;
    defer doc.deinit();

    doc.putBool("enabled", false) catch return;
    storage.update(WbStorage.STORE_SCHEDULES, found.key, doc.toBytes()) catch return;
    storage.flush();
    log.info("disabled backup schedule for '{s}'", .{service_name});
}

const ParsedPorts = struct {
    port: u16 = 0,
    wasm_port: u16 = 0,
};

const DbCfgSubset = struct {
    port: u16 = 0,
};

const ServiceCfgSubset = struct {
    wasm: struct {
        http: struct {
            port: u16 = 0,
        } = .{},
    } = .{},
};

fn parseDeployPorts(allocator: std.mem.Allocator, db_yaml: []const u8, service_yaml: []const u8) ParsedPorts {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: ParsedPorts = .{};

    {
        var yaml: Yaml = .{ .source = db_yaml };
        if (yaml.load(a)) |_| {
            if (yaml.parse(a, DbCfgSubset)) |parsed| {
                out.port = parsed.port;
            } else |_| {}
        } else |_| {}
    }
    {
        var yaml: Yaml = .{ .source = service_yaml };
        if (yaml.load(a)) |_| {
            if (yaml.parse(a, ServiceCfgSubset)) |parsed| {
                out.wasm_port = parsed.wasm.http.port;
            } else |_| {}
        } else |_| {}
    }

    return out;
}
