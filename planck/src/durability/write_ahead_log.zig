const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const mem = std.mem;
const fmt = std.fmt;
const testing = std.testing;
const crc32 = std.hash.Crc32;
const json = std.json;
const WalError = @import("wal_error.zig").WalError;
const LogArchiver = @import("log_archiver.zig").LogArchiver;
const CheckpointRecord = @import("checkpoint.zig").CheckpointRecord;

const EngineMetrics = @import("../common/metrics.zig").EngineMetrics;
const StopWatch = @import("../common/metrics.zig").StopWatch;
const LogRecordKind = @import("../common/common.zig").LogRecordKind;
const LogRecord = @import("../common/common.zig").LogRecord;
const Buffer = @import("utils").Buffer;
const Now = @import("utils").Now;
const log = std.log.scoped(.wal);

pub const WalConfig = struct {
    dir_path: []const u8,
    max_file_size: usize,
    max_buffer_size: usize,
    flush_interval_in_ms: i64,
    io: Io,
    retain_logs_days: u32 = 15,
    log_archive_enabled: bool,
    log_archive_dest_path: []const u8,
    skip_buffers: bool = false,
};

pub const WalHeader = struct {
    startLSN: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    lastLSN: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn read(io: std.Io, file: File) !WalHeader {
        var header_buf: [16]u8 = undefined;
        _ = try file.readPositionalAll(io, header_buf[0..], 0);
        const slsn = std.mem.readInt(u64, header_buf[0..8], .little);
        const llsn = std.mem.readInt(u64, header_buf[8..16], .little);

        return WalHeader{
            .startLSN = std.atomic.Value(u64).init(slsn),
            .lastLSN = std.atomic.Value(u64).init(llsn),
        };
    }
    pub fn write(self: *WalHeader, io: Io, file: File) !void {
        const slsn = self.startLSN.load(.monotonic);
        const llsn = self.lastLSN.load(.monotonic);

        var header_buf: [16]u8 = undefined;
        std.mem.writeInt(u64, header_buf[0..8], slsn, .little);
        std.mem.writeInt(u64, header_buf[8..16], llsn, .little);
        try file.writePositionalAll(io, header_buf[0..], 0);
    }

    pub fn update(self: *WalHeader) void {
        const llsn = self.lastLSN.load(.monotonic);
        self.startLSN.store(llsn, .monotonic);
        self.lastLSN.store(llsn, .monotonic);
    }
};

pub const ReplayResult = struct {
    arena: *std.heap.ArenaAllocator,
    records: []const LogRecord,
};

pub const WriteAheadLog = struct {
    allocator: mem.Allocator,
    io: Io,
    dir_path: []const u8,
    current_seq: u64,
    current_file: ?File,
    engine_metrics: ?*EngineMetrics,
    buffer: Buffer,
    max_buffer_size: usize,
    max_file_size: usize,
    file_size: usize = 16,
    header: WalHeader = .{},
    flushed_lsn: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    lsn: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pending_writes: u32 = 0,
    last_sync_time: i64 = 0,
    now: Now,
    needs_sync: bool = false,
    retain_logs_days: u32,
    log_archiver: ?*LogArchiver = null,
    skip_buffers: bool = false,
    flush_interval_in_ms: i64,

    pub fn init(allocator: mem.Allocator, engine_metrics: ?*EngineMetrics, config: WalConfig) !*WriteAheadLog {
        const io = config.io;

        Dir.createDirPath(.cwd(), io, config.dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const buf_size = if (config.skip_buffers) 4096 else config.max_buffer_size;

        var self = try allocator.create(WriteAheadLog);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .dir_path = try allocator.dupe(u8, config.dir_path),
            .current_seq = 0,
            .current_file = null,
            .buffer = try Buffer.init(allocator, buf_size),
            .max_buffer_size = buf_size,
            .max_file_size = config.max_file_size,
            .retain_logs_days = config.retain_logs_days,
            .header = .{},
            .now = Now{ .io = io },
            .flush_interval_in_ms = config.flush_interval_in_ms,
            .engine_metrics = engine_metrics,
            .skip_buffers = config.skip_buffers,
        };

        self.last_sync_time = self.now.toMilliSeconds();
        
        if (config.log_archive_enabled and !config.skip_buffers) {
            self.log_archiver = try LogArchiver.init(allocator, io, .{
                .dest_path = config.log_archive_dest_path,
                .retain_logs_days = config.retain_logs_days,
                .wal_path = config.dir_path,
            });
            if (self.log_archiver) |archiver| {
                archiver.startTasks();
            }
        }

        var max_seq: u64 = 0;
        var found_file = false;

        if (Dir.openDir(.cwd(), io, self.dir_path, .{ .iterate = true })) |dir| {
            var wal_dir = dir;
            defer wal_dir.close(io);
            var dir_iter = wal_dir.iterate();
            while (dir_iter.next(io) catch null) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".wal")) {
                    const seq_str = entry.name[0 .. entry.name.len - 4];
                    const seq = fmt.parseUnsigned(u64, seq_str, 10) catch continue;
                    if (!found_file or seq > max_seq) {
                        max_seq = seq;
                    }
                    found_file = true;
                }
            }
        } else |_| {}

        if (found_file) {
            self.current_seq = max_seq;
            const file_path = try self.getFilePath(self.current_seq);
            defer self.allocator.free(file_path);
            self.current_file = Dir.openFile(.cwd(), io, file_path, .{ .mode = .read_write }) catch null;
            if (self.current_file) |file| {
                const stat = file.stat(io) catch null;
                if (stat) |s| {
                    self.file_size = s.size;
                }
                self.header = try WalHeader.read(self.io, file);
                const persisted_lsn = self.header.lastLSN.load(.monotonic);
                self.lsn.store(persisted_lsn, .monotonic);
                self.flushed_lsn.store(persisted_lsn, .monotonic);
            }
        } else {
            self.current_seq = 0;
            self.current_file = null;
        }
        return self;
    }

    pub fn deinit(self: *WriteAheadLog) WalError!void {
        try self.flush();
        if (self.current_file) |file| {
            file.close(self.io);
        }
        self.buffer.deinit();
        self.allocator.free(self.dir_path);
        self.allocator.destroy(self);
    }

    fn getFilePath(self: *WriteAheadLog, seq: u64) ![]u8 {
        return try fmt.allocPrint(self.allocator, "{s}/{d:0>6}.wal", .{ self.dir_path, seq });
    }

    pub fn incrementLSN(self: *WriteAheadLog) u64 {
        const lsn = self.lsn.load(.monotonic) + 1;
        self.lsn.store(lsn, .monotonic);
        return lsn;
    }

    pub fn flushedLSN(self: *WriteAheadLog, flushed_lsn: u64) void {
        self.flushed_lsn.store(flushed_lsn, .monotonic);
    }

    fn flushBuffer(self: *WriteAheadLog) WalError!void {
        var sw: StopWatch = if (self.engine_metrics) |em| em.wal.start(self.io, .Flush) else .{};
        defer if (self.engine_metrics) |em| em.wal.stop(self.io, &sw, .Flush);

        if (self.buffer.pos == 0) {
            return;
        }
        if (self.current_file == null) {
            try self.rotate();

            self.file_size = 16 + self.buffer.pos;
        }
        var file = self.current_file.?;

        const write_offset = self.file_size - self.buffer.pos;
        file.writePositionalAll(self.io, self.buffer.slice(), write_offset) catch return WalError.WriteFailed;
        self.buffer.reset();
        self.needs_sync = true;
    }

    pub fn sync(self: *WriteAheadLog) WalError!void {
        if (!self.needs_sync) return;

        var sw: StopWatch = if (self.engine_metrics) |em| em.wal.start(self.io, .Fsync) else .{};
        defer if (self.engine_metrics) |em| em.wal.stop(self.io, &sw, .Fsync);

        if (self.current_file) |file| {
            try file.sync(self.io);
            self.needs_sync = false;
            self.pending_writes = 0;
            self.last_sync_time = self.now.toMilliSeconds();
        }
    }

    pub fn flush(self: *WriteAheadLog) WalError!void {
        try self.flushBuffer();
        try self.sync();
    }

    pub fn append(self: *WriteAheadLog, record: LogRecord) !void {
        var sw: StopWatch = if (self.engine_metrics) |em| em.wal.start(self.io, .Append) else .{};
        defer if (self.engine_metrics) |em| em.wal.stop(self.io, &sw, .Append);

        if (self.buffer.pos + record.size() >= self.max_buffer_size) {
            try self.flush();
        }

        const now_ms = self.now.toMilliSeconds();
        if (now_ms - self.last_sync_time >= self.flush_interval_in_ms and self.buffer.pos > 0) {
            try self.flush();
        }

        if (self.file_size >= self.max_file_size) {
            try self.flush();
            try self.rotate();
        }

        try LogRecord.serialize(record, self.buffer.writer());

        self.file_size += record.size();
        self.pending_writes += 1;
        self.header.lastLSN.store(self.lsn.load(.monotonic), .monotonic);

        if (self.skip_buffers) {
            try self.flush();
        }
    }

    pub fn appendAndSync(self: *WriteAheadLog, record: LogRecord) !void {
        var sw: StopWatch = if (self.engine_metrics) |em| em.wal.start(self.io, .Append) else .{};
        defer if (self.engine_metrics) |em| em.wal.stop(self.io, &sw, .Append);

        if (self.file_size >= self.max_file_size) {
            try self.flush();
            try self.rotate();
        }

        try LogRecord.serialize(record, self.buffer.writer());
        self.file_size += record.size();
        self.pending_writes += 1;
        self.header.lastLSN.store(self.lsn.load(.monotonic), .monotonic);
        try self.flush();
    }

    pub fn rotate(self: *WriteAheadLog) WalError!void {
        try self.sync();
        if (self.current_file) |file| {
            self.header.write(self.io, file) catch |err| {
                file.close(self.io);
                std.debug.print("Failed to write WAL header during rotation: {s}\n", .{@errorName(err)});
                return WalError.FailedToWriteHeader;
            };
            file.close(self.io);

            if (self.log_archiver) |ls| {
                var name_buf: [24]u8 = undefined;
                const name = fmt.bufPrint(&name_buf, "{d:0>6}.wal", .{self.current_seq}) catch unreachable;
                ls.enqueue(self.current_seq, name);
            }
        }
        self.current_seq += 1;
        const file_path = try self.getFilePath(self.current_seq);
        defer self.allocator.free(file_path);
        self.current_file = try Dir.createFile(.cwd(), self.io, file_path, .{ .read = true, .truncate = false });
        if (self.current_file) |file| {
            self.header.update();
            self.header.write(self.io, file) catch |err| {
                file.close(self.io);
                std.debug.print("Failed to write WAL header during rotation: {s}\n", .{@errorName(err)});
                return WalError.FailedToWriteHeader;
            };
        }
        self.file_size = 16;
        self.needs_sync = false;
    }

    pub fn checkpoint(self: *WriteAheadLog) WalError!void {
        try self.flush();
        const cp = CheckpointRecord{ .file_seq = if (self.current_file == null) 0 else self.current_seq, .last_flushed_lsn = self.flushed_lsn.load(.monotonic) };
        try cp.save(self.io, self.dir_path);
        try self.rotate();
    }

    pub fn truncate(self: *WriteAheadLog) WalError!void {
        var sw: StopWatch = if (self.engine_metrics) |em| em.wal.start(self.io, .Truncate) else .{};
        defer if (self.engine_metrics) |em| em.wal.stop(self.io, &sw, .Truncate);

        const ns_per_day: i128 = 24 * 3600 * std.time.ns_per_s;
        const retain_ns: i128 = @as(i128, self.retain_logs_days) * ns_per_day;
        const now_ns: i128 = std.Io.Clock.now(.real, self.io).toNanoseconds();
        const cutoff_ns: i128 = now_ns - retain_ns;

        var wal_dir = Dir.openDir(.cwd(), self.io, self.dir_path, .{ .iterate = true }) catch return;
        defer wal_dir.close(self.io);

        var dir_iter = wal_dir.iterate();
        while (dir_iter.next(self.io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".wal")) continue;

            const seq_str = entry.name[0 .. entry.name.len - 4];
            const seq = fmt.parseUnsigned(u64, seq_str, 10) catch continue;

            if (seq >= self.current_seq) continue;

            const file_path = self.getFilePath(seq) catch continue;
            defer self.allocator.free(file_path);

            const file = Dir.openFile(.cwd(), self.io, file_path, .{}) catch continue;
            const stat = file.stat(self.io) catch {
                file.close(self.io);
                continue;
            };
            file.close(self.io);

            const file_mtime: i128 = stat.mtime.toNanoseconds();
            if (file_mtime >= cutoff_ns) continue;

            Dir.deleteFile(.cwd(), self.io, file_path) catch |err| {
                log.warn("truncate: failed to delete {s}: {}", .{ entry.name, err });
                continue;
            };
            log.info("truncate: deleted {s} (seq {d}, age > {d} days)", .{
                entry.name, seq, self.retain_logs_days,
            });
        }
    }

    pub fn hasData(self: *WriteAheadLog) bool {
        return (self.current_file != null and self.file_size > 16) or self.current_seq > 0;
    }

    pub fn reset(self: *WriteAheadLog) WalError!void {
        try self.flush();

        if (self.current_file) |file| {
            file.close(self.io);
            self.current_file = null;
        }

        var wal_dir = Dir.openDir(.cwd(), self.io, self.dir_path, .{ .iterate = true }) catch return;
        defer wal_dir.close(self.io);

        var dir_iter = wal_dir.iterate();
        while (dir_iter.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wal") and !std.mem.eql(u8, entry.name, "CHECKPOINT")) continue;

            const file_path = fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_path, entry.name }) catch continue;
            defer self.allocator.free(file_path);
            Dir.deleteFile(.cwd(), self.io, file_path) catch {};
        }

        self.current_seq = 0;
        self.file_size = 16;
        self.buffer.reset();
        self.header = .{};
        self.pending_writes = 0;
        self.needs_sync = false;
    }

    pub fn replayFile(self: *WriteAheadLog, seq: u64, list: *std.ArrayList(LogRecord), allocator: mem.Allocator) !void {
        const file_path = try self.getFilePath(seq);
        defer self.allocator.free(file_path);
        var file = try Dir.openFile(.cwd(), self.io, file_path, .{});
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const content = try allocator.alloc(u8, stat.size);
        defer allocator.free(content);
        self.header = try WalHeader.read(self.io, file);
        _ = try file.readPositionalAll(self.io, content, 0);

        var offset: usize = 16;
        while (offset < content.len) {
            const BufferReader = struct {
                buffer: []const u8,
                pos: usize,

                pub fn readInt(r: *@This(), comptime T: type, endian: std.builtin.Endian) !T {
                    const size = @sizeOf(T);
                    if (r.pos + size > r.buffer.len) return error.EndOfStream;
                    const value = std.mem.readInt(T, r.buffer[r.pos..][0..size], endian);
                    r.pos += size;
                    return value;
                }

                pub fn readAll(r: *@This(), buf: []u8) !void {
                    if (r.pos + buf.len > r.buffer.len) return error.EndOfStream;
                    @memcpy(buf, r.buffer[r.pos..][0..buf.len]);
                    r.pos += buf.len;
                }
            };

            var reader = BufferReader{ .buffer = content[offset..], .pos = 0 };
            const record_result = LogRecord.deserialize(allocator, &reader) catch |err| {
                if (err == error.InvalidRecordLength or err == error.ChecksumMismatch) {
                    std.debug.print("Replay Failed: {s}", .{@errorName(err)});
                    break;
                }
                return err;
            };
            if (record_result) |record| {
                try list.append(allocator, record);
                offset += record.size();
            } else {
                break;
            }
        }
    }

    pub fn replay(self: *WriteAheadLog) !ReplayResult {
        try self.flush();

        var sw: StopWatch = if (self.engine_metrics) |em| em.wal.start(self.io, .Replay) else .{};
        const gpa = std.heap.page_allocator;
        var arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        var records_list: std.ArrayList(LogRecord) = .empty;
        const cp = try CheckpointRecord.load(self.allocator, self.io, self.dir_path);
        var seq = cp.file_seq;
        if (seq == 0) seq = 1;
        while (seq <= self.current_seq) : (seq += 1) {
            self.replayFile(seq, &records_list, arena.allocator()) catch |err| {
                if (err == error.FileNotFound) {
                    break;
                }
                return err;
            };
        }
        if (self.engine_metrics) |em| em.wal.stop(self.io, &sw, .Replay);
        return ReplayResult{
            .arena = arena,
            .records = try records_list.toOwnedSlice(arena.allocator()),
        };
    }
};
