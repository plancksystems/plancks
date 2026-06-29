const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const wasmer = @import("wasmer");
const Config = @import("../common/config.zig").Config;
const Service = @import("../common/service.zig").Service;
const Engine = @import("../engine/engine.zig").Engine;
const Pool = @import("pool.zig");
const InstancePool = Pool.InstancePool;
const host = @import("host.zig");
const upstream_pool_mod = @import("upstream_pool.zig");
const UpstreamPool = upstream_pool_mod.UpstreamPool;
const WasmPathMetrics = @import("metrics.zig").WasmPathMetrics;
const StopWatch = @import("utils").StopWatch;

pub const WASM_FUEL_PER_CALL: u64 = 2_000_000_000;

fn meteringCost(operator: c_int) callconv(std.builtin.CallingConvention.c) u64 {
    _ = operator;
    return 1;
}

pub const WasmRuntime = struct {
    allocator: Allocator,
    wasm_engine: *wasmer.Engine,
    store: *wasmer.Store,
    module: *wasmer.Module,
    pool: InstancePool,
    db_engine: *Engine,
    io: Io,
    upstreams: ?*UpstreamPool = null,
    metrics: WasmPathMetrics = .{},
    providers_yaml: []const u8,

    pub fn init(allocator: Allocator, config: *const Config, service: *const Service, db_engine: *Engine, io: Io, providers_yaml: []const u8) !*WasmRuntime {
        if (service.name.len == 0) return error.WasmNameNotConfigured;
        const base_name = if (std.mem.indexOf(u8, service.name, ".db.")) |idx| service.name[0..idx] else service.name;

        const wasm_path = try std.fmt.allocPrint(allocator, "{s}/wasm/planck.{s}.wasm", .{ config.base_dir, base_name });
        defer allocator.free(wasm_path);

        const wasm_bytes = Io.Dir.readFileAlloc(.cwd(), io, wasm_path, allocator, .unlimited) catch
            return error.WasmModuleNotFound;
        defer allocator.free(wasm_bytes);

        if (wasm_bytes.len < 1024) return error.WasmModuleTooSmall;

        const wasm_config = try wasmer.Config.init();
        const metering = try wasmer.Metering.init(WASM_FUEL_PER_CALL, meteringCost);
        wasm_config.pushMiddleware(try metering.asMiddleware());
        const wasm_engine = try wasmer.Engine.withConfig(wasm_config);
        errdefer wasm_engine.deinit();

        const store = try wasmer.Store.init(wasm_engine);
        errdefer store.deinit();

        const module = try wasmer.Module.init(store, wasm_bytes);
        errdefer module.deinit();

        const self = try allocator.create(WasmRuntime);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .wasm_engine = wasm_engine,
            .store = store,
            .module = module,
            .pool = undefined,
            .db_engine = db_engine,
            .io = io,
            .providers_yaml = try allocator.dupe(u8, providers_yaml),
        };

        if (service.upstreams.len > 0) {
            self.upstreams = try UpstreamPool.init(allocator, io, service.upstreams);
        }
        errdefer if (self.upstreams) |p| p.deinit();

        self.pool = try InstancePool.init(
            allocator,
            self,
            io,
            service.wasm.min_instances,
            service.wasm.max_instances,
            service.wasm.autoscale,
        );

        self.pool.startReaper();

        return self;
    }

    pub fn handleRequestRaw(self: *WasmRuntime, allocator: Allocator, raw_request: []const u8) ![]const u8 {
        const io = self.io;

        var sw_acq: StopWatch = .{};
        sw_acq.start(io);
        var instance = try self.pool.acquire();
        sw_acq.stop(io);
        _ = self.metrics.pool_acquire_ns.fetchAdd(sw_acq.elapsedNs(), .monotonic);

        const out = try instance.processRaw(allocator, raw_request, &self.metrics);

        var sw_rel: StopWatch = .{};
        sw_rel.start(io);
        self.pool.release(instance);
        sw_rel.stop(io);
        _ = self.metrics.pool_release_ns.fetchAdd(sw_rel.elapsedNs(), .monotonic);

        _ = self.metrics.requests.fetchAdd(1, .monotonic);
        return out;
    }

    pub fn deinit(self: *WasmRuntime) void {
        self.pool.deinit();
        if (self.upstreams) |p| p.deinit();
        self.module.deinit();
        self.store.deinit();
        self.wasm_engine.deinit();
        self.allocator.free(self.providers_yaml);
        self.allocator.destroy(self);
    }
};
