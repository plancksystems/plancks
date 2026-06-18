const std = @import("std");
const Io = std.Io;

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub const Engine = @import("engine/engine.zig").Engine;

pub const Config = @import("common/config.zig").Config;

pub const change_streams = @import("common/change_streams.zig");
pub const StreamStore = change_streams.StreamStore;

pub const ChangeStreamer = @import("change_stream/streamer.zig").ChangeStreamer;
pub const ChangeStreamerConfig = @import("change_stream/streamer.zig").ChangeStreamerConfig;
pub const ChangeStreamShipRecord = @import("change_stream/streamer.zig").ShipRecord;

pub const Entry = @import("common/common.zig").Entry;

pub const KeyGen = @import("common/keygen.zig").KeyGen;

pub const MemTable = @import("memtable/memtable.zig").MemTable;

pub const SkipList = @import("memtable/skiplist.zig").SkipList;

pub const OpKind = @import("common/common.zig").OpKind;

pub const Db = @import("storage/db.zig").Db;

pub const ValueLog = @import("storage/vlog.zig").ValueLog;

pub const VLogConfig = @import("storage/vlog.zig").VLogConfig;

pub const VlogEntry = @import("common/common.zig").VlogEntry;

pub const EngineMetrics = @import("common/metrics.zig").EngineMetrics;

pub const Index = @import("storage/bptree.zig").Index;

pub const IndexConfig = @import("storage/bptree.zig").IndexConfig;

pub const SlottedPage = @import("storage/bptree.zig").SlottedPage;

pub const PageType = @import("storage/bptree.zig").PageType;

pub const Cell = @import("storage/bptree.zig").Cell;

pub const LruCache = @import("storage/lru_cache.zig").LruCache;

pub const WriteAheadLog = @import("durability/write_ahead_log.zig").WriteAheadLog;


test {
    std.testing.refAllDecls(@This());

    _ = @import("common/config.zig");
    _ = @import("common/keygen.zig");
    _ = @import("common/common.zig");

    _ = @import("storage/vlog.zig");
    _ = @import("storage/bptree.zig");
    _ = @import("storage/lru_cache.zig");
    _ = @import("storage/db.zig");
    _ = @import("storage/security.zig");
    _ = @import("storage/field_extractor.zig");
    _ = @import("storage/query_helpers.zig");

    _ = @import("storage/compression.zig");
    _ = @import("storage/query_engine.zig");

    _ = @import("common/metrics.zig");
    _ = @import("common/constants.zig");
    _ = @import("common/change_streams.zig");
    _ = @import("change_stream/streamer.zig");

    _ = @import("memtable/memtable.zig");
    _ = @import("memtable/skiplist.zig");

    _ = @import("tcp/message_buffer_pool.zig");

    _ = @import("engine/engine.zig");

    _ = @import("wasm/upstream_pool.zig");
}
