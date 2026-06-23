const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const VlogEntry = @import("../common/common.zig").VlogEntry;
const Entry = @import("../common/common.zig").Entry;
const Buffer = @import("utils").Buffer;
const EngineMetrics = @import("../common/metrics.zig").EngineMetrics;
const log = std.log.scoped(.vlog);

const MAGIC: u32 = 0x53535442;

const VERSION: u8 = 2;

const HEADER_SIZE = 67;

const crc32 = std.hash.Crc32;

const Header = struct {
    magic: u32 = MAGIC,
    version: u8 = VERSION,
    id: u16,
    count: u64 = 0,
    deleted: u64 = 0,
    last_gc_ts: i64 = 0,
    total_bytes: u64 = 0,
    live_bytes: u64 = 0,
    dead_bytes: u64 = 0,
    lsn: u64 = 0,

    pub fn deadRatio(self: *const Header) f64 {
        if (self.total_bytes == 0) return 0.0;
        return @as(f64, @floatFromInt(self.dead_bytes)) /
            @as(f64, @floatFromInt(self.total_bytes));
    }

    pub fn isGcCandidate(self: *const Header, threshold: f64) bool {
        return self.deadRatio() >= threshold;
    }

    fn encode(self: *const Header, buf: *[HEADER_SIZE]u8) void {
        mem.writeInt(u32, buf[0..4], self.magic, .little);
        buf[4] = self.version;
        mem.writeInt(u16, buf[5..7], self.id, .little);
        mem.writeInt(u64, buf[7..15], self.count, .little);
        mem.writeInt(u64, buf[15..23], self.deleted, .little);
        mem.writeInt(i64, buf[23..31], self.last_gc_ts, .little);
        mem.writeInt(u64, buf[31..39], self.total_bytes, .little);
        mem.writeInt(u64, buf[39..47], self.live_bytes, .little);
        mem.writeInt(u64, buf[47..55], self.dead_bytes, .little);
        mem.writeInt(u64, buf[55..63], self.lsn, .little);
        mem.writeInt(u32, buf[63..67], crc32.hash(buf[0..63]), .little);
    }

    fn decode(buf: *const [HEADER_SIZE]u8) !Header {
        if (mem.readInt(u32, buf[0..4], .little) != MAGIC) return error.InvalidMagicNumber;
        if (buf[4] != VERSION) return error.IncompatibleVersion;
        if (mem.readInt(u32, buf[63..67], .little) != crc32.hash(buf[0..63])) return error.HeaderChecksumMismatch;
        return Header{
            .magic = MAGIC,
            .version = VERSION,
            .id = mem.readInt(u16, buf[5..7], .little),
            .count = mem.readInt(u64, buf[7..15], .little),
            .deleted = mem.readInt(u64, buf[15..23], .little),
            .last_gc_ts = mem.readInt(i64, buf[23..31], .little),
            .total_bytes = mem.readInt(u64, buf[31..39], .little),
            .live_bytes = mem.readInt(u64, buf[39..47], .little),
            .dead_bytes = mem.readInt(u64, buf[47..55], .little),
            .lsn = mem.readInt(u64, buf[55..63], .little),
        };
    }
};

pub const VLogConfig = struct {
    id: u16,
    file_name: []const u8,
    block_size: u64,
    max_file_size: usize,
    io: Io,
};

pub const ValueLog = struct {
    allocator: Allocator,
    io: Io,
    file: File,
    path: []const u8,
    offset: u64,
    engine_metrics: *EngineMetrics,
    tmpf: ?File = null,
    buffers: Buffer,
    header: Header = undefined,

    pub fn init(allocator: Allocator, config: VLogConfig, engine_metrics: *EngineMetrics) !*ValueLog {
        const io = config.io;

        var is_new = false;
        var file: File = undefined;
        if (Dir.openFile(.cwd(), io, config.file_name, .{ .mode = .read_write })) |f| {
            file = f;
        } else |err| switch (err) {
            error.FileNotFound => {
                file = try Dir.createFile(.cwd(), io, config.file_name, .{ .read = true, .truncate = false });
                is_new = true;
            },
            else => return err,
        }

        const vlog = try allocator.create(ValueLog);
        vlog.* = ValueLog{
            .file = file,
            .io = io,
            .allocator = allocator,
            .offset = 0,
            .path = try allocator.dupe(u8, config.file_name),
            .buffers = try Buffer.init(allocator, config.block_size),
            .header = try readHeader(allocator, io, is_new, file, config.id),
            .engine_metrics = engine_metrics,
        };

        const stat = try vlog.file.stat(io);
        vlog.offset = stat.size;

        return vlog;
    }

    pub fn deinit(self: *ValueLog) !void {
        if (self.buffers.pos > 0) {
            try self.file.writePositionalAll(self.io, self.buffers.slice(), self.offset - self.buffers.pos);
            try self.file.sync(self.io);
        }
        self.file.close(self.io);
        if (self.tmpf) |t| t.close(self.io);
        self.allocator.free(self.path);
        self.buffers.deinit();
        self.allocator.destroy(self);
    }

    fn readHeader(allocator: Allocator, io: Io, is_new: bool, file: File, id: u16) !Header {
        _ = allocator;
        if (is_new) {
            const header = Header{ .id = id };
            var header_buf: [HEADER_SIZE]u8 = undefined;
            header.encode(&header_buf);
            try file.writePositionalAll(io, &header_buf, 0);
            try file.sync(io);
            return header;
        }
        var header_buf: [HEADER_SIZE]u8 = undefined;
        _ = try file.readPositionalAll(io, &header_buf, 0);
        return Header.decode(&header_buf);
    }

    pub fn syncHeader(self: *ValueLog) !void {
        var header_buf: [HEADER_SIZE]u8 = undefined;
        self.header.encode(&header_buf);
        try self.file.writePositionalAll(self.io, &header_buf, 0);
        try self.file.sync(self.io);
    }

    pub fn flush(self: *ValueLog) !void {
        var sw = self.engine_metrics.vlog.start(self.io, .Flush);
        const target_file = if (self.tmpf) |file| file else self.file;

        target_file.writePositionalAll(self.io, self.buffers.slice(), self.offset - self.buffers.pos) catch |err| {
            log.err("Failed to write buffers to file: {s}", .{@errorName(err)});
            return err;
        };
        self.syncHeader() catch |err| {
            log.err("Failed to sync header after flush: {s}", .{@errorName(err)});
            return err;
        };

        self.buffers.reset();
        self.buffers.pos = 0;
        self.engine_metrics.vlog.stop(self.io, &sw, .Flush);
    }

    pub fn post(self: *ValueLog, entry: VlogEntry) anyerror!u64 {
        var sw = self.engine_metrics.vlog.start(self.io, .Write);
        const entry_offset = self.offset;

        if (self.buffers.pos + entry.size() >= self.buffers.len) {
            try self.flush();
        }

        entry.write(self.buffers.writer()) catch |err| {
            log.err("Failed to write entry to buffer: {s}", .{@errorName(err)});
            return err;
        };

        self.offset += entry.size();
        self.engine_metrics.vlog.stop(self.io, &sw, .Write);
        return entry_offset;
    }

    pub fn put(self: *ValueLog, old_offset: u64, old_entry: VlogEntry, entry: VlogEntry) anyerror!u64 {
        var sw = self.engine_metrics.vlog.start(self.io, .Write);
        const target_file = if (self.tmpf) |file| file else self.file;

        target_file.writePositionalAll(self.io, try old_entry.toBytes(self.allocator), old_offset) catch |err| {
            log.err("Failed to write tombstone for old entry at offset {d}: {s}", .{ old_offset, @errorName(err) });
            return err;
        };

        target_file.sync(self.io) catch |err| {
            log.err("Failed to sync file after writing tombstone for old entry at offset {d}: {s}", .{ old_offset, @errorName(err) });
            return err;
        };

        const offset = try self.post(entry);
        self.engine_metrics.vlog.stop(self.io, &sw, .Write);
        return offset;
    }

    pub fn del(self: *ValueLog, old_offset: u64) anyerror!u64 {
        var sw = self.engine_metrics.vlog.start(self.io, .Write);
        var deleted_entry = self.get(old_offset) catch |err| {
            log.err("Failed to read old entry at offset {d}: {s}", .{ old_offset, @errorName(err) });
            return err;
        };
        defer deleted_entry.deinit(self.allocator);

        deleted_entry.tombstone = true;
        const target_file = if (self.tmpf) |file| file else self.file;

        target_file.writePositionalAll(self.io, try deleted_entry.toBytes(self.allocator), old_offset) catch |err| {
            self.engine_metrics.vlog.stop(self.io, &sw, .Write);
            log.err("Failed to write tombstone for old entry at offset {d}: {s}", .{ old_offset, @errorName(err) });
            return err;
        };

        target_file.sync(self.io) catch |err| {
            self.engine_metrics.vlog.stop(self.io, &sw, .Write);
            log.err("Failed to sync file after writing tombstone for old entry at offset {d}: {s}", .{ old_offset, @errorName(err) });
            return err;
        };
        self.engine_metrics.vlog.stop(self.io, &sw, .Write);
        return deleted_entry.size();
    }

    pub fn get(self: *ValueLog, offset: u64) !VlogEntry {
        var sw = self.engine_metrics.vlog.start(self.io, .Read);
        const source_file = if (self.tmpf) |file| file else self.file;

        var header_buf: [16 + 8 + 8]u8 = undefined;
        _ = try source_file.readPositionalAll(self.io, &header_buf, offset);

        const value_len = mem.readInt(u64, header_buf[24..32], .little);

        const entry_size = 16 + 8 + 8 + value_len + 8 + 1 + 8;

        const entry_buf = try self.allocator.alloc(u8, entry_size);
        defer self.allocator.free(entry_buf);
        _ = try source_file.readPositionalAll(self.io, entry_buf, offset);

        self.engine_metrics.vlog.stop(self.io, &sw, .Read);
        return try VlogEntry.readFromSlice(self.allocator, entry_buf);
    }
};

test "vlog - magic and version constants" {
    try std.testing.expectEqual(@as(u32, 0x53535442), MAGIC);
    try std.testing.expectEqual(@as(u8, 2), VERSION);
}

test "vlog - Header struct defaults" {
    const header = Header{
        .id = 1,
        .count = 100,
        .deleted = 10,
        .last_gc_ts = 1234567890,
    };

    try std.testing.expectEqual(MAGIC, header.magic);
    try std.testing.expectEqual(VERSION, header.version);
    try std.testing.expectEqual(@as(u64, 100), header.count);
    try std.testing.expectEqual(@as(u64, 10), header.deleted);
    try std.testing.expectEqual(@as(i64, 1234567890), header.last_gc_ts);
}

test "vlog - Header encode then decode preserves every field" {
    const original = Header{
        .id = 42,
        .count = 42,
        .deleted = 5,
        .last_gc_ts = 9876543210,
        .total_bytes = 1000000,
        .live_bytes = 600000,
        .dead_bytes = 400000,
        .lsn = 777,
    };

    var buf: [HEADER_SIZE]u8 = undefined;
    original.encode(&buf);
    const decoded = try Header.decode(&buf);

    try std.testing.expectEqual(original.magic, decoded.magic);
    try std.testing.expectEqual(original.version, decoded.version);
    try std.testing.expectEqual(original.id, decoded.id);
    try std.testing.expectEqual(original.count, decoded.count);
    try std.testing.expectEqual(original.deleted, decoded.deleted);
    try std.testing.expectEqual(original.last_gc_ts, decoded.last_gc_ts);
    try std.testing.expectEqual(original.total_bytes, decoded.total_bytes);
    try std.testing.expectEqual(original.live_bytes, decoded.live_bytes);
    try std.testing.expectEqual(original.dead_bytes, decoded.dead_bytes);
    try std.testing.expectEqual(original.lsn, decoded.lsn);
}

test "vlog - Header decode rejects a corrupted field" {
    var buf: [HEADER_SIZE]u8 = undefined;
    (Header{ .id = 7, .total_bytes = 500 }).encode(&buf);
    buf[40] ^= 0xFF;
    try std.testing.expectError(error.HeaderChecksumMismatch, Header.decode(&buf));
}

test "vlog - VLogConfig struct" {
    const config = VLogConfig{
        .id = 10,
        .file_name = "test.vlog",
        .block_size = 4096,
        .max_file_size = 256 * 1024 * 1024,
        .io = undefined,
    };

    try std.testing.expectEqualStrings("test.vlog", config.file_name);
    try std.testing.expectEqual(@as(u64, 4096), config.block_size);
    try std.testing.expectEqual(@as(usize, 256 * 1024 * 1024), config.max_file_size);
}

test "vlog - entry size calculation" {
    const key_size: usize = 16;
    const value_len_size: usize = 8;
    const timestamp_size: usize = 8;
    const checksum_size: usize = 8;
    const overhead = key_size + value_len_size + timestamp_size + checksum_size;

    const value_len: usize = 100;
    const expected_entry_size = overhead + value_len;
    try std.testing.expectEqual(@as(usize, 140), expected_entry_size);

    const value_len_1k: usize = 1024;
    const expected_entry_size_1k = overhead + value_len_1k;
    try std.testing.expectEqual(@as(usize, 1064), expected_entry_size_1k);
}


test "vlog - entry size with empty value" {
    const overhead: usize = 16 + 8 + 8 + 8;
    const expected_entry_size = overhead + 0;
    try std.testing.expectEqual(@as(usize, 40), expected_entry_size);
}

test "vlog - Header with max values" {
    const header = Header{
        .id = 999,
        .count = std.math.maxInt(u64),
        .deleted = std.math.maxInt(u64),
        .last_gc_ts = std.math.maxInt(i64),
    };

    try std.testing.expectEqual(std.math.maxInt(u64), header.count);
    try std.testing.expectEqual(std.math.maxInt(u64), header.deleted);
    try std.testing.expectEqual(std.math.maxInt(i64), header.last_gc_ts);
}

test "vlog - Header with zero values" {
    const header = Header{
        .id = 0,
        .count = 0,
        .deleted = 0,
        .last_gc_ts = 0,
    };

    try std.testing.expectEqual(@as(u64, 0), header.count);
    try std.testing.expectEqual(@as(u64, 0), header.deleted);
    try std.testing.expectEqual(@as(i64, 0), header.last_gc_ts);
}

test "vlog - Header with negative timestamp" {
    const header = Header{
        .id = 101,
        .count = 10,
        .deleted = 5,
        .last_gc_ts = -1000,
    };

    try std.testing.expectEqual(@as(i64, -1000), header.last_gc_ts);
}

test "vlog - VLogConfig with minimum block size" {
    const config = VLogConfig{
        .id = 1,
        .file_name = "test.vlog",
        .block_size = 1,
        .max_file_size = 1,
        .io = undefined,
    };

    try std.testing.expectEqual(@as(u64, 1), config.block_size);
    try std.testing.expectEqual(@as(usize, 1), config.max_file_size);
}

test "vlog - VLogConfig with large values" {
    const config = VLogConfig{
        .id = 123,
        .file_name = "large.vlog",
        .block_size = 1024 * 1024,
        .max_file_size = 1024 * 1024 * 1024,
        .io = undefined,
    };

    try std.testing.expectEqual(@as(u64, 1024 * 1024), config.block_size);
    try std.testing.expectEqual(@as(usize, 1024 * 1024 * 1024), config.max_file_size);
}

test "vlog - magic number is unique" {
    try std.testing.expect(MAGIC != 0x89504E47);
    try std.testing.expect(MAGIC != 0x25504446);
    try std.testing.expect(MAGIC != 0x504B0304);
}

test "vlog - Header deadRatio calculation" {
    var header = Header{
        .id = 200,
        .count = 100,
        .deleted = 50,
        .last_gc_ts = 0,
        .total_bytes = 1000,
        .live_bytes = 500,
        .dead_bytes = 500,
    };
    try std.testing.expectApproxEqRel(@as(f64, 0.5), header.deadRatio(), 0.01);

    header.total_bytes = 1000;
    header.live_bytes = 1000;
    header.dead_bytes = 0;
    try std.testing.expectApproxEqRel(@as(f64, 0.0), header.deadRatio(), 0.01);

    header.total_bytes = 1000;
    header.live_bytes = 0;
    header.dead_bytes = 1000;
    try std.testing.expectApproxEqRel(@as(f64, 1.0), header.deadRatio(), 0.01);

    header.total_bytes = 0;
    header.live_bytes = 0;
    header.dead_bytes = 0;
    try std.testing.expectEqual(@as(f64, 0.0), header.deadRatio());
}

test "vlog - Header isGcCandidate" {
    var header = Header{
        .id = 300,
        .count = 100,
        .deleted = 60,
        .last_gc_ts = 0,
        .total_bytes = 1000,
        .live_bytes = 400,
        .dead_bytes = 600,
    };

    try std.testing.expect(header.isGcCandidate(0.5));

    try std.testing.expect(!header.isGcCandidate(0.7));

    try std.testing.expect(header.isGcCandidate(0.6));
}
