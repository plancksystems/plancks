const std = @import("std");
const builtin = @import("builtin");
const schnell = @import("schnell");
const utils = @import("utils");
const build_options = @import("build_options");

const AuthMiddleware = @import("middleware/auth.zig").AuthMiddleware;
const LogMiddleware = @import("middleware/log.zig").LogMiddleware;
const CorsMiddleware = schnell.CorsMiddleware;

const AppServices = @import("tasks/services.zig").AppServices;
const WbConfig = @import("tasks/config.zig").WbConfig;
const Scheduler = @import("tasks/scheduler.zig").Scheduler;
const compat = @import("tasks/compat.zig");

var app_logger: utils.AppLogger = undefined;
var logger_ready: bool = false;

var shutdown_app: ?*schnell.App = null;
var shutdown_io: ?std.Io = null;
var shutdown_triggered: std.atomic.Value(bool) = .init(false);

fn shutdownSignalHandler(sig: std.c.SIG) callconv(.c) void {
    _ = sig;
    if (shutdown_triggered.swap(true, .seq_cst)) return;
    const app = shutdown_app orelse return;
    const io = shutdown_io orelse return;
    app.stop(io);
}

fn installShutdownHandlers() void {
    if (comptime builtin.target.os.tag == .windows) return;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = shutdownSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

fn logFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_str = comptime switch (message_level) {
        .err => "ERROR",
        .warn => " WARN",
        .info => " INFO",
        .debug => "DEBUG",
    };

    var buf: [4096]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "[" ++ level_str ++ "][" ++ @tagName(scope) ++ "] ", .{}) catch return;
    const body = std.fmt.bufPrint(buf[prefix.len..], format ++ "\n", args) catch return;
    const line = buf[0 .. prefix.len + body.len];

    if (logger_ready) {
        app_logger.write(message_level, line);
    }
    if (comptime builtin.os.tag != .windows) {
        _ = std.c.write(2, line.ptr, line.len);
    }
}

const system_db_api = @import("api/system_db.zig");
const connect_api = @import("api/connect.zig");
const schema_api = @import("api/schema.zig");
const app_api = @import("api/app.zig");
const app_lifecycle_api = @import("api/app_lifecycle.zig");
const health_api = @import("api/health.zig");
const databases_api = @import("api/databases.zig");
const services_api = @import("api/services.zig");
const left_pane_api = @import("api/left_pane.zig");
const schedule_api = @import("api/schedule.zig");
const deploy_api = @import("api/deploy.zig");
const app_deploy = @import("api/app_deploy.zig");
const query_api = @import("api/query.zig");
const monitor_api = @import("api/monitor.zig");
const logs_api = @import("api/logs.zig");
const admin_api = @import("api/admin.zig");
const exim_api = @import("api/exim.zig");

const Ctx = @import("ctx.zig").Ctx;

const index_html = @embedFile("ui/dist/index.html");
const index_js = @embedFile("ui/dist/index.js");
const index_css = @embedFile("ui/dist/index.css");
const Io = std.Io;

const log = std.log.scoped(.workbench);

var system_db_connected: bool = false;

var wb_ctx: Ctx = undefined;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const cli_args = try init.minimal.args.toSlice(init.arena.allocator());
    var threaded: std.Io.Threaded = .init(allocator, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const io = threaded.io();

    const wb_config = try WbConfig.load(allocator, io);
    defer wb_config.deinit(allocator);

    _ = cli_args;

    const log_path = if (wb_config.logging.path.len > 0)
        wb_config.logging.path
    else
        std.fmt.allocPrint(allocator, "{s}/workbench.log", .{wb_config.data_dir}) catch null;
    if (log_path) |lp| {
        app_logger.setup(io, lp, wb_config.logging.max_size_mb, wb_config.logging.max_files);
        logger_ready = true;
    }
    defer if (logger_ready) app_logger.deinit();

    const config = try allocator.create(compat.Config);
    config.* = .{};
    const services = try AppServices.init(allocator, config, wb_config, io);

    app_deploy.setServices(services);

    services.tryAutoConnect(allocator);
    if (services.storage != null) {
        system_db_connected = true;
    }

    var app = try schnell.App.init(allocator, .{
        .port = wb_config.listen_port,
        .max_body_size = 100 * 1024 * 1024,
    }, &.{});
    defer app.deinit();

    var cors_mw = CorsMiddleware.init(.{});
    try app.use(cors_mw.middleware());

    var log_mw = LogMiddleware{};
    try app.use(log_mw.middleware());

    var auth_mw = AuthMiddleware{ .connected = &system_db_connected };
    try app.use(auth_mw.middleware());

    const serveHtml = struct {
        fn handle(_: std.mem.Allocator, _: *const schnell.Request, res: *schnell.Response, _: ?*anyopaque) anyerror!void {
            try res.setHeader("Content-Type", "text/html");
            try res.write(index_html);
        }
    }.handle;

    const serveJs = struct {
        fn handle(_: std.mem.Allocator, _: *const schnell.Request, res: *schnell.Response, _: ?*anyopaque) anyerror!void {
            try res.setHeader("Content-Type", "application/javascript");
            try res.write(index_js);
        }
    }.handle;

    const serveCss = struct {
        fn handle(_: std.mem.Allocator, _: *const schnell.Request, res: *schnell.Response, _: ?*anyopaque) anyerror!void {
            try res.setHeader("Content-Type", "text/css");
            try res.write(index_css);
        }
    }.handle;

    try app.server.router.get(allocator, "/", serveHtml);
    try app.server.router.get(allocator, "/index.html", serveHtml);
    try app.server.router.get(allocator, "/index.js", serveJs);
    try app.server.router.get(allocator, "/index.css", serveCss);

    app.onResponse(struct {
        fn hook(req: *const schnell.Request, res: *schnell.Response) void {
            if (std.mem.startsWith(u8, req.path, "/api/")) {
                var i: usize = 0;
                while (i < res.headers.items.len) {
                    if (std.ascii.eqlIgnoreCase(res.headers.items[i].name, "Content-Type")) {
                        _ = res.headers.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
                res.setHeader("Content-Type", "application/json") catch {};
            }
        }
    }.hook);

    wb_ctx = .{ .services = services, .connected = &system_db_connected };

    try app.get("/api/health", health_api.handle, &wb_ctx);

    try app.get("/api/system-db/status", system_db_api.handleStatus, &wb_ctx);
    try app.post("/api/system-db/connect", system_db_api.handleConnect, &wb_ctx);
    try app.post("/api/system-db/logout", system_db_api.handleLogout, &wb_ctx);

    try app.post("/api/connect", connect_api.handleConnect, &wb_ctx);
    try app.post("/api/disconnect", connect_api.handleDisconnect, &wb_ctx);
    try app.get("/api/databases", databases_api.handle, &wb_ctx);
    try app.get("/api/services", services_api.handle, &wb_ctx);
    try app.get("/api/left-pane", left_pane_api.handle, &wb_ctx);
    try app.post("/api/schema", schema_api.handle, &wb_ctx);
    try app.post("/api/query", query_api.handle, &wb_ctx);
    try app.post("/api/deploy", deploy_api.handle, &wb_ctx);
    try app.post("/api/admin", admin_api.handle, &wb_ctx);
    try app.get("/api/monitor", monitor_api.handleMonitor, &wb_ctx);
    try app.get("/api/stats", monitor_api.handleStats, &wb_ctx);
    try app.post("/api/monitor/gc", monitor_api.handleGc, &wb_ctx);
    try app.get("/api/logs", logs_api.handle, &wb_ctx);
    try app.get("/api/schedules", schedule_api.handleList, &wb_ctx);
    try app.post("/api/schedules", schedule_api.handleAction, &wb_ctx);
    try app.post("/api/export", exim_api.handleExport, &wb_ctx);
    try app.post("/api/import", exim_api.handleImport, &wb_ctx);
    try app.get("/api/apps", app_api.handleList, &wb_ctx);
    try app.post("/api/apps", app_api.handleCreate, &wb_ctx);
    try app.post("/api/app-lifecycle", app_lifecycle_api.handle, &wb_ctx);

    try app.server.router.post(allocator, "/api/deploy-app", app_deploy.handle);

    var scheduler: ?*Scheduler = null;
    scheduler = Scheduler.init(allocator, io, services.storage, services.service_manager, 60000) catch null;
    if (scheduler) |sched| {
        for (services.databases) |entry| {
            if (std.mem.eql(u8, entry.name, "systemdb")) continue;
            sched.watchServiceWithApp(entry.app, entry.name) catch {};
        }
        services.scheduler = sched;
        sched.setAppServices(services);
        sched.startTasks();
    }
    defer if (scheduler) |sched| sched.deinit();

    services.ready = true;

    shutdown_app = &app;
    shutdown_io = io;
    installShutdownHandlers();

    log.info("Planck Workbench v{s} ready on http://127.0.0.1:{d}", .{ build_options.version, wb_config.listen_port });
    try app.run(io);

    log.info("Shutting down...", .{});
    if (services.service_manager) |svc_mgr| {
        for (services.apps) |a| {
            for (services.databases) |entry| {
                if (std.mem.eql(u8, a.name, entry.app)) {
                    svc_mgr.stop(entry.app, entry.name) catch {};
                }
            }
            if (services.app_manager) |amgr| {
                try amgr.stop(a.name);
            }
        }
    }
    try services.shutdownDeployedApps();
}

test {
    _ = @import("tasks/paths.zig");
    _ = @import("tasks/config.zig");
    _ = @import("tasks/bson_util.zig");
    _ = @import("tasks/storage.zig");
    _ = @import("tasks/services.zig");
    _ = @import("tasks/scheduler.zig");
    _ = @import("tasks/dev_supervisor.zig");
}
