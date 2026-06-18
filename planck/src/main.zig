const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const Config = @import("common/config.zig").Config;
const Service = @import("common/service.zig").Service;
const Engine = @import("engine/engine.zig").Engine;
const Server = @import("tcp/server.zig").Server;
const SecurityManager = @import("storage/security.zig").SecurityManager;
const ReplicationManager = @import("tcp/replication.zig").ReplicationManager;
const ChangeStreamer = @import("change_stream/streamer.zig").ChangeStreamer;
const change_streams = @import("common/change_streams.zig");
const WasmRuntime = @import("wasm/runtime.zig").WasmRuntime;
const wasm_handler = @import("http/wasm_handler.zig");
const schnell = @import("schnell");
const utils = @import("utils");
const Now = utils.Now;
const AppLogger = utils.AppLogger;
const parseLevel = utils.parseLevel;

var log_io: ?Io = null;

var app_logger: AppLogger = undefined;

var logger_ready: bool = false;

var min_log_level: std.log.Level = .info;

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

fn logFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    if (@intFromEnum(message_level) > @intFromEnum(min_log_level)) return;

    const level_str = comptime switch (message_level) {
        .err => "ERROR",
        .warn => " WARN",
        .info => " INFO",
        .debug => "DEBUG",
    };

    const ts: i64 = if (log_io) |io| (Now{ .io = io }).toMilliSeconds() else 0;
    var buf: [2048]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "[{d}][" ++ level_str ++ "][" ++ @tagName(scope) ++ "] ", .{ts}) catch return;
    const body = std.fmt.bufPrint(buf[prefix.len..], format ++ "\n", args) catch return;
    const line = buf[0 .. prefix.len + body.len];

    if (logger_ready) {
        app_logger.write(message_level, line);
    } else if (builtin.os.tag != .windows) {
        _ = std.c.write(2, line.ptr, line.len);
    }
}

fn configDir(io: Io) Io.Dir {
    if (Io.Dir.access(.cwd(), io, "db.yaml", .{})) {
        return .cwd();
    } else |_| {}

    const default_path = switch (builtin.os.tag) {
        .linux, .freebsd => "/var/lib/planck",
        .macos => "/usr/local/var/planck",
        .windows => "C:\\ProgramData\\Planck",
        else => return .cwd(),
    };

    if (Io.Dir.openDir(.cwd(), io, default_path, .{})) |dir| {
        return dir;
    } else |_| {}

    return .cwd();
}

fn startHttpServer(server: *schnell.Server, thr_io: Io) Io.Cancelable!void {
    server.listen(thr_io) catch |err| {
        log.err("HTTP server error: {}", .{err});
    };
}

pub fn main(_: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    defer if (builtin.mode == .Debug) {
        if (gpa.detectLeaks() > 0) {
            std.process.exit(1);
        }
    };

    var threaded: std.Io.Threaded = .init(allocator, .{
        .async_limit = .unlimited,
    });
    defer threaded.deinit();
    const io = threaded.io();
    log_io = io;

    const config_dir = configDir(io);
    var config = Config.load(allocator, io, config_dir) catch |err| {
        log.err("Failed to load config: {}", .{err});
        return err;
    };
    defer config.deinit(allocator);

    var service = Service.load(allocator, io, config_dir) catch |err| {
        log.err("Failed to load service.yaml: {}", .{err});
        return err;
    };
    defer service.deinit(allocator);

    min_log_level = parseLevel(config.logging.level);
    if (config.logging.path.len > 0) {
        app_logger.setup(io, config.logging.path, config.logging.max_size_mb, config.logging.max_files);
        logger_ready = true;
    }
    defer {
        if (logger_ready) {
            logger_ready = false;
            app_logger.deinit();
        }
    }

    log.info("Starting Planck....", .{});

    const security_enabled = true;

    const replication: ?*ReplicationManager = if (config.primary == true and config.replica.enabled) blk: {
        const repl = ReplicationManager.init(allocator, io, config) catch |err| {
            log.err("Failed to initialize replication manager: {}", .{err});
            return err;
        };
        repl.startTasks();
        log.info("Replication started - replica {s}:{d}", .{ config.replica.address, config.replica.port });
        break :blk repl;
    } else null;
    defer if (replication) |repl| repl.deinit();

    const stream_stores: ?[]change_streams.StreamStore =
        if (config.change_streams.stores.len > 0)
            change_streams.compile(allocator, config.change_streams) catch |err| {
                log.err("Failed to compile change_streams config: {}", .{err});
                return err;
            }
        else
            null;
    defer if (stream_stores) |ss| change_streams.freeStores(allocator, ss);

    const change_streamer: ?*ChangeStreamer = if (stream_stores) |ss| blk: {
        const cs = ChangeStreamer.init(allocator, io, .{
            .stores = ss,
            .ring_capacity = config.change_streams.ring_capacity,
        }) catch |err| {
            log.err("Failed to initialize change streamer: {}", .{err});
            return err;
        };
        log.info("Change streamer started ({d} stores, ring_capacity {d})", .{ ss.len, config.change_streams.ring_capacity });
        break :blk cs;
    } else null;
    defer if (change_streamer) |cs| cs.deinit();

    const engine = Engine.init(allocator, config, io, replication, change_streamer) catch |err| {
        log.err("Failed to initialize engine: {}", .{err});
        return err;
    };
    defer engine.deinit();

    const wasm_runtime: ?*WasmRuntime = if (service.wasm.enabled) blk: {
        break :blk WasmRuntime.init(allocator, config, service, engine, io) catch |err| {
            log.warn("WASM runtime not ready: {} - DB will start without WASM", .{err});
            break :blk null;
        };
    } else null;
    if (wasm_runtime != null) log.info("WASM runtime initialized - {d} instances pooled", .{service.wasm.max_instances});
    defer if (wasm_runtime) |wrt| wrt.deinit();

    var http_server: ?schnell.Server = if (wasm_runtime) |wrt| blk: {
        var srv = try schnell.Server.init(allocator, service.wasm.http);
        srv.setRawHandler(wasm_handler.handleRaw, @ptrCast(wrt));
        break :blk srv;
    } else null;
    defer if (http_server) |*hs| hs.deinit();

    var http_group: Io.Group = .init;
    if (http_server) |*hs| {
        http_group.async(io, startHttpServer, .{ hs, io });
        log.info("WASM HTTP server listening on :{d}", .{service.wasm.http.port});
    }

    defer if (http_server) |*hs| {
        hs.stop(io);
        http_group.cancel(io);
    };

    var server = Server.init(allocator, config, io, engine, security_enabled, config_dir) catch |err| {
        log.err("Failed to initialize server: {}", .{err});
        return err;
    };
    defer server.deinit();

    server.run() catch |err| {
        log.err("Server error: {}", .{err});
        return err;
    };

    log.info("Shutting down engine...", .{});
    engine.shutdown() catch |err| {
        log.err("Engine shutdown error: {}", .{err});
    };
}
