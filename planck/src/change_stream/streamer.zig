const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const common = @import("../common/common.zig");
const OpKind = common.OpKind;
const nowMs = common.nowMs;
const change_streams = @import("../common/change_streams.zig");
const StreamStore = change_streams.StreamStore;
const utils = @import("utils");
const csf = utils.change_stream_frame;
const Mutex = utils.Mutex;

const log = std.log.scoped(.change_streamer);

const PARK_QUANTUM_MS: u32 = 50;

pub const ShipRecord = struct {
    kind: OpKind,
    store_ns: []const u8,
    lsn: u64,
    doc_id: u128,
    timestamp: i64,
    data: []const u8,
};

pub const ChangeStreamerConfig = struct {
    stores: []const StreamStore,
    ring_capacity: usize = 16 * 1024,
};

pub const WatchOutcome = struct {
    frames: [][]u8,
    high_lsn: u64,

    pub fn freeOutcome(self: *WatchOutcome, allocator: Allocator) void {
        for (self.frames) |f| allocator.free(f);
        if (self.frames.len > 0) allocator.free(self.frames);
        self.frames = &.{};
    }
};

pub const ChangeStreamer = struct {
    allocator: Allocator,
    io: Io,
    cfg: ChangeStreamerConfig,

    entries: [][]u8,
    lsns: []u64,
    head: usize = 0,
    count: usize = 0,
    mutex: Mutex,

    oldest_lsn: std.atomic.Value(u64),
    high_lsn: std.atomic.Value(u64),

    pub fn init(allocator: Allocator, io: Io, cfg: ChangeStreamerConfig) !*ChangeStreamer {
        if (cfg.ring_capacity == 0) return error.InvalidConfig;
        const self = try allocator.create(ChangeStreamer);
        errdefer allocator.destroy(self);

        const entries = try allocator.alloc([]u8, cfg.ring_capacity);
        errdefer allocator.free(entries);
        const lsns = try allocator.alloc(u64, cfg.ring_capacity);
        errdefer allocator.free(lsns);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .entries = entries,
            .lsns = lsns,
            .mutex = .{},
            .oldest_lsn = .init(0),
            .high_lsn = .init(0),
        };
        return self;
    }

    pub fn deinit(self: *ChangeStreamer) void {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + self.cfg.ring_capacity - self.count + i) % self.cfg.ring_capacity;
            self.allocator.free(self.entries[idx]);
        }
        self.allocator.free(self.entries);
        self.allocator.free(self.lsns);
        self.allocator.destroy(self);
    }

    pub fn ship(self: *ChangeStreamer, record: ShipRecord) void {
        const kind: csf.Kind = switch (record.kind) {
            .insert => .insert,
            .update => .update,
            .delete => .delete,
            .read, .sequence => return,
        };
        if (!self.matchesFilter(record.store_ns, record.kind)) {
            log.info("ship: DROPPED (filter miss) store_ns='{s}' kind={s} lsn={d}", .{ record.store_ns, @tagName(record.kind), record.lsn });
            return;
        }
        log.info("ship: ACCEPTED store_ns='{s}' kind={s} lsn={d} value.len={d}", .{ record.store_ns, @tagName(record.kind), record.lsn, record.data.len });

        const frame: csf.Frame = .{
            .kind = kind,
            .writer_lsn = record.lsn,
            .timestamp_ms = record.timestamp,
            .store_ns = record.store_ns,
            .key = record.doc_id,
            .value = if (record.data.len == 0) null else record.data,
        };

        const encoded = frame.encodeAlloc(self.allocator) catch |err| {
            log.err("ship: encode failed lsn={d}: {}", .{ record.lsn, err });
            return;
        };

        self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.count == self.cfg.ring_capacity) {
            self.allocator.free(self.entries[self.head]);
            const next_oldest_idx = (self.head + 1) % self.cfg.ring_capacity;
            self.oldest_lsn.store(self.lsns[next_oldest_idx], .release);
        } else {
            if (self.count == 0) self.oldest_lsn.store(record.lsn, .release);
            self.count += 1;
        }

        self.entries[self.head] = encoded;
        self.lsns[self.head] = record.lsn;
        self.head = (self.head + 1) % self.cfg.ring_capacity;
        self.high_lsn.store(record.lsn, .release);
    }

    fn matchesFilter(self: *ChangeStreamer, store_ns: []const u8, op: OpKind) bool {
        for (self.cfg.stores) |s| {
            if (std.mem.eql(u8, s.ns, store_ns)) return s.matches(op);
        }
        return false;
    }

    pub fn watch(self: *ChangeStreamer, out_allocator: Allocator, stores: []const []const u8, since_lsn: u64, max_wait_ms: u32, max_records: u32) !WatchOutcome {
        const oldest = self.oldest_lsn.load(.acquire);
        if (since_lsn > 0 and oldest > 0 and since_lsn < oldest) {
            return error.CursorBehindRetention;
        }

        if (self.high_lsn.load(.acquire) > since_lsn) {
            const out = try self.snapshotSince(out_allocator, stores, since_lsn, max_records);
            log.info("watch: FAST since_lsn={d} high_lsn={d} returning {d} frame(s)", .{ since_lsn, out.high_lsn, out.frames.len });
            return out;
        }

        const start_ms = nowMs(self.io);
        const deadline_ms = start_ms + @as(i64, @intCast(max_wait_ms));

        while (self.high_lsn.load(.acquire) <= since_lsn) {
            const remaining = deadline_ms - nowMs(self.io);
            if (remaining <= 0) {
                return .{
                    .frames = &.{},
                    .high_lsn = self.high_lsn.load(.acquire),
                };
            }
            const sleep_for: i64 = @min(remaining, @as(i64, PARK_QUANTUM_MS));
            self.io.sleep(Io.Duration.fromMilliseconds(sleep_for), .awake) catch |err| switch (err) {
                error.Canceled => return err,
            };
        }

        const out = try self.snapshotSince(out_allocator, stores, since_lsn, max_records);
        log.info("watch: WOKE since_lsn={d} high_lsn={d} returning {d} frame(s)", .{ since_lsn, out.high_lsn, out.frames.len });
        return out;
    }

    fn snapshotSince(self: *ChangeStreamer, out_allocator: Allocator, stores: []const []const u8, since_lsn: u64, max_records_arg: u32) !WatchOutcome {
        self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (since_lsn > 0 and self.oldest_lsn.load(.acquire) > 0 and
            since_lsn < self.oldest_lsn.load(.acquire))
        {
            return error.CursorBehindRetention;
        }

        const cap_records: usize = if (max_records_arg == 0) 256 else @as(usize, max_records_arg);

        var picked: std.ArrayList([]u8) = .empty;
        errdefer {
            for (picked.items) |f| out_allocator.free(f);
            picked.deinit(out_allocator);
        }

        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + self.cfg.ring_capacity - self.count + i) % self.cfg.ring_capacity;
            const lsn = self.lsns[idx];
            if (lsn <= since_lsn) continue;

            if (stores.len > 0 and !frameStoreInList(self.entries[idx], stores)) continue;

            const copy = try out_allocator.dupe(u8, self.entries[idx]);
            errdefer out_allocator.free(copy);
            try picked.append(out_allocator, copy);

            if (picked.items.len >= cap_records) break;
        }

        return .{
            .frames = try picked.toOwnedSlice(out_allocator),
            .high_lsn = self.high_lsn.load(.acquire),
        };
    }

};

fn frameStoreInList(encoded: []const u8, stores: []const []const u8) bool {
    if (encoded.len < 22 + 2) return false;
    const sns_len = std.mem.readInt(u16, encoded[22..24], .little);
    if (encoded.len < 24 + sns_len) return false;
    const sns = encoded[24 .. 24 + sns_len];
    for (stores) |want| {
        if (std.mem.eql(u8, want, sns)) return true;
    }
    return false;
}

const testing = std.testing;
const proto = @import("proto");
const Threaded = std.Io.Threaded;

fn makeStreamer(allocator: Allocator, io: Io, capacity: usize, stream_stores: []const StreamStore) !*ChangeStreamer {
    return ChangeStreamer.init(allocator, io, .{
        .stores = stream_stores,
        .ring_capacity = capacity,
    });
}

fn shipInsert(cs: *ChangeStreamer, ns: []const u8, lsn: u64, key: u128, value: []const u8) void {
    cs.ship(.{
        .kind = .insert,
        .store_ns = ns,
        .lsn = lsn,
        .doc_id = key,
        .timestamp = 0,
        .data = value,
    });
}

test "ChangeStreamer: ship filtered store is dropped" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stores = [_]StreamStore{.{ .ns = "orders", .op_mask = 0b111 }};
    var cs = try makeStreamer(testing.allocator, io, 16, &stores);
    defer cs.deinit();

    shipInsert(cs, "users", 1, 1, "x");
    try testing.expectEqual(@as(u64, 0), cs.high_lsn.load(.acquire));

    shipInsert(cs, "orders", 1, 1, "x");
    try testing.expectEqual(@as(u64, 1), cs.high_lsn.load(.acquire));
}

test "ChangeStreamer: watch returns nothing when empty + max_wait=0" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stores = [_]StreamStore{.{ .ns = "orders", .op_mask = 0b111 }};
    var cs = try makeStreamer(testing.allocator, io, 16, &stores);
    defer cs.deinit();

    var outcome = try cs.watch(testing.allocator, &.{}, 0, 0, 10);
    defer outcome.freeOutcome(testing.allocator);
    try testing.expectEqual(@as(usize, 0), outcome.frames.len);
    try testing.expectEqual(@as(u64, 0), outcome.high_lsn);
}

test "ChangeStreamer: watch returns shipped record" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stores = [_]StreamStore{.{ .ns = "orders", .op_mask = 0b111 }};
    var cs = try makeStreamer(testing.allocator, io, 16, &stores);
    defer cs.deinit();

    shipInsert(cs, "orders", 7, 100, "payload");

    var outcome = try cs.watch(testing.allocator, &.{}, 0, 0, 10);
    defer outcome.freeOutcome(testing.allocator);
    try testing.expectEqual(@as(usize, 1), outcome.frames.len);
    try testing.expectEqual(@as(u64, 7), outcome.high_lsn);

    const parsed = try csf.Frame.decode(outcome.frames[0]);
    try testing.expectEqual(csf.Kind.insert, parsed.frame.kind);
    try testing.expectEqual(@as(u64, 7), parsed.frame.writer_lsn);
    try testing.expectEqualStrings("orders", parsed.frame.store_ns);
}

test "ChangeStreamer: watch since_lsn filters out older frames" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stores = [_]StreamStore{.{ .ns = "orders", .op_mask = 0b111 }};
    var cs = try makeStreamer(testing.allocator, io, 16, &stores);
    defer cs.deinit();

    shipInsert(cs, "orders", 1, 1, "a");
    shipInsert(cs, "orders", 2, 2, "b");
    shipInsert(cs, "orders", 3, 3, "c");

    var outcome = try cs.watch(testing.allocator, &.{}, 2, 0, 10);
    defer outcome.freeOutcome(testing.allocator);
    try testing.expectEqual(@as(usize, 1), outcome.frames.len);
    const parsed = try csf.Frame.decode(outcome.frames[0]);
    try testing.expectEqual(@as(u64, 3), parsed.frame.writer_lsn);
    try testing.expectEqual(@as(u64, 3), outcome.high_lsn);
}

test "ChangeStreamer: store filter in watch limits results" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stores = [_]StreamStore{
        .{ .ns = "orders", .op_mask = 0b111 },
        .{ .ns = "payments", .op_mask = 0b111 },
    };
    var cs = try makeStreamer(testing.allocator, io, 16, &stores);
    defer cs.deinit();

    shipInsert(cs, "orders", 1, 1, "o1");
    shipInsert(cs, "payments", 2, 2, "p1");
    shipInsert(cs, "orders", 3, 3, "o2");

    const want_orders = [_][]const u8{"orders"};
    var outcome = try cs.watch(testing.allocator, &want_orders, 0, 0, 10);
    defer outcome.freeOutcome(testing.allocator);
    try testing.expectEqual(@as(usize, 2), outcome.frames.len);
    const p1 = try csf.Frame.decode(outcome.frames[0]);
    const p2 = try csf.Frame.decode(outcome.frames[1]);
    try testing.expectEqualStrings("orders", p1.frame.store_ns);
    try testing.expectEqualStrings("orders", p2.frame.store_ns);
}

test "ChangeStreamer: max_records caps the snapshot" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stores = [_]StreamStore{.{ .ns = "orders", .op_mask = 0b111 }};
    var cs = try makeStreamer(testing.allocator, io, 16, &stores);
    defer cs.deinit();

    var lsn: u64 = 1;
    while (lsn <= 10) : (lsn += 1) shipInsert(cs, "orders", lsn, lsn, "x");

    var outcome = try cs.watch(testing.allocator, &.{}, 0, 0, 3);
    defer outcome.freeOutcome(testing.allocator);
    try testing.expectEqual(@as(usize, 3), outcome.frames.len);
}

test "ChangeStreamer: ring overflow evicts oldest + CursorBehindRetention" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stores = [_]StreamStore{.{ .ns = "orders", .op_mask = 0b111 }};
    var cs = try makeStreamer(testing.allocator, io, 3, &stores);
    defer cs.deinit();

    shipInsert(cs, "orders", 1, 1, "a");
    shipInsert(cs, "orders", 2, 2, "b");
    shipInsert(cs, "orders", 3, 3, "c");
    shipInsert(cs, "orders", 4, 4, "d");
    shipInsert(cs, "orders", 5, 5, "e");

    try testing.expectEqual(@as(u64, 3), cs.oldest_lsn.load(.acquire));
    try testing.expectEqual(@as(u64, 5), cs.high_lsn.load(.acquire));

    try testing.expectError(error.CursorBehindRetention, cs.watch(testing.allocator, &.{}, 1, 0, 10));

    var outcome = try cs.watch(testing.allocator, &.{}, 3, 0, 10);
    defer outcome.freeOutcome(testing.allocator);
    try testing.expectEqual(@as(usize, 2), outcome.frames.len);
}

test "ChangeStreamer: watch times out with max_wait_ms when no data" {
    var threaded: Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stores = [_]StreamStore{.{ .ns = "orders", .op_mask = 0b111 }};
    var cs = try makeStreamer(testing.allocator, io, 16, &stores);
    defer cs.deinit();

    const start = nowMs(io);
    var outcome = try cs.watch(testing.allocator, &.{}, 0, 150, 10);
    defer outcome.freeOutcome(testing.allocator);
    const elapsed = nowMs(io) - start;

    try testing.expectEqual(@as(usize, 0), outcome.frames.len);
    try testing.expect(elapsed >= 140);
    try testing.expect(elapsed < 500);
}
