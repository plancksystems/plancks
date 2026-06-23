const std = @import("std");
const builtin = @import("builtin");
const planck = @import("planck");
const utils = @import("utils");
const compat = @import("compat.zig");
const bson_util = @import("bson_util.zig");

const Config = compat.Config;
const DbConfig = compat.DbConfig;
const Logger = compat.Logger;
const PlacnkClient = planck.Client;
const TimeoutConfig = planck.TimeoutConfig;
const WbStorage = @import("storage.zig").WbStorage;
const ServiceManager = @import("service_manager.zig").ServiceManager;
const AppManager = @import("app_manager.zig").AppManager;
const WbConfig = @import("config.zig").WbConfig;
const RunMode = @import("config.zig").RunMode;
const Scheduler = @import("scheduler.zig").Scheduler;
const ConnectionPool = @import("connection_pool.zig").ConnectionPool;
const ServiceControl = utils.ServiceControl;
const sc_labels = utils.labels;
const bson = planck.bson;
const Cron = planck.utils.Cron;
const Now = planck.utils.Now;
const log = std.log.scoped(.services);

pub const ServiceKind = enum {
    wasm,
    sse,

    pub fn toBsonStr(self: ServiceKind) []const u8 {
        return switch (self) {
            .wasm => "wasm",
            .sse => "sse_hub",
        };
    }

    pub fn fromBsonStr(s: []const u8) ?ServiceKind {
        if (std.mem.eql(u8, s, "wasm")) return .wasm;
        if (std.mem.eql(u8, s, "sse_hub")) return .sse;
        return null;
    }
};

pub const DbEntry = struct {
    name: []const u8,
    host: []const u8,
    port: u16,
    label: []const u8,
    wasm_port: u16 = 0,
    app: []const u8 = "",
};

pub const App = struct {
    name: []const u8,
    port: u16,
};

pub const ConnectResult = struct {
    role: []const u8,
};

pub const AppServices = struct {
    databases: []DbEntry,
    apps: []App,
    allocator: std.mem.Allocator,
    logger: *Logger,
    io: std.Io,
    storage: ?*WbStorage = null,
    service_manager: ?*ServiceManager = null,
    app_manager: ?*AppManager = null,
    scheduler: ?*Scheduler = null,
    query_node_url: ?[]const u8 = null,
    wb_config: *const WbConfig,
    pool: *ConnectionPool,

    ready: bool = false,

    deploying: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: *const Config, wb_config: *const WbConfig, io: std.Io) !*AppServices {
        const self = try allocator.create(AppServices);
        self.allocator = allocator;
        self.io = io;
        self.wb_config = wb_config;

        const logger = try allocator.create(Logger);
        logger.* = undefined;
        logger.setup(self.io, "planck-wb.log", 10, 3);
        self.logger = logger;

        _ = config;
        self.databases = &.{};
        self.apps = &.{};

        const data_dir = wb_config.data_dir;
        self.query_node_url = wb_config.getQueryNodeUrl(allocator) catch null;

        self.storage = null;

        self.service_manager = ServiceManager.init(allocator, io, wb_config.planck_dir, data_dir, wb_config.planck_bin) catch |err| blk: {
            log.warn("service manager init failed: {}", .{err});
            break :blk null;
        };

        self.app_manager = AppManager.init(allocator, io, data_dir) catch |err| blk: {
            log.warn("app manager init failed: {}", .{err});
            break :blk null;
        };

        self.pool = try ConnectionPool.init(allocator, io);

        self.scheduler = null;
        self.ready = false;

        return self;
    }

    pub fn waitForPort(self: *AppServices, host: []const u8, port: u16, max_retries: u32) !void {
        _ = host;
        const net = std.Io.net;
        const address = net.IpAddress.parseIp4("127.0.0.1", port) catch return error.PortNotReady;

        var attempts: u32 = 0;
        while (attempts < max_retries) : (attempts += 1) {
            var socket = address.connect(self.io, .{
                .mode = .stream,
                .protocol = .tcp,
            }) catch {
                self.io.sleep(std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
                continue;
            };
            socket.close(self.io);
            return;
        }
        return error.PortNotReady;
    }


    pub fn connectSystemDb(self: *AppServices, allocator: std.mem.Allocator, uid: []const u8, key: []const u8) !ConnectResult {
        if (self.storage) |st| {
            log.warn("connectSystemDb: replacing existing storage connection", .{});
            st.deinit();
            self.storage = null;
        }

        const port: u16 = self.wb_config.system_db.port;

        const conn_str = try std.fmt.allocPrint(allocator, "{s}:{d};uid={s};key={s}", .{
            self.wb_config.system_db.host, port, uid, key,
        });
        defer allocator.free(conn_str);

        self.storage = try WbStorage.init(self.allocator, self.io, conn_str);

        if (self.scheduler) |sched| {
            sched.storage = self.storage;
        }

        log.info("Connected to system DB as {s}", .{uid});

        self.ensureSystemDbSchedules(uid, key);

        return ConnectResult{ .role = "admin" };
    }

    fn ensureSystemDbSchedules(self: *AppServices, uid: []const u8, key: []const u8) void {
        const storage = self.storage orelse return;
        const allocator = self.allocator;

        const has_system_app = if (storage.getApp("system") catch null) |existing| blk: {
            allocator.free(existing.value);
            break :blk true;
        } else false;

        if (!has_system_app) {
            _ = storage.putApp("system", "System database (workbench-managed)", "", "system") catch |err| {
                log.warn("ensureSystemDbSchedules: failed to create 'system' app: {}", .{err});
                return;
            };
        }

        var sysdb_present = false;
        if (storage.getApp("system") catch null) |existing| {
            defer allocator.free(existing.value);
            var bdoc = bson.BsonDocument.init(allocator, existing.value, false) catch null;
            if (bdoc) |*d| {
                defer d.deinit();
                if ((d.getArray("services") catch null)) |services_arr| {
                    const count = services_arr.len() catch 0;
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const val = (services_arr.get(i) catch null) orelse continue;
                        const sd = switch (val) {
                            .document => |dd| dd.data,
                            else => continue,
                        };
                        var elem = bson.BsonDocument.init(allocator, sd, false) catch continue;
                        defer elem.deinit();
                        if ((elem.getString("name") catch null)) |name| {
                            if (std.mem.eql(u8, name, "systemdb")) {
                                sysdb_present = true;
                                break;
                            }
                        }
                    }
                }
            }
        }

        if (!sysdb_present) {
            var svc_doc = bson.BsonDocument.empty(allocator);
            defer svc_doc.deinit();
            svc_doc.putString("name", "systemdb") catch return;
            svc_doc.putString("admin_uid", uid) catch return;
            svc_doc.putString("admin_key", key) catch return;
            svc_doc.putString("description", "System database") catch return;
            svc_doc.putInt32("port", @intCast(self.wb_config.system_db.port)) catch return;
            svc_doc.putString("kind", "db") catch return;
            svc_doc.putString("status", "running") catch return;

            storage.addServiceToApp("system", svc_doc.toBytes()) catch |err| {
                log.warn("ensureSystemDbSchedules: failed to add systemdb to system app: {}", .{err});
                return;
            };
            log.info("registered systemdb under 'system' app in sysapps", .{});
        }

        self.pool.register("systemdb", self.wb_config.system_db.host, self.wb_config.system_db.port, uid, key) catch {};
        self.pool.setRole("systemdb", "admin");

        const has_backup = if (storage.findByField(WbStorage.STORE_SCHEDULES, "name", "systemdb-backup") catch null) |existing| blk: {
            allocator.free(existing.value);
            break :blk true;
        } else false;

        if (has_backup) return;

        const data_dir = self.wb_config.data_dir;
        const backup_path = std.fmt.allocPrint(allocator, "{s}/backups/systemdb/", .{data_dir}) catch return;
        defer allocator.free(backup_path);

        const cron_expr: []const u8 =  "0 2 * * *";
        const cron = Cron.parse(cron_expr) catch return;
        const now_ms = (Now{ .io = self.io }).toMilliSeconds();
        const next_run = cron.nextRunAfter(now_ms) catch 0;

        var sched_doc = bson.BsonDocument.empty(allocator);
        defer sched_doc.deinit();

        sched_doc.putString("name", "systemdb-backup") catch return;
        sched_doc.putString("service", "systemdb") catch return;
        sched_doc.putString("task_type", "backup") catch return;
        sched_doc.putString("cron_expr", cron_expr) catch return;
        sched_doc.putBool("enabled", true) catch return;
        sched_doc.putString("backup_path", backup_path) catch return;
        sched_doc.putString("description", "Auto-created system DB backup") catch return;
        sched_doc.putInt64("created_at", now_ms) catch return;
        sched_doc.putInt64("updated_at", now_ms) catch return;
        sched_doc.putInt64("last_run_at", 0) catch return;
        sched_doc.putInt64("next_run_at", next_run) catch return;

        _ = storage.put(WbStorage.STORE_SCHEDULES, sched_doc.toBytes()) catch return;
        storage.flush();
        log.info("created systemdb-backup schedule ({s})", .{cron_expr});
    }

    pub fn tryAutoConnect(self: *AppServices, allocator: std.mem.Allocator) void {
        if (self.storage != null) {
            log.info("tryAutoConnect: already connected, skipping", .{});
            return;
        }

        const creds = self.loadCredentials() catch return;
        defer {
            allocator.free(creds.uid);
            allocator.free(creds.key);
        }

        if (self.storage != null) return;

        _ = self.connectSystemDb(allocator, creds.uid, creds.key) catch |err| {
            log.warn("Auto-connect to system DB failed: {}", .{err});
            return;
        };

        self.loadDeployedServices(allocator) catch |err| {
            log.warn("failed to load deployed services: {}", .{err});
            return;
        };

        self.reconcileSupervisor(allocator);

        self.ensureServicesRunning();

        log.info("Auto-connected to system DB", .{});
    }

    pub fn loadDeployedServices(self: *AppServices, allocator: std.mem.Allocator) !void {
        _ = allocator;
        const storage = self.storage orelse return;

        var db_list: std.ArrayList(DbEntry) = .empty;
        errdefer db_list.deinit(self.allocator);

        var apps: std.ArrayList(App) = .empty;
        errdefer apps.deinit(self.allocator);

        const app_docs = try storage.listApps();
        defer storage.freeDocuments(app_docs);

        for (app_docs) |app_doc| {
            var bdoc = bson.BsonDocument.init(self.allocator, app_doc.value, false) catch continue;
            defer bdoc.deinit();

            const app_name = (try bdoc.getString("name")) orelse continue;
            const app_port = (bdoc.getInt32("port") catch null) orelse 0;

            try apps.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, app_name),
                .port = @as(u16, @intCast(app_port)),
            });

            const services_arr = (try bdoc.getArray("services")) orelse continue;
            const svc_count = services_arr.len() catch 0;

            for (0..svc_count) |si| {
                const val = (try services_arr.get(si)) orelse continue;
                const svc_data = switch (val) {
                    .document => |d| d.data,
                    else => continue,
                };

                const name = bson_util.getString(self.allocator, svc_data, "name") orelse continue;
                const port = bson_util.getInt32(self.allocator, svc_data, "port") orelse continue;
                const host = bson_util.getString(self.allocator, svc_data, "host") orelse "127.0.0.1";
                const wasm_port = bson_util.getInt32(self.allocator, svc_data, "wasm_port");

                const label = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ host, port });
                const name_dupe = try self.allocator.dupe(u8, name);
                const host_dupe = try self.allocator.dupe(u8, host);
                const app_dupe = try self.allocator.dupe(u8, app_name);

                try db_list.append(self.allocator, .{
                    .name = name_dupe,
                    .host = host_dupe,
                    .port = @intCast(port),
                    .label = label,
                    .wasm_port = if (wasm_port) |wp| @intCast(wp) else 0,
                    .app = app_dupe,
                });

                const admin_uid = bson_util.getString(self.allocator, svc_data, "admin_uid");
                const admin_key = bson_util.getString(self.allocator, svc_data, "admin_key");
                if (admin_uid != null and admin_key != null) {
                    self.pool.register(name, host, @intCast(port), admin_uid.?, admin_key.?) catch |err| {
                        log.warn("failed to register '{s}' in pool: {}", .{ name, err });
                        continue;
                    };
                    self.pool.setRole(name, "admin");
                }
            }
        }

        for (self.apps) |app| {
            self.allocator.free(app.name);
        }
        if (self.apps.len > 0) self.allocator.free(self.apps);
        self.apps = try apps.toOwnedSlice(self.allocator);

        for (self.databases) |entry| {
            self.allocator.free(@constCast(entry.name));
            self.allocator.free(@constCast(entry.host));
            self.allocator.free(@constCast(entry.label));
            if (entry.app.len > 0) self.allocator.free(@constCast(entry.app));
        }
        if (self.databases.len > 0) self.allocator.free(self.databases);

        self.databases = try db_list.toOwnedSlice(self.allocator);
    }

    pub fn loadDeployedApps(self: *AppServices, allocator: std.mem.Allocator) !void {
        const storage = self.storage orelse return;

        var apps: std.ArrayList(*App) = .empty;
        errdefer apps.deinit(self.allocator);

        const app_docs = try storage.listApps();
        defer storage.freeDocuments(app_docs);

        for (app_docs) |app_doc| {
            var bdoc = bson.BsonDocument.init(self.allocator, app_doc.value, false) catch continue;
            defer bdoc.deinit();

            const app_name = (try bdoc.getString("name")) orelse continue;

            const services_arr = (try bdoc.getArray("services")) orelse continue;
            const svc_count = services_arr.len() catch 0;

            var app = try App.init(allocator, app_name);

            for (0..svc_count) |si| {
                const val = (try services_arr.get(si)) orelse continue;
                const svc_data = switch (val) {
                    .document => |d| d.data,
                    else => continue,
                };

                const name = bson_util.getString(self.allocator, svc_data, "name") orelse continue;
                const port = bson_util.getInt32(self.allocator, svc_data, "port") orelse continue;
                const host = bson_util.getString(self.allocator, svc_data, "host") orelse "127.0.0.1";
                const wasm_port = bson_util.getInt32(self.allocator, svc_data, "wasm_port");

                const label = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ host, port });
                const name_dupe = try self.allocator.dupe(u8, name);
                const host_dupe = try self.allocator.dupe(u8, host);

                try app.addService(self.allocator, .{
                    .name = name_dupe,
                    .host = host_dupe,
                    .port = @intCast(port),
                    .label = label,
                    .wasm_port = if (wasm_port) |wp| @intCast(wp) else 0,
                });

                const admin_uid = bson_util.getString(self.allocator, svc_data, "admin_uid");
                const admin_key = bson_util.getString(self.allocator, svc_data, "admin_key");
                if (admin_uid != null and admin_key != null) {
                    self.pool.register(name, host, @intCast(port), admin_uid.?, admin_key.?) catch |err| {
                        log.warn("failed to register '{s}' in pool: {}", .{ name, err });
                        continue;
                    };
                    self.pool.setRole(name, "admin");
                }
            }
        }

        for (self.apps) |app| {
            app.deinit(allocator);
            allocator.destroy(app);
        }
        if (self.apps.len > 0) self.allocator.free(self.apps);

        self.apps = try apps.toOwnedSlice(self.allocator);
    }

    fn reconcileSupervisor(self: *AppServices, allocator: std.mem.Allocator) void {
        var sc = ServiceControl.init(allocator);

        const svc_prefix = std.fmt.allocPrint(allocator, "{s}svc{s}", .{
            sc_labels.PREFIX,
            if (builtin.os.tag == .linux) "-" else ".",
        }) catch return;
        defer allocator.free(svc_prefix);

        const svc_units = sc.listMatching(self.io, svc_prefix) catch &.{};
        defer {
            for (svc_units) |u| allocator.free(u);
            allocator.free(svc_units);
        }

        var expected_svcs: std.StringHashMap(void) = .init(allocator);
        defer {
            var it = expected_svcs.iterator();
            while (it.next()) |e| allocator.free(e.key_ptr.*);
            expected_svcs.deinit();
        }

        for (self.databases) |entry| {
            const lbl = sc_labels.service(allocator, entry.app, entry.name) catch continue;
            expected_svcs.put(lbl, {}) catch {
                allocator.free(lbl);
                continue;
            };
        }

        for (svc_units) |unit| {
            if (expected_svcs.contains(unit)) continue;
            log.warn("reconcile: orphan svc unit '{s}' — stopping + unregistering", .{unit});
            sc.stop(self.io, unit) catch {};
            sc.unregister(self.io, unit) catch {};
        }

        const app_prefix = std.fmt.allocPrint(allocator, "{s}app{s}", .{
            sc_labels.PREFIX,
            if (builtin.os.tag == .linux) "-" else ".",
        }) catch return;
        defer allocator.free(app_prefix);

        const app_units = sc.listMatching(self.io, app_prefix) catch &.{};
        defer {
            for (app_units) |u| allocator.free(u);
            allocator.free(app_units);
        }

        var expected_apps: std.StringHashMap(void) = .init(allocator);
        defer {
            var it = expected_apps.iterator();
            while (it.next()) |e| allocator.free(e.key_ptr.*);
            expected_apps.deinit();
        }

        const apps_dir_path = std.fmt.allocPrint(allocator, "{s}/apps", .{
            self.service_manager.?.data_dir,
        }) catch return;
        defer allocator.free(apps_dir_path);

        if (std.Io.Dir.openDir(.cwd(), self.io, apps_dir_path, .{ .iterate = true })) |*apps_dir_var| {
            var apps_dir = apps_dir_var.*;
            defer apps_dir.close(self.io);
            var iter = apps_dir.iterate();
            while (iter.next(self.io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                const lbl = sc_labels.shellApp(allocator, entry.name) catch continue;
                expected_apps.put(lbl, {}) catch {
                    allocator.free(lbl);
                    continue;
                };
            }
        } else |_| {}

        for (app_units) |unit| {
            if (expected_apps.contains(unit)) continue;
            log.warn("reconcile: orphan app unit '{s}' — stopping + unregistering", .{unit});
            sc.stop(self.io, unit) catch {};
            sc.unregister(self.io, unit) catch {};
        }
    }

    fn ensureServicesRunning(self: *AppServices) void {
        const svc_mgr = self.service_manager orelse return;

        for (self.databases) |entry| {
            if (std.mem.eql(u8, entry.name, "systemdb")) continue;


            const svc_status = svc_mgr.status(entry.app, entry.name) catch {
                log.warn("ensureServicesRunning: status check failed for '{s}'", .{entry.name});
                continue;
            };

            if (svc_status.state == .running) {
                log.info("ensureServicesRunning: '{s}' already running (pid={d})", .{
                    entry.name, svc_status.pid orelse 0,
                });
                continue;
            }

            log.info("ensureServicesRunning: spawning '{s}' (app='{s}')", .{ entry.name, entry.app });
            svc_mgr.start(entry.app, entry.name) catch |err| {
                log.warn("ensureServicesRunning: failed to start '{s}': {}", .{ entry.name, err });
                continue;
            };
            self.waitForPort("127.0.0.1", entry.port, 10) catch {
                log.warn("ensureServicesRunning: '{s}' not ready after timeout", .{entry.name});
            };
        }
    }

    pub fn shutdownDeployedApps(self: *AppServices) !void {
        const app_mgr = self.app_manager orelse return;
        const storage = self.storage orelse return;

        const docs = storage.listApps() catch {
            log.warn("shutdownDeployedApps: listApps failed", .{});
            return;
        };
        defer storage.freeDocuments(docs);

        for (docs) |doc| {
            var bdoc = bson.BsonDocument.init(self.allocator, doc.value, false) catch continue;
            defer bdoc.deinit();
            const name = (bdoc.getString("name") catch null) orelse continue;
            app_mgr.stop(name) catch |err| {
                log.warn("shutdownDeployedApps: stop '{s}' failed: {}", .{ name, err });
            };
        }
    }



    const Credentials = struct { uid: []const u8, key: []const u8 };

    fn credentialsPath(self: *AppServices) ![]const u8 {
        const data_dir = self.wb_config.data_dir;
        return try std.fmt.allocPrint(self.allocator, "{s}/.credentials", .{data_dir});
    }

    pub fn clearCredentials(self: *AppServices) void {
        const path = self.credentialsPath() catch return;
        defer self.allocator.free(path);
        std.Io.Dir.deleteFile(.cwd(), self.io, path) catch {};
    }

    pub fn disconnectAll(self: *AppServices) void {
        log.warn("disconnectAll called - tearing down all connections", .{});
        if (self.storage) |st| {
            st.deinit();
            self.storage = null;
        }
        self.clearCredentials();
    }

    pub fn saveCredentials(self: *AppServices, uid: []const u8, key: []const u8) !void {
        const path = try self.credentialsPath();
        defer self.allocator.free(path);

        const content = try std.fmt.allocPrint(self.allocator, "{s}\n{s}\n", .{ uid, key });
        defer self.allocator.free(content);

        try std.Io.Dir.writeFile(.cwd(), self.io, .{ .sub_path = path, .data = content });
    }

    pub fn loadCredentials(self: *AppServices) !Credentials {
        const path = try self.credentialsPath();
        defer self.allocator.free(path);

        const content = try std.Io.Dir.readFileAlloc(.cwd(), self.io, path, self.allocator, .unlimited);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        const uid_line = lines.next() orelse return error.InvalidCredentials;
        const key_line = lines.next() orelse return error.InvalidCredentials;

        if (uid_line.len == 0 or key_line.len == 0) return error.InvalidCredentials;

        return .{
            .uid = try self.allocator.dupe(u8, uid_line),
            .key = try self.allocator.dupe(u8, key_line),
        };
    }


    pub fn connectDb(self: *AppServices, index: usize, uid: []const u8, key: []const u8) !ConnectResult {
        if (index >= self.databases.len) return error.InvalidIndex;

        const entry = &self.databases[index];

        try self.pool.register(entry.name, entry.host, entry.port, uid, key);

        const conn = self.pool.acquire(entry.name) catch |err| {
            self.pool.unregister(entry.name);
            return err;
        };

        const role = self.detectRole(conn.client, uid);
        self.pool.release(entry.name, false);
        self.pool.setRole(entry.name, role);

        log.info("Connected to {s} as {s} (role: {s})", .{ entry.label, uid, role });
        return ConnectResult{ .role = role };
    }

    pub fn disconnectDb(self: *AppServices, index: usize) void {
        if (index >= self.databases.len) return;
        const entry = &self.databases[index];
        self.pool.unregister(entry.name);
    }

    pub fn disconnectByName(self: *AppServices, name: []const u8) void {
        self.pool.disconnect(name);
    }

    pub fn getPortForService(self: *AppServices, name: []const u8) u16 {
        return self.pool.getPort(name);
    }

    pub fn resolveApp(self: *AppServices, service_name: []const u8) []const u8 {
        for (self.databases) |entry| {
            if (std.mem.eql(u8, entry.name, service_name)) return entry.app;
        }
        return "";
    }

    pub fn fanOutSaveToken(self: *AppServices, args: struct {
        app: []const u8,
        uid: []const u8,
        provider: []const u8,
        token: []const u8,
        expires_at: i64,
        claims: ?[]const u8 = null,
        role: []const u8,
        client_ip: ?[]const u8 = null,
    }) void {
        for (self.databases) |entry| {
            if (!std.mem.eql(u8, entry.app, args.app)) continue;
            const conn = self.pool.acquire(entry.name) catch continue;
            defer self.pool.release(entry.name, false);
            conn.client.adminSaveToken(.{
                .app = args.app,
                .uid = args.uid,
                .provider = args.provider,
                .token = args.token,
                .expires_at = args.expires_at,
                .claims = args.claims,
                .role = args.role,
                .client_ip = args.client_ip,
            }) catch {
                log.err("fanOutSaveToken: failed for service '{s}'", .{entry.name});
            };
        }
    }

    pub fn handleTokenRefresh(self: *AppServices, args: struct {
        app: []const u8,
        old_token: []const u8,
        new_token: []const u8,
        uid: []const u8,
        provider: []const u8,
        expires_at: i64,
        claims: ?[]const u8 = null,
        role: []const u8,
        client_ip: ?[]const u8 = null,
    }) void {
        self.fanOutRevokeToken(args.app, args.old_token);
        self.fanOutSaveToken(.{
            .app = args.app,
            .uid = args.uid,
            .provider = args.provider,
            .token = args.new_token,
            .expires_at = args.expires_at,
            .claims = args.claims,
            .role = args.role,
            .client_ip = args.client_ip,
        });
    }

    pub fn fanOutRevokeToken(self: *AppServices, app: []const u8, token: []const u8) void {
        for (self.databases) |entry| {
            if (!std.mem.eql(u8, entry.app, app)) continue;
            const conn = self.pool.acquire(entry.name) catch continue;
            defer self.pool.release(entry.name, false);
            conn.client.adminRevokeToken(app, token) catch {
                log.err("fanOutRevokeToken: failed for service '{s}'", .{entry.name});
            };
        }
    }

    fn detectRole(self: *AppServices, client: *PlacnkClient, uid: []const u8) []const u8 {
        const bson_data = client.list(.User, null) catch {
            return "read_only";
        };
        defer self.allocator.free(bson_data);

        const json_str = bson.toJson(self.allocator, bson_data) catch {
            return "read_only";
        };
        defer self.allocator.free(json_str);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_str, .{}) catch {
            return "read_only";
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.get("users")) |users_val| {
                if (users_val == .array) {
                    for (users_val.array.items) |item| {
                        if (item == .object) {
                            const uname = if (item.object.get("username")) |u| (if (u == .string) u.string else null) else null;
                            if (uname) |name| {
                                if (std.mem.eql(u8, name, uid)) {
                                    if (item.object.get("role")) |r| {
                                        if (r == .integer) return switch (r.integer) {
                                            0 => "admin",
                                            1 => "read_write",
                                            2 => "read_only",
                                            else => "none",
                                        };
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return "read_only";
    }

    pub fn deinit(self: *AppServices, allocator: std.mem.Allocator) void {
        if (self.service_manager) |sm| sm.deinit();
        if (self.storage) |st| st.deinit();
        self.pool.deinit();
        for (self.databases) |entry| {
            allocator.free(@constCast(entry.name));
            allocator.free(@constCast(entry.host));
            allocator.free(@constCast(entry.label));
        }
        if (self.databases.len > 0) allocator.free(self.databases);
        self.logger.deinit();
        allocator.destroy(self.logger);
        allocator.destroy(self);
    }


};

test "service kind serializes to its bson string" {
    try std.testing.expectEqualStrings("wasm", ServiceKind.wasm.toBsonStr());
    try std.testing.expectEqualStrings("sse_hub", ServiceKind.sse.toBsonStr());
}

test "service kind parses back from its bson string" {
    try std.testing.expectEqual(ServiceKind.wasm, ServiceKind.fromBsonStr("wasm").?);
    try std.testing.expectEqual(ServiceKind.sse, ServiceKind.fromBsonStr("sse_hub").?);
}

test "service kind is null for an unknown string" {
    try std.testing.expect(ServiceKind.fromBsonStr("redis") == null);
}
