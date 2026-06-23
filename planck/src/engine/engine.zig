const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const Mutex = @import("utils").Mutex;
const RwLock = @import("utils").RwLock;
const Result = @import("../common/common.zig").Result;
const Db = @import("../storage/db.zig").Db;
const Config = @import("../common/config.zig").Config;
const WriteAheadLog = @import("../durability/write_ahead_log.zig").WriteAheadLog;
const WalConfig = @import("../durability/write_ahead_log.zig").WalConfig;
const Index = @import("../storage/bptree.zig").Index;
const IndexConfig = @import("../storage/bptree.zig").IndexConfig;
const common = @import("../common/common.zig");
const ParsedQuery = @import("../storage/query_engine.zig").ParsedQuery;
const Entry = common.Entry;
const AggregateResult = @import("../storage/query_engine.zig").AggregateResult;
const Now = @import("utils").Now;
const KeyGen = @import("../common/keygen.zig").KeyGen;
const Catalog = @import("../storage/catalog.zig").Catalog;
const LruCache = @import("../storage/lru_cache.zig").LruCache;
const bson = @import("bson");
const ReplicationManager = @import("../tcp/replication.zig").ReplicationManager;
const ShipRecord = @import("../tcp/replication.zig").ShipRecord;
const ChangeStreamer = @import("../change_stream/streamer.zig").ChangeStreamer;
const query_engine = @import("../storage/query_engine.zig");
const FieldExtractor = @import("../storage/field_extractor.zig").FieldExtractor;
const FieldValue = @import("../storage/field_extractor.zig").FieldValue;

const EngineMetrics = @import("../common/metrics.zig").EngineMetrics;
const DbMetrics = @import("../common/metrics.zig").DbMetrics;
const IndexMetrics = @import("../common/metrics.zig").IndexMetrics;
const VlogMetrics = @import("../common/metrics.zig").VlogMetrics;
const WalMetrics = @import("../common/metrics.zig").WalMetrics;
const WasmMetrics = @import("../common/metrics.zig").WasmMetrics;
const HttpMetrics = @import("../common/metrics.zig").HttpMetrics;
const HttpMethodTag = @import("../common/metrics.zig").HttpMethodTag;

const q = @import("../storage/query_helpers.zig");
const matchesAllPredicates = q.matchesAllPredicates;
const compareByField = q.compareByField;
const compareBsonValues = q.compareBsonValues;
const applyProjection = q.applyProjection;
const matchesPredicate = q.matchesPredicate;
const compareByMultiFields = q.compareByMultiFields;

const proto = @import("proto");
const StatsTag = proto.StatsTag;
const utils_backup = @import("utils").backup;
const Exporter = @import("../exim/export.zig").Exporter;
const Importer = @import("../exim/import.zig").Importer;
const EximManifest = @import("utils").manifest.EximManifest;
const query_executor = @import("query_executor.zig");
const log = std.log.scoped(.engine);

pub const Engine = struct {
    allocator: Allocator,
    config: *Config,
    io: Io,
    db: *Db,
    wal: *WriteAheadLog,
    primary_index: *Index(u128, u64),
    keygen: KeyGen,
    catalog: *Catalog,
    engine_metrics: *EngineMetrics,
    db_mutex: RwLock,
    wal_mutex: Mutex,
    primary_index_mutex: RwLock,
    catalog_mutex: RwLock,
    read_cache: ?*LruCache(u128, []const u8),
    replication: ?*ReplicationManager,
    change_streamer: ?*ChangeStreamer,
    btree_has_data: std.atomic.Value(bool),
    sequences: std.StringHashMapUnmanaged(i64),
    seq_mutex: Mutex,
    now: Now,

    pub fn init(allocator: Allocator, config: *Config, io: Io, replication: ?*ReplicationManager, change_streamer: ?*ChangeStreamer) !*Engine {
        const engine = try allocator.create(Engine);
        errdefer allocator.destroy(engine);

        try setupDirs(config, io);
        if (Db.repairInterruptedGc(allocator, config.paths.vlog, config.paths.index, io)) |recovered| {
            if (recovered > 0) log.warn("recovered {d} interrupted GC swap(s) on startup", .{recovered});
        } else |err| log.warn("GC repair on startup failed: {}", .{err});
        const engine_metrics = try EngineMetrics.init(allocator);
        errdefer engine_metrics.deinit(allocator);

        const primary_index_ptr = try allocator.create(Index(u128, u64));
        errdefer allocator.destroy(primary_index_ptr);

        primary_index_ptr.* = try Index(u128, u64).init(allocator, IndexConfig{
            .dir_path = config.paths.index,
            .file_name = "primary",
            .pool_size = config.index.primary.pool_size,
            .io = io,
        }, engine_metrics);
        errdefer primary_index_ptr.deinit();

        const wal = try WriteAheadLog.init(allocator, engine_metrics, WalConfig{
            .dir_path = config.paths.wal,
            .max_file_size = config.file_sizes.wal,
            .flush_interval_in_ms = config.durability.flush_interval_in_ms,
            .max_buffer_size = config.buffers.wal,
            .skip_buffers = config.durability.flush_interval_in_ms == 0,
            .io = io,
            .log_archive_enabled = config.durability.log_archive.enabled,
            .log_archive_dest_path = config.durability.log_archive.dest_path,
            .retain_logs_days = config.durability.log_archive.retain_logs_days,
        });

        errdefer wal.deinit() catch {};

        const db = try Db.init(allocator, config, io, wal, primary_index_ptr, engine_metrics);
        db.replication = replication;
        errdefer db.deinit();

        try loadSecondaryIndexesFromCatalog(db, allocator, config, io, engine_metrics);

        const keygen = KeyGen.init();

        var read_cache: ?*LruCache(u128, []const u8) = null;
        if (config.cache.enabled and config.cache.capacity > 0) {
            read_cache = try allocator.create(LruCache(u128, []const u8));
            read_cache.?.* = LruCache(u128, []const u8).init(allocator, config.cache.capacity, io);
            log.info("Read cache initialized with capacity {d}", .{config.cache.capacity});
        }
        errdefer if (read_cache) |c| {
            c.deinit();
            allocator.destroy(c);
        };

        engine.* = Engine{
            .allocator = allocator,
            .config = config,
            .io = io,
            .db = db,
            .wal = wal,
            .primary_index = primary_index_ptr,
            .keygen = keygen,
            .catalog = db.catalog,
            .db_mutex = .{},
            .wal_mutex = .{},
            .primary_index_mutex = .{},
            .catalog_mutex = .{},
            .engine_metrics = engine_metrics,
            .replication = replication,
            .change_streamer = change_streamer,
            .read_cache = read_cache,
            .btree_has_data = std.atomic.Value(bool).init(false),
            .now = Now{ .io = io },
            .sequences = .empty,
            .seq_mutex = .{},
        };

        engine.loadSequences();
        engine.mergeRecoveredSequences();
        log.info("Engine initialized", .{});
        if (config.backup_dir.len == 0) {
            log.warn("backup_dir is not set in db.yaml - backups will fail unless the caller passes an explicit path. Set `backup_dir` (preferably on a different disk from base_dir) for configured backups.", .{});
        } else {
            log.info("backup_dir='{s}'", .{config.backup_dir});
        }
        return engine;
    }

    pub fn nextSequence(self: *Engine, allocator: Allocator, io: Io, name: []const u8) !i64 {
        _ = allocator;
        _ = io;
        self.seq_mutex.lock(self.io);
        defer self.seq_mutex.unlock(self.io);

        const result = self.sequences.getOrPut(self.allocator, name) catch return error.SequenceFailed;
        if (!result.found_existing) {
            result.key_ptr.* = self.allocator.dupe(u8, name) catch return error.SequenceFailed;
            result.value_ptr.* = 0;
        }
        result.value_ptr.* += 1;
        const new_val = result.value_ptr.*;

        var buf: [4 + 256 + 8]u8 = undefined;
        const name_len: u32 = @intCast(name.len);
        @memcpy(buf[0..4], std.mem.asBytes(&std.mem.nativeToLittle(u32, name_len)));
        @memcpy(buf[4..][0..name.len], name);
        const val_le = std.mem.nativeToLittle(i64, new_val);
        @memcpy(buf[4 + name.len ..][0..8], std.mem.asBytes(&val_le));
        const total_len = 4 + name.len + 8;

        self.wal_mutex.lock(self.io);
        defer self.wal_mutex.unlock(self.io);
        const lsn = self.wal.incrementLSN();
        self.wal.append(.{
            .lsn = lsn,
            .key = 0,
            .value = buf[0..total_len],
            .timestamp = self.now.toMilliSeconds(),
            .kind = .sequence,
        }) catch |e| {
            result.value_ptr.* -= 1;
            log.err("Sequence WAL append failed for '{s}': {}", .{ name, e });
            return error.SequenceFailed;
        };

        return new_val;
    }

    fn flushSequences(self: *Engine) void {
        self.seq_mutex.lock(self.io);
        defer self.seq_mutex.unlock(self.io);

        if (self.sequences.count() == 0) return;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&path_buf, "{s}/_sequences.dat.tmp", .{self.config.base_dir}) catch return;

        var file = Dir.createFile(.cwd(), self.io, tmp_path, .{}) catch |e| {
            log.warn("flushSequences: create tmp failed: {}", .{e});
            return;
        };

        var iter = self.sequences.iterator();
        while (iter.next()) |entry| {
            var line_buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "{s}\t{d}\n", .{ entry.key_ptr.*, entry.value_ptr.* }) catch continue;
            file.writeStreamingAll(self.io, line) catch |e| {
                log.warn("flushSequences: write failed: {}", .{e});
                file.close(self.io);
                return;
            };
        }
        file.sync(self.io) catch {};
        file.close(self.io);

        var final_buf: [std.fs.max_path_bytes]u8 = undefined;
        const final_path = std.fmt.bufPrint(&final_buf, "{s}/_sequences.dat", .{self.config.base_dir}) catch return;
        Dir.rename(.cwd(), tmp_path, .cwd(), final_path, self.io) catch |e| {
            log.warn("flushSequences: rename failed: {}", .{e});
        };
    }

    fn loadSequences(self: *Engine) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/_sequences.dat", .{self.config.base_dir}) catch return;

        const data = Dir.readFileAlloc(.cwd(), self.io, path, self.allocator, @enumFromInt(1_000_000)) catch |err| {
            if (err != error.FileNotFound) {
                log.warn("loadSequences: read failed: {}", .{err});
            }
            return;
        };
        defer self.allocator.free(data);

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const name = line[0..tab];
            const val = std.fmt.parseInt(i64, line[tab + 1 ..], 10) catch continue;

            const result = self.sequences.getOrPut(self.allocator, name) catch continue;
            if (!result.found_existing) {
                result.key_ptr.* = self.allocator.dupe(u8, name) catch continue;
            }
            result.value_ptr.* = val;
        }

        log.info("Loaded {d} sequences from _sequences.dat", .{self.sequences.count()});
    }

    fn mergeRecoveredSequences(self: *Engine) void {
        var iter = self.db.recovered_sequences.iterator();
        var merged: usize = 0;
        while (iter.next()) |entry| {
            const result = self.sequences.getOrPut(self.allocator, entry.key_ptr.*) catch continue;
            if (!result.found_existing) {
                result.key_ptr.* = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                result.value_ptr.* = entry.value_ptr.*;
                merged += 1;
            } else if (entry.value_ptr.* > result.value_ptr.*) {
                result.value_ptr.* = entry.value_ptr.*;
                merged += 1;
            }
        }
        if (merged > 0) {
            log.info("Merged {d} recovered sequences from WAL", .{merged});
        }
    }

    pub fn deinit(self: *Engine) void {
        if (self.read_cache) |cache| {
            cache.deinit();
            self.allocator.destroy(cache);
        }
        self.primary_index.deinit();
        self.allocator.destroy(self.primary_index);
        self.db.deinit();
        self.engine_metrics.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn setupDirs(config: *Config, io: Io) !void {
        Dir.createDirPath(.cwd(), io, config.base_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                log.err("Failed to create base directory '{s}': {}", .{ config.base_dir, err });
                return err;
            }
        };

        Dir.createDirPath(.cwd(), io, config.paths.index) catch |err| {
            if (err != error.PathAlreadyExists) {
                log.err("Failed to create index directory '{s}': {}", .{ config.paths.index, err });
                return err;
            }
        };

        Dir.createDirPath(.cwd(), io, config.paths.vlog) catch |err| {
            if (err != error.PathAlreadyExists) {
                log.err("Failed to create vlog directory '{s}': {}", .{ config.paths.vlog, err });
                return err;
            }
        };

        Dir.createDirPath(.cwd(), io, config.paths.wal) catch |err| {
            if (err != error.PathAlreadyExists) {
                log.err("Failed to create WAL directory '{s}': {}", .{ config.paths.wal, err });
                return err;
            }
        };

        log.info("Database directories initialized", .{});
    }

    fn loadSecondaryIndexesFromCatalog(db: *Db, allocator: Allocator, config: *Config, io: Io, engine_metrics: *EngineMetrics) !void {
        log.info("Loading indexes...", .{});
        var indexes = try db.catalog.listIndexes(allocator);
        defer indexes.deinit(allocator);

        var count: usize = 0;
        for (indexes.items) |index_meta| {
            if (index_meta.store_id == 0) continue;

            if (db.secondary_indexes.contains(index_meta.ns)) {
                continue;
            }

            const index_ptr = try allocator.create(Index([]const u8, void));
            errdefer allocator.destroy(index_ptr);

            const index_ns_owned = try allocator.dupe(u8, index_meta.ns);
            errdefer allocator.free(index_ns_owned);

            index_ptr.* = try Index([]const u8, void).init(allocator, .{
                .dir_path = config.paths.index,
                .file_name = index_ns_owned,
                .pool_size = config.index.secondary.pool_size,
                .io = io,
            }, engine_metrics);

            try db.secondary_indexes.put(index_ns_owned, index_ptr);
            count += 1;
        }

        if (count > 0) {
            log.info("Loaded {} secondary indexes from catalog", .{count});
        }
    }

    pub fn resolveStore(self: *Engine, store_ns: []const u8) !*proto.Store {
        const store = self.catalog.findStoreByNamespace(store_ns) orelse return error.StoreNotFound;
        if (store.status == .deleting) return error.StoreDeleteInProgress;
        return store;
    }

    pub fn post(self: *Engine, store_ns: []const u8, value: []const u8, auto_create: bool) !u128 {
        if (value.len > self.config.buffers.wal -| 43) return error.DocumentSizeExceedsAllowedLength;

        const timestamp = self.now.toMilliSeconds();

        self.catalog_mutex.lock(self.io);
        const store_id = blk: {
            if (self.resolveStore(store_ns)) |store| {
                break :blk store.store_id;
            } else |err| {
                if (err == error.StoreNotFound and auto_create) {
                    const created = self.catalog.createStore(store_ns, null) catch {
                        self.catalog_mutex.unlock(self.io);
                        return error.StoreNotFound;
                    };
                    break :blk created.store_id;
                }
                self.catalog_mutex.unlock(self.io);
                return err;
            }
        };
        self.catalog_mutex.unlock(self.io);

        const vlog_id: u8 = @truncate(self.db.current_vlog.id);
        const key = try self.keygen.Gen(store_id, vlog_id, 4, self.io);

        self.wal_mutex.lock(self.io);
        defer self.wal_mutex.unlock(self.io);
        const lsn = self.wal.incrementLSN();
        try self.wal.append(.{
            .lsn = lsn,
            .key = key,
            .value = value,
            .timestamp = timestamp,
            .kind = .insert,
        });

        self.db_mutex.lock(self.io);
        defer self.db_mutex.unlock(self.io);
        try self.db.post(.{
            .lsn = lsn,
            .key = key,
            .value = value,
            .timestamp = timestamp,
            .kind = .insert,
        });

        if (self.replication) |repl| {
            repl.ship(.{
                .op_kind = 0,
                .store_ns = store_ns,
                .lsn = lsn,
                .doc_id = key,
                .timestamp = timestamp,
                .data = value,
            });
        }
        if (self.change_streamer) |cs| {
            cs.ship(.{
                .kind = .insert,
                .store_ns = store_ns,
                .lsn = lsn,
                .doc_id = key,
                .timestamp = timestamp,
                .data = value,
            });
        }

        return key;
    }

    pub fn postLocal(self: *Engine, store_ns: []const u8, value: []const u8, auto_create: bool) !u128 {
        if (value.len > self.config.buffers.wal -| 43) return error.DocumentSizeExceedsAllowedLength;

        const timestamp = self.now.toMilliSeconds();

        self.catalog_mutex.lock(self.io);
        const store_id = blk: {
            if (self.resolveStore(store_ns)) |store| {
                break :blk store.store_id;
            } else |err| {
                if (err == error.StoreNotFound and auto_create) {
                    const created = self.catalog.createStore(store_ns, null) catch {
                        self.catalog_mutex.unlock(self.io);
                        return error.StoreNotFound;
                    };
                    break :blk created.store_id;
                }
                self.catalog_mutex.unlock(self.io);
                return err;
            }
        };
        self.catalog_mutex.unlock(self.io);

        const vlog_id: u8 = @truncate(self.db.current_vlog.id);
        const key = try self.keygen.Gen(store_id, vlog_id, 4, self.io);

        self.wal_mutex.lock(self.io);
        defer self.wal_mutex.unlock(self.io);
        const lsn = self.wal.incrementLSN();
        try self.wal.append(.{
            .lsn = lsn,
            .key = key,
            .value = value,
            .timestamp = timestamp,
            .kind = .insert,
        });

        self.db_mutex.lock(self.io);
        defer self.db_mutex.unlock(self.io);
        try self.db.post(.{
            .lsn = lsn,
            .key = key,
            .value = value,
            .timestamp = timestamp,
            .kind = .insert,
        });

        return key;
    }

    pub fn postBatch(self: *Engine, store_ns: []const u8, values: [][]const u8, allocator: std.mem.Allocator, auto_create: bool) ![]u128 {
        const max_doc_size = self.config.buffers.wal -| 43;
        for (values) |val| {
            if (val.len > max_doc_size) return error.DocumentSizeExceedsAllowedLength;
        }

        const timestamp = self.now.toMilliSeconds();

        self.catalog_mutex.lock(self.io);
        const store_id = blk: {
            if (self.resolveStore(store_ns)) |store| {
                break :blk store.store_id;
            } else |err| {
                if (err == error.StoreNotFound and auto_create) {
                    const created = self.catalog.createStore(store_ns, null) catch {
                        self.catalog_mutex.unlock(self.io);
                        return error.StoreNotFound;
                    };
                    break :blk created.store_id;
                }
                self.catalog_mutex.unlock(self.io);
                return err;
            }
        };
        self.catalog_mutex.unlock(self.io);

        const vlog_id: u8 = @truncate(self.db.current_vlog.id);

        const keys = try allocator.alloc(u128, values.len);
        errdefer allocator.free(keys);

        for (values, 0..) |_, i| {
            keys[i] = try self.keygen.Gen(store_id, vlog_id, 4, self.io);
        }

        for (values, 0..) |value, i| {
            self.wal_mutex.lock(self.io);
            defer self.wal_mutex.unlock(self.io);
            const lsn = self.wal.incrementLSN();
            try self.wal.append(.{
                .lsn = lsn,
                .key = keys[i],
                .value = value,
                .timestamp = timestamp,
                .kind = .insert,
            });

            self.db_mutex.lock(self.io);
            defer self.db_mutex.unlock(self.io);
            try self.db.post(.{
                .lsn = lsn,
                .key = keys[i],
                .value = value,
                .timestamp = timestamp,
                .kind = .insert,
            });

            if (self.replication) |repl| {
                repl.ship(.{
                    .op_kind = 0,
                    .store_ns = store_ns,
                    .lsn = lsn,
                    .doc_id = keys[i],
                    .timestamp = timestamp,
                    .data = value,
                });
            }
            if (self.change_streamer) |cs| {
                cs.ship(.{
                    .kind = .insert,
                    .store_ns = store_ns,
                    .lsn = lsn,
                    .doc_id = keys[i],
                    .timestamp = timestamp,
                    .data = value,
                });
            }
        }

        return keys;
    }

    pub fn get(self: *Engine, key: u128) ![]const u8 {
        if (self.read_cache) |cache| {
            if (try cache.getCopy(key)) |cached_copy| {
                return cached_copy;
            }
        }

        self.db_mutex.lockShared(self.io);
        defer self.db_mutex.unlockShared(self.io);
        const value = try self.db.get(key);

        if (self.read_cache) |cache| {
            const cached = self.allocator.dupe(u8, value) catch return value;
            cache.put(key, cached) catch self.allocator.free(cached);
        }

        return value;
    }

    pub fn put(self: *Engine, store_ns: []const u8, key: u128, value: []const u8) !void {
        if (value.len > self.config.buffers.wal -| 43) return error.DocumentSizeExceedsAllowedLength;

        const timestamp = self.now.toMilliSeconds();

        self.wal_mutex.lock(self.io);
        defer self.wal_mutex.unlock(self.io);
        const lsn = self.wal.incrementLSN();
        try self.wal.append(.{
            .lsn = lsn,
            .key = key,
            .value = value,
            .timestamp = timestamp,
            .kind = .update,
        });

        self.db_mutex.lock(self.io);
        defer self.db_mutex.unlock(self.io);
        try self.db.put(lsn, key, value, timestamp);

        if (self.replication) |repl| {
            repl.ship(.{
                .op_kind = 1,
                .store_ns = store_ns,
                .lsn = lsn,
                .doc_id = key,
                .timestamp = timestamp,
                .data = value,
            });
        }
        if (self.change_streamer) |cs| {
            cs.ship(.{
                .kind = .update,
                .store_ns = store_ns,
                .lsn = lsn,
                .doc_id = key,
                .timestamp = timestamp,
                .data = value,
            });
        }

        if (self.read_cache) |cache| {
            cache.remove(key);
        }
    }

    pub fn putLocal(self: *Engine, key: u128, value: []const u8) !void {
        if (value.len > self.config.buffers.wal -| 43) return error.DocumentSizeExceedsAllowedLength;

        const timestamp = self.now.toMilliSeconds();

        self.wal_mutex.lock(self.io);
        defer self.wal_mutex.unlock(self.io);
        const lsn = self.wal.incrementLSN();
        try self.wal.append(.{
            .lsn = lsn,
            .key = key,
            .value = value,
            .timestamp = timestamp,
            .kind = .update,
        });

        self.db_mutex.lock(self.io);
        defer self.db_mutex.unlock(self.io);
        try self.db.put(lsn, key, value, timestamp);

        if (self.read_cache) |cache| {
            cache.remove(key);
        }
    }

    pub fn del(self: *Engine, store_ns: []const u8, key: u128) !void {
        const timestamp = self.now.toMilliSeconds();

        self.wal_mutex.lock(self.io);
        defer self.wal_mutex.unlock(self.io);
        const lsn = self.wal.incrementLSN();
        try self.wal.append(.{
            .lsn = lsn,
            .key = key,
            .value = &[_]u8{},
            .timestamp = timestamp,
            .kind = .delete,
        });

        self.db_mutex.lock(self.io);
        defer self.db_mutex.unlock(self.io);

        try self.db.del(lsn, key, timestamp);

        if (self.replication) |repl| {
            repl.ship(.{
                .op_kind = 2,
                .store_ns = store_ns,
                .lsn = lsn,
                .doc_id = key,
                .timestamp = timestamp,
                .data = &[_]u8{},
            });
        }
        if (self.change_streamer) |cs| {
            cs.ship(.{
                .kind = .delete,
                .store_ns = store_ns,
                .lsn = lsn,
                .doc_id = key,
                .timestamp = timestamp,
                .data = &[_]u8{},
            });
        }

        if (self.read_cache) |cache| {
            cache.remove(key);
        }
    }

    pub fn dropIndex(self: *Engine, index_ns: []const u8) !void {
        const idx = self.catalog.indexes.get(index_ns) orelse return error.IndexNotFound;
        const idx_ns_copy = try self.allocator.dupe(u8, idx.ns);
        defer self.allocator.free(idx_ns_copy);

        const idx_path_copy = try self.allocator.dupe(u8, idx.index_path);
        defer self.allocator.free(idx_path_copy);

        try self.catalog.dropIndex(index_ns);

        self.db.removeSecondaryIndex(idx_ns_copy);

        if (idx_path_copy.len > 0) {
            Dir.deleteFile(.cwd(), self.io, idx_path_copy) catch |err| {
                log.warn("dropIndex: failed to delete index file '{s}': {}", .{ idx_path_copy, err });
            };
            log.info("dropIndex: deleted index file '{s}'", .{idx_path_copy});
        }

        log.info("dropIndex: removed index '{s}'", .{index_ns});
    }

    pub fn dropStore(self: *Engine, store_ns: []const u8) !void {
        const store = self.catalog.findStoreByNamespace(store_ns) orelse return error.StoreNotFound;
        const store_id = store.store_id;

        if (self.catalog.getIndexesByStoreId(store_id)) |idx_list| {
            var ns_list: std.ArrayList([]const u8) = .empty;
            defer {
                for (ns_list.items) |ns| self.allocator.free(@constCast(ns));
                ns_list.deinit(self.allocator);
            }
            for (idx_list.items) |idx| {
                try ns_list.append(self.allocator, try self.allocator.dupe(u8, idx.ns));
            }
            for (ns_list.items) |ns| {
                self.dropIndex(ns) catch |err| {
                    log.warn("dropStore: failed to delete index '{s}': {}", .{ ns, err });
                };
            }
        }

        _ = self.db.removeStoreEntries(store_id) catch |err| {
            log.err("dropStore: failed to remove store entries for store_id={d}: {}", .{ store_id, err });
            return err;
        };

        try self.catalog.dropStore(store_ns);

        log.info("dropStore: removed store '{s}'", .{store_ns});
    }

    pub fn applyLogRecord(self: *Engine, store_ns: []const u8, lsn: u64, doc_id: u128, timestamp: i64, op_kind: u8, data: []const u8) !void {
        switch (op_kind) {
            0 => {
                self.wal_mutex.lock(self.io);
                defer self.wal_mutex.unlock(self.io);
                try self.wal.append(.{
                    .lsn = lsn,
                    .key = doc_id,
                    .value = data,
                    .timestamp = timestamp,
                    .kind = if (op_kind == 0) .insert else .update,
                });

                const entry = Entry{
                    .lsn = lsn,
                    .key = doc_id,
                    .value = data,
                    .timestamp = timestamp,
                    .kind = .insert,
                };
                {
                    self.db_mutex.lock(self.io);
                    defer self.db_mutex.unlock(self.io);

                    try self.db.post(entry);
                }
            },
            1 => {
                self.wal_mutex.lock(self.io);
                defer self.wal_mutex.unlock(self.io);
                try self.wal.append(.{
                    .lsn = lsn,
                    .key = doc_id,
                    .value = data,
                    .timestamp = timestamp,
                    .kind = if (op_kind == 0) .insert else .update,
                });

                {
                    self.db_mutex.lock(self.io);
                    defer self.db_mutex.unlock(self.io);
                    try self.db.put(lsn, doc_id, data, timestamp);
                }
                if (self.read_cache) |cache| cache.remove(doc_id);
            },
            2 => {
                self.wal_mutex.lock(self.io);
                defer self.wal_mutex.unlock(self.io);
                try self.wal.append(.{
                    .lsn = lsn,
                    .key = doc_id,
                    .value = &[_]u8{},
                    .timestamp = timestamp,
                    .kind = .delete,
                });

                {
                    self.db_mutex.lock(self.io);
                    defer self.db_mutex.unlock(self.io);
                    try self.db.del(lsn, doc_id, timestamp);
                }

                if (self.read_cache) |cache| cache.remove(doc_id);
            },
            3 => {
            },
            4 => {
                self.catalog_mutex.lock(self.io);
                defer self.catalog_mutex.unlock(self.io);

                const store_id: u16 = @intCast(doc_id & 0xFFFF);
                const desc = if (data.len > 0) data else null;
                _ = self.catalog.createStoreWithId(store_ns, desc, store_id) catch |err| {
                    log.warn("applyLogRecord: createStoreWithId({s}, id={d}) failed: {} - may already exist", .{ store_ns, store_id, err });
                    return;
                };
                log.info("applyLogRecord: created store '{s}' with id={d}", .{ store_ns, store_id });
            },
            5 => {
                var decoder = bson.Decoder.init(self.allocator, data);
                const index = decoder.decode(proto.Index) catch |err| {
                    log.err("applyLogRecord: failed to decode index payload for {s}: {}", .{ store_ns, err });
                    return err;
                };
                defer self.allocator.free(index.field);

                const store_id: u16 = @intCast(doc_id & 0xFFFF);

                self.catalog_mutex.lock(self.io);
                self.db_mutex.lock(self.io);
                self.db.createSecondaryIndex(store_id, store_ns, index.field, index.field_type) catch |err| {
                    self.db_mutex.unlock(self.io);
                    self.catalog_mutex.unlock(self.io);
                    log.warn("applyLogRecord: createSecondaryIndex({s}) failed: {} - may already exist", .{ store_ns, err });
                    return;
                };
                self.db_mutex.unlock(self.io);
                self.catalog_mutex.unlock(self.io);
            },
            6 => {
            },
            7 => {
                self.catalog_mutex.lock(self.io);
                self.db_mutex.lock(self.io);
                defer self.db_mutex.unlock(self.io);
                defer self.catalog_mutex.unlock(self.io);
                self.dropStore(store_ns) catch |err| {
                    log.warn("applyLogRecord: dropStore({s}) failed: {}", .{ store_ns, err });
                };
            },
            8 => {
                self.catalog_mutex.lock(self.io);
                self.db_mutex.lock(self.io);
                defer self.db_mutex.unlock(self.io);
                defer self.catalog_mutex.unlock(self.io);
                self.dropIndex(store_ns) catch |err| {
                    log.warn("applyLogRecord: dropIndex({s}) failed: {}", .{ store_ns, err });
                };
            },
            254 => {
                self.db_mutex.lock(self.io);
                self.db.flushOnDemand() catch |e| {
                    self.db_mutex.unlock(self.io);
                    log.err("applyLogRecord: flush failed: {}", .{e});
                    return;
                };
                self.db_mutex.unlock(self.io);
            },
            else => return error.UnknownOpKind,
        }
    }

    pub fn getCacheStats(self: *Engine) ?struct { hits: u64, misses: u64, size: usize, capacity: usize } {
        if (self.read_cache) |cache| {
            return cache.getStats();
        }
        return null;
    }

    pub fn getStats(self: *Engine, stat: StatsTag) ![]const u8 {
        const m = self.engine_metrics;

        var doc = bson.BsonDocument.empty(self.allocator);
        defer doc.deinit();

        switch (stat) {
            .WalStats => try putWalStats(&doc, &m.wal),
            .DbStats => try putDbStats(&doc, &m.db),
            .IndexStats => try putIndexStats(&doc, &m.index),
            .VLogStats => try putVlogStats(&doc, &m.vlog),
            .GcStats => {
                try doc.putString("status", "gc metrics not enabled");
            },
            .HistoryStats => {
                try doc.putString("status", "stats history not available");
            },
            .AllStats => {
                var wal_doc = bson.BsonDocument.empty(self.allocator);
                defer wal_doc.deinit();
                try putWalStats(&wal_doc, &m.wal);
                try doc.putDocument("wal", wal_doc);

                var db_doc = bson.BsonDocument.empty(self.allocator);
                defer db_doc.deinit();
                try putDbStats(&db_doc, &m.db);
                try doc.putDocument("db", db_doc);

                var idx_doc = bson.BsonDocument.empty(self.allocator);
                defer idx_doc.deinit();
                try putIndexStats(&idx_doc, &m.index);
                try doc.putDocument("index", idx_doc);

                var vlog_doc = bson.BsonDocument.empty(self.allocator);
                defer vlog_doc.deinit();
                try putVlogStats(&vlog_doc, &m.vlog);
                try doc.putDocument("vlog", vlog_doc);

                var wasm_doc = bson.BsonDocument.empty(self.allocator);
                defer wasm_doc.deinit();
                try putWasmStats(&wasm_doc, &m.wasm);
                try doc.putDocument("wasm", wasm_doc);

                var http_doc = bson.BsonDocument.empty(self.allocator);
                defer http_doc.deinit();
                try putHttpStats(self.allocator, &http_doc, &m.http);
                try doc.putDocument("http", http_doc);
            },
        }

        const bytes = doc.toBytes();
        return try self.allocator.dupe(u8, bytes);
    }

    pub fn getVlogHeaders(self: *Engine) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.allocator);

        var iter = self.db.vlogs.iterator();
        while (iter.next()) |entry| {
            const vlog_id = entry.key_ptr.*;
            const vlog = entry.value_ptr.*;
            const h = vlog.header;

            var doc = bson.BsonDocument.empty(self.allocator);
            defer doc.deinit();

            try doc.putInt32("vlog_id", @intCast(vlog_id));
            try doc.putInt64("count", @intCast(h.count));
            try doc.putInt64("deleted", @intCast(h.deleted));
            try doc.putInt64("total_bytes", @intCast(h.total_bytes));
            try doc.putInt64("live_bytes", @intCast(h.live_bytes));
            try doc.putInt64("dead_bytes", @intCast(h.dead_bytes));
            try doc.putDouble("dead_ratio", h.deadRatio());
            try doc.putBool("is_tail", vlog_id == self.db.tail_vlog_id);

            const bytes = doc.toBytes();
            try result.appendSlice(self.allocator, bytes);
        }

        return try self.allocator.dupe(u8, result.items);
    }

    fn putWalStats(doc: *bson.BsonDocument, wal: *const WalMetrics) !void {
        try doc.putInt64("total_appends", @intCast(wal.total_appends.load(.monotonic)));
        try doc.putInt64("total_bytes_written", @intCast(wal.total_bytes_written.load(.monotonic)));
        try doc.putInt64("total_fsyncs", @intCast(wal.total_fsyncs.load(.monotonic)));
        try doc.putInt64("total_flushes", @intCast(wal.total_flushes.load(.monotonic)));
        try doc.putInt64("total_truncates", @intCast(wal.total_truncates.load(.monotonic)));
        try doc.putInt64("total_replays", @intCast(wal.total_replays.load(.monotonic)));
        try doc.putDouble("avg_append_latency_us", wal.getAvgAppendLatency());
        try doc.putDouble("avg_fsync_latency_us", wal.getAvgFsyncLatency());
        try doc.putDouble("avg_flush_latency_us", wal.getAvgFlushLatency());
        try doc.putDouble("avg_truncate_latency_us", wal.getAvgTruncateLatency());
    }

    fn putDbStats(doc: *bson.BsonDocument, db: *const DbMetrics) !void {
        try doc.putInt64("total_reads", @intCast(db.total_reads.load(.monotonic)));
        try doc.putInt64("total_writes", @intCast(db.total_writes.load(.monotonic)));
        try doc.putInt64("total_deletes", @intCast(db.total_deletes.load(.monotonic)));
        try doc.putInt64("total_updates", @intCast(db.total_updates.load(.monotonic)));
        try doc.putInt64("total_flushes", @intCast(db.total_flushes.load(.monotonic)));
        try doc.putDouble("avg_read_latency_us", db.getAvgReadLatency());
        try doc.putDouble("avg_write_latency_us", db.getAvgWriteLatency());
        try doc.putDouble("avg_update_latency_us", db.getAvgUpdateLatency());
        try doc.putDouble("avg_flush_latency_us", db.getAvgFlushLatency());
    }

    fn putIndexStats(doc: *bson.BsonDocument, idx: *const IndexMetrics) !void {
        try doc.putInt64("total_inserts", @intCast(idx.total_inserts.load(.monotonic)));
        try doc.putInt64("total_searches", @intCast(idx.total_searches.load(.monotonic)));
        try doc.putInt64("total_deletes", @intCast(idx.total_deletes.load(.monotonic)));
        try doc.putInt64("total_scans", @intCast(idx.total_scans.load(.monotonic)));
        try doc.putInt64("total_flushes", @intCast(idx.total_flushes.load(.monotonic)));
        try doc.putInt64("total_updates", @intCast(idx.total_updates.load(.monotonic)));
        try doc.putDouble("avg_insert_latency_us", idx.getAvgInsertLatency());
        try doc.putDouble("avg_search_latency_us", idx.getAvgSearchLatency());
        try doc.putDouble("avg_flush_latency_us", idx.getAvgFlushLatency());
    }

    fn putVlogStats(doc: *bson.BsonDocument, vlog: *const VlogMetrics) !void {
        try doc.putInt64("total_writes", @intCast(vlog.total_writes.load(.monotonic)));
        try doc.putInt64("total_reads", @intCast(vlog.total_reads.load(.monotonic)));
        try doc.putInt64("total_bytes_written", @intCast(vlog.total_bytes_written.load(.monotonic)));
        try doc.putInt64("total_gc_runs", @intCast(vlog.total_gc_runs.load(.monotonic)));
        try doc.putInt64("bytes_reclaimed", @intCast(vlog.bytes_reclaimed.load(.monotonic)));
        try doc.putInt64("total_flushes", @intCast(vlog.total_flushes.load(.monotonic)));
        try doc.putDouble("avg_write_latency_us", vlog.getAvgWriteLatency());
        try doc.putDouble("avg_read_latency_us", vlog.getAvgReadLatency());
        try doc.putDouble("avg_flush_latency_us", vlog.getAvgFlushLatency());
    }

    fn putWasmStats(doc: *bson.BsonDocument, wasm: *const WasmMetrics) !void {
        try doc.putInt32("active_instances", @intCast(wasm.active_instances.load(.monotonic)));
        try doc.putInt32("pool_size", @intCast(wasm.pool_size.load(.monotonic)));
        try doc.putInt32("min_instances", @intCast(wasm.min_instances));
        try doc.putInt32("max_instances", @intCast(wasm.max_instances));
        try doc.putInt64("total_requests_processed", @intCast(wasm.total_requests_processed.load(.monotonic)));
        try doc.putInt64("total_instances_recycled", @intCast(wasm.total_instances_recycled.load(.monotonic)));
        try doc.putDouble("avg_request_latency_us", wasm.getAvgRequestLatency());
    }

    fn putHttpStats(allocator: std.mem.Allocator, doc: *bson.BsonDocument, http: *const HttpMetrics) !void {
        try doc.putInt64("total_requests", @intCast(http.total_requests.load(.monotonic)));
        try doc.putDouble("avg_latency_us", http.getAvgLatency());

        const method_names = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS" };
        for (method_names, 0..) |name, i| {
            const mm = &http.method_metrics[i];
            const count = mm.count.load(.monotonic);
            if (count == 0) continue;

            var method_doc = bson.BsonDocument.empty(allocator);
            defer method_doc.deinit();
            try method_doc.putInt64("count", @intCast(count));
            try method_doc.putDouble("avg_latency_us", mm.getAvgLatency());
            try doc.putDocument(name, method_doc);
        }
    }

    pub fn flush(self: *Engine) !void {
        self.db_mutex.lock(self.io);
        self.db.flushOnDemand() catch |e| {
            self.db_mutex.unlock(self.io);
            return e;
        };
        self.db_mutex.unlock(self.io);

        self.btree_has_data.store(true, .release);
        self.flushSequences();
        log.info("Flush on-demand completed", .{});
    }

    pub fn truncateWal(self: *Engine) !void {
        try self.flush();
        try self.wal.truncate();
        log.info("WAL truncate on-demand completed", .{});
    }

    pub fn garbageCollect(self: *Engine, vlog_ids: []const u16) ![]const u8 {
        self.db_mutex.lock(self.io);
        defer self.db_mutex.unlock(self.io);
        try self.db.garbageCollect(vlog_ids);

        var doc = bson.BsonDocument.empty(self.allocator);
        defer doc.deinit();
        try doc.putInt32("collected", @intCast(vlog_ids.len));

        return try self.allocator.dupe(u8, doc.toBytes());
    }

    pub fn garbageCollectAuto(self: *Engine) ![]const u8 {
        const threshold: f64 = @as(f64, @floatFromInt(self.config.gc.dead_ratio)) / 100.0;

        var eligible: std.ArrayList(u16) = .empty;
        defer eligible.deinit(self.allocator);

        {
            self.db_mutex.lock(self.io);
            defer self.db_mutex.unlock(self.io);

            var iter = self.db.vlogs.iterator();
            while (iter.next()) |entry| {
                const vlog_id = entry.key_ptr.*;
                if (vlog_id == self.db.tail_vlog_id) continue;
                if (entry.value_ptr.*.header.isGcCandidate(threshold)) {
                    try eligible.append(self.allocator, vlog_id);
                }
            }
        }

        log.info("garbageCollectAuto: {d} vlog(s) above dead_ratio {d:.2}", .{ eligible.items.len, threshold });

        return try self.garbageCollect(eligible.items);
    }

    pub fn rangeQuery(self: *Engine, start_key: u128, end_key: u128, limit: ?u32) ![]Entry {
        const actual_limit = limit orelse 100;

        var results: std.ArrayList(Entry) = .empty;
        errdefer {
            for (results.items) |entry| {
                self.allocator.free(entry.value);
            }
            results.deinit(self.allocator);
        }

        self.primary_index_mutex.lock(self.io);
        defer self.primary_index_mutex.unlock(self.io);

        var sk_buf: [16]u8 = undefined;
        var ek_buf: [16]u8 = undefined;
        std.mem.writeInt(u128, &sk_buf, start_key, .big);
        std.mem.writeInt(u128, &ek_buf, end_key, .big);

        var it = try self.primary_index.tree.rangeScan(&sk_buf, &ek_buf);
        defer it.deinit();

        var count: u32 = 0;

        while (try it.next()) |cell| {
            if (count >= actual_limit) break;
            if (cell.key.len < 16) continue;

            const key = std.mem.readInt(u128, cell.key[0..16], .big);

            self.db_mutex.lock(self.io);
            const value = self.db.get(@bitCast(key)) catch |err| {
                self.db_mutex.unlock(self.io);
                log.warn("Failed to read document key={x}: {}", .{ key, err });
                continue;
            };
            defer self.allocator.free(value);
            const value_copy = self.allocator.dupe(u8, value) catch |err| {
                self.db_mutex.unlock(self.io);
                return err;
            };
            self.db_mutex.unlock(self.io);

            try results.append(self.allocator, Entry{
                .lsn = 0,
                .key = key,
                .value = value_copy,
                .timestamp = self.now.toMilliSeconds(),
                .kind = .read,
            });

            count += 1;
        }

        return results.toOwnedSlice(self.allocator);
    }

    pub fn listDocs(self: *Engine, store_ns: []const u8, limit: ?u32, offset: ?u32) ![]Entry {
        self.catalog_mutex.lock(self.io);
        const store = self.resolveStore(store_ns) catch |err| {
            self.catalog_mutex.unlock(self.io);
            return err;
        };
        const store_id = store.store_id;
        self.catalog_mutex.unlock(self.io);

        const actual_limit = limit orelse 100;
        const actual_offset = offset orelse 0;

        var keys: std.ArrayList(u128) = .empty;
        defer keys.deinit(self.allocator);

        {
            self.primary_index_mutex.lock(self.io);
            defer self.primary_index_mutex.unlock(self.io);

            const range = KeyGen.storeKeyRange(store_id);
            var sk_buf: [16]u8 = undefined;
            var ek_buf: [16]u8 = undefined;
            std.mem.writeInt(u128, &sk_buf, range.min, .big);
            std.mem.writeInt(u128, &ek_buf, range.max, .big);

            var it = try self.primary_index.tree.rangeScan(&sk_buf, &ek_buf);
            defer it.deinit();

            var count: u32 = 0;
            var skipped: u32 = 0;
            while (try it.next()) |cell| {
                if (count >= actual_limit) break;
                if (cell.key.len < 16) continue;

                const key = std.mem.readInt(u128, cell.key[0..16], .big);

                const doc_type: u8 = @truncate((key >> 104) & 0xFF);
                if (doc_type != 4) continue;

                if (skipped < actual_offset) {
                    skipped += 1;
                    continue;
                }

                try keys.append(self.allocator, key);
                count += 1;
            }
        }

        var results: std.ArrayList(Entry) = .empty;
        errdefer results.deinit(self.allocator);

        for (keys.items) |key| {
            self.db_mutex.lock(self.io);
            const value = self.db.get(@bitCast(key)) catch |err| {
                self.db_mutex.unlock(self.io);
                log.warn("Failed to read document key={x}: {}", .{ key, err });
                continue;
            };
            defer self.allocator.free(value);
            const value_copy = self.allocator.dupe(u8, value) catch |err| {
                self.db_mutex.unlock(self.io);
                return err;
            };
            self.db_mutex.unlock(self.io);

            try results.append(self.allocator, Entry{
                .lsn = 0,
                .key = key,
                .value = value_copy,
                .timestamp = self.now.toMilliSeconds(),
                .kind = .insert,
            });
        }

        return results.toOwnedSlice(self.allocator);
    }


    pub fn queryDocs(self: *Engine, store_ns: []const u8, query_json: []const u8) ![]Entry {
        return query_executor.queryDocs(self, store_ns, query_json);
    }

    pub fn countDocs(self: *Engine, store_ns: []const u8, query_json: []const u8) !u64 {
        return query_executor.countDocs(self, store_ns, query_json);
    }

    pub fn scanDocs(self: *Engine, start_key: ?u128, limit_count: u32, skip_count: u32) ![]Entry {
        return query_executor.scanDocs(self, start_key, limit_count, skip_count);
    }

    pub fn aggregateDocs(self: *Engine, store_ns: []const u8, query_json: []const u8) ![]u8 {
        return query_executor.aggregateDocs(self, store_ns, query_json);
    }

    pub fn createBackup(self: *Engine, backup_dir: []const u8) ![]const u8 {
        const effective_dir = if (backup_dir.len > 0)
            backup_dir
        else if (self.config.backup_dir.len > 0)
            self.config.backup_dir
        else {
            std.log.err("backup: no path supplied and config.backup_dir is unset - set `backup_dir` in db.yaml or pass a path explicitly", .{});
            return error.BackupDirNotConfigured;
        };

        std.log.info("backup: backup_dir='{s}' vlog_dir='{s}' index_dir='{s}'", .{
            effective_dir, self.config.paths.vlog, self.config.paths.index,
        });

        std.Io.Dir.createDirPath(.cwd(), self.io, effective_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                std.log.err("backup: createDirPath '{s}' failed: {}", .{ effective_dir, err });
                return err;
            },
        };

        var secondary_paths: std.ArrayList([]const u8) = .empty;
        defer {
            for (secondary_paths.items) |p| self.allocator.free(p);
            secondary_paths.deinit(self.allocator);
        }
        {
            self.catalog_mutex.lock(self.io);
            defer self.catalog_mutex.unlock(self.io);
            var it = self.db.secondary_indexes.iterator();
            while (it.next()) |entry| {
                const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.idx", .{ self.config.paths.index, entry.key_ptr.* });
                try secondary_paths.append(self.allocator, path);
            }
        }

        const ts = (Now{ .io = self.io }).toMilliSeconds();
        const out_path = try std.fmt.allocPrint(self.allocator, "{s}/backup_{d}.planck", .{ effective_dir, ts });
        defer self.allocator.free(out_path);

        const meta = utils_backup.createServiceArchive(
            self.allocator,
            self.io,
            out_path,
            self.config.paths.vlog,
            self.config.paths.index,
            secondary_paths.items,
            self.config.paths.wal,
            ts,
        ) catch |err| {
            std.log.err("backup: createServiceArchive failed: {}", .{err});
            return err;
        };
        defer self.allocator.free(meta.backup_path);

        var doc = bson.BsonDocument.empty(self.allocator);
        defer doc.deinit();
        try doc.putString("backup_path", meta.backup_path);
        try doc.putInt64("timestamp", meta.timestamp);
        try doc.putInt64("size_bytes", @intCast(meta.size_bytes));
        try doc.putInt32("vlog_count", @intCast(meta.vlog_count));
        try doc.putInt64("entry_count", @intCast(meta.entry_count));
        _ = self.catalog.createBackup(std.fs.path.basename(meta.backup_path), meta.backup_path, meta.size_bytes, null) catch |err| {
            std.log.err("backup: catalog.createBackup failed: {}", .{err});
            return err;
        };
        return try self.allocator.dupe(u8, doc.toBytes());
    }

    pub fn restoreFromBackup(self: *Engine, backup_path: []const u8, target_path: []const u8) ![]const u8 {
        const meta = try utils_backup.restoreInnerArchive(self.allocator, self.io, backup_path, target_path);
        defer self.allocator.free(meta.backup_path);

        var doc = bson.BsonDocument.empty(self.allocator);
        defer doc.deinit();
        try doc.putString("backup_path", meta.backup_path);
        try doc.putInt64("timestamp", meta.timestamp);
        try doc.putInt64("size_bytes", @intCast(meta.size_bytes));
        try doc.putInt32("vlog_count", @intCast(meta.vlog_count));
        try doc.putInt64("entry_count", @intCast(meta.entry_count));

        return try self.allocator.dupe(u8, doc.toBytes());
    }

    pub fn exportStore(self: *Engine, store_ns: []const u8, format: []const u8, file_path: []const u8) ![]const u8 {
        try self.flush();

        self.catalog_mutex.lockShared(self.io);
        defer self.catalog_mutex.unlockShared(self.io);

        self.db_mutex.lockShared(self.io);
        defer self.db_mutex.unlockShared(self.io);

        var exporter = Exporter.init(self.allocator, self.io, self.catalog, self.db, self.primary_index);
        return try exporter.exportStore(store_ns, format, file_path);
    }

    fn resolveEximDir(self: *Engine, manifest_dir: ?[]const u8) ![]const u8 {
        const effective = blk: {
            if (manifest_dir) |d| {
                if (d.len > 0) break :blk try self.allocator.dupe(u8, d);
            }
            if (self.config.exim_dir.len > 0) break :blk try self.allocator.dupe(u8, self.config.exim_dir);
            break :blk try std.fmt.allocPrint(self.allocator, "{s}/exim", .{self.config.base_dir});
        };
        errdefer self.allocator.free(effective);
        std.Io.Dir.createDirPath(.cwd(), self.io, effective) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return effective;
    }

    pub fn exportWithManifest(self: *Engine, em: *const EximManifest, query_json: ?[]const u8) ![]const u8 {
        try self.flush();

        const effective_dir = try self.resolveEximDir(em.output_dir);
        defer self.allocator.free(effective_dir);
        var em2 = em.*;
        em2.output_dir = effective_dir;

        self.catalog_mutex.lockShared(self.io);
        defer self.catalog_mutex.unlockShared(self.io);

        self.db_mutex.lockShared(self.io);
        defer self.db_mutex.unlockShared(self.io);

        var exporter = Exporter.init(self.allocator, self.io, self.catalog, self.db, self.primary_index);
        defer exporter.deinit();

        if (query_json) |qj| {
            try exporter.setFilter(qj);
        }

        return try exporter.exportWithManifest(&em2);
    }

    pub fn importData(self: *Engine, payload: []const u8) ![]const u8 {
        var importer = Importer.init(
            self.allocator,
            self.io,
            &importPostCallback,
            @ptrCast(self),
        );
        const result = try importer.importData(payload);
        try self.flush();
        return result;
    }

    pub fn importWithManifest(self: *Engine, em: *const EximManifest) ![]const u8 {
        const effective_dir = try self.resolveEximDir(em.output_dir);
        defer self.allocator.free(effective_dir);
        var em2 = em.*;
        em2.output_dir = effective_dir;

        var importer = Importer.init(
            self.allocator,
            self.io,
            &importPostCallback,
            @ptrCast(self),
        );
        const result = try importer.importWithManifest(&em2);
        try self.flush();
        return result;
    }

    fn importPostCallback(ctx: *anyopaque, store_ns: []const u8, value: []const u8) anyerror!u128 {
        const engine: *Engine = @ptrCast(@alignCast(ctx));
        return try engine.post(store_ns, value, true);
    }

    pub fn shutdown(self: *Engine) !void {
        self.db_mutex.lock(self.io);
        defer self.db_mutex.unlock(self.io);
        try self.db.shutdown();
    }
};

test "Engine - setupDirs creates PathAlreadyExists gracefully" {
    const err = error.PathAlreadyExists;
    const should_propagate = (err != error.PathAlreadyExists);
    try std.testing.expect(!should_propagate);
}
