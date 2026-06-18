const std = @import("std");
const Allocator = std.mem.Allocator;
const wasmer = @import("wasmer");
const wasm = wasmer.wasm;
const proto = @import("proto");
const Packet = proto.Packet;
const Operation = proto.Operation;
const Engine = @import("../engine/engine.zig").Engine;
const dispatchOp = @import("../engine/dispatch.zig").dispatch;
const Buffer = @import("utils").Buffer;
const Now = @import("utils").Now;
const StopWatch = @import("utils").StopWatch;
const schnell = @import("schnell");
const upstream_pool_mod = @import("upstream_pool.zig");
const UpstreamPool = upstream_pool_mod.UpstreamPool;
const runtime_mod = @import("runtime.zig");
const WasmRuntime = runtime_mod.WasmRuntime;
const WasmPathMetrics = @import("metrics.zig").WasmPathMetrics;

pub const HostContext = struct {
    engine: *Engine,
    allocator: Allocator,
    io: std.Io,
    memory: ?*wasmer.Memory,
    response_buf: std.ArrayList(u8),
    upstreams: ?*UpstreamPool = null,
    runtime: ?*WasmRuntime = null,
    metrics: ?*WasmPathMetrics = null,

    pub fn init(allocator: Allocator, engine: *Engine, io: std.Io) HostContext {
        return .{
            .engine = engine,
            .allocator = allocator,
            .io = io,
            .memory = null,
            .response_buf = .empty,
            .upstreams = null,
            .metrics = null,
        };
    }

    pub fn deinit(self: *HostContext) void {
        self.response_buf.deinit(self.allocator);
    }
};

const c_callconv = std.builtin.CallingConvention.c;
const EnvCallback = *const fn (
    ?*anyopaque,
    ?*const wasm.ValVec,
    ?*wasm.ValVec,
) callconv(c_callconv) ?*wasm.Trap;
const Finalizer = *const fn (?*anyopaque) callconv(c_callconv) void;

extern "c" fn wasm_functype_new(args: *wasm.ValtypeVec, results: *wasm.ValtypeVec) ?*anyopaque;
extern "c" fn wasm_functype_delete(functype: *anyopaque) void;
extern "c" fn wasm_func_new_with_env(store: *wasmer.Store, functype: ?*anyopaque, callback: EnvCallback, env: ?*anyopaque, finalizer: ?Finalizer) ?*wasmer.Func;
extern "c" fn wasm_valtype_vec_new_uninitialized(out: *wasm.ValtypeVec, size: usize) void;

inline fn ctxFromEnv(env: ?*anyopaque) ?*HostContext {
    const raw = env orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn hostRequestCallback(env: ?*anyopaque, args: ?*const wasm.ValVec, results: ?*wasm.ValVec) callconv(c_callconv) ?*wasm.Trap {
    const log = std.log.scoped(.wasm);
    const ctx = ctxFromEnv(env) orelse return null;
    const mem = ctx.memory orelse return null;
    const mem_data = mem.data();

    const a = args orelse return null;
    const query_ptr: usize = @intCast(@as(u32, @bitCast(a.data[0].of.i32)));
    const query_len: usize = @intCast(@as(u32, @bitCast(a.data[1].of.i32)));
    const dest_ptr: usize = @intCast(@as(u32, @bitCast(a.data[2].of.i32)));
    const dest_cap: usize = @intCast(@as(u32, @bitCast(a.data[3].of.i32)));

    const query_bytes = mem_data[query_ptr .. query_ptr + query_len];

    var sw_total: StopWatch = .{};
    sw_total.start(ctx.io);
    defer if (ctx.metrics) |m| {
        sw_total.stop(ctx.io);
        _ = m.dispatch_ns.fetchAdd(sw_total.elapsedNs(), .monotonic);
        _ = m.dispatch_calls.fetchAdd(1, .monotonic);
    };

    var sw_des: StopWatch = .{};
    sw_des.start(ctx.io);
    const packet = Packet.deserialize(ctx.allocator, query_bytes) catch |err| {
        log.err("host_request: deserialize failed: {s}", .{@errorName(err)});
        setResult(results, -1);
        return null;
    };
    sw_des.stop(ctx.io);
    if (ctx.metrics) |m| _ = m.dispatch_deserialize_ns.fetchAdd(sw_des.elapsedNs(), .monotonic);
    defer Packet.free(ctx.allocator, packet);

    var sw_eng: StopWatch = .{};
    sw_eng.start(ctx.io);
    const reply_op = dispatchOp(ctx.engine, ctx.allocator, ctx.io, &packet.op) catch |err| {
        const op_name = @tagName(packet.op);
        const store_hint: []const u8 = switch (packet.op) {
            .Insert => |x| x.store_ns,
            .BatchInsert => |x| x.store_ns,
            .Update => |x| x.store_ns,
            .Delete => |x| x.store_ns,
            .Query => |x| x.store_ns,
            .Aggregate => |x| x.store_ns,
            .Scan => |x| x.store_ns,
            .Range => |x| x.store_ns,
            else => "?",
        };
        log.err("host_request: dispatch failed: {s} op={s} store='{s}'", .{ @errorName(err), op_name, store_hint });
        setResult(results, -2);
        return null;
    };
    sw_eng.stop(ctx.io);
    if (ctx.metrics) |m| _ = m.dispatch_engine_ns.fetchAdd(sw_eng.elapsedNs(), .monotonic);

    const reply = switch (reply_op) {
        .Reply => |r| r,
        else => {
            Packet.free(ctx.allocator, .{ .checksum = 0, .packet_length = 0, .packet_id = 0, .timestamp = 0, .op = reply_op });
            setResult(results, -2);
            return null;
        },
    };

    const data = reply.data orelse "";
    defer if (reply.data) |d| ctx.allocator.free(d);
    const header_size: usize = 5;
    const total_size = header_size + data.len;

    if (total_size > dest_cap) {
        log.err("host_request: reply {d} bytes exceeds dest_cap {d}", .{ total_size, dest_cap });
        setResult(results, -4);
        return null;
    }

    var sw_rep: StopWatch = .{};
    sw_rep.start(ctx.io);
    mem_data[dest_ptr] = @intFromEnum(reply.status);
    std.mem.writeInt(u32, mem_data[dest_ptr + 1 ..][0..4], @intCast(data.len), .little);
    if (data.len > 0) {
        @memcpy(mem_data[dest_ptr + header_size .. dest_ptr + header_size + data.len], data);
    }
    sw_rep.stop(ctx.io);
    if (ctx.metrics) |m| _ = m.dispatch_reply_write_ns.fetchAdd(sw_rep.elapsedNs(), .monotonic);

    setResult(results, @intCast(total_size));
    return null;
}

fn hostRespondCallback(env: ?*anyopaque, args: ?*const wasm.ValVec, results: ?*wasm.ValVec) callconv(c_callconv) ?*wasm.Trap {
    _ = results;
    const ctx = ctxFromEnv(env) orelse return null;
    const mem = ctx.memory orelse return null;
    const mem_data = mem.data();

    const a = args orelse return null;
    const ptr: usize = @intCast(@as(u32, @bitCast(a.data[0].of.i32)));
    const len: usize = @intCast(@as(u32, @bitCast(a.data[1].of.i32)));

    ctx.response_buf.clearRetainingCapacity();
    ctx.response_buf.appendSlice(ctx.allocator, mem_data[ptr .. ptr + len]) catch {};
    return null;
}

fn hostLogCallback(env: ?*anyopaque, args: ?*const wasm.ValVec, results: ?*wasm.ValVec) callconv(c_callconv) ?*wasm.Trap {
    _ = results;
    const ctx = ctxFromEnv(env) orelse return null;
    const mem = ctx.memory orelse return null;
    const mem_data = mem.data();

    const a = args orelse return null;
    const level: i32 = a.data[0].of.i32;
    const ptr: usize = @intCast(@as(u32, @bitCast(a.data[1].of.i32)));
    const len: usize = @intCast(@as(u32, @bitCast(a.data[2].of.i32)));

    const msg = mem_data[ptr .. ptr + len];
    const log = std.log.scoped(.wasm);
    switch (level) {
        0 => log.debug("{s}", .{msg}),
        1 => log.info("{s}", .{msg}),
        2 => log.warn("{s}", .{msg}),
        else => log.err("{s}", .{msg}),
    }
    return null;
}

fn setResult(results: ?*wasm.ValVec, value: i32) void {
    const r = results orelse return;
    r.data[0] = .{ .kind = .i32, .of = .{ .i32 = value } };
}

fn setResultI64(results: ?*wasm.ValVec, value: i64) void {
    const r = results orelse return;
    r.data[0] = .{ .kind = .i64, .of = .{ .i64 = value } };
}

fn hostNowUnixSCallback(env: ?*anyopaque, args: ?*const wasm.ValVec, results: ?*wasm.ValVec) callconv(c_callconv) ?*wasm.Trap {
    _ = args;
    const ctx = ctxFromEnv(env) orelse return null;
    const now: Now = .{ .io = ctx.io };
    setResultI64(results, now.toSeconds());
    return null;
}

fn hostRandomBytesCallback(env: ?*anyopaque, args: ?*const wasm.ValVec, results: ?*wasm.ValVec) callconv(c_callconv) ?*wasm.Trap {
    _ = results;
    const log = std.log.scoped(.wasm);
    const ctx = ctxFromEnv(env) orelse return null;
    const mem = ctx.memory orelse return null;
    const mem_data = mem.data();

    const a = args orelse return null;
    const dest_ptr: usize = @intCast(@as(u32, @bitCast(a.data[0].of.i32)));
    const len: usize = @intCast(@as(u32, @bitCast(a.data[1].of.i32)));

    const mem_size = mem.size();
    if (dest_ptr + len > mem_size) {
        log.err("host_random_bytes: out-of-bounds ptr={d} len={d} memsize={d}", .{ dest_ptr, len, mem_size });
        return null;
    }

    std.Io.random(ctx.io, mem_data[dest_ptr .. dest_ptr + len]);
    return null;
}

pub fn createHostRequestFunc(store: *wasmer.Store, ctx: *HostContext) !*wasmer.Func {
    var params: wasm.ValtypeVec = undefined;
    wasm_valtype_vec_new_uninitialized(&params, 4);
    params.data[0] = wasm.Valtype.init(.i32);
    params.data[1] = wasm.Valtype.init(.i32);
    params.data[2] = wasm.Valtype.init(.i32);
    params.data[3] = wasm.Valtype.init(.i32);

    var results: wasm.ValtypeVec = undefined;
    wasm_valtype_vec_new_uninitialized(&results, 1);
    results.data[0] = wasm.Valtype.init(.i32);

    const functype = wasm_functype_new(&params, &results) orelse return error.FuncInit;
    defer wasm_functype_delete(functype);

    return wasm_func_new_with_env(store, functype, &hostRequestCallback, ctx, null) orelse return error.FuncInit;
}

pub fn createHostNowUnixSFunc(store: *wasmer.Store, ctx: *HostContext) !*wasmer.Func {
    var params: wasm.ValtypeVec = undefined;
    wasm_valtype_vec_new_uninitialized(&params, 0);

    var results: wasm.ValtypeVec = undefined;
    wasm_valtype_vec_new_uninitialized(&results, 1);
    results.data[0] = wasm.Valtype.init(.i64);

    const functype = wasm_functype_new(&params, &results) orelse return error.FuncInit;
    defer wasm_functype_delete(functype);

    return wasm_func_new_with_env(store, functype, &hostNowUnixSCallback, ctx, null) orelse return error.FuncInit;
}

pub fn createHostRandomBytesFunc(store: *wasmer.Store, ctx: *HostContext) !*wasmer.Func {
    var params: wasm.ValtypeVec = undefined;
    wasm_valtype_vec_new_uninitialized(&params, 2);
    params.data[0] = wasm.Valtype.init(.i32);
    params.data[1] = wasm.Valtype.init(.i32);

    var results: wasm.ValtypeVec = undefined;
    wasm_valtype_vec_new_uninitialized(&results, 0);

    const functype = wasm_functype_new(&params, &results) orelse return error.FuncInit;
    defer wasm_functype_delete(functype);

    return wasm_func_new_with_env(store, functype, &hostRandomBytesCallback, ctx, null) orelse return error.FuncInit;
}

pub fn createHostLogFunc(store: *wasmer.Store, ctx: *HostContext) !*wasmer.Func {
    var params: wasm.ValtypeVec = undefined;
    wasm_valtype_vec_new_uninitialized(&params, 3);
    params.data[0] = wasm.Valtype.init(.i32);
    params.data[1] = wasm.Valtype.init(.i32);
    params.data[2] = wasm.Valtype.init(.i32);

    var results: wasm.ValtypeVec = undefined;
    wasm_valtype_vec_new_uninitialized(&results, 0);

    const functype = wasm_functype_new(&params, &results) orelse return error.FuncInit;
    defer wasm_functype_delete(functype);

    return wasm_func_new_with_env(store, functype, &hostLogCallback, ctx, null) orelse return error.FuncInit;
}

pub fn createHostRespondFunc(store: *wasmer.Store, ctx: *HostContext) !*wasmer.Func {
    var params: wasm.ValtypeVec = undefined;
    wasm_valtype_vec_new_uninitialized(&params, 2);
    params.data[0] = wasm.Valtype.init(.i32);
    params.data[1] = wasm.Valtype.init(.i32);

    var results: wasm.ValtypeVec = undefined;
    wasm_valtype_vec_new_uninitialized(&results, 0);

    const functype = wasm_functype_new(&params, &results) orelse return error.FuncInit;
    defer wasm_functype_delete(functype);

    return wasm_func_new_with_env(store, functype, &hostRespondCallback, ctx, null) orelse return error.FuncInit;
}

fn hostCallServiceCallback(env: ?*anyopaque, args: ?*const wasm.ValVec, results: ?*wasm.ValVec) callconv(c_callconv) ?*wasm.Trap {
    const log = std.log.scoped(.wasm);
    const ctx = ctxFromEnv(env) orelse return null;
    const mem = ctx.memory orelse return null;
    const mem_data = mem.data();

    const a = args orelse return null;
    const svc_ptr: usize = @intCast(@as(u32, @bitCast(a.data[0].of.i32)));
    const svc_len: usize = @intCast(@as(u32, @bitCast(a.data[1].of.i32)));
    const path_ptr: usize = @intCast(@as(u32, @bitCast(a.data[2].of.i32)));
    const path_len: usize = @intCast(@as(u32, @bitCast(a.data[3].of.i32)));
    const method_ptr: usize = @intCast(@as(u32, @bitCast(a.data[4].of.i32)));
    const method_len: usize = @intCast(@as(u32, @bitCast(a.data[5].of.i32)));
    const body_ptr: usize = @intCast(@as(u32, @bitCast(a.data[6].of.i32)));
    const body_len: usize = @intCast(@as(u32, @bitCast(a.data[7].of.i32)));
    const hdr_ptr: usize = @intCast(@as(u32, @bitCast(a.data[8].of.i32)));
    const hdr_len: usize = @intCast(@as(u32, @bitCast(a.data[9].of.i32)));
    const out_ptr: usize = @intCast(@as(u32, @bitCast(a.data[10].of.i32)));
    const out_cap: usize = @intCast(@as(u32, @bitCast(a.data[11].of.i32)));

    const svc = mem_data[svc_ptr..][0..svc_len];
    const path = mem_data[path_ptr..][0..path_len];
    const method = mem_data[method_ptr..][0..method_len];
    const body: ?[]const u8 = if (body_len > 0) mem_data[body_ptr..][0..body_len] else null;
    const headers_blob: []const u8 = if (hdr_len > 0) mem_data[hdr_ptr..][0..hdr_len] else "";

    const pool = ctx.upstreams orelse {
        setResult(results, -1);
        return null;
    };
    const upstream = pool.lookup(svc) orelse {
        setResult(results, -1);
        return null;
    };

    const prev_in_flight = upstream.in_flight.fetchAdd(1, .acq_rel);
    defer _ = upstream.in_flight.fetchSub(1, .acq_rel);
    if (prev_in_flight >= upstream.max_in_flight) {
        setResult(results, -5);
        return null;
    }

    upstream.mutex.lockUncancelable(ctx.io);
    const allow = upstream.breaker.shouldAllow();
    upstream.mutex.unlock(ctx.io);
    if (!allow) {
        setResult(results, -4);
        return null;
    }

    const url = std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ upstream.url, path }) catch {
        setResult(results, -6);
        return null;
    };
    defer ctx.allocator.free(url);

    var hdr_list: std.ArrayList([2][]const u8) = .empty;
    defer hdr_list.deinit(ctx.allocator);
    var saw_content_type = false;
    if (headers_blob.len > 0) {
        var lines = std.mem.splitSequence(u8, headers_blob, "\r\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
            const name = std.mem.trim(u8, trimmed[0..colon], " \t");
            const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
            if (name.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(name, "content-type")) saw_content_type = true;
            hdr_list.append(ctx.allocator, .{ name, value }) catch {
                setResult(results, -6);
                return null;
            };
        }
    }
    if (!saw_content_type) {
        hdr_list.append(ctx.allocator, .{ "Content-Type", "application/json" }) catch {
            setResult(results, -6);
            return null;
        };
    }

    var resp = schnell.Client.requestTimed(ctx.allocator, ctx.io, .{
        .method = method,
        .url = url,
        .body = body,
        .timeout_ms = upstream.timeout_ms,
        .headers = hdr_list.items,
    }) catch |err| {
        upstream.mutex.lockUncancelable(ctx.io);
        upstream.breaker.recordFailure();
        upstream.mutex.unlock(ctx.io);
        const code: i32 = switch (err) {
            error.Timeout => -3,
            else => -6,
        };
        log.warn("host_call_service: {s} {s} failed: {s}", .{ method, url, @errorName(err) });
        setResult(results, code);
        return null;
    };
    defer resp.deinit();

    upstream.mutex.lockUncancelable(ctx.io);
    if (resp.status >= 500) {
        upstream.breaker.recordFailure();
    } else {
        upstream.breaker.recordSuccess();
    }
    upstream.mutex.unlock(ctx.io);

    const total = 4 + resp.body.len;
    if (total > out_cap) {
        setResult(results, -2);
        return null;
    }
    std.mem.writeInt(u32, mem_data[out_ptr..][0..4], resp.status, .little);
    if (resp.body.len > 0) {
        @memcpy(mem_data[out_ptr + 4 ..][0..resp.body.len], resp.body);
    }
    setResult(results, @intCast(total));
    return null;
}

pub fn createHostCallServiceFunc(store: *wasmer.Store, ctx: *HostContext) !*wasmer.Func {
    var params: wasm.ValtypeVec = undefined;
    wasm_valtype_vec_new_uninitialized(&params, 12);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        params.data[i] = wasm.Valtype.init(.i32);
    }

    var results: wasm.ValtypeVec = undefined;
    wasm_valtype_vec_new_uninitialized(&results, 1);
    results.data[0] = wasm.Valtype.init(.i32);

    const functype = wasm_functype_new(&params, &results) orelse return error.FuncInit;
    defer wasm_functype_delete(functype);

    return wasm_func_new_with_env(store, functype, &hostCallServiceCallback, ctx, null) orelse return error.FuncInit;
}
