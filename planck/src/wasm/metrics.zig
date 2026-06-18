
const std = @import("std");

pub const WasmPathMetrics = struct {
    requests: std.atomic.Value(u64) = .{ .raw = 0 },

    pool_acquire_ns: std.atomic.Value(u64) = .{ .raw = 0 },
    memcpy_in_ns: std.atomic.Value(u64) = .{ .raw = 0 },
    process_fn_ns: std.atomic.Value(u64) = .{ .raw = 0 },
    dupe_response_ns: std.atomic.Value(u64) = .{ .raw = 0 },
    pool_release_ns: std.atomic.Value(u64) = .{ .raw = 0 },

    dispatch_calls: std.atomic.Value(u64) = .{ .raw = 0 },
    dispatch_ns: std.atomic.Value(u64) = .{ .raw = 0 },
    dispatch_deserialize_ns: std.atomic.Value(u64) = .{ .raw = 0 },
    dispatch_engine_ns: std.atomic.Value(u64) = .{ .raw = 0 },
    dispatch_reply_write_ns: std.atomic.Value(u64) = .{ .raw = 0 },

    pub fn reset(self: *WasmPathMetrics) void {
        self.requests.store(0, .release);
        self.pool_acquire_ns.store(0, .release);
        self.memcpy_in_ns.store(0, .release);
        self.process_fn_ns.store(0, .release);
        self.dupe_response_ns.store(0, .release);
        self.pool_release_ns.store(0, .release);
        self.dispatch_calls.store(0, .release);
        self.dispatch_ns.store(0, .release);
        self.dispatch_deserialize_ns.store(0, .release);
        self.dispatch_engine_ns.store(0, .release);
        self.dispatch_reply_write_ns.store(0, .release);
    }

    pub fn writeJson(self: *const WasmPathMetrics, buf: []u8) ![]u8 {
        const reqs = self.requests.load(.acquire);
        const denom: f64 = if (reqs == 0) 1.0 else @floatFromInt(reqs);

        const pool_acq = self.pool_acquire_ns.load(.acquire);
        const memcpy_in = self.memcpy_in_ns.load(.acquire);
        const proc_fn = self.process_fn_ns.load(.acquire);
        const dupe = self.dupe_response_ns.load(.acquire);
        const pool_rel = self.pool_release_ns.load(.acquire);

        const disp_calls = self.dispatch_calls.load(.acquire);
        const disp_ns = self.dispatch_ns.load(.acquire);
        const disp_des = self.dispatch_deserialize_ns.load(.acquire);
        const disp_eng = self.dispatch_engine_ns.load(.acquire);
        const disp_rep = self.dispatch_reply_write_ns.load(.acquire);
        const disp_calls_denom: f64 = if (disp_calls == 0) 1.0 else @floatFromInt(disp_calls);

        const wasm_code_ns: u64 = if (proc_fn > disp_ns) proc_fn - disp_ns else 0;

        return std.fmt.bufPrint(buf,
            \\{{
            \\  "requests": {d},
            \\  "totals_ns": {{
            \\    "pool_acquire":  {d},
            \\    "memcpy_in":     {d},
            \\    "process_fn":    {d},
            \\    "dupe_response": {d},
            \\    "pool_release":  {d},
            \\    "dispatch":      {d},
            \\    "wasm_code":     {d}
            \\  }},
            \\  "per_request_avg_ns": {{
            \\    "pool_acquire":  {d:.1},
            \\    "memcpy_in":     {d:.1},
            \\    "process_fn":    {d:.1},
            \\    "dupe_response": {d:.1},
            \\    "pool_release":  {d:.1},
            \\    "dispatch":      {d:.1},
            \\    "wasm_code":     {d:.1},
            \\    "total":         {d:.1}
            \\  }},
            \\  "dispatch_calls_total": {d},
            \\  "avg_dispatch_calls_per_request": {d:.2},
            \\  "per_dispatch_avg_ns": {{
            \\    "deserialize":  {d:.1},
            \\    "engine":       {d:.1},
            \\    "reply_write":  {d:.1},
            \\    "total":        {d:.1}
            \\  }}
            \\}}
        , .{
            reqs,
            pool_acq, memcpy_in, proc_fn, dupe, pool_rel, disp_ns, wasm_code_ns,
            @as(f64, @floatFromInt(pool_acq)) / denom,
            @as(f64, @floatFromInt(memcpy_in)) / denom,
            @as(f64, @floatFromInt(proc_fn)) / denom,
            @as(f64, @floatFromInt(dupe)) / denom,
            @as(f64, @floatFromInt(pool_rel)) / denom,
            @as(f64, @floatFromInt(disp_ns)) / denom,
            @as(f64, @floatFromInt(wasm_code_ns)) / denom,
            @as(f64, @floatFromInt(pool_acq + memcpy_in + proc_fn + dupe + pool_rel)) / denom,
            disp_calls,
            @as(f64, @floatFromInt(disp_calls)) / denom,
            @as(f64, @floatFromInt(disp_des)) / disp_calls_denom,
            @as(f64, @floatFromInt(disp_eng)) / disp_calls_denom,
            @as(f64, @floatFromInt(disp_rep)) / disp_calls_denom,
            @as(f64, @floatFromInt(disp_ns)) / disp_calls_denom,
        });
    }
};
