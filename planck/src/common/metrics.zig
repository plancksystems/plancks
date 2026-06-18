const std = @import("std");
const Io = std.Io;

pub const StopWatch = @import("utils").StopWatch;

pub const LatencyCounter = struct {
    count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    latency_sum: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn record(self: *LatencyCounter, latency: u64) void {
        _ = self.count.fetchAdd(1, .monotonic);
        _ = self.latency_sum.fetchAdd(latency, .monotonic);
    }

    pub fn avg(self: *const LatencyCounter) f64 {
        return avgOf(self.count.load(.monotonic), self.latency_sum.load(.monotonic));
    }

    pub fn avgOf(count: u64, sum: u64) f64 {
        if (count == 0) return 0.0;
        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(count));
    }
};

pub const DbOperation = enum { Read, Write, Delete, Update, Flush };

pub const DbMetrics = struct {
    total_reads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_writes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_deletes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_updates: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_flushes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    read_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    write_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    update_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    flush_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn start(self: *DbMetrics, io: Io, op: DbOperation) StopWatch {
        _ = self;
        _ = op;
        var sw = StopWatch{};
        sw.start(io);
        return sw;
    }

    pub fn stop(self: *DbMetrics, io: Io, sw: *StopWatch, op: DbOperation) void {
        sw.stop(io);
        const latency_us = @as(u64, @intFromFloat(sw.elapsedUs()));

        switch (op) {
            .Read => {
                _ = self.total_reads.fetchAdd(1, .monotonic);
                _ = self.read_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
            .Write => {
                _ = self.total_writes.fetchAdd(1, .monotonic);
                _ = self.write_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
            .Delete => {
                _ = self.total_deletes.fetchAdd(1, .monotonic);
            },
            .Update => {
                _ = self.total_updates.fetchAdd(1, .monotonic);
                _ = self.update_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
            .Flush => {
                _ = self.total_flushes.fetchAdd(1, .monotonic);
                _ = self.flush_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
        }
    }
    pub fn getAvgReadLatency(self: *const DbMetrics) f64 {
        return LatencyCounter.avgOf(self.total_reads.load(.monotonic), self.read_latency_sum_us.load(.monotonic));
    }

    pub fn getAvgWriteLatency(self: *const DbMetrics) f64 {
        return LatencyCounter.avgOf(self.total_writes.load(.monotonic), self.write_latency_sum_us.load(.monotonic));
    }

    pub fn getAvgUpdateLatency(self: *const DbMetrics) f64 {
        return LatencyCounter.avgOf(self.total_updates.load(.monotonic), self.update_latency_sum_us.load(.monotonic));
    }

    pub fn getAvgFlushLatency(self: *const DbMetrics) f64 {
        return LatencyCounter.avgOf(self.total_flushes.load(.monotonic), self.flush_latency_sum_us.load(.monotonic));
    }
};

pub const WalOperation = enum {
    Append,
    Flush,
    Truncate,
    Fsync,
    Replay,
};

pub const WalMetrics = struct {
    total_appends: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_fsyncs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_replays: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_flushes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_truncates: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    append_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    fsync_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    flush_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    truncate_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn start(self: *WalMetrics, io: Io, op: WalOperation) StopWatch {
        _ = self;
        _ = op;
        var sw = StopWatch{};
        sw.start(io);
        return sw;
    }

    pub fn stop(self: *WalMetrics, io: Io, sw: *StopWatch, op: WalOperation) void {
        sw.stop(io);
        const latency_us = @as(u64, @intFromFloat(sw.elapsedUs()));

        switch (op) {
            .Append => {
                _ = self.total_appends.fetchAdd(1, .monotonic);
                _ = self.append_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
            .Fsync => {
                _ = self.total_fsyncs.fetchAdd(1, .monotonic);
                _ = self.fsync_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
            .Replay => {
                _ = self.total_replays.fetchAdd(1, .monotonic);
            },
            .Flush => {
                _ = self.total_flushes.fetchAdd(1, .monotonic);
                _ = self.flush_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
            .Truncate => {
                _ = self.total_truncates.fetchAdd(1, .monotonic);
                _ = self.truncate_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
        }
    }

    pub fn recordBytes(self: *WalMetrics, bytes: u64) void {
        _ = self.total_bytes_written.fetchAdd(bytes, .monotonic);
    }

    pub fn getAvgAppendLatency(self: *const WalMetrics) f64 {
        return LatencyCounter.avgOf(self.total_appends.load(.monotonic), self.append_latency_sum_us.load(.monotonic));
    }

    pub fn getAvgFsyncLatency(self: *const WalMetrics) f64 {
        return LatencyCounter.avgOf(self.total_fsyncs.load(.monotonic), self.fsync_latency_sum_us.load(.monotonic));
    }

    pub fn getAvgFlushLatency(self: *const WalMetrics) f64 {
        return LatencyCounter.avgOf(self.total_flushes.load(.monotonic), self.flush_latency_sum_us.load(.monotonic));
    }

    pub fn getAvgTruncateLatency(self: *const WalMetrics) f64 {
        return LatencyCounter.avgOf(self.total_truncates.load(.monotonic), self.truncate_latency_sum_us.load(.monotonic));
    }
};

pub const VlogOperation = enum {
    Write,
    Read,
    Flush,
    Gc,
};

pub const VlogMetrics = struct {
    total_writes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_reads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_gc_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    bytes_reclaimed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_flushes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    write_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    read_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    flush_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pub fn start(self: *VlogMetrics, io: Io, op: VlogOperation) StopWatch {
        _ = self;
        _ = op;
        var sw = StopWatch{};
        sw.start(io);
        return sw;
    }

    pub fn stop(self: *VlogMetrics, io: Io, sw: *StopWatch, op: VlogOperation) void {
        sw.stop(io);
        const latency_us = @as(u64, @intFromFloat(sw.elapsedUs()));

        switch (op) {
            .Write => {
                _ = self.total_writes.fetchAdd(1, .monotonic);
                _ = self.write_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
            .Read => {
                _ = self.total_reads.fetchAdd(1, .monotonic);
                _ = self.read_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
            .Gc => {
                _ = self.total_gc_runs.fetchAdd(1, .monotonic);
            },
            .Flush => {
                _ = self.total_flushes.fetchAdd(1, .monotonic);
                _ = self.flush_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
        }
    }

    pub fn recordBytes(self: *VlogMetrics, bytes: u64) void {
        _ = self.total_bytes_written.fetchAdd(bytes, .monotonic);
    }

    pub fn recordGcReclaimed(self: *VlogMetrics, bytes: u64) void {
        _ = self.bytes_reclaimed.fetchAdd(bytes, .monotonic);
    }

    pub fn getAvgWriteLatency(self: *const VlogMetrics) f64 {
        return LatencyCounter.avgOf(self.total_writes.load(.monotonic), self.write_latency_sum_us.load(.monotonic));
    }

    pub fn getAvgReadLatency(self: *const VlogMetrics) f64 {
        return LatencyCounter.avgOf(self.total_reads.load(.monotonic), self.read_latency_sum_us.load(.monotonic));
    }

    pub fn getAvgFlushLatency(self: *const VlogMetrics) f64 {
        return LatencyCounter.avgOf(self.total_flushes.load(.monotonic), self.flush_latency_sum_us.load(.monotonic));
    }
};

pub const IndexOperation = enum {
    Insert,
    Update,
    Search,
    Delete,
    RangeScan,
    Flush,
};

pub const IndexMetrics = struct {
    total_inserts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_searches: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_deletes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_scans: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_flushes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_updates: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    update_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    insert_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    search_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    flush_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn start(self: *IndexMetrics, io: Io, op: IndexOperation) StopWatch {
        _ = self;
        _ = op;
        var sw = StopWatch{};
        sw.start(io);
        return sw;
    }

    pub fn stop(self: *IndexMetrics, io: Io, sw: *StopWatch, op: IndexOperation) void {
        sw.stop(io);
        const latency_us = @as(u64, @intFromFloat(sw.elapsedUs()));

        switch (op) {
            .Insert => {
                _ = self.total_inserts.fetchAdd(1, .monotonic);
                _ = self.insert_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
            .Update => {
                _ = self.total_updates.fetchAdd(1, .monotonic);
                _ = self.update_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
            .Search => {
                _ = self.total_searches.fetchAdd(1, .monotonic);
                _ = self.search_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
            .Delete => {
                _ = self.total_deletes.fetchAdd(1, .monotonic);
            },
            .RangeScan => {
                _ = self.total_scans.fetchAdd(1, .monotonic);
            },
            .Flush => {
                _ = self.total_flushes.fetchAdd(1, .monotonic);
                _ = self.flush_latency_sum_us.fetchAdd(latency_us, .monotonic);
            },
        }
    }

    pub fn getAvgInsertLatency(self: *const IndexMetrics) f64 {
        return LatencyCounter.avgOf(self.total_inserts.load(.monotonic), self.insert_latency_sum_us.load(.monotonic));
    }

    pub fn getAvgSearchLatency(self: *const IndexMetrics) f64 {
        return LatencyCounter.avgOf(self.total_searches.load(.monotonic), self.search_latency_sum_us.load(.monotonic));
    }

    pub fn getAvgFlushLatency(self: *const IndexMetrics) f64 {
        return LatencyCounter.avgOf(self.total_flushes.load(.monotonic), self.flush_latency_sum_us.load(.monotonic));
    }
};

pub const GcMetrics = struct {
    total_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_bytes_reclaimed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_run_duration_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn recordRun(self: *GcMetrics, bytes_reclaimed: u64, duration_ms: u64) void {
        _ = self.total_runs.fetchAdd(1, .monotonic);
        _ = self.total_bytes_reclaimed.fetchAdd(bytes_reclaimed, .monotonic);
        self.last_run_duration_ms.store(duration_ms, .monotonic);
    }
};

pub const HttpMethodTag = enum(u8) {
    GET = 0,
    POST = 1,
    PUT = 2,
    DELETE = 3,
    PATCH = 4,
    HEAD = 5,
    OPTIONS = 6,
};

pub const MethodMetrics = struct {
    count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn record(self: *MethodMetrics, latency_us: u64) void {
        _ = self.count.fetchAdd(1, .monotonic);
        _ = self.latency_sum_us.fetchAdd(latency_us, .monotonic);
    }

    pub fn getAvgLatency(self: *const MethodMetrics) f64 {
        const c = self.count.load(.monotonic);
        if (c == 0) return 0;
        return @as(f64, @floatFromInt(self.latency_sum_us.load(.monotonic))) / @as(f64, @floatFromInt(c));
    }
};

pub const HttpMetrics = struct {
    total_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    method_metrics: [7]MethodMetrics = [_]MethodMetrics{.{}} ** 7,

    pub fn start(self: *HttpMetrics, io: Io, method: HttpMethodTag) StopWatch {
        _ = self;
        _ = method;
        var sw = StopWatch{};
        sw.start(io);
        return sw;
    }

    pub fn stop(self: *HttpMetrics, io: Io, sw: *StopWatch, method: HttpMethodTag) void {
        sw.stop(io);
        const latency_us = @as(u64, @intFromFloat(sw.elapsedUs()));
        _ = self.total_requests.fetchAdd(1, .monotonic);
        _ = self.total_latency_sum_us.fetchAdd(latency_us, .monotonic);
        self.method_metrics[@intFromEnum(method)].record(latency_us);
    }

    pub fn record(self: *HttpMetrics, method: HttpMethodTag, latency_us: u64) void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
        _ = self.total_latency_sum_us.fetchAdd(latency_us, .monotonic);
        self.method_metrics[@intFromEnum(method)].record(latency_us);
    }

    pub fn getAvgLatency(self: *const HttpMetrics) f64 {
        const c = self.total_requests.load(.monotonic);
        if (c == 0) return 0;
        return @as(f64, @floatFromInt(self.total_latency_sum_us.load(.monotonic))) / @as(f64, @floatFromInt(c));
    }
};

pub const WasmMetrics = struct {
    active_instances: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    pool_size: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    min_instances: u32 = 0,
    max_instances: u32 = 0,
    total_requests_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_instances_recycled: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    request_latency_sum_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn start(self: *WasmMetrics, io: Io) StopWatch {
        _ = self.active_instances.fetchAdd(1, .monotonic);
        var sw = StopWatch{};
        sw.start(io);
        return sw;
    }

    pub fn stop(self: *WasmMetrics, io: Io, sw: *StopWatch) void {
        sw.stop(io);
        const latency_us = @as(u64, @intFromFloat(sw.elapsedUs()));
        _ = self.active_instances.fetchSub(1, .monotonic);
        _ = self.total_requests_processed.fetchAdd(1, .monotonic);
        _ = self.request_latency_sum_us.fetchAdd(latency_us, .monotonic);
    }

    pub fn recordInstanceAdded(self: *WasmMetrics) void {
        _ = self.pool_size.fetchAdd(1, .monotonic);
    }

    pub fn recordInstanceRemoved(self: *WasmMetrics) void {
        _ = self.pool_size.fetchSub(1, .monotonic);
    }

    pub fn recordRecycle(self: *WasmMetrics) void {
        _ = self.total_instances_recycled.fetchAdd(1, .monotonic);
    }

    pub fn getAvgRequestLatency(self: *const WasmMetrics) f64 {
        const c = self.total_requests_processed.load(.monotonic);
        if (c == 0) return 0;
        return @as(f64, @floatFromInt(self.request_latency_sum_us.load(.monotonic))) / @as(f64, @floatFromInt(c));
    }
};

pub const EngineMetrics = struct {
    db: DbMetrics = .{},
    wal: WalMetrics = .{},
    vlog: VlogMetrics = .{},
    index: IndexMetrics = .{},
    gc: GcMetrics = .{},
    wasm: WasmMetrics = .{},
    http: HttpMetrics = .{},

    pub fn init(allocator: std.mem.Allocator) !*EngineMetrics {
        const em = try allocator.create(EngineMetrics);
        em.* = .{};
        return em;
    }

    pub fn deinit(self: *EngineMetrics, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};


const testing = std.testing;

test "DbMetrics - counters increment" {
    var m = DbMetrics{};
    try testing.expectEqual(@as(u64, 0), m.total_reads.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), m.total_writes.load(.monotonic));
    _ = m.total_reads.fetchAdd(1, .monotonic);
    _ = m.total_reads.fetchAdd(1, .monotonic);
    _ = m.total_writes.fetchAdd(1, .monotonic);
    try testing.expectEqual(@as(u64, 2), m.total_reads.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), m.total_writes.load(.monotonic));
}

test "DbMetrics - avg latency zero when no ops" {
    const m = DbMetrics{};
    try testing.expectEqual(@as(f64, 0.0), m.getAvgReadLatency());
    try testing.expectEqual(@as(f64, 0.0), m.getAvgWriteLatency());
    try testing.expectEqual(@as(f64, 0.0), m.getAvgUpdateLatency());
    try testing.expectEqual(@as(f64, 0.0), m.getAvgFlushLatency());
}

test "DbMetrics - avg latency calculation" {
    var m = DbMetrics{};
    _ = m.total_reads.fetchAdd(2, .monotonic);
    _ = m.read_latency_sum_us.fetchAdd(100, .monotonic);
    try testing.expectEqual(@as(f64, 50.0), m.getAvgReadLatency());
}

test "WalMetrics - counters and bytes" {
    var m = WalMetrics{};
    _ = m.total_appends.fetchAdd(5, .monotonic);
    m.recordBytes(1024);
    m.recordBytes(2048);
    try testing.expectEqual(@as(u64, 5), m.total_appends.load(.monotonic));
    try testing.expectEqual(@as(u64, 3072), m.total_bytes_written.load(.monotonic));
}

test "WalMetrics - avg latency zero when no ops" {
    const m = WalMetrics{};
    try testing.expectEqual(@as(f64, 0.0), m.getAvgAppendLatency());
    try testing.expectEqual(@as(f64, 0.0), m.getAvgFsyncLatency());
    try testing.expectEqual(@as(f64, 0.0), m.getAvgFlushLatency());
    try testing.expectEqual(@as(f64, 0.0), m.getAvgTruncateLatency());
}

test "VlogMetrics - counters and bytes" {
    var m = VlogMetrics{};
    _ = m.total_writes.fetchAdd(3, .monotonic);
    _ = m.total_reads.fetchAdd(7, .monotonic);
    m.recordBytes(4096);
    m.recordGcReclaimed(512);
    try testing.expectEqual(@as(u64, 3), m.total_writes.load(.monotonic));
    try testing.expectEqual(@as(u64, 7), m.total_reads.load(.monotonic));
    try testing.expectEqual(@as(u64, 4096), m.total_bytes_written.load(.monotonic));
    try testing.expectEqual(@as(u64, 512), m.bytes_reclaimed.load(.monotonic));
}

test "VlogMetrics - avg latency zero when no ops" {
    const m = VlogMetrics{};
    try testing.expectEqual(@as(f64, 0.0), m.getAvgWriteLatency());
    try testing.expectEqual(@as(f64, 0.0), m.getAvgReadLatency());
    try testing.expectEqual(@as(f64, 0.0), m.getAvgFlushLatency());
}

test "IndexMetrics - counters" {
    var m = IndexMetrics{};
    _ = m.total_inserts.fetchAdd(10, .monotonic);
    _ = m.total_searches.fetchAdd(20, .monotonic);
    _ = m.total_deletes.fetchAdd(3, .monotonic);
    _ = m.total_scans.fetchAdd(5, .monotonic);
    try testing.expectEqual(@as(u64, 10), m.total_inserts.load(.monotonic));
    try testing.expectEqual(@as(u64, 20), m.total_searches.load(.monotonic));
    try testing.expectEqual(@as(u64, 3), m.total_deletes.load(.monotonic));
    try testing.expectEqual(@as(u64, 5), m.total_scans.load(.monotonic));
}

test "IndexMetrics - avg latency zero when no ops" {
    const m = IndexMetrics{};
    try testing.expectEqual(@as(f64, 0.0), m.getAvgInsertLatency());
    try testing.expectEqual(@as(f64, 0.0), m.getAvgSearchLatency());
    try testing.expectEqual(@as(f64, 0.0), m.getAvgFlushLatency());
}

test "GcMetrics - recordRun" {
    var m = GcMetrics{};
    m.recordRun(1024, 50);
    m.recordRun(2048, 75);
    try testing.expectEqual(@as(u64, 2), m.total_runs.load(.monotonic));
    try testing.expectEqual(@as(u64, 3072), m.total_bytes_reclaimed.load(.monotonic));
    try testing.expectEqual(@as(u64, 75), m.last_run_duration_ms.load(.monotonic));
}

test "EngineMetrics - init and deinit" {
    const allocator = testing.allocator;
    const em = try EngineMetrics.init(allocator);
    defer em.deinit(allocator);
    try testing.expectEqual(@as(u64, 0), em.db.total_reads.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), em.wal.total_appends.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), em.vlog.total_writes.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), em.index.total_inserts.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), em.gc.total_runs.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), em.wasm.total_requests_processed.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), em.http.total_requests.load(.monotonic));
}


test "MethodMetrics - record increments count and latency" {
    var m = MethodMetrics{};
    try testing.expectEqual(@as(u64, 0), m.count.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), m.latency_sum_us.load(.monotonic));

    m.record(500);
    m.record(1500);

    try testing.expectEqual(@as(u64, 2), m.count.load(.monotonic));
    try testing.expectEqual(@as(u64, 2000), m.latency_sum_us.load(.monotonic));
}

test "MethodMetrics - avg latency zero when no requests" {
    const m = MethodMetrics{};
    try testing.expectEqual(@as(f64, 0.0), m.getAvgLatency());
}

test "MethodMetrics - avg latency calculation" {
    var m = MethodMetrics{};
    m.record(100);
    m.record(200);
    m.record(300);
    try testing.expectEqual(@as(f64, 200.0), m.getAvgLatency());
}


test "HttpMetrics - record updates total and per-method" {
    var h = HttpMetrics{};
    try testing.expectEqual(@as(u64, 0), h.total_requests.load(.monotonic));

    h.record(.GET, 1000);
    h.record(.GET, 2000);
    h.record(.POST, 500);

    try testing.expectEqual(@as(u64, 3), h.total_requests.load(.monotonic));
    try testing.expectEqual(@as(u64, 3500), h.total_latency_sum_us.load(.monotonic));

    try testing.expectEqual(@as(u64, 2), h.method_metrics[@intFromEnum(HttpMethodTag.GET)].count.load(.monotonic));
    try testing.expectEqual(@as(u64, 3000), h.method_metrics[@intFromEnum(HttpMethodTag.GET)].latency_sum_us.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), h.method_metrics[@intFromEnum(HttpMethodTag.POST)].count.load(.monotonic));
    try testing.expectEqual(@as(u64, 500), h.method_metrics[@intFromEnum(HttpMethodTag.POST)].latency_sum_us.load(.monotonic));

    try testing.expectEqual(@as(u64, 0), h.method_metrics[@intFromEnum(HttpMethodTag.DELETE)].count.load(.monotonic));
}

test "HttpMetrics - avg latency zero when no requests" {
    const h = HttpMetrics{};
    try testing.expectEqual(@as(f64, 0.0), h.getAvgLatency());
}

test "HttpMetrics - avg latency calculation" {
    var h = HttpMetrics{};
    h.record(.GET, 100);
    h.record(.POST, 300);
    try testing.expectEqual(@as(f64, 200.0), h.getAvgLatency());
    try testing.expectEqual(@as(f64, 100.0), h.method_metrics[@intFromEnum(HttpMethodTag.GET)].getAvgLatency());
}


test "WasmMetrics - instance tracking" {
    var w = WasmMetrics{};
    try testing.expectEqual(@as(u32, 0), w.pool_size.load(.monotonic));

    w.recordInstanceAdded();
    w.recordInstanceAdded();
    w.recordInstanceAdded();
    try testing.expectEqual(@as(u32, 3), w.pool_size.load(.monotonic));

    w.recordInstanceRemoved();
    try testing.expectEqual(@as(u32, 2), w.pool_size.load(.monotonic));
}

test "WasmMetrics - recycle counter" {
    var w = WasmMetrics{};
    try testing.expectEqual(@as(u64, 0), w.total_instances_recycled.load(.monotonic));

    w.recordRecycle();
    w.recordRecycle();
    try testing.expectEqual(@as(u64, 2), w.total_instances_recycled.load(.monotonic));
}

test "WasmMetrics - avg request latency zero when no requests" {
    const w = WasmMetrics{};
    try testing.expectEqual(@as(f64, 0.0), w.getAvgRequestLatency());
}

test "WasmMetrics - avg request latency calculation" {
    var w = WasmMetrics{};
    _ = w.total_requests_processed.fetchAdd(1, .monotonic);
    _ = w.request_latency_sum_us.fetchAdd(500, .monotonic);
    _ = w.total_requests_processed.fetchAdd(1, .monotonic);
    _ = w.request_latency_sum_us.fetchAdd(1500, .monotonic);
    try testing.expectEqual(@as(f64, 1000.0), w.getAvgRequestLatency());
}

test "WasmMetrics - static config fields" {
    var w = WasmMetrics{};
    w.min_instances = 2;
    w.max_instances = 16;
    try testing.expectEqual(@as(u32, 2), w.min_instances);
    try testing.expectEqual(@as(u32, 16), w.max_instances);
}
