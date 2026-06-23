const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const ValueLog = @import("vlog.zig").ValueLog;
const VLogConfig = @import("vlog.zig").VLogConfig;
const WriteAheadLog = @import("../durability/write_ahead_log.zig").WriteAheadLog;
const WalConfig = @import("../durability/write_ahead_log.zig").WalConfig;
const ReplayResult = @import("../durability/write_ahead_log.zig").ReplayResult;
const CheckpointRecord = @import("../durability/checkpoint.zig").CheckpointRecord;
const LogRecord = @import("../common/common.zig").LogRecord;
const OpKind = @import("../common/common.zig").OpKind;
const common = @import("../common/common.zig");
const VlogEntry = common.VlogEntry;
const Entry = common.Entry;
const CurrentVlog = common.CurrentVlog;
const Now = @import("utils").Now;
const Config = @import("../common/config.zig").Config;
const KeyGen = @import("../common/keygen.zig").KeyGen;
const Index = @import("bptree.zig").Index;
const IndexConfig = @import("bptree.zig").IndexConfig;
const RangeIterator = @import("bptree.zig").RangeIterator;
const MemTable = @import("../memtable/memtable.zig").MemTable;
const SkipList = @import("../memtable/skiplist.zig").SkipList;
const Catalog = @import("catalog.zig").Catalog;
const constants = @import("../common/constants.zig");
const SYSTEM_CATALOG_STORE_ID = constants.SYSTEM_CATALOG_STORE_ID;
const SYSTEM_VLOG_FILENAME = constants.SYSTEM_VLOG_FILENAME;
const FieldExtractor = @import("field_extractor.zig").FieldExtractor;
const FieldValue = @import("field_extractor.zig").FieldValue;
const proto = @import("proto");
const EngineMetrics = @import("../common/metrics.zig").EngineMetrics;
const MAX_KEY_SIZE = @import("../common/config.zig").MAX_KEY_SIZE;
const ReplicationManager = @import("../tcp/replication.zig").ReplicationManager;
const log = std.log.scoped(.db);

pub const Db = struct {
    allocator: Allocator,
    io: Io,
    now: Now,
    memtable: *MemTable,
    vlogs: std.HashMap(u16, *ValueLog, std.hash_map.AutoContext(u16), std.hash_map.default_max_load_percentage),
    current_vlog: CurrentVlog,
    head_vlog_id: u16,
    tail_vlog_id: u16,
    config: *Config,
    primary_index: *Index(u128, u64),
    catalog: *Catalog,
    secondary_indexes: std.StringHashMap(*Index([]const u8, void)),
    count: usize = 0,

    engine_metrics: *EngineMetrics,
    wal: *WriteAheadLog,

    system_store_key: u128 = 0,

    system_vlog: *ValueLog,
    system_index: *Index(u128, u64),
    replication: ?*ReplicationManager = null,
    recovered_sequences: std.StringHashMapUnmanaged(i64) = .empty,

    pub fn init(allocator: Allocator, config: *Config, io: Io, wal: *WriteAheadLog, primary_index: *Index(u128, u64), engine_metrics: *EngineMetrics) !*Db {
        const db = try allocator.create(Db);
        errdefer allocator.destroy(db);

        var sys_vlog_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sys_vlog_path = try std.fmt.bufPrint(&sys_vlog_path_buf, "{s}/{s}", .{
            config.paths.vlog, SYSTEM_VLOG_FILENAME,
        });
        const system_vlog = try ValueLog.init(allocator, .{
            .id = 0,
            .file_name = sys_vlog_path,
            .max_file_size = config.file_sizes.vlog,
            .block_size = config.buffers.vlog,
            .io = io,
        }, engine_metrics);
        errdefer system_vlog.deinit() catch {};

        const system_index_ptr = try allocator.create(Index(u128, u64));
        errdefer allocator.destroy(system_index_ptr);
        system_index_ptr.* = try Index(u128, u64).init(allocator, IndexConfig{
            .dir_path = config.paths.index,
            .file_name = "system.catalog",
            .pool_size = config.index.primary.pool_size,
            .io = io,
        }, engine_metrics);
        errdefer system_index_ptr.deinit();

        const catalog = try Catalog.init(allocator, io, wal, system_vlog, system_index_ptr);
        errdefer catalog.deinit();
        try catalog.loadFromVlog();
        try catalog.ensureSystemStores();

        db.* = Db{
            .allocator = allocator,
            .io = io,
            .now = Now{ .io = io },
            .memtable = try MemTable.init(allocator, io, config.buffers.memtable),
            .vlogs = std.HashMap(u16, *ValueLog, std.hash_map.AutoContext(u16), std.hash_map.default_max_load_percentage).init(allocator),
            .config = config,
            .primary_index = primary_index,
            .catalog = catalog,
            .secondary_indexes = std.StringHashMap(*Index([]const u8, void)).init(allocator),
            .current_vlog = CurrentVlog{ .id = 0, .offset = 0 },
            .head_vlog_id = 0,
            .tail_vlog_id = 0,
            .wal = wal,
            .engine_metrics = engine_metrics,
            .system_vlog = system_vlog,
            .system_index = system_index_ptr,
        };

        try db.load_vlogs();

        db.recover() catch |err| {
            log.err("Error during WAL replay: {}", .{err});
            return error.WalReplayFailed;
        };

        return db;
    }

    pub fn deinit(self: *Db) void {
        var vlog_iter = self.vlogs.iterator();
        while (vlog_iter.next()) |vlog| {
            vlog.value_ptr.*.deinit() catch {};
        }
        self.vlogs.deinit();

        var idx_iter = self.secondary_indexes.iterator();
        while (idx_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(@constCast(entry.key_ptr.*));
        }
        self.secondary_indexes.deinit();

        self.memtable.deinit();

        self.catalog.deinit();
        self.system_vlog.deinit() catch {};
        self.system_index.deinit();
        self.allocator.destroy(self.system_index);
        self.wal.deinit() catch {};
        self.allocator.destroy(self);
    }

    fn recover(self: *Db) !void {
        const cp = try CheckpointRecord.load(self.allocator, self.io, self.config.paths.wal);

        const replay_result = try self.replay();
        defer {
            replay_result.arena.deinit();
            self.allocator.destroy(replay_result.arena);
        }

        if (replay_result.records.len == 0) {
            log.info("WAL recovery: clean start (checkpoint file_seq={d} last_flushed_lsn={d})", .{
                cp.file_seq, cp.last_flushed_lsn,
            });
            return;
        }

        log.info("WAL recovery: replaying {d} records (last_flushed_lsn={d})", .{
            replay_result.records.len, cp.last_flushed_lsn,
        });

        var applied: usize = 0;
        var skipped: usize = 0;
        var max_recovered_lsn: u64 = cp.last_flushed_lsn;

        var catalog_applied: usize = 0;
        for (replay_result.records) |record| {
            const key_store_id: u16 = @truncate((record.key >> 112) & 0xFFFF);
            if (key_store_id != SYSTEM_CATALOG_STORE_ID) continue;

            const was_applied = self.catalog.applyRecovery(record) catch |err| {
                log.warn("Recovery pass1: skipping catalog lsn={d} key={d}: {s}", .{
                    record.lsn, record.key, @errorName(err),
                });
                continue;
            };
            if (was_applied) {
                catalog_applied += 1;
                applied += 1;
                if (record.lsn > max_recovered_lsn) max_recovered_lsn = record.lsn;
            } else {
                skipped += 1;
            }
        }

        if (catalog_applied > 0) {
            try self.system_vlog.flush();
            try self.system_index.flush();
            self.load_vlogs() catch |err| {
                log.warn("Recovery: load_vlogs after pass1 failed: {}", .{err});
            };
        }

        for (replay_result.records) |record| {
            if (record.kind == .sequence) {
                self.applyRecoveredSequence(record);
                applied += 1;
                if (record.lsn > max_recovered_lsn) max_recovered_lsn = record.lsn;
                continue;
            }

            const key_store_id: u16 = @truncate((record.key >> 112) & 0xFFFF);
            if (key_store_id == SYSTEM_CATALOG_STORE_ID) continue;

            const was_applied = self.applyRecoveryRecord(record) catch |err| {
                log.warn("Recovery pass2: skipping data lsn={d} kind={s} key={d}: {s}", .{
                    record.lsn, @tagName(record.kind), record.key, @errorName(err),
                });
                continue;
            };
            if (was_applied) {
                applied += 1;
                if (record.lsn > max_recovered_lsn) max_recovered_lsn = record.lsn;
            } else {
                skipped += 1;
            }
        }

        if (applied > 0) {
            var vlog_iter = self.vlogs.iterator();
            while (vlog_iter.next()) |v| {
                try v.value_ptr.*.flush();
            }
            try self.primary_index.flush();
            var sec_iter = self.secondary_indexes.iterator();
            while (sec_iter.next()) |s| {
                try s.value_ptr.*.flush();
            }

            self.wal.flushed_lsn.store(max_recovered_lsn, .monotonic);
            self.wal.lsn.store(max_recovered_lsn, .monotonic);
            try self.wal.checkpoint();
        }

        log.info("WAL recovery done: applied={d} skipped={d} max_recovered_lsn={d}", .{
            applied, skipped, max_recovered_lsn,
        });
    }

    fn applyRecoveryRecord(self: *Db, record: LogRecord) !bool {
        const key = record.key;
        const metadata = KeyGen.extractMetadata(key);
        const vlog_id = metadata.vlog_id;

        const vlog = self.vlogs.get(vlog_id) orelse {
            log.warn("Recovery: vlog_id={d} not found, skipping key={d}", .{ vlog_id, key });
            return false;
        };

        switch (record.kind) {
            .read, .sequence => return false,

            .insert => {
                if (try self.primary_index.search(key)) |offset| {
                    var existing = try vlog.get(offset);
                    defer existing.deinit(self.allocator);
                    if (existing.lsn >= record.lsn) return false;

                    existing.tombstone = true;
                    const new_entry = VlogEntry{
                        .key = key,
                        .lsn = record.lsn,
                        .value = record.value,
                        .timestamp = record.timestamp,
                    };
                    const new_offset = try vlog.put(offset, existing, new_entry);
                    try self.updateVlogStats(vlog, new_entry.size(), existing.size(), false, .update);
                    vlog.header.lsn = record.lsn;
                    try self.primary_index.update(key, new_offset);
                    try self.updateSecondaryIndexes(key, record.value, record.lsn);
                } else {
                    const new_entry = VlogEntry{
                        .key = key,
                        .lsn = record.lsn,
                        .value = record.value,
                        .timestamp = record.timestamp,
                    };
                    const offset = try vlog.post(new_entry);
                    try self.updateVlogStats(vlog, new_entry.size(), 0, false, .insert);
                    vlog.header.lsn = record.lsn;
                    try self.primary_index.insert(key, offset);
                    try self.updateSecondaryIndexes(key, record.value, record.lsn);
                }
                return true;
            },

            .update => {
                if (try self.primary_index.search(key)) |offset| {
                    var existing = try vlog.get(offset);
                    defer existing.deinit(self.allocator);
                    if (existing.lsn >= record.lsn) return false;

                    existing.tombstone = true;
                    const new_entry = VlogEntry{
                        .key = key,
                        .lsn = record.lsn,
                        .value = record.value,
                        .timestamp = record.timestamp,
                    };
                    const new_offset = try vlog.put(offset, existing, new_entry);
                    try self.updateVlogStats(vlog, new_entry.size(), existing.size(), false, .update);
                    vlog.header.lsn = record.lsn;
                    try self.primary_index.update(key, new_offset);
                    try self.updateSecondaryIndexes(key, record.value, record.lsn);
                } else {
                    const new_entry = VlogEntry{
                        .key = key,
                        .lsn = record.lsn,
                        .value = record.value,
                        .timestamp = record.timestamp,
                    };
                    const offset = try vlog.post(new_entry);
                    try self.updateVlogStats(vlog, new_entry.size(), 0, false, .insert);
                    vlog.header.lsn = record.lsn;
                    try self.primary_index.insert(key, offset);
                    try self.updateSecondaryIndexes(key, record.value, record.lsn);
                }
                return true;
            },

            .delete => {
                const offset = (try self.primary_index.search(key)) orelse return false;
                var existing = try vlog.get(offset);
                defer existing.deinit(self.allocator);
                if (existing.tombstone) return false;

                const bytes_deleted = try vlog.del(offset);
                try self.updateVlogStats(vlog, 0, bytes_deleted, true, .delete);
                vlog.header.lsn = record.lsn;
                try self.primary_index.delete(key);
                self.removeFromSecondaryIndexes(key, existing.value) catch |e| switch (e) {
                    error.KeyNotFound => {},
                    else => log.warn("WAL replay(delete): secondary index cleanup failed for key {d}: {s}", .{ key, @errorName(e) }),
                };
                return true;
            },
        }
    }

    fn applyRecoveredSequence(self: *Db, record: LogRecord) void {
        const value = record.value;
        if (value.len < 12) return;

        const name_len = std.mem.readInt(u32, value[0..4], .little);
        if (4 + name_len + 8 > value.len) return;

        const name = value[4..][0..name_len];
        const seq_val = std.mem.readInt(i64, value[4 + name_len ..][0..8], .little);

        const result = self.recovered_sequences.getOrPut(self.allocator, name) catch return;
        if (!result.found_existing) {
            result.key_ptr.* = self.allocator.dupe(u8, name) catch return;
            result.value_ptr.* = seq_val;
        } else {
            if (seq_val > result.value_ptr.*) {
                result.value_ptr.* = seq_val;
            }
        }
    }

    pub fn replay(self: *Db) !ReplayResult {
        var arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer {
            arena.deinit();
            self.allocator.destroy(arena);
        }

        var records_to_replay: std.ArrayList(LogRecord) = .empty;

        const cp = try CheckpointRecord.load(self.allocator, self.io, self.config.paths.wal);

        var wal_files: std.ArrayList(u64) = .empty;
        defer wal_files.deinit(self.allocator);

        const wal_dir = try Dir.openDir(.cwd(), self.io, self.config.paths.wal, .{ .iterate = true });
        defer wal_dir.close(self.io);

        var dir_iter = wal_dir.iterate();
        while (try dir_iter.next(self.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".wal")) {
                const seq_str = entry.name[0 .. entry.name.len - 4];
                const seq = std.fmt.parseUnsigned(u64, seq_str, 10) catch continue;
                try wal_files.append(self.allocator, seq);
            }
        }

        std.mem.sort(u64, wal_files.items, {}, std.sort.asc(u64));

        for (wal_files.items) |seq| {
            if (seq >= cp.file_seq) {
                var file_records: std.ArrayList(LogRecord) = .empty;
                self.wal.replayFile(seq, &file_records, arena.allocator()) catch |err| {
                    log.warn("Failed to replay WAL file {d}: {s}", .{ seq, @errorName(err) });
                    continue;
                };

                for (file_records.items) |record| {
                    if (record.lsn <= cp.last_flushed_lsn) continue;
                    try records_to_replay.append(arena.allocator(), record);
                }
            }
        }

        return ReplayResult{
            .arena = arena,
            .records = try records_to_replay.toOwnedSlice(arena.allocator()),
        };
    }

    fn load_vlogs(self: *Db) !void {
        const vlog_dir = try Dir.openDir(.cwd(), self.io, self.config.paths.vlog, .{ .iterate = true });
        defer vlog_dir.close(self.io);

        var min_id: u16 = std.math.maxInt(u16);
        var max_id: u16 = 0;
        var files_found: bool = false;

        var iter = vlog_dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".vlog")) continue;
            const base = entry.name[0 .. entry.name.len - 5];
            _ = std.fmt.parseUnsigned(u16, base, 10) catch continue;

            files_found = true;

            var buf: [512]u8 = undefined;
            const vlog_file_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.config.paths.vlog, entry.name });

            const vlog = try ValueLog.init(self.allocator, .{
                .id = 0,
                .file_name = vlog_file_path,
                .max_file_size = self.config.file_sizes.vlog,
                .block_size = self.config.buffers.vlog,
                .io = self.io,
            }, self.engine_metrics);

            const vlog_id = vlog.header.id;
            try self.vlogs.put(vlog_id, vlog);

            if (vlog_id < min_id) min_id = vlog_id;
            if (vlog_id > max_id) max_id = vlog_id;

            if (vlog.header.total_bytes == 0) {
                vlog.header.total_bytes = vlog.offset;
                vlog.header.live_bytes = vlog.offset;
                vlog.header.dead_bytes = 0;
            }
        }

        if (!files_found) {
            var buf: [256]u8 = undefined;
            const vlog_file_name = try std.fmt.bufPrint(&buf, "{s}/{d}.vlog", .{ self.config.paths.vlog, 0 });
            const vlog = try ValueLog.init(self.allocator, .{
                .id = 0,
                .file_name = vlog_file_name,
                .max_file_size = self.config.file_sizes.vlog,
                .block_size = self.config.buffers.vlog,
                .io = self.io,
            }, self.engine_metrics);
            try self.vlogs.put(0, vlog);

            self.head_vlog_id = 0;
            self.tail_vlog_id = 0;
        } else {
            self.head_vlog_id = min_id;
            self.tail_vlog_id = max_id;
        }

        self.current_vlog.id = self.tail_vlog_id;
        if (self.vlogs.get(self.current_vlog.id)) |vlog| {
            self.current_vlog.offset = vlog.offset;
        }
    }

    pub fn post(self: *Db, entry: Entry) !void {
        var sw = self.engine_metrics.db.start(self.io, .Write);
        defer self.engine_metrics.db.stop(self.io, &sw, .Write);

        const switched = try self.memtable.post(entry);
        if (switched) {
            self.flush() catch |e| {
                std.log.err("memtable flush failed in post: {s}", .{@errorName(e)});
            };
        }
    }

    pub fn put(self: *Db, lsn: u64, key: u128, value: []const u8, timestamp: i64) !void {
        var sw = self.engine_metrics.db.start(self.io, .Update);
        defer self.engine_metrics.db.stop(self.io, &sw, .Update);

        const switched = try self.memtable.put(lsn, key, value, timestamp);
        if (switched) {
            self.flush() catch |e| {
                std.log.err("memtable flush failed in post: {s}", .{@errorName(e)});
            };
        }
    }

    pub fn del(self: *Db, lsn: u64, key: u128, timestamp: i64) !void {
        var sw = self.engine_metrics.db.start(self.io, .Write);
        defer self.engine_metrics.db.stop(self.io, &sw, .Write);

        var value: []const u8 = &[_]u8{};
        var vlog_entry: ?VlogEntry = null;
        defer if (vlog_entry) |*e| e.deinit(self.allocator);

        if (self.memtable.pendingDelete(key)) {
            log.warn("del: key {d} already has pending tombstone, skipping", .{key});
            return;
        }

        if (self.memtable.get(key)) |v| {
            value = v;
        } else |_| {
            if (try self.primary_index.search(key)) |old_offset| {
                const metadata = KeyGen.extractMetadata(key);
                if (self.vlogs.get(metadata.vlog_id)) |vlog| {
                    vlog_entry = try vlog.get(old_offset);
                    value = vlog_entry.?.value;
                }
            } else {
                log.debug("del: key {d} not in primary index (idempotent)", .{key});
                return;
            }
        }

        const switched = try self.memtable.post(.{
            .lsn = lsn,
            .key = key,
            .value = value,
            .timestamp = timestamp,
            .kind = .delete,
        });
        if (switched) {
            self.flush() catch |e| {
                std.log.err("memtable flush failed in post: {s}", .{@errorName(e)});
            };
        }
    }

    pub fn get(self: *Db, key: u128) ![]const u8 {
        var sw = self.engine_metrics.db.start(self.io, .Read);
        const ret = self.memtable.get(key) catch |e| {
            if (e == error.NotFound) {
                const key_u128: u128 = @bitCast(key);
                if (try self.primary_index.search(key_u128)) |offset| {
                    const metadata = KeyGen.extractMetadata(key_u128);
                    if (self.vlogs.get(metadata.vlog_id)) |vlog| {
                        var vlog_entry = try vlog.get(offset);
                        defer vlog_entry.deinit(self.allocator);

                        if (vlog_entry.tombstone) {
                            self.engine_metrics.db.stop(self.io, &sw, .Read);
                            return error.NotFound;
                        }
                        self.engine_metrics.db.stop(self.io, &sw, .Read);
                        return try self.allocator.dupe(u8, vlog_entry.value);
                    }
                }
                self.engine_metrics.db.stop(self.io, &sw, .Read);
                return error.NotFound;
            }
            self.engine_metrics.db.stop(self.io, &sw, .Read);
            return e;
        };
        if (ret.len > 0) {
            self.engine_metrics.db.stop(self.io, &sw, .Read);
            return try self.allocator.dupe(u8, ret);
        }
        self.engine_metrics.db.stop(self.io, &sw, .Read);
        return error.NotFound;
    }

    pub fn getByOffset(self: *Db, key: u128, offset: u64) ![]const u8 {
        const ret = self.memtable.get(key) catch |e| {
            if (e == error.NotFound) {
                const metadata = KeyGen.extractMetadata(key);
                if (self.vlogs.get(metadata.vlog_id)) |vlog| {
                    var vlog_entry = try vlog.get(offset);
                    defer vlog_entry.deinit(self.allocator);

                    if (vlog_entry.tombstone) {
                        return error.NotFound;
                    }

                    return try self.allocator.dupe(u8, vlog_entry.value);
                }
                return error.NotFound;
            }
            return e;
        };
        if (ret.len > 0) {
            return try self.allocator.dupe(u8, ret);
        }
        return error.NotFound;
    }

    pub fn shutdown(self: *Db) !void {
        try self.memtable.switchActive();
        try self.flush();
    }

    pub fn createSecondaryIndex(self: *Db, store_id: u16, index_ns: []const u8, field_name: []const u8, field_type: proto.FieldType) !void {
        if (self.secondary_indexes.contains(index_ns)) return;

        var idx_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const index_path = try std.fmt.bufPrint(&idx_path_buf, "{s}/{s}.idx", .{
            self.config.paths.index, index_ns,
        });

        _ = try self.catalog.createIndexForStore(store_id, index_ns, field_name, field_type, false, index_path);

        try self.flushOnDemand();

        const index_ns_owned = try self.allocator.dupe(u8, index_ns);
        errdefer self.allocator.free(index_ns_owned);

        const index_ptr = try self.allocator.create(Index([]const u8, void));
        index_ptr.* = try Index([]const u8, void).init(self.allocator, .{
            .dir_path = self.config.paths.index,
            .file_name = index_ns_owned,
            .pool_size = self.config.index.secondary.pool_size,
            .io = self.io,
        }, self.engine_metrics);

        try self.secondary_indexes.put(index_ns_owned, index_ptr);

        var extractor = FieldExtractor.init(self.allocator);
        var doc_count: usize = 0;

        {
            var iter = try self.primary_index.iterator();
            defer iter.deinit();

            while (try iter.next()) |cell| {
                if (cell.key.len >= 16) {
                    const primary_key = std.mem.readInt(u128, cell.key[0..16], .big);

                    const metadata = KeyGen.extractMetadata(primary_key);
                    if (metadata.store_id != store_id) {
                        continue;
                    }

                    if (cell.value.len >= 8) {
                        const offset = std.mem.readInt(u64, cell.value[0..8], .little);

                        if (self.vlogs.get(metadata.vlog_id)) |vlog| {
                            var vlog_entry = vlog.get(offset) catch continue;
                            defer vlog_entry.deinit(self.allocator);

                            if (vlog_entry.tombstone) continue;

                            const field_value = try extractor.extract(vlog_entry.value, field_name, field_type);
                            defer if (field_value) |fv| fv.deinit(self.allocator);

                            if (field_value) |fv| {
                                var composite_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;
                                const composite_key = try self.makeCompositeKey(&composite_key_buf, fv, primary_key);
                                try index_ptr.insert(composite_key, {});
                                doc_count += 1;
                            }
                        }
                    }
                }
            }
        }

        try index_ptr.flush();
    }

    fn updateSecondaryIndexes(self: *Db, primary_key: u128, value: []const u8, lsn: u64) !void {
        const metadata = KeyGen.extractMetadata(primary_key);
        const store_id = metadata.store_id;

        const indexes_list = self.catalog.getIndexesByStoreId(store_id) orelse return;

        var extractor = FieldExtractor.init(self.allocator);

        for (indexes_list.items) |index_meta| {
            if (self.secondary_indexes.get(index_meta.ns)) |index| {
                const field_value = try extractor.extract(value, index_meta.field, index_meta.field_type);
                defer if (field_value) |fv| fv.deinit(self.allocator);

                if (field_value) |fv| {
                    var composite_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;
                    const composite_key = try self.makeCompositeKey(&composite_key_buf, fv, primary_key);
                    index.tree.lsn = lsn;
                    try index.insert(composite_key, {});
                }
            }
        }
    }

    fn removeFromSecondaryIndexes(self: *Db, primary_key: u128, value: []const u8) !void {
        const metadata = KeyGen.extractMetadata(primary_key);
        const store_id = metadata.store_id;

        const indexes_list = self.catalog.getIndexesByStoreId(store_id) orelse return;

        var extractor = FieldExtractor.init(self.allocator);

        for (indexes_list.items) |index_meta| {
            if (self.secondary_indexes.get(index_meta.ns)) |index| {
                const field_value = try extractor.extract(value, index_meta.field, index_meta.field_type);
                defer if (field_value) |fv| fv.deinit(self.allocator);

                if (field_value) |fv| {
                    var composite_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;
                    const composite_key = try self.makeCompositeKey(&composite_key_buf, fv, primary_key);

                    try index.delete(composite_key);
                }
            }
        }
    }

    fn makeCompositeKey(_: *Db, buf: []u8, field_value: FieldValue, primary_key: u128) ![]const u8 {
        const max_key_size = MAX_KEY_SIZE;
        var offset: usize = 0;

        switch (field_value) {
            .string => |s| {
                const copy_len = @min(s.len, max_key_size);
                @memcpy(buf[offset..][0..copy_len], s[0..copy_len]);
                if (copy_len < max_key_size) {
                    @memset(buf[offset + copy_len .. offset + max_key_size], 0);
                }
                offset += max_key_size;
            },
            .u64_val => |v| {
                std.mem.writeInt(u64, buf[offset..][0..8], v, .big);
                offset += 8;
            },
            .i64_val => |v| {
                const biased: u64 = @bitCast(v ^ @as(i64, std.math.minInt(i64)));
                std.mem.writeInt(u64, buf[offset..][0..8], biased, .big);
                offset += 8;
            },
            .u32_val => |v| {
                std.mem.writeInt(u32, buf[offset..][0..4], v, .big);
                offset += 4;
            },
            .i32_val => |v| {
                const biased: u32 = @bitCast(v ^ @as(i32, std.math.minInt(i32)));
                std.mem.writeInt(u32, buf[offset..][0..4], biased, .big);
                offset += 4;
            },
            .bool_val => |v| {
                buf[offset] = if (v) 1 else 0;
                offset += 1;
            },
            .f64_val => |v| {
                const bits: u64 = @bitCast(v);
                const sortable = if (v >= 0.0)
                    bits ^ 0x8000000000000000
                else
                    ~bits;
                std.mem.writeInt(u64, buf[offset..][0..8], sortable, .big);
                offset += 8;
            },
        }

        std.mem.writeInt(u128, buf[offset..][0..16], primary_key, .big);
        offset += 16;

        return buf[0..offset];
    }

    fn convertFieldValue(fv: FieldValue, target_type: proto.FieldType) FieldValue {
        return switch (target_type) {
            .U32 => switch (fv) {
                .i64_val => |v| FieldValue{ .u32_val = std.math.lossyCast(u32, v) },
                .i32_val => |v| FieldValue{ .u32_val = std.math.lossyCast(u32, v) },
                .u64_val => |v| FieldValue{ .u32_val = std.math.lossyCast(u32, v) },
                else => fv,
            },
            .I32 => switch (fv) {
                .i64_val => |v| FieldValue{ .i32_val = std.math.lossyCast(i32, v) },
                .u32_val => |v| FieldValue{ .i32_val = std.math.lossyCast(i32, v) },
                .u64_val => |v| FieldValue{ .i32_val = std.math.lossyCast(i32, v) },
                else => fv,
            },
            .U64 => switch (fv) {
                .i64_val => |v| FieldValue{ .u64_val = std.math.lossyCast(u64, v) },
                .i32_val => |v| FieldValue{ .u64_val = std.math.lossyCast(u64, v) },
                .u32_val => |v| FieldValue{ .u64_val = v },
                else => fv,
            },
            .I64 => switch (fv) {
                .u64_val => |v| FieldValue{ .i64_val = std.math.lossyCast(i64, v) },
                .i32_val => |v| FieldValue{ .i64_val = v },
                .u32_val => |v| FieldValue{ .i64_val = v },
                else => fv,
            },
            .F64 => switch (fv) {
                .i64_val => |v| FieldValue{ .f64_val = @floatFromInt(v) },
                .i32_val => |v| FieldValue{ .f64_val = @floatFromInt(v) },
                .u64_val => |v| FieldValue{ .f64_val = @floatFromInt(v) },
                .u32_val => |v| FieldValue{ .f64_val = @floatFromInt(v) },
                else => fv,
            },
            else => fv,
        };
    }

    fn updateVlogStats(self: *Db, vlog: *ValueLog, bytes_written: u64, bytes_erased: u64, is_delete: bool, op: OpKind) !void {
        _ = self;
        if (op == .insert) {
            vlog.header.total_bytes += bytes_written;
            vlog.header.live_bytes += bytes_written;
        } else if (op == .delete) {
            vlog.header.live_bytes -|= bytes_erased;
            vlog.header.dead_bytes += bytes_erased;
        } else if (op == .update) {
            vlog.header.total_bytes += bytes_written;
            vlog.header.live_bytes = (vlog.header.live_bytes + bytes_written) -| bytes_erased;
            vlog.header.dead_bytes += bytes_erased;
        }

        if (is_delete) {
            if (vlog.header.count > 0) vlog.header.count -= 1;
            vlog.header.deleted += 1;
        } else {
            vlog.header.count += 1;
        }
    }

    fn maybeRotateVlog(self: *Db) !void {
        if (self.vlogs.get(self.current_vlog.id)) |current_vlog| {
            if (current_vlog.offset >= self.config.file_sizes.vlog) {
                try current_vlog.flush();

                const new_vlog_id = self.tail_vlog_id + 1;
                var buf: [256]u8 = undefined;
                const vlog_file_name = try std.fmt.bufPrint(&buf, "{s}/{d}.vlog", .{ self.config.paths.vlog, new_vlog_id });
                const new_vlog = try ValueLog.init(self.allocator, .{
                    .id = new_vlog_id,
                    .file_name = vlog_file_name,
                    .max_file_size = self.config.file_sizes.vlog,
                    .block_size = self.config.buffers.vlog,
                    .io = self.io,
                }, self.engine_metrics);

                try self.vlogs.put(new_vlog_id, new_vlog);

                self.tail_vlog_id = new_vlog_id;
                self.current_vlog.id = new_vlog_id;
                self.current_vlog.offset = 0;
            }
        }
    }

    pub fn flushOnDemand(self: *Db) !void {
        try self.memtable.switchActive();
        try self.flush();
    }

    pub fn flush(self: *Db) !void {
        var sw = self.engine_metrics.db.start(self.io, .Flush);
        defer self.engine_metrics.db.stop(self.io, &sw, .Flush);

        try self.maybeRotateVlog();

        var flush_total: u32 = 0;
        var flush_skipped: u32 = 0;

        {
            var sl_iter = self.memtable.lists.iterator();
            while (sl_iter.next()) |skl| self.count += skl.count;
        }

        {
            var sl_iter = self.memtable.lists.iterator();
            while (sl_iter.next()) |skl| {
                var iter = skl.iterator();
                while (iter.next()) |entry| {
                    if (entry.kind == .delete) continue;
                    flush_total += 1;
                    self.wal.flushedLSN(entry.lsn);
                    const metadata = KeyGen.extractMetadata(entry.key);
                    if (self.vlogs.get(metadata.vlog_id)) |vlog| {
                        vlog.header.lsn = entry.lsn;
                        const vlog_entry = VlogEntry{
                            .key = entry.key,
                            .lsn = entry.lsn,
                            .value = entry.value,
                            .timestamp = entry.timestamp,
                        };

                        if (entry.kind == .insert) {
                            const offset = try vlog.post(vlog_entry);
                            try self.updateVlogStats(vlog, vlog_entry.size(), 0, false, .insert);
                            self.primary_index.tree.lsn = entry.lsn;
                            self.primary_index.insert(entry.key, offset) catch |e| {
                                if (e == error.KeyAlreadyExists) {
                                    log.err("Flush(insert): primary index insert failed for key {d}: {s}", .{ entry.key, @errorName(e) });
                                    const bytes_deleted = vlog.del(offset) catch 0;
                                    self.updateVlogStats(vlog, 0, bytes_deleted, true, .delete) catch {};
                                    continue;
                                }
                                log.err("Flush(insert): primary index insert failed for key {d}: {s}", .{ entry.key, @errorName(e) });
                                continue;
                            };
                            try self.updateSecondaryIndexes(entry.key, entry.value, entry.lsn);
                        } else {
                            const old_offset = self.primary_index.search(entry.key) catch |e| {
                                log.err("Flush(update): failed to search primary index for key {d}: {s}", .{ entry.key, @errorName(e) });
                                return e;
                            };
                            if (old_offset) |ooffset| {
                                var oentry = vlog.get(ooffset) catch |err| {
                                    log.err("Flush(update): failed to read old entry at offset {d}: {s}", .{ ooffset, @errorName(err) });
                                    return err;
                                };
                                defer oentry.deinit(self.allocator);
                                oentry.tombstone = true;
                                const offset = try vlog.put(ooffset, oentry, vlog_entry);
                                try self.updateVlogStats(vlog, entry.value.len, oentry.size(), false, .update);
                                self.primary_index.tree.lsn = entry.lsn;
                                self.primary_index.update(entry.key, offset) catch |e| {
                                    log.err("Flush(update): failed to update primary index for key {d}: {s}", .{ entry.key, @errorName(e) });
                                    return e;
                                };
                            } else {
                                const offset = try vlog.post(vlog_entry);
                                try self.updateVlogStats(vlog, vlog_entry.size(), 0, false, .insert);
                                self.primary_index.tree.lsn = entry.lsn;
                                try self.primary_index.insert(entry.key, offset);
                                try self.updateSecondaryIndexes(entry.key, entry.value, entry.lsn);
                            }
                        }
                    } else {
                        flush_skipped += 1;
                        log.warn("Flush(upsert): skipping entry - vlog_id={d} not found in vlogs map", .{metadata.vlog_id});
                    }
                }
            }
        }

        {
            var sl_iter = self.memtable.lists.iterator();
            while (sl_iter.next()) |skl| {
                var iter = skl.iterator();
                while (iter.next()) |entry| {
                    if (entry.kind != .delete) continue;
                    flush_total += 1;
                    self.wal.flushedLSN(entry.lsn);
                    const metadata = KeyGen.extractMetadata(entry.key);
                    if (self.vlogs.get(metadata.vlog_id)) |vlog| {
                        vlog.header.lsn = entry.lsn;
                        const old_offset = self.primary_index.search(entry.key) catch |e| {
                            if (e != error.NotFound) log.err("Failed to search primary index for key {d}: {s}", .{ entry.key, @errorName(e) });
                            return e;
                        };
                        const ooffset = old_offset orelse {
                            log.debug("Flush(delete): key {d} not in primary index, skipping transient key", .{entry.key});
                            continue;
                        };
                        const bytes_deleted = try vlog.del(ooffset);
                        try self.updateVlogStats(vlog, 0, bytes_deleted, true, .delete);
                        try self.primary_index.delete(entry.key);
                        self.removeFromSecondaryIndexes(entry.key, entry.value) catch |e| switch (e) {
                            error.KeyNotFound => {},
                            else => log.warn("Flush(delete): secondary index cleanup failed for key {d}: {s}", .{ entry.key, @errorName(e) }),
                        };
                    } else {
                        flush_skipped += 1;
                        log.warn("Flush(delete): skipping entry - vlog_id={d} not found in vlogs map", .{metadata.vlog_id});
                    }
                }
            }
        }

        while (self.memtable.lists.pop()) |skl| skl.deinit();

        var vlog_iter = self.vlogs.iterator();
        while (vlog_iter.next()) |vlog| {
            try vlog.value_ptr.*.flush();
        }

        self.primary_index.tree.lsn = self.wal.flushed_lsn.load(.monotonic);
        try self.primary_index.flush();

        var sec_iter = self.secondary_indexes.iterator();
        while (sec_iter.next()) |sec_entry| {
            sec_entry.value_ptr.*.tree.lsn = self.wal.flushed_lsn.load(.monotonic);
            try sec_entry.value_ptr.*.flush();
        }

        self.wal.checkpoint() catch |e| {
            log.err("Failed to checkpoint WAL after flush: {s}", .{@errorName(e)});
            return e;
        };

        if (self.replication) |repl| {
            repl.shipFlush();
        }
    }

    pub fn findBySecondaryIndex(self: *Db, index_ns: []const u8, field_value: FieldValue) !std.ArrayList(u128) {
        var result: std.ArrayList(u128) = .empty;

        const index = self.secondary_indexes.get(index_ns) orelse return error.IndexNotFound;

        const index_meta = self.catalog.indexes.get(index_ns);
        const converted_fv = if (index_meta) |meta|
            convertFieldValue(field_value, meta.field_type)
        else
            field_value;

        var start_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;
        var end_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;

        const start_key = try self.makeCompositeKey(&start_key_buf, converted_fv, 0);
        const end_key = try self.makeCompositeKey(&end_key_buf, converted_fv, std.math.maxInt(u128));

        var iter = try index.tree.rangeScan(start_key, end_key);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            const key_len = entry.key.len;
            if (key_len >= 16) {
                const primary_key = std.mem.readInt(u128, entry.key[key_len - 16 ..][0..16], .big);
                try result.append(self.allocator, primary_key);
            }
        }

        return result;
    }

    pub fn secondaryIndexIterator(self: *Db, index_ns: []const u8) !RangeIterator {
        const index = self.secondary_indexes.get(index_ns) orelse return error.IndexNotFound;
        const index_meta = self.catalog.indexes.get(index_ns);

        var start_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;
        var end_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;

        const start_key = try self.makeMinCompositeKey(&start_key_buf, index_meta);
        const end_key = try self.makeMaxCompositeKey(&end_key_buf, index_meta);

        return index.tree.rangeScan(start_key, end_key);
    }

    pub const SecondaryRangeCtx = struct {
        iter: RangeIterator,
        has_min: bool,
        has_max: bool,
        min_inclusive: bool,
        max_inclusive: bool,
        start_field_len: usize,
        end_field_len: usize,
        start_field_buf: [MAX_KEY_SIZE]u8,
        end_field_buf: [MAX_KEY_SIZE]u8,

        pub fn next(self: *SecondaryRangeCtx) !?u128 {
            while (true) {
                const entry = try self.iter.next() orelse return null;
                const key_len = entry.key.len;
                if (key_len < 16) continue;

                const primary_key = std.mem.readInt(u128, entry.key[key_len - 16 ..][0..16], .big);
                const field_bytes = entry.key[0 .. key_len - 16];

                if (self.has_min and !self.min_inclusive) {
                    if (std.mem.eql(u8, field_bytes, self.start_field_buf[0..self.start_field_len])) continue;
                }
                if (self.has_max and !self.max_inclusive) {
                    if (std.mem.eql(u8, field_bytes, self.end_field_buf[0..self.end_field_len])) continue;
                }

                return primary_key;
            }
        }

        pub fn deinit(self: *SecondaryRangeCtx) void {
            self.iter.deinit();
        }
    };

    pub fn secondaryIndexRangeIterator(self: *Db, index_ns: []const u8, min_val: ?FieldValue, max_val: ?FieldValue, min_inclusive: bool, max_inclusive: bool) !SecondaryRangeCtx {
        const index = self.secondary_indexes.get(index_ns) orelse return error.IndexNotFound;
        const index_meta = self.catalog.indexes.get(index_ns);

        const conv_min = if (min_val) |v| (if (index_meta) |meta| convertFieldValue(v, meta.field_type) else v) else null;
        const conv_max = if (max_val) |v| (if (index_meta) |meta| convertFieldValue(v, meta.field_type) else v) else null;

        var start_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;
        var end_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;

        const start_key = if (conv_min) |v|
            try self.makeCompositeKey(&start_key_buf, v, 0)
        else
            try self.makeMinCompositeKey(&start_key_buf, index_meta);

        const end_key = if (conv_max) |v|
            try self.makeCompositeKey(&end_key_buf, v, std.math.maxInt(u128))
        else
            try self.makeMaxCompositeKey(&end_key_buf, index_meta);

        var ctx = SecondaryRangeCtx{
            .iter = try index.tree.rangeScan(start_key, end_key),
            .has_min = conv_min != null,
            .has_max = conv_max != null,
            .min_inclusive = min_inclusive,
            .max_inclusive = max_inclusive,
            .start_field_len = 0,
            .end_field_len = 0,
            .start_field_buf = undefined,
            .end_field_buf = undefined,
        };

        if (conv_min != null) {
            const field_len = start_key.len - 16;
            @memcpy(ctx.start_field_buf[0..field_len], start_key[0..field_len]);
            ctx.start_field_len = field_len;
        }
        if (conv_max != null) {
            const field_len = end_key.len - 16;
            @memcpy(ctx.end_field_buf[0..field_len], end_key[0..field_len]);
            ctx.end_field_len = field_len;
        }

        return ctx;
    }

    pub fn findBySecondaryIndexRange(self: *Db, index_ns: []const u8, min_val: ?FieldValue, max_val: ?FieldValue, min_inclusive: bool, max_inclusive: bool) !std.ArrayList(u128) {
        var result: std.ArrayList(u128) = .empty;

        const index = self.secondary_indexes.get(index_ns) orelse return error.IndexNotFound;
        const index_meta = self.catalog.indexes.get(index_ns);

        const conv_min = if (min_val) |v| (if (index_meta) |meta| convertFieldValue(v, meta.field_type) else v) else null;
        const conv_max = if (max_val) |v| (if (index_meta) |meta| convertFieldValue(v, meta.field_type) else v) else null;

        var start_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;
        var end_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;

        const start_key = if (conv_min) |v|
            try self.makeCompositeKey(&start_key_buf, v, 0)
        else
            try self.makeMinCompositeKey(&start_key_buf, index_meta);

        const end_key = if (conv_max) |v|
            try self.makeCompositeKey(&end_key_buf, v, std.math.maxInt(u128))
        else
            try self.makeMaxCompositeKey(&end_key_buf, index_meta);

        var iter = try index.tree.rangeScan(start_key, end_key);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            const key_len = entry.key.len;
            if (key_len < 16) continue;

            const primary_key = std.mem.readInt(u128, entry.key[key_len - 16 ..][0..16], .big);

            if (conv_min != null and !min_inclusive) {
                const field_bytes = entry.key[0 .. key_len - 16];
                const bound_bytes = start_key[0 .. start_key.len - 16];
                if (std.mem.eql(u8, field_bytes, bound_bytes)) continue;
            }
            if (conv_max != null and !max_inclusive) {
                const field_bytes = entry.key[0 .. key_len - 16];
                const bound_bytes = end_key[0 .. end_key.len - 16];
                if (std.mem.eql(u8, field_bytes, bound_bytes)) continue;
            }

            try result.append(self.allocator, primary_key);
        }

        return result;
    }

    pub fn findBySecondaryIndexMulti(self: *Db, index_ns: []const u8, values: []const FieldValue) !std.ArrayList(u128) {
        var result: std.ArrayList(u128) = .empty;
        var seen = std.AutoHashMap(u128, void).init(self.allocator);
        defer seen.deinit();

        for (values) |fv| {
            var keys = try self.findBySecondaryIndex(index_ns, fv);
            defer keys.deinit(self.allocator);
            for (keys.items) |pk| {
                if (!seen.contains(pk)) {
                    try seen.put(pk, {});
                    try result.append(self.allocator, pk);
                }
            }
        }

        return result;
    }

    pub fn countBySecondaryIndex(self: *Db, index_ns: []const u8, field_value: FieldValue) !u64 {
        var count: u64 = 0;

        const index = self.secondary_indexes.get(index_ns) orelse return error.IndexNotFound;

        const index_meta = self.catalog.indexes.get(index_ns);
        const converted_fv = if (index_meta) |meta|
            convertFieldValue(field_value, meta.field_type)
        else
            field_value;

        var start_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;
        var end_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;

        const start_key = try self.makeCompositeKey(&start_key_buf, converted_fv, 0);
        const end_key = try self.makeCompositeKey(&end_key_buf, converted_fv, std.math.maxInt(u128));

        var iter = try index.tree.rangeScan(start_key, end_key);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            if (entry.key.len >= 16) {
                count += 1;
            }
        }

        return count;
    }

    pub fn countBySecondaryIndexRange(self: *Db, index_ns: []const u8, min_val: ?FieldValue, max_val: ?FieldValue, min_inclusive: bool, max_inclusive: bool) !u64 {
        var count: u64 = 0;

        const index = self.secondary_indexes.get(index_ns) orelse return error.IndexNotFound;
        const index_meta = self.catalog.indexes.get(index_ns);

        const conv_min = if (min_val) |v| (if (index_meta) |meta| convertFieldValue(v, meta.field_type) else v) else null;
        const conv_max = if (max_val) |v| (if (index_meta) |meta| convertFieldValue(v, meta.field_type) else v) else null;

        var start_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;
        var end_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;

        const start_key = if (conv_min) |v|
            try self.makeCompositeKey(&start_key_buf, v, 0)
        else
            try self.makeMinCompositeKey(&start_key_buf, index_meta);

        const end_key = if (conv_max) |v|
            try self.makeCompositeKey(&end_key_buf, v, std.math.maxInt(u128))
        else
            try self.makeMaxCompositeKey(&end_key_buf, index_meta);

        var iter = try index.tree.rangeScan(start_key, end_key);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            const key_len = entry.key.len;
            if (key_len < 16) continue;

            if (conv_min != null and !min_inclusive) {
                const field_bytes = entry.key[0 .. key_len - 16];
                const bound_bytes = start_key[0 .. start_key.len - 16];
                if (std.mem.eql(u8, field_bytes, bound_bytes)) continue;
            }
            if (conv_max != null and !max_inclusive) {
                const field_bytes = entry.key[0 .. key_len - 16];
                const bound_bytes = end_key[0 .. end_key.len - 16];
                if (std.mem.eql(u8, field_bytes, bound_bytes)) continue;
            }

            count += 1;
        }

        return count;
    }

    pub fn countBySecondaryIndexMulti(self: *Db, index_ns: []const u8, values: []const FieldValue) !u64 {
        var total: u64 = 0;
        var seen = std.AutoHashMap(u128, void).init(self.allocator);
        defer seen.deinit();

        const index_obj = self.secondary_indexes.get(index_ns) orelse return error.IndexNotFound;
        const index_meta = self.catalog.indexes.get(index_ns);

        for (values) |fv| {
            const converted_fv = if (index_meta) |meta|
                convertFieldValue(fv, meta.field_type)
            else
                fv;

            var start_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;
            var end_key_buf: [MAX_KEY_SIZE + 16]u8 = undefined;

            const start_key = try self.makeCompositeKey(&start_key_buf, converted_fv, 0);
            const end_key = try self.makeCompositeKey(&end_key_buf, converted_fv, std.math.maxInt(u128));

            var iter = try index_obj.tree.rangeScan(start_key, end_key);
            defer iter.deinit();

            while (try iter.next()) |entry| {
                const key_len = entry.key.len;
                if (key_len < 16) continue;
                const primary_key = std.mem.readInt(u128, entry.key[key_len - 16 ..][0..16], .big);
                if (!seen.contains(primary_key)) {
                    try seen.put(primary_key, {});
                    total += 1;
                }
            }
        }

        return total;
    }

    fn makeMinCompositeKey(_: *Db, buf: []u8, index_meta: ?*const proto.Index) ![]const u8 {
        const max_key_size = MAX_KEY_SIZE;
        const field_size: usize = if (index_meta) |meta| switch (meta.field_type) {
            .String => max_key_size,
            .U64, .I64, .F64 => 8,
            .U32, .I32 => 4,
            .Boolean => 1,
            else => 8,
        } else 8;

        @memset(buf[0..field_size], 0);
        std.mem.writeInt(u128, buf[field_size..][0..16], 0, .big);
        return buf[0 .. field_size + 16];
    }

    fn makeMaxCompositeKey(_: *Db, buf: []u8, index_meta: ?*const proto.Index) ![]const u8 {
        const max_key_size = MAX_KEY_SIZE;
        const field_size: usize = if (index_meta) |meta| switch (meta.field_type) {
            .String => max_key_size,
            .U64, .I64, .F64 => 8,
            .U32, .I32 => 4,
            .Boolean => 1,
            else => 8,
        } else 8;

        @memset(buf[0..field_size], 0xFF);
        std.mem.writeInt(u128, buf[field_size..][0..16], std.math.maxInt(u128), .big);
        return buf[0 .. field_size + 16];
    }

    const VlogReadRequest = struct {
        key: u128,
        offset: u64,
    };

    pub fn getBySecondaryIndex(self: *Db, index_ns: []const u8, field_value: FieldValue) !std.ArrayList([]const u8) {
        var result: std.ArrayList([]const u8) = .empty;

        const primary_keys = try self.findBySecondaryIndex(index_ns, field_value);
        defer primary_keys.deinit(self.allocator);

        if (primary_keys.items.len == 0) return result;

        var by_vlog = std.AutoHashMap(u16, std.ArrayList(VlogReadRequest)).init(self.allocator);
        defer {
            var iter = by_vlog.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit();
            }
            by_vlog.deinit();
        }

        for (primary_keys.items) |key| {
            if (try self.primary_index.search(key)) |offset| {
                const metadata = KeyGen.extractMetadata(key);
                const vlog_id = metadata.vlog_id;

                var list = by_vlog.get(vlog_id) orelse blk: {
                    const new_list = std.ArrayList(VlogReadRequest).init(self.allocator);
                    try by_vlog.put(vlog_id, new_list);
                    break :blk new_list;
                };

                try list.append(VlogReadRequest{ .key = key, .offset = offset });
                try by_vlog.put(vlog_id, list);
            }
        }

        var iter = by_vlog.iterator();
        while (iter.next()) |entry| {
            const requests = entry.value_ptr;
            std.mem.sort(VlogReadRequest, requests.items, {}, struct {
                fn lessThan(_: void, a: VlogReadRequest, b: VlogReadRequest) bool {
                    return a.offset < b.offset;
                }
            }.lessThan);
        }

        var vlog_iter = by_vlog.iterator();
        while (vlog_iter.next()) |entry| {
            const vlog_id = entry.key_ptr.*;
            const requests = entry.value_ptr;

            if (self.vlogs.get(vlog_id)) |vlog| {
                for (requests.items) |req| {
                    var vlog_entry = vlog.get(req.offset) catch {
                        const value = self.get(@bitCast(req.key)) catch continue;
                        try result.append(self.allocator, value);
                        continue;
                    };
                    defer vlog_entry.deinit(self.allocator);

                    if (vlog_entry.tombstone) continue;

                    const value_copy = try self.allocator.dupe(u8, vlog_entry.value);
                    try result.append(self.allocator, value_copy);
                }
            } else {
                for (requests.items) |req| {
                    const value = self.get(@intCast(req.key)) catch continue;
                    try result.append(self.allocator, value);
                }
            }
        }

        return result;
    }

    pub fn garbageCollect(self: *Db, vlog_ids: []const u16) !void {
        for (vlog_ids) |vlog_id| {
            try self.garbageCollectSingle(vlog_id);
        }
    }

    pub fn repairInterruptedGc(allocator: Allocator, vlog_path: []const u8, index_path: []const u8, io: Io) !usize {
        var vlog_dir = Dir.openDir(.cwd(), io, vlog_path, .{ .iterate = true }) catch return 0;
        defer vlog_dir.close(io);

        var markers: std.ArrayList([]const u8) = .empty;
        defer {
            for (markers.items) |m| allocator.free(m);
            markers.deinit(allocator);
        }
        var orphans: std.ArrayList([]const u8) = .empty;
        defer {
            for (orphans.items) |m| allocator.free(m);
            orphans.deinit(allocator);
        }
        {
            var it = vlog_dir.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.startsWith(u8, entry.name, "gc_")) continue;
                if (std.mem.endsWith(u8, entry.name, ".inprogress")) {
                    try markers.append(allocator, try allocator.dupe(u8, entry.name));
                } else {
                    try orphans.append(allocator, try allocator.dupe(u8, entry.name));
                }
            }
        }

        // No marker => no swap had started, so every gc_* shadow is a leftover from
        // a build phase that crashed before the commit. The real {id}.vlog / primary.idx
        // are untouched and authoritative, so the shadows are pure orphans. This runs at
        // startup only (GC never runs concurrently), and uses collect-then-delete so a
        // directory is never mutated mid-iteration. Returns 0: no swaps were rolled forward.
        if (markers.items.len == 0) {
            for (orphans.items) |name| Dir.deleteFile(vlog_dir, io, name) catch {};

            var idx_dir = Dir.openDir(.cwd(), io, index_path, .{ .iterate = true }) catch return 0;
            defer idx_dir.close(io);
            var idx_orphans: std.ArrayList([]const u8) = .empty;
            defer {
                for (idx_orphans.items) |m| allocator.free(m);
                idx_orphans.deinit(allocator);
            }
            {
                var it = idx_dir.iterate();
                while (it.next(io) catch null) |entry| {
                    if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "gc_")) {
                        try idx_orphans.append(allocator, try allocator.dupe(u8, entry.name));
                    }
                }
            }
            for (idx_orphans.items) |name| Dir.deleteFile(idx_dir, io, name) catch {};
            return 0;
        }

        const index_dir = Dir.openDir(.cwd(), io, index_path, .{}) catch return 0;

        for (markers.items) |marker| {
            const id_str = marker["gc_".len .. marker.len - ".inprogress".len];
            var sbuf: [64]u8 = undefined;
            var obuf: [64]u8 = undefined;
            const shadow_fn = std.fmt.bufPrint(&sbuf, "gc_{s}.vlog", .{id_str}) catch continue;
            const orig_fn = std.fmt.bufPrint(&obuf, "{s}.vlog", .{id_str}) catch continue;
            Dir.rename(vlog_dir, shadow_fn, vlog_dir, orig_fn, io) catch {};
        }
        Dir.rename(index_dir, "gc_primary.idx", index_dir, "primary.idx", io) catch {};
        for (markers.items) |marker| Dir.deleteFile(vlog_dir, io, marker) catch {};
        return markers.items.len;
    }

    fn garbageCollectSingle(self: *Db, vlog_id: u16) !void {
        try self.flushOnDemand();

        const old_vlog = self.vlogs.get(vlog_id) orelse return error.VlogNotFound;

        const index_dir = try Dir.openDir(.cwd(), self.io, self.config.paths.index, .{});

        try Dir.copyFile(index_dir, "primary.idx", index_dir, "gc_primary.idx", self.io, .{});

        var shadow_index = try Index(u128, u64).init(self.allocator, .{
            .dir_path = self.config.paths.index,
            .file_name = "gc_primary",
            .pool_size = self.config.index.primary.pool_size,
            .io = self.io,
        }, self.engine_metrics);

        var vlog_buf: [256]u8 = undefined;
        const shadow_vlog_name = try std.fmt.bufPrint(&vlog_buf, "{s}/gc_{d}.vlog", .{ self.config.paths.vlog, vlog_id });
        const shadow_vlog = try ValueLog.init(self.allocator, .{
            .id = vlog_id,
            .file_name = shadow_vlog_name,
            .max_file_size = self.config.file_sizes.vlog,
            .block_size = self.config.buffers.vlog,
            .io = self.io,
        }, self.engine_metrics);

        var live_entries: usize = 0;

        {
            var iter = try self.primary_index.iterator();
            defer iter.deinit();

            while (try iter.next()) |cell| {
                if (cell.key.len >= 16 and cell.value.len >= 8) {
                    const key = std.mem.readInt(u128, cell.key[0..16], .big);
                    const old_offset = std.mem.readInt(u64, cell.value[0..8], .little);

                    const metadata = KeyGen.extractMetadata(key);
                    if (metadata.vlog_id != vlog_id) continue;

                    var vlog_entry = old_vlog.get(old_offset) catch continue;
                    defer vlog_entry.deinit(self.allocator);

                    if (vlog_entry.tombstone) continue;

                    const new_offset = try shadow_vlog.post(vlog_entry);
                    try shadow_index.update(key, new_offset);
                    live_entries += 1;
                }
            }
        }
        try shadow_vlog.flush();
        const vlog_header_size: u64 = 63;
        shadow_vlog.header.total_bytes = shadow_vlog.offset - vlog_header_size;
        shadow_vlog.header.live_bytes = shadow_vlog.offset - vlog_header_size;
        shadow_vlog.header.dead_bytes = 0;
        shadow_vlog.header.count = live_entries;
        shadow_vlog.header.deleted = 0;
        shadow_vlog.header.last_gc_ts = self.now.toMilliSeconds();
        try shadow_vlog.syncHeader();
        try shadow_index.flush();

        try old_vlog.deinit();
        _ = self.vlogs.remove(vlog_id);

        try shadow_vlog.deinit();
        shadow_index.deinit();

        const vlog_dir = try Dir.openDir(.cwd(), self.io, self.config.paths.vlog, .{});

        var fname_buf: [64]u8 = undefined;
        const orig_vlog_fn = try std.fmt.bufPrint(&fname_buf, "{d}.vlog", .{vlog_id});
        var sfname_buf: [64]u8 = undefined;
        const shadow_vlog_fn = try std.fmt.bufPrint(&sfname_buf, "gc_{d}.vlog", .{vlog_id});
        var marker_buf: [64]u8 = undefined;
        const marker_fn = try std.fmt.bufPrint(&marker_buf, "gc_{d}.inprogress", .{vlog_id});

        self.primary_index.deinit();

        // Crash-safe swap: the marker lets startup roll these renames forward if we crash
        // between them. rename() replaces atomically and recovery reads only the final
        // names, so a crash can never leave a missing primary.idx or {id}.vlog.
        {
            const mf = try Dir.createFile(vlog_dir, self.io, marker_fn, .{ .truncate = true });
            mf.close(self.io);
        }
        try Dir.rename(vlog_dir, shadow_vlog_fn, vlog_dir, orig_vlog_fn, self.io);
        try Dir.rename(index_dir, "gc_primary.idx", index_dir, "primary.idx", self.io);
        Dir.deleteFile(vlog_dir, self.io, marker_fn) catch {};

        self.primary_index.* = try Index(u128, u64).init(self.allocator, .{
            .dir_path = self.config.paths.index,
            .file_name = "primary",
            .pool_size = self.config.index.primary.pool_size,
            .io = self.io,
        }, self.engine_metrics);

        var orig_buf: [256]u8 = undefined;
        const orig_vlog_path = try std.fmt.bufPrint(&orig_buf, "{s}/{d}.vlog", .{ self.config.paths.vlog, vlog_id });
        const new_vlog = try ValueLog.init(self.allocator, .{
            .id = vlog_id,
            .file_name = orig_vlog_path,
            .max_file_size = self.config.file_sizes.vlog,
            .block_size = self.config.buffers.vlog,
            .io = self.io,
        }, self.engine_metrics);
        try self.vlogs.put(vlog_id, new_vlog);

        log.info("GC complete for vlog {d}: {} live entries - vlog and primary index switched over", .{ vlog_id, live_entries });
    }

    pub fn removeStoreEntries(self: *Db, store_id: u16) !u64 {
        const range = KeyGen.storeKeyRange(store_id);

        var keys_to_delete: std.ArrayList(u128) = .empty;
        defer keys_to_delete.deinit(self.allocator);
        var offsets_to_delete: std.ArrayList(u64) = .empty;
        defer offsets_to_delete.deinit(self.allocator);

        {
            var iter = try self.primary_index.rangeScan(range.min, range.max);
            defer iter.deinit();

            while (try iter.next()) |cell| {
                if (cell.key.len < 16 or cell.value.len < 8) continue;
                const key = std.mem.readInt(u128, cell.key[0..16], .big);
                const offset = std.mem.readInt(u64, cell.value[0..8], .little);
                try keys_to_delete.append(self.allocator, key);
                try offsets_to_delete.append(self.allocator, offset);
            }
        }

        var deleted: u64 = 0;
        for (keys_to_delete.items, offsets_to_delete.items) |key, offset| {
            const metadata = KeyGen.extractMetadata(key);
            if (self.vlogs.get(metadata.vlog_id)) |vlog| {
                const entry_size = vlog.del(offset) catch |err| {
                    log.warn("removeStoreEntries: failed to tombstone key={d} offset={d}: {}", .{ key, offset, err });
                    continue;
                };
                vlog.header.deleted += 1;
                if (vlog.header.count > 0) vlog.header.count -= 1;
                vlog.header.dead_bytes += entry_size;
                if (vlog.header.live_bytes >= entry_size) {
                    vlog.header.live_bytes -= entry_size;
                }
            }
            self.primary_index.delete(key) catch |err| {
                log.warn("removeStoreEntries: failed to delete key={d} from primary index: {}", .{ key, err });
                continue;
            };
            deleted += 1;
        }

        if (deleted > 0) {
            self.primary_index.flush() catch |err| {
                log.err("removeStoreEntries: failed to flush primary index: {}", .{err});
                return err;
            };

            var vlog_iter = self.vlogs.iterator();
            while (vlog_iter.next()) |entry| {
                entry.value_ptr.*.syncHeader() catch |err| {
                    log.warn("removeStoreEntries: failed to sync vlog header for vlog_id={d}: {}", .{ entry.key_ptr.*, err });
                };
            }

            log.info("removeStoreEntries: removed {d} entries for store_id={d}", .{ deleted, store_id });
        }

        return deleted;
    }

    pub fn removeSecondaryIndex(self: *Db, index_ns: []const u8) void {
        if (self.secondary_indexes.fetchRemove(index_ns)) |entry| {
            const idx = entry.value;
            idx.deinit();
            self.allocator.destroy(idx);
            self.allocator.free(@constCast(entry.key));
            log.info("removeSecondaryIndex: removed in-memory index '{s}'", .{index_ns});
        }
    }
};

test "repairInterruptedGc rolls an interrupted GC swap forward" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = ".gc_repair_test";
    const vlog_path = root ++ "/vlogs";
    const index_path = root ++ "/indexes";

    const cwd = Dir.cwd();
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    try cwd.createDirPath(io, vlog_path);
    try cwd.createDirPath(io, index_path);

    var vlog_dir = try cwd.openDir(io, vlog_path, .{});
    defer vlog_dir.close(io);
    var index_dir = try cwd.openDir(io, index_path, .{});
    defer index_dir.close(io);

    try vlog_dir.writeFile(io, .{ .sub_path = "7.vlog", .data = "OLD-VLOG" });
    try index_dir.writeFile(io, .{ .sub_path = "primary.idx", .data = "OLD-IDX" });
    try vlog_dir.writeFile(io, .{ .sub_path = "gc_7.vlog", .data = "NEW-VLOG" });
    try index_dir.writeFile(io, .{ .sub_path = "gc_primary.idx", .data = "NEW-IDX" });
    try vlog_dir.writeFile(io, .{ .sub_path = "gc_7.inprogress", .data = "" });

    try std.testing.expectEqual(@as(usize, 1), try Db.repairInterruptedGc(allocator, vlog_path, index_path, io));

    const vlog_after = try vlog_dir.readFileAlloc(io, "7.vlog", allocator, .unlimited);
    defer allocator.free(vlog_after);
    try std.testing.expectEqualStrings("NEW-VLOG", vlog_after);

    const idx_after = try index_dir.readFileAlloc(io, "primary.idx", allocator, .unlimited);
    defer allocator.free(idx_after);
    try std.testing.expectEqualStrings("NEW-IDX", idx_after);

    try std.testing.expectError(error.FileNotFound, vlog_dir.access(io, "gc_7.vlog", .{}));
    try std.testing.expectError(error.FileNotFound, vlog_dir.access(io, "gc_7.inprogress", .{}));
    try std.testing.expectError(error.FileNotFound, index_dir.access(io, "gc_primary.idx", .{}));
}

test "repairInterruptedGc deletes orphaned shadow files when no marker exists" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = ".gc_orphan_test";
    const vlog_path = root ++ "/vlogs";
    const index_path = root ++ "/indexes";

    const cwd = Dir.cwd();
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    try cwd.createDirPath(io, vlog_path);
    try cwd.createDirPath(io, index_path);

    var vlog_dir = try cwd.openDir(io, vlog_path, .{});
    defer vlog_dir.close(io);
    var index_dir = try cwd.openDir(io, index_path, .{});
    defer index_dir.close(io);

    // Build-phase crash: shadows exist but NO marker, so the real files are authoritative.
    try vlog_dir.writeFile(io, .{ .sub_path = "7.vlog", .data = "OLD-VLOG" });
    try index_dir.writeFile(io, .{ .sub_path = "primary.idx", .data = "OLD-IDX" });
    try vlog_dir.writeFile(io, .{ .sub_path = "gc_7.vlog", .data = "PARTIAL-VLOG" });
    try index_dir.writeFile(io, .{ .sub_path = "gc_primary.idx", .data = "PARTIAL-IDX" });

    // No swaps rolled forward.
    try std.testing.expectEqual(@as(usize, 0), try Db.repairInterruptedGc(allocator, vlog_path, index_path, io));

    // Orphans removed.
    try std.testing.expectError(error.FileNotFound, vlog_dir.access(io, "gc_7.vlog", .{}));
    try std.testing.expectError(error.FileNotFound, index_dir.access(io, "gc_primary.idx", .{}));

    // Real files untouched.
    const vlog_after = try vlog_dir.readFileAlloc(io, "7.vlog", allocator, .unlimited);
    defer allocator.free(vlog_after);
    try std.testing.expectEqualStrings("OLD-VLOG", vlog_after);
    const idx_after = try index_dir.readFileAlloc(io, "primary.idx", allocator, .unlimited);
    defer allocator.free(idx_after);
    try std.testing.expectEqualStrings("OLD-IDX", idx_after);
}
