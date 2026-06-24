const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const wasmer = @import("wasmer");
const host = @import("host.zig");
const HostContext = host.HostContext;
const WasmRuntime = @import("runtime.zig").WasmRuntime;
const WASM_FUEL_PER_CALL = @import("runtime.zig").WASM_FUEL_PER_CALL;
const Mutex = @import("utils").Mutex;
const WasmPathMetrics = @import("metrics.zig").WasmPathMetrics;
const StopWatch = @import("utils").StopWatch;
const nowMs = @import("../common/common.zig").nowMs;
const log = std.log.scoped(.wasm);

const WASM_PAGE_BYTES: usize = 64 * 1024;
const MAX_INSTANCE_MEMORY_BYTES: usize = 256 * 1024 * 1024;

const IDLE_TTL_MS: i64 = 60_000;
const REAPER_INTERVAL_MS: i64 = 15_000;

pub const PooledInstance = struct {
    store: *wasmer.Store,
    instance: *wasmer.Instance,
    memory: *wasmer.Memory,
    process_fn: *wasmer.Func,
    context: *HostContext,
    runtime: *WasmRuntime,
    request_count: u32 = 0,
    last_used_ms: i64 = 0,

    pub fn init(runtime: *WasmRuntime) !PooledInstance {
        const store = try wasmer.Store.init(runtime.wasm_engine);
        errdefer store.deinit();
        const module = runtime.module;
        const allocator = runtime.allocator;

        const ctx = try allocator.create(HostContext);
        errdefer allocator.destroy(ctx);
        ctx.* = HostContext.init(allocator, runtime.db_engine, runtime.io);
        errdefer ctx.deinit();
        ctx.upstreams = runtime.upstreams;
        ctx.runtime = runtime;

        const host_respond_fn = try host.createHostRespondFunc(store, ctx);
        const host_request_fn = try host.createHostRequestFunc(store, ctx);
        const host_log_fn = try host.createHostLogFunc(store, ctx);
        const host_call_service_fn = try host.createHostCallServiceFunc(store, ctx);
        const host_now_unix_s_fn = try host.createHostNowUnixSFunc(store, ctx);
        const host_random_bytes_fn = try host.createHostRandomBytesFunc(store, ctx);

        var import_types = module.imports();
        defer import_types.deinit();
        const import_slice = import_types.toSlice();

        const ordered_imports = try allocator.alloc(*wasmer.Func, import_slice.len);
        defer allocator.free(ordered_imports);
        var matched: usize = 0;
        for (import_slice) |maybe_import| {
            const imp = maybe_import orelse continue;
            const name_vec = imp.name();
            const fname = name_vec.toSlice();

            const func: *wasmer.Func = if (std.mem.eql(u8, fname, "host_respond"))
                host_respond_fn
            else if (std.mem.eql(u8, fname, "host_request"))
                host_request_fn
            else if (std.mem.eql(u8, fname, "host_log"))
                host_log_fn
            else if (std.mem.eql(u8, fname, "host_call_service"))
                host_call_service_fn
            else if (std.mem.eql(u8, fname, "host_now_unix_s"))
                host_now_unix_s_fn
            else if (std.mem.eql(u8, fname, "host_random_bytes"))
                host_random_bytes_fn
            else
                continue;

            ordered_imports[matched] = func;
            matched += 1;
        }

        const instance = try wasmer.Instance.init(store, module, ordered_imports[0..matched]);
        errdefer instance.deinit();

        const memory = instance.getExportMem(module, "memory") orelse
            return error.MemoryExportNotFound;

        {
            const declared_max = memory.getType().limits().max;
            if (declared_max == wasmer.LIMITS_MAX_DEFAULT) {
                log.warn("WASM guest declares unbounded memory; per-call growth is not hard-capped (only steady-state recycle at {d} bytes). Rebuild the guest with a max_memory of {d} bytes to enforce a per-call cap.", .{ MAX_INSTANCE_MEMORY_BYTES, MAX_INSTANCE_MEMORY_BYTES });
            } else if (@as(usize, declared_max) * WASM_PAGE_BYTES > MAX_INSTANCE_MEMORY_BYTES) {
                log.err("WASM guest declares memory max {d} pages ({d} bytes) > cap {d} bytes; refusing to load", .{ declared_max, @as(usize, declared_max) * WASM_PAGE_BYTES, MAX_INSTANCE_MEMORY_BYTES });
                return error.WasmMemoryExceedsCap;
            }
        }

        const initial_pages = memory.pages();
        memory.grow(64) catch {};
        const final_pages = memory.pages();
        log.info("WASM memory: {d} → {d} pages ({d}KB → {d}KB)", .{
            initial_pages,      final_pages,
            initial_pages * 64, final_pages * 64,
        });

        const process_fn = instance.getExportFunc(module, "process") orelse
            return error.ProcessExportNotFound;

        ctx.memory = memory;

        if (instance.getExportFunc(module, "init")) |init_fn| {
            defer init_fn.deinit();
            _ = init_fn.call(i32, .{}) catch return error.WasmInitFailed;
        }

        return PooledInstance{
            .store = store,
            .instance = instance,
            .memory = memory,
            .process_fn = process_fn,
            .context = ctx,
            .runtime = runtime,
            .last_used_ms = nowMs(runtime.io),
        };
    }

    pub fn revive(self: *PooledInstance) bool {
        const fresh = PooledInstance.init(self.runtime) catch |err| {
            log.err("WASM instance revive failed: {s}", .{@errorName(err)});
            return false;
        };
        self.* = fresh;
        return true;
    }

    pub fn processRaw(self: *PooledInstance, allocator: Allocator, raw_request: []const u8, metrics: *WasmPathMetrics) ![]const u8 {
        const io = self.runtime.io;

        self.context.metrics = metrics;

        var sw_mem: StopWatch = .{};
        sw_mem.start(io);
        const req_offset: usize = 65536;
        const mem_data = self.memory.data();
        if (req_offset + raw_request.len > self.memory.size()) {
            return error.WasmMemoryTooSmall;
        }
        @memcpy(mem_data[req_offset .. req_offset + raw_request.len], raw_request);
        sw_mem.stop(io);
        _ = metrics.memcpy_in_ns.fetchAdd(sw_mem.elapsedNs(), .monotonic);

        const mem_before = self.memory.size();

        var sw_proc: StopWatch = .{};
        sw_proc.start(io);
        wasmer.Metering.setRemainingPoints(self.instance, WASM_FUEL_PER_CALL);
        const ret = self.process_fn.call(i32, .{
            @as(i32, @intCast(req_offset)),
            @as(i32, @intCast(raw_request.len)),
        }) catch |err| {
            if (wasmer.Metering.pointsExhausted(self.instance)) {
                log.err("WASM guest call exceeded the {d}-instruction fuel budget", .{WASM_FUEL_PER_CALL});
                return error.WasmFuelExhausted;
            }
            log.err("process_fn.call failed: {s}", .{@errorName(err)});
            return err;
        };
        sw_proc.stop(io);
        _ = metrics.process_fn_ns.fetchAdd(sw_proc.elapsedNs(), .monotonic);

        self.request_count += 1;
        const mem_after = self.memory.size();
        if (mem_after != mem_before) {
            log.warn("WASM memory grew: {d}KB → {d}KB (+{d}KB)", .{
                mem_before / 1024, mem_after / 1024, (mem_after - mem_before) / 1024,
            });
        }

        if (ret != 0) {
            log.err("WASM process returned {d}", .{ret});
            return error.WasmProcessFailed;
        }

        const buf = self.context.response_buf.items;
        if (buf.len == 0) {
            return error.EmptyResponse;
        }

        var sw_dupe: StopWatch = .{};
        sw_dupe.start(io);
        const out = try allocator.dupe(u8, buf);
        sw_dupe.stop(io);
        _ = metrics.dupe_response_ns.fetchAdd(sw_dupe.elapsedNs(), .monotonic);
        return out;
    }

    pub fn deinit(self: *PooledInstance) void {
        const allocator = self.runtime.allocator;
        self.context.deinit();
        allocator.destroy(self.context);
        self.instance.deinit();
        self.store.deinit();
    }
};

pub const InstancePool = struct {
    instances: std.ArrayList(PooledInstance),
    in_use: []bool,
    dormant: []bool,
    mutex: Mutex,
    available_signal: std.Io.Condition,
    io: std.Io,
    min_size: u16,
    max_size: u16,
    autoscale: bool,
    runtime: *WasmRuntime,
    allocator: Allocator,
    group: Io.Group,

    pub fn init(allocator: Allocator, runtime: *WasmRuntime, io: std.Io, min_size: u16, max_size: u16, autoscale: bool) !InstancePool {
        const in_use = try allocator.alloc(bool, max_size);
        errdefer allocator.free(in_use);
        @memset(in_use, false);

        const dormant = try allocator.alloc(bool, max_size);
        errdefer allocator.free(dormant);
        @memset(dormant, false);

        var pool = InstancePool{
            .instances = .empty,
            .in_use = in_use,
            .dormant = dormant,
            .mutex = .{},
            .available_signal = .init,
            .io = io,
            .min_size = min_size,
            .max_size = max_size,
            .autoscale = autoscale,
            .runtime = runtime,
            .allocator = allocator,
            .group = Io.Group.init,
        };

        try pool.instances.ensureTotalCapacity(allocator, max_size);

        for (0..min_size) |_| {
            const instance = try PooledInstance.init(runtime);
            try pool.instances.append(allocator, instance);
            runtime.db_engine.engine_metrics.wasm.recordInstanceAdded();
        }

        runtime.db_engine.engine_metrics.wasm.min_instances = min_size;
        runtime.db_engine.engine_metrics.wasm.max_instances = max_size;

        return pool;
    }

    pub fn acquire(self: *InstancePool) !*PooledInstance {
        self.mutex.lock(self.io);

        while (true) {
            const count = self.instances.items.len;

            for (0..count) |idx| {
                if (self.in_use[idx]) continue;
                if (self.dormant[idx]) continue;
                self.in_use[idx] = true;
                self.mutex.unlock(self.io);
                return &self.instances.items[idx];
            }

            for (0..count) |idx| {
                if (!self.dormant[idx]) continue;
                self.dormant[idx] = false;
                self.in_use[idx] = true;
                self.mutex.unlock(self.io);
                if (self.instances.items[idx].revive()) {
                    self.runtime.db_engine.engine_metrics.wasm.recordInstanceAdded();
                    return &self.instances.items[idx];
                }
                self.mutex.lock(self.io);
                self.in_use[idx] = false;
                self.dormant[idx] = true;
                self.available_signal.signal(self.io);
                continue;
            }

            if (self.autoscale and count < self.max_size) {
                self.mutex.unlock(self.io);
                var fresh = PooledInstance.init(self.runtime) catch {
                    self.mutex.lock(self.io);
                    self.available_signal.waitUncancelable(self.io, &self.mutex.impl);
                    continue;
                };
                self.mutex.lock(self.io);
                if (self.instances.items.len >= self.max_size) {
                    self.mutex.unlock(self.io);
                    fresh.deinit();
                    self.mutex.lock(self.io);
                    continue;
                }
                const new_idx = self.instances.items.len;
                self.instances.append(self.allocator, fresh) catch {
                    self.mutex.unlock(self.io);
                    fresh.deinit();
                    return error.NoAvailableInstances;
                };
                self.in_use[new_idx] = true;
                self.runtime.db_engine.engine_metrics.wasm.recordInstanceAdded();
                self.mutex.unlock(self.io);
                return &self.instances.items[new_idx];
            }

            self.available_signal.waitUncancelable(self.io, &self.mutex.impl);
        }
    }

    pub fn release(self: *InstancePool, instance: *PooledInstance) void {
        self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const base = @intFromPtr(self.instances.items.ptr);
        const addr = @intFromPtr(instance);
        const idx = (addr - base) / @sizeOf(PooledInstance);

        if (instance.memory.size() > MAX_INSTANCE_MEMORY_BYTES) {
            log.warn("recycling WASM instance over memory cap: {d} bytes", .{instance.memory.size()});
            instance.deinit();
            self.dormant[idx] = true;
            self.in_use[idx] = false;
            self.available_signal.signal(self.io);
            return;
        }

        instance.last_used_ms = nowMs(self.io);

        self.in_use[idx] = false;
        self.available_signal.signal(self.io);
    }

    pub fn startReaper(self: *InstancePool) void {
        self.group.async(self.io, reaperLoop, .{self});
    }

    fn reaperLoop(self: *InstancePool) Io.Cancelable!void {
        while (true) {
            self.io.sleep(Io.Duration.fromMilliseconds(REAPER_INTERVAL_MS), .awake) catch |err| {
                if (err == error.Canceled) return error.Canceled;
            };
            const reaped = self.reapIdle();
            if (reaped > 0) {
                log.info("WASM reaper: reclaimed {d} idle instance(s)", .{reaped});
            }
        }
    }

    fn reapIdle(self: *InstancePool) usize {
        const now_ms = nowMs(self.io);
        self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        var live: usize = 0;
        for (self.dormant) |d| live += @intFromBool(!d);
        const appended = self.instances.items.len;
        if (live > appended) live = appended;

        var reaped: usize = 0;
        for (self.instances.items, 0..) |*inst, idx| {
            if (live - reaped <= self.min_size) break;
            if (self.in_use[idx]) continue;
            if (self.dormant[idx]) continue;
            if (now_ms - inst.last_used_ms < IDLE_TTL_MS) continue;

            inst.deinit();
            self.dormant[idx] = true;
            self.runtime.db_engine.engine_metrics.wasm.recordInstanceRemoved();
            reaped += 1;
        }
        return reaped;
    }

    pub fn deinit(self: *InstancePool) void {
        self.group.cancel(self.io);
        for (self.instances.items, 0..) |*inst, idx| {
            if (self.dormant[idx]) continue;
            inst.deinit();
        }
        self.instances.deinit(self.allocator);
        self.allocator.free(self.in_use);
        self.allocator.free(self.dormant);
    }
};
