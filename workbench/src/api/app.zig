const std = @import("std");
const bson = @import("bson");
const schnell = @import("schnell");
const Io = std.Io;
const Dir = Io.Dir;
const Paths = @import("../tasks/paths.zig").Paths;
const AppRequest = @import("../model/requests/app.zig").AppRequest;
const AppActionResponse = @import("../model/responses/app.zig").AppActionResponse;
const ListAppsResponse = @import("../model/responses/app.zig").ListAppsResponse;
const types = @import("../model/types.zig");
const services_mod = @import("../tasks/services.zig");
const AppServices = services_mod.AppServices;
const ServiceKind = services_mod.ServiceKind;
const Ctx = @import("../ctx.zig").Ctx;
const json = @import("json.zig");

const log = std.log.scoped(.api_app);

pub fn handleCreate(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const body = try req.getBody(allocator, AppRequest);

    const out = if (std.mem.eql(u8, body.action, "create"))
        try createApp(ctx.services, allocator, &body)
    else if (std.mem.eql(u8, body.action, "delete"))
        try deleteApp(ctx.services, allocator, &body)
    else
        try json.serialize(allocator, AppActionResponse{ .success = false, .@"error" = "Unknown action" });

    try res.json(out);
}

fn createApp(services: *AppServices, allocator: std.mem.Allocator, body: *const AppRequest) ![]const u8 {
    if (body.name.len == 0) return json.serialize(allocator, AppActionResponse{ .success = false, .@"error" = "App name is required" });

    const storage = services.storage orelse return json.serialize(allocator, AppActionResponse{ .success = false, .@"error" = "Storage not initialized" });

    if (try storage.getApp(body.name)) |existing| {
        allocator.free(existing.value);
        return json.serialize(allocator, AppActionResponse{ .success = false, .@"error" = "App already exists" });
    }

    const svc_mgr = services.service_manager orelse return json.serialize(allocator, AppActionResponse{ .success = false, .@"error" = "Service manager not initialized" });

    svc_mgr.createAppDir(body.name) catch {
        return json.serialize(allocator, AppActionResponse{ .success = false, .@"error" = "Failed to create app directory" });
    };

    const p = Paths{ .data_dir = svc_mgr.data_dir };
    const app_dir = try p.appDir(allocator, body.name);
    defer allocator.free(app_dir);

    const public_dir = try p.appPublic(allocator, body.name);
    defer allocator.free(public_dir);
    Dir.createDirPath(.cwd(), services.io, public_dir) catch {};

    _ = storage.putApp(body.name, body.description, app_dir, "shell") catch {
        return json.serialize(allocator, AppActionResponse{ .success = false, .@"error" = "Failed to store app" });
    };

    log.info("created shell app '{s}'", .{body.name});

    forwardAppToQueryNode(services, allocator, "create", body.name, body.description, 0);

    return json.serialize(allocator, AppActionResponse{ .success = true });
}

fn deleteApp(services: *AppServices, allocator: std.mem.Allocator, body: *const AppRequest) ![]const u8 {
    if (body.name.len == 0) return json.serialize(allocator, AppActionResponse{ .success = false, .@"error" = "App name is required" });

    const storage = services.storage orelse return json.serialize(allocator, AppActionResponse{ .success = false, .@"error" = "Storage not initialized" });

    const found = try storage.getApp(body.name) orelse return json.serialize(allocator, AppActionResponse{ .success = false, .@"error" = "App not found" });
    defer allocator.free(found.value);

    var doc = bson.BsonDocument.init(allocator, found.value, false) catch {
        return json.serialize(allocator, AppActionResponse{ .success = false, .@"error" = "Parse error" });
    };
    if (try doc.getArray("services")) |arr| {
        if ((arr.len() catch 0) > 0) return json.serialize(allocator, AppActionResponse{ .success = false, .@"error" = "Cannot delete app with active services" });
    }

    storage.deleteApp(body.name) catch {};

    if (services.service_manager) |svc_mgr| {
        const p2 = Paths{ .data_dir = svc_mgr.data_dir };
        const app_dir = p2.appDir(allocator, body.name) catch "";
        defer if (app_dir.len > 0) allocator.free(app_dir);
        if (app_dir.len > 0) Dir.deleteTree(.cwd(), services.io, app_dir) catch {};
    }

    forwardAppToQueryNode(services, allocator, "delete", body.name, "", 0);

    return json.serialize(allocator, AppActionResponse{ .success = true });
}

pub fn handleList(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, _: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const services = ctx.services;
    const storage = services.storage orelse {
        try res.json(try json.serialize(allocator, ListAppsResponse{ .success = true }));
        return;
    };

    const docs = storage.listApps() catch {
        try res.json(try json.serialize(allocator, ListAppsResponse{ .success = true }));
        return;
    };
    defer storage.freeDocuments(docs);

    var apps: std.ArrayList(types.AppInfo) = .empty;
    defer apps.deinit(allocator);

    for (docs) |doc| {
        var bdoc = bson.BsonDocument.init(allocator, doc.value, false) catch continue;
        defer bdoc.deinit();

        var port: i32 = 0;
        if (bdoc.getField("port") catch null) |pv| {
            switch (pv) {
                .int32 => |p| port = p,
                else => {},
            }
        }

        var svc_list: std.ArrayList(types.ServiceInfo) = .empty;

        if (bdoc.getArray("services") catch null) |arr| {
            const count = arr.len() catch 0;
            for (0..count) |si| {
                const val = (arr.get(si) catch null) orelse continue;
                const sd = switch (val) {
                    .document => |d| d.data,
                    else => continue,
                };
                var svc_doc = bson.BsonDocument.init(allocator, sd, false) catch continue;
                defer svc_doc.deinit();

                var svc_port: i32 = 0;
                if (svc_doc.getField("port") catch null) |sp| {
                    switch (sp) {
                        .int32 => |p| svc_port = p,
                        else => {},
                    }
                }
                var svc_wasm_port: i32 = 0;
                if (svc_doc.getField("wasm_port") catch null) |wp| {
                    switch (wp) {
                        .int32 => |p| svc_wasm_port = p,
                        else => {},
                    }
                }

                const svc_storage_name = (svc_doc.getString("name") catch null) orelse "";
                try svc_list.append(allocator, .{
                    .name = svc_storage_name,
                    .service_name = (svc_doc.getString("service_name") catch null) orelse svc_storage_name,
                    .description = (svc_doc.getString("description") catch null) orelse "",
                    .admin_uid = (svc_doc.getString("admin_uid") catch null) orelse "",
                    .admin_key = (svc_doc.getString("admin_key") catch null) orelse "",
                    .kind = (svc_doc.getString("kind") catch null) orelse ServiceKind.wasm.toBsonStr(),
                    .status = (svc_doc.getString("status") catch null) orelse "unknown",
                    .port = svc_port,
                    .wasm_port = svc_wasm_port,
                });
            }
        }

        const app_name = (bdoc.getString("name") catch null) orelse "unknown";
        const app_kind = (bdoc.getString("kind") catch null) orelse "shell";

        var shell_status: []const u8 = "not_deployed";
        var shell_port: u16 = 0;
        var shell_pid: i32 = 0;
        if (services.app_manager) |mgr| {
            const st = mgr.status(app_name, app_kind);
            shell_status = st.state;
            shell_port = st.port;
            if (st.pid) |p| shell_pid = @intCast(p);
        }

        try apps.append(allocator, .{
            .name = app_name,
            .description = (bdoc.getString("description") catch null) orelse "",
            .path = (bdoc.getString("path") catch null) orelse "",
            .port = port,
            .services = try svc_list.toOwnedSlice(allocator),
            .kind = app_kind,
            .shell_status = shell_status,
            .shell_port = shell_port,
            .shell_pid = shell_pid,
        });
    }

    const out = try json.serialize(allocator, ListAppsResponse{ .success = true, .apps = apps.items });
    try res.json(out);
}

fn forwardAppToQueryNode(services: *AppServices, allocator: std.mem.Allocator, action: []const u8, name: []const u8, description: []const u8, port: u16) void {
    const base_url = services.query_node_url orelse return;

    const qn_port = if (services.wb_config.query) |q| q.port else 0;
    if (qn_port == 0) return;
    services.waitForPort("127.0.0.1", qn_port, 2) catch {
        log.warn("query node not reachable - skipping app {s} for '{s}'", .{ action, name });
        return;
    };

    const health_url = std.fmt.allocPrint(allocator, "{s}/api/health", .{base_url}) catch return;
    defer allocator.free(health_url);
    {
        var health_resp = schnell.Client.request(allocator, services.io, .{
            .method = "GET",
            .url = health_url,
        }) catch |err| {
            log.warn("query node health check failed for app {s} '{s}': {}", .{ action, name, err });
            return;
        };
        defer health_resp.deinit();
        if (health_resp.status != 200 or std.mem.indexOf(u8, health_resp.body, "\"ready\":true") == null) {
            log.warn("query node not ready - skipping app {s} for '{s}'", .{ action, name });
            return;
        }
    }

    var form: std.ArrayList(u8) = .empty;
    defer form.deinit(allocator);

    form.appendSlice(allocator, "action=") catch return;
    form.appendSlice(allocator, action) catch return;
    form.appendSlice(allocator, "&name=") catch return;
    urlEncode(&form, allocator, name) catch return;

    if (std.mem.eql(u8, action, "create")) {
        form.appendSlice(allocator, "&description=") catch return;
        urlEncode(&form, allocator, description) catch return;
        var pbuf: [6]u8 = undefined;
        const ps = std.fmt.bufPrint(&pbuf, "{d}", .{port}) catch "0";
        form.appendSlice(allocator, "&port=") catch return;
        form.appendSlice(allocator, ps) catch return;
    }

    const url = std.fmt.allocPrint(allocator, "{s}/api/app-replica", .{base_url}) catch return;
    defer allocator.free(url);

    var resp = schnell.Client.request(allocator, services.io, .{
        .method = "POST",
        .url = url,
        .headers = &.{.{ "Content-Type", "application/x-www-form-urlencoded" }},
        .body = form.items,
    }) catch |err| {
        log.warn("HTTP request to query node failed for app {s} '{s}': {}", .{ action, name, err });
        return;
    };
    defer resp.deinit();

    if (resp.status != 200 or std.mem.indexOf(u8, resp.body, "\"success\":false") != null) {
        log.warn("query node returned error for app {s} '{s}' (status {d}): {s}", .{ action, name, resp.status, resp.body });
        return;
    }

    log.info("cross-node app {s} succeeded for '{s}'", .{ action, name });
}

fn urlEncode(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try buf.append(allocator, c);
        } else if (c == ' ') {
            try buf.append(allocator, '+');
        } else {
            const hex = "0123456789ABCDEF";
            try buf.append(allocator, '%');
            try buf.append(allocator, hex[c >> 4]);
            try buf.append(allocator, hex[c & 0x0F]);
        }
    }
}
