const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const planck = @import("planck");
const PlanckClient = planck.PlanckClient;
const Cron = planck.utils.Cron;
const Now = planck.utils.Now;
const bson = planck.bson;

const bson_util = @import("bson_util.zig");
const WbStorage = @import("storage.zig").WbStorage;
const AppServices = @import("services.zig").AppServices;
const backup_orch = @import("backup_orch.zig");
const service_manager_mod = @import("service_manager.zig");
const ServiceManager = service_manager_mod.ServiceManager;
const ProcessMetrics = service_manager_mod.ProcessMetrics;
const utils_backup = @import("utils").backup;

const log = std.log.scoped(.scheduler);

const watchdog_max_failures = 5;

const watchdog_max_backoff_ms: i64 = 60_000;

pub const HealthState = enum {
    running,
    degraded,
    crashed,
    failed,

    pub fn label(self: HealthState) []const u8 {
        return @tagName(self);
    }
};

pub const MetricsSnapshot = struct {
    ts: i64 = 0,
    cpu_percent: f64 = 0.0,
    rss_mb: f64 = 0.0,
};

const METRICS_HISTORY_SIZE = 360;

pub const ServiceMetrics = struct {
    rss_bytes: u64 = 0,
    cpu_percent: f64 = 0.0,
    prev_cpu_time_us: u64 = 0,
    prev_tick_ms: i64 = 0,
    history: [METRICS_HISTORY_SIZE]MetricsSnapshot = [_]MetricsSnapshot{.{}} ** METRICS_HISTORY_SIZE,
    history_len: usize = 0,
    history_start: usize = 0,
};

const WatchdogEntry = struct {
    name: []const u8,
    app: []const u8 = "",
    uid: []const u8 = "",
    key: []const u8 = "",
    port: u16 = 0,
    consecutive_failures: u32 = 0,
    backoff_ms: i64 = 0,
    failed: bool = false,
    stats_failures: u32 = 0,
};

const stats_max_failures: u32 = 3;

pub const Scheduler = struct {
    allocator: Allocator,
    io: Io,
    storage: ?*WbStorage,
    service_manager: ?*ServiceManager,
    app_services: ?*anyopaque = null,
    check_interval_ms: i64,
    group: Io.Group,
    watchdog_entries: std.ArrayList(WatchdogEntry),
    metrics: std.StringHashMap(ServiceMetrics),

    pub fn init(
        allocator: Allocator,
        io: Io,
        storage: ?*WbStorage,
        service_manager: ?*ServiceManager,
        check_interval_ms: i64
    ) !*Scheduler {
        const self = try allocator.create(Scheduler);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .storage = storage,
            .service_manager = service_manager,
            .app_services = null,
            .check_interval_ms = if (check_interval_ms > 0) check_interval_ms else 60000,
            .group = Io.Group.init,
            .watchdog_entries = .empty,
            .metrics = std.StringHashMap(ServiceMetrics).init(allocator),
        };
        return self;
    }

    pub fn setAppServices(self: *Scheduler, services_ptr: *anyopaque) void {
        self.app_services = services_ptr;
    }

    pub fn deinit(self: *Scheduler) void {
        self.group.cancel(self.io);
        
        for (self.watchdog_entries.items) |entry| {
            self.allocator.free(entry.name);
            if (entry.app.len > 0) self.allocator.free(entry.app);
        }
        self.watchdog_entries.deinit(self.allocator);
        self.metrics.deinit();
        self.allocator.destroy(self);
    }

    pub fn watchService(self: *Scheduler, name: []const u8) !void {
        self.watchServiceWithApp("", name, 0, "", "") catch {};
    }

    pub fn watchServiceWithApp(self: *Scheduler, app: []const u8, name: []const u8) !void {
        for (self.watchdog_entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return;
        }
        try self.watchdog_entries.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .app = if (app.len > 0) try self.allocator.dupe(u8, app) else "",
        });
    }

    pub fn startTasks(self: *Scheduler) void {
        log.info("scheduler started (interval: {}ms)", .{self.check_interval_ms});
        self.group.async(self.io, runLoop, .{self});
    }

    fn runLoop(self: *Scheduler) Io.Cancelable!void {
        while (true) {
            self.tick() catch |err| {
                log.err("scheduler tick failed: {}", .{err});
            };

            self.io.sleep(Io.Duration.fromMilliseconds(@intCast(self.check_interval_ms)), .awake) catch |err| {
                if (err == error.Canceled) return error.Canceled;
            };
        }
    }

    fn tick(self: *Scheduler) !void {
        self.watchdogTick();

        const storage = self.storage orelse {
            log.warn("tick: storage is null, skipping schedule scan", .{});
            return;
        };

        const now_ms = (Now{ .io = self.io }).toMilliSeconds();

        const docs = storage.list(WbStorage.STORE_SCHEDULES) catch |err| {
            log.err("failed to list schedules: {}", .{err});
            return;
        };
        defer storage.freeDocuments(@constCast(docs));

        log.info("tick: found {d} schedule docs, now_ms={d}", .{ docs.len, now_ms });

        for (docs) |doc| {
            const enabled = bson_util.getBool(self.allocator, doc.value, "enabled") orelse false;
            if (!enabled) continue;

            const next_run = bson_util.getInt64(self.allocator, doc.value, "next_run_at") orelse 0;
            const name = bson_util.getString(self.allocator, doc.value, "name") orelse "?";
            const task_type = bson_util.getString(self.allocator, doc.value, "task_type") orelse continue;

            const target = if (std.mem.eql(u8, task_type, "backup"))
                (bson_util.getString(self.allocator, doc.value, "app") orelse {
                    log.warn("tick: schedule '{s}' is a backup task but has no 'app' field", .{name});
                    continue;
                })
            else
                (bson_util.getString(self.allocator, doc.value, "service") orelse {
                    log.warn("tick: schedule '{s}' has no 'service' field", .{name});
                    continue;
                });

            if (next_run != 0 and now_ms < next_run) {
                log.info("tick: schedule '{s}' not due yet (next_run={d}, now={d})", .{ name, next_run, now_ms });
                continue;
            }

            log.info("executing schedule '{s}' (type: {s}, target: {s})", .{ name, task_type, target });

            self.executeTask(target, task_type, doc.value) catch |err| {
                log.err("schedule '{s}' failed: {}", .{ name, err });
            };

            self.updateNextRun(doc.key, doc.value, now_ms) catch |err| {
                log.err("failed to update next_run for '{s}': {}", .{ name, err });
            };
        }
    }

    fn executeTask(self: *Scheduler, service_name: []const u8, task_type: []const u8, schedule_data: []const u8) !void {
        if (std.mem.eql(u8, task_type, "backup")) {
            try self.executeBackup(service_name, schedule_data);
        } else if (std.mem.eql(u8, task_type, "gc")) {
            try self.executeGc(service_name);
        } else if (std.mem.eql(u8, task_type, "stats")) {
            try self.executeStats(service_name);
        } else if (std.mem.eql(u8, task_type, "restore")) {
            try self.executeRestore(service_name, schedule_data);
        } else if (std.mem.eql(u8, task_type, "truncate")) {
            try self.executeTruncate(service_name);
        } else if (std.mem.eql(u8, task_type, "export")) {
            try self.executeExport(service_name, schedule_data);
        } else if (std.mem.eql(u8, task_type, "import")) {
            try self.executeImport(service_name, schedule_data);
        } else {
            log.warn("unknown task_type: {s}", .{task_type});
        }
    }


    fn watchdogTick(self: *Scheduler) void {
        const svc_mgr = self.service_manager orelse return;

        for (self.watchdog_entries.items) |*entry| {
            if (entry.failed) continue;

            const svc_status = svc_mgr.status(entry.app, entry.name) catch {
                log.warn("watchdog: status check failed for '{s}'", .{entry.name});
                continue;
            };

            if (svc_status.state == .running) {
                if (entry.consecutive_failures > 0) {
                    log.info("watchdog: '{s}' recovered after {d} restart attempts", .{ entry.name, entry.consecutive_failures });
                    entry.consecutive_failures = 0;
                    entry.backoff_ms = 0;
                }

                if (svc_status.pid) |pid| {
                    const pm = service_manager_mod.getProcessMetrics(pid);
                    const now_ms = (Now{ .io = self.io }).toMilliSeconds();

                    const gop = self.metrics.getOrPut(entry.name) catch continue;
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{};
                    }

                    var m = gop.value_ptr;
                    m.rss_bytes = pm.rss_bytes;

                    if (m.prev_tick_ms > 0 and m.prev_cpu_time_us > 0) {
                        const dt_ms = now_ms - m.prev_tick_ms;
                        if (dt_ms > 0) {
                            const cpu_delta_us = pm.cpu_time_us -| m.prev_cpu_time_us;
                            const dt_us: u64 = @intCast(dt_ms * 1000);
                            m.cpu_percent = @as(f64, @floatFromInt(cpu_delta_us)) / @as(f64, @floatFromInt(dt_us)) * 100.0;
                        }
                    }
                    m.prev_cpu_time_us = pm.cpu_time_us;
                    m.prev_tick_ms = now_ms;

                    const idx = (m.history_start + m.history_len) % METRICS_HISTORY_SIZE;
                    m.history[idx] = .{
                        .ts = now_ms,
                        .cpu_percent = m.cpu_percent,
                        .rss_mb = @as(f64, @floatFromInt(m.rss_bytes)) / (1024.0 * 1024.0),
                    };
                    if (m.history_len < METRICS_HISTORY_SIZE) {
                        m.history_len += 1;
                    } else {
                        m.history_start = (m.history_start + 1) % METRICS_HISTORY_SIZE;
                    }
                }

                if (entry.stats_failures < stats_max_failures) {
                    if (self.executeStats(entry.name)) {
                        if (entry.stats_failures > 0) {
                            log.info("watchdog: '{s}' stats recovered after {d} failures", .{ entry.name, entry.stats_failures });
                            entry.stats_failures = 0;
                        }
                    } else |err| {
                        entry.stats_failures += 1;
                        if (entry.stats_failures == stats_max_failures) {
                            log.warn("watchdog: '{s}' stats disabled after {d} consecutive failures ({}). Will resume on next redeploy. See gaps.md §4.1c.", .{ entry.name, entry.stats_failures, err });
                        } else {
                            log.warn("watchdog: auto-stats for '{s}' failed (attempt {d}/{d}): {}", .{ entry.name, entry.stats_failures, stats_max_failures, err });
                        }
                    }
                }

                continue;
            }

            entry.consecutive_failures += 1;

            if (entry.consecutive_failures > watchdog_max_failures) {
                log.err("watchdog: '{s}' failed {d} consecutive times, giving up", .{ entry.name, entry.consecutive_failures });
                entry.failed = true;
                continue;
            }

            if (entry.backoff_ms == 0) {
                entry.backoff_ms = 1000;
            } else {
                entry.backoff_ms = @min(entry.backoff_ms * 2, watchdog_max_backoff_ms);
            }

            log.info("watchdog: '{s}' is down (attempt {d}/{d}), restarting in {d}ms", .{
                entry.name, entry.consecutive_failures, watchdog_max_failures, entry.backoff_ms,
            });

            self.io.sleep(Io.Duration.fromMilliseconds(entry.backoff_ms), .awake) catch {};

            svc_mgr.start(entry.app, entry.name) catch |err| {
                log.err("watchdog: failed to restart '{s}': {}", .{ entry.name, err });
            };
        }
    }

    pub fn getHealthState(self: *Scheduler, name: []const u8) HealthState {
        const svc_mgr = self.service_manager orelse return .running;

        var app: []const u8 = "";
        for (self.watchdog_entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                if (entry.failed) return .failed;
                if (entry.consecutive_failures > 0) return .crashed;
                app = entry.app;
                break;
            }
        }

        const svc_status = svc_mgr.status(app, name) catch return .degraded;
        return if (svc_status.state == .running) .running else .crashed;
    }

    pub fn getServiceMetrics(self: *Scheduler, name: []const u8) ?ServiceMetrics {
        return self.metrics.get(name);
    }

    pub fn getMetricsHistoryJson(self: *Scheduler, allocator: Allocator, name: []const u8) ![]const u8 {
        const m = self.metrics.get(name) orelse return try allocator.dupe(u8, "[]");

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.append(allocator, '[');

        for (0..m.history_len) |i| {
            const idx = (m.history_start + i) % METRICS_HISTORY_SIZE;
            const snap = m.history[idx];
            if (snap.ts == 0) continue;
            if (buf.items.len > 1) try buf.append(allocator, ',');

            var tmp: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{{\"ts\":{d},\"cpu_percent\":{d:.1},\"rss_mb\":{d:.1}}}", .{ snap.ts, snap.cpu_percent, snap.rss_mb }) catch continue;
            try buf.appendSlice(allocator, s);
        }

        try buf.append(allocator, ']');
        return try allocator.dupe(u8, buf.items);
    }

    pub fn resetWatchdog(self: *Scheduler, name: []const u8) void {
        for (self.watchdog_entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.consecutive_failures = 0;
                entry.backoff_ms = 0;
                entry.failed = false;
                entry.stats_failures = 0;
                return;
            }
        }
    }

    pub fn resetStatsBackoff(self: *Scheduler, name: []const u8) void {
        for (self.watchdog_entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.stats_failures = 0;
                return;
            }
        }
    }

    fn connectToService(self: *Scheduler, service_name: []const u8) !*PlanckClient {
        const storage = self.storage orelse return error.ServiceNotFound;

        const svc_doc = blk: {
            const app_docs = storage.listApps() catch return error.ServiceNotFound;
            defer storage.freeDocuments(app_docs);
            for (app_docs) |app_doc| {
                var adoc = bson.BsonDocument.init(self.allocator, app_doc.value, false) catch continue;
                defer adoc.deinit();
                const arr = (adoc.getArray("services") catch null) orelse continue;
                const count = arr.len() catch 0;
                for (0..count) |i| {
                    const val = (arr.get(i) catch null) orelse continue;
                    const sd = switch (val) {
                        .document => |d| d.data,
                        else => continue,
                    };
                    const sn = bson_util.getString(self.allocator, sd, "name") orelse continue;
                    if (std.mem.eql(u8, sn, service_name)) {
                        const dupe = self.allocator.dupe(u8, sd) catch return error.ServiceNotFound;
                        break :blk WbStorage.Document{ .key = 0, .value = dupe };
                    }
                }
            }
            return error.ServiceNotFound;
        };
        defer self.allocator.free(svc_doc.value);

        const admin_uid = bson_util.getString(self.allocator, svc_doc.value, "admin_uid") orelse return error.MissingCredentials;
        const admin_key_val = bson_util.getString(self.allocator, svc_doc.value, "admin_key") orelse return error.MissingCredentials;
        const port = bson_util.getInt32(self.allocator, svc_doc.value, "port") orelse return error.MissingPort;

        const conn_str = try std.fmt.allocPrint(self.allocator, "127.0.0.1:{d};uid={s};key={s}", .{
            port, admin_uid, admin_key_val,
        });
        defer self.allocator.free(conn_str);

        const client = try PlanckClient.init(self.allocator, self.io);
        var auth = client.connect(conn_str) catch |err| {
            client.deinit();
            return err;
        };
        auth.deinit();
        return client;
    }


    fn executeBackup(self: *Scheduler, app_name: []const u8, schedule_data: []const u8) !void {
        const services_ptr = self.app_services orelse {
            log.err("backup schedule for '{s}' has no AppServices reference", .{app_name});
            return error.SchedulerNotWired;
        };
        const services: *AppServices = @ptrCast(@alignCast(services_ptr));

        const backup_dir = bson_util.getString(self.allocator, schedule_data, "backup_path") orelse "";

        const result = backup_orch.backupApp(services, self.allocator, app_name, backup_dir, .scheduled) catch |err| {
            log.err("backup schedule for app '{s}' failed: {}", .{ app_name, err });
            return err;
        };
        defer self.allocator.free(result.output_path);

        log.info("scheduled backup completed for app '{s}' → {s} ({d} bytes)", .{ app_name, result.output_path, result.bytes });
    }

    fn executeGc(self: *Scheduler, service_name: []const u8) !void {
        const client = try self.connectToService(service_name);
        defer {
            client.disconnect();
            client.deinit();
        }

        const mode_result = try client.adminSetMode(false);
        self.allocator.free(mode_result);

        self.io.sleep(Io.Duration.fromMilliseconds(2000), .awake) catch {};

        const gc_result = client.adminCollect("") catch |err| {
            const restore_result = client.adminSetMode(true) catch {
                log.err("CRITICAL: failed to restore online mode for '{s}'", .{service_name});
                return err;
            };
            self.allocator.free(restore_result);
            return err;
        };
        self.allocator.free(gc_result);

        const restore_result = try client.adminSetMode(true);
        self.allocator.free(restore_result);

        log.info("gc completed for '{s}'", .{service_name});
    }

    fn executeStats(self: *Scheduler, service_name: []const u8) !void {
        const client = try self.connectToService(service_name);
        defer {
            client.disconnect();
            client.deinit();
        }

        const stats_data = try client.adminStats(.AllStats);
        defer self.allocator.free(stats_data);

        var doc = bson.BsonDocument.empty(self.allocator);
        defer doc.deinit();

        try doc.putString("service", service_name);
        try doc.putInt64("ts", (Now{ .io = self.io }).toMilliSeconds());
        try doc.put("data", .{ .binary = .{ .subtype = .generic, .data = stats_data } });

        const storage = self.storage orelse return;
        try storage.saveStats(WbStorage.STORE_STATS, doc.toBytes());
        storage.flush();

        log.info("stats snapshot stored for '{s}'", .{service_name});
    }

    fn executeRestore(self: *Scheduler, service_name: []const u8, schedule_data: []const u8) !void {
        const backup_path = bson_util.getString(self.allocator, schedule_data, "backup_path") orelse return error.MissingBackupPath;
        const target_path = bson_util.getString(self.allocator, schedule_data, "target_path") orelse return error.MissingTargetPath;

        const svc_mgr = self.service_manager orelse return error.NoServiceManager;
        const app = self.appForService(service_name);

        svc_mgr.stop(app, service_name) catch |err| {
            log.err("failed to stop '{s}' for restore: {}", .{ service_name, err });
            return err;
        };

        self.io.sleep(Io.Duration.fromMilliseconds(3000), .awake) catch {};

        const client = self.connectToService(service_name) catch |err| {
            log.err("cannot connect to stopped '{s}' for restore, restarting: {}", .{ service_name, err });
            svc_mgr.start(app, service_name) catch {};
            return err;
        };
        defer {
            client.disconnect();
            client.deinit();
        }

        const result = client.adminRestore(backup_path, target_path) catch |err| {
            log.err("restore failed for '{s}', restarting: {}", .{ service_name, err });
            svc_mgr.start(app, service_name) catch {};
            return err;
        };
        self.allocator.free(result);

        svc_mgr.start(app, service_name) catch |err| {
            log.err("CRITICAL: failed to restart '{s}' after restore: {}", .{ service_name, err });
            return err;
        };

        log.info("restore completed for '{s}'", .{service_name});
    }

    fn appForService(self: *Scheduler, name: []const u8) []const u8 {
        for (self.watchdog_entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.app;
        }
        return "";
    }

    fn executeTruncate(self: *Scheduler, service_name: []const u8) !void {
        const client = try self.connectToService(service_name);
        defer {
            client.disconnect();
            client.deinit();
        }

        try client.adminTruncate();

        log.info("wal truncate completed for '{s}'", .{service_name});
    }

    fn executeExport(self: *Scheduler, service_name: []const u8, schedule_data: []const u8) !void {
        const manifest_yaml = bson_util.getString(self.allocator, schedule_data, "manifest") orelse {
            log.err("export schedule for '{s}' missing manifest", .{service_name});
            return error.MissingManifest;
        };

        const client = try self.connectToService(service_name);
        defer {
            client.disconnect();
            client.deinit();
        }

        const now_ms = (Now{ .io = self.io }).toMilliSeconds();
        const resolved = try resolveTemplateVars(self.allocator, manifest_yaml, now_ms);
        defer self.allocator.free(resolved);

        const pql_mod = planck.pql;
        var query_json: ?[]u8 = null;
        defer if (query_json) |qj| self.allocator.free(qj);

        const query_text = extractYamlField(resolved, "query");
        if (query_text) |qt| {
            var ast = pql_mod.parse(self.allocator, qt) catch {
                log.err("export schedule for '{s}': failed to parse PQL query", .{service_name});
                return error.InvalidQuery;
            };
            defer ast.deinit();

            query_json = ast.toJson(self.allocator) catch {
                log.err("export schedule for '{s}': failed to convert query to JSON", .{service_name});
                return error.InvalidQuery;
            };
        }

        const result = try client.adminExportManifest(resolved, query_json);
        defer self.allocator.free(result);

        log.info("export completed for '{s}': {s}", .{ service_name, result });
    }

    fn executeImport(self: *Scheduler, service_name: []const u8, schedule_data: []const u8) !void {
        const manifest_yaml = bson_util.getString(self.allocator, schedule_data, "manifest") orelse {
            log.err("import schedule for '{s}' missing manifest", .{service_name});
            return error.MissingManifest;
        };

        const client = try self.connectToService(service_name);
        defer {
            client.disconnect();
            client.deinit();
        }

        const result = try client.adminImportManifest(manifest_yaml);
        defer self.allocator.free(result);

        log.info("import completed for '{s}': {s}", .{ service_name, result });
    }


    fn updateNextRun(self: *Scheduler, doc_key: u128, old_value: []const u8, now_ms: i64) !void {
        const cron_expr = bson_util.getString(self.allocator, old_value, "cron_expr") orelse return error.MissingCronExpr;

        const cron = Cron.parse(cron_expr) catch return error.InvalidCronExpr;
        const next = cron.nextRunAfter(now_ms) catch return error.CronComputeFailed;

        var doc = bson.BsonDocument.empty(self.allocator);
        defer doc.deinit();

        if (bson_util.getString(self.allocator, old_value, "name")) |v| try doc.putString("name", v);
        if (bson_util.getString(self.allocator, old_value, "app")) |v| try doc.putString("app", v);
        if (bson_util.getString(self.allocator, old_value, "service")) |v| try doc.putString("service", v);
        if (bson_util.getString(self.allocator, old_value, "task_type")) |v| try doc.putString("task_type", v);
        try doc.putString("cron_expr", cron_expr);
        try doc.putBool("enabled", bson_util.getBool(self.allocator, old_value, "enabled") orelse true);
        if (bson_util.getString(self.allocator, old_value, "backup_path")) |v| try doc.putString("backup_path", v);
        if (bson_util.getString(self.allocator, old_value, "target_path")) |v| try doc.putString("target_path", v);
        if (bson_util.getString(self.allocator, old_value, "manifest")) |v| try doc.putString("manifest", v);
        if (bson_util.getString(self.allocator, old_value, "description")) |v| try doc.putString("description", v);
        try doc.putInt64("created_at", bson_util.getInt64(self.allocator, old_value, "created_at") orelse 0);
        try doc.putInt64("updated_at", now_ms);
        try doc.putInt64("last_run_at", now_ms);
        try doc.putInt64("next_run_at", next);

        const storage = self.storage orelse return;
        try storage.update(WbStorage.STORE_SCHEDULES, doc_key, doc.toBytes());
        storage.flush();
    }


};


const ms_per_day: i64 = 86_400_000;

fn resolveTemplateVars(allocator: Allocator, input: []const u8, now_ms: i64) ![]u8 {
    const today = @divFloor(now_ms, ms_per_day) * ms_per_day;

    const vars = [_]struct { key: []const u8, value: i64 }{
        .{ .key = "${today}", .value = today },
        .{ .key = "${yesterday}", .value = today - ms_per_day },
        .{ .key = "${tomorrow}", .value = today + ms_per_day },
        .{ .key = "${now}", .value = now_ms },
        .{ .key = "${week_ago}", .value = now_ms - 7 * ms_per_day },
        .{ .key = "${month_ago}", .value = now_ms - 30 * ms_per_day },
    };

    var result = try allocator.dupe(u8, input);
    errdefer allocator.free(result);

    for (vars) |v| {
        while (std.mem.indexOf(u8, result, v.key)) |idx| {
            var num_buf: [24]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{v.value}) catch break;
            const new_len = result.len - v.key.len + num_str.len;
            const new_buf = try allocator.alloc(u8, new_len);
            @memcpy(new_buf[0..idx], result[0..idx]);
            @memcpy(new_buf[idx..][0..num_str.len], num_str);
            @memcpy(new_buf[idx + num_str.len ..], result[idx + v.key.len ..]);
            allocator.free(result);
            result = new_buf;
        }
    }

    return result;
}

fn extractYamlField(yaml: []const u8, field: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < yaml.len) {
        const line_start = pos;
        while (pos < yaml.len and yaml[pos] != '\n') pos += 1;
        const line = yaml[line_start..pos];
        if (pos < yaml.len) pos += 1;

        if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) continue;

        if (line.len > field.len + 1 and
            std.mem.startsWith(u8, line, field) and
            line[field.len] == ':')
        {
            var val = std.mem.trimStart(u8, line[field.len + 1 ..], &.{ ' ', '\t' });
            val = std.mem.trimEnd(u8, val, &.{ '\r', ' ', '\t' });
            if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                return val[1 .. val.len - 1];
            }
            if (val.len == 0) return null;
            return val;
        }
    }
    return null;
}
