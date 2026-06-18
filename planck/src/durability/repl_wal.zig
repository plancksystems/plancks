const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const Buffer = @import("utils").Buffer;
const Now = @import("utils").Now;
const CheckpointRecord = @import("checkpoint.zig").CheckpointRecord;

const log = std.log.scoped(.repl_wal);

pub const ReplWalConfig = struct {
    dir_path: []const u8,
    max_file_size: u64,
    sync_interval_ms: u64,
    buffer_size: u64,
    io: Io,
};

pub const ReplWal = struct {
    allocator: Allocator,
    io: Io,
    dir_path: []const u8,

    current_seq: u64,
    current_file: ?File,
    file_size: u64,
    max_file_size: u64,
    sync_interval_ms: u64,
    last_rotate_time: i64 = 0,
    now: Now,
    buffer: Buffer,
    record_count: u32,
    last_lsn: u64 = 0,

    pub fn init(allocator: Allocator, config: ReplWalConfig) !*ReplWal {
        const io = config.io;

        Dir.createDirPath(.cwd(), io, config.dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        var max_seq: u64 = 0;
        var found_file = false;

        if (Dir.openDir(.cwd(), io, config.dir_path, .{ .iterate = true })) |dir| {
            var wal_dir = dir;
            defer wal_dir.close(io);
            var dir_iter = wal_dir.iterate();
            while (dir_iter.next(io) catch null) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".rwal")) {
                    const seq_str = entry.name[0 .. entry.name.len - 5];
                    const seq = fmt.parseUnsigned(u64, seq_str, 10) catch continue;
                    if (!found_file or seq > max_seq) {
                        max_seq = seq;
                    }
                    found_file = true;
                }
            }
        } else |_| {}

        const self = try allocator.create(ReplWal);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .dir_path = try allocator.dupe(u8, config.dir_path),
            .current_seq = if (found_file) max_seq else 1,
            .current_file = null,
            .file_size = 0,
            .max_file_size = config.max_file_size,
            .sync_interval_ms = config.sync_interval_ms,
            .now = Now{ .io = io },
            .buffer = try Buffer.init(allocator, @intCast(config.buffer_size)),
            .record_count = 0,
        };

        self.last_rotate_time = self.now.toMilliSeconds();

        if (found_file) {
            const file_path = try self.getFilePath(max_seq);
            defer allocator.free(file_path);
            if (Dir.openFile(.cwd(), io, file_path, .{ .mode = .read_write })) |file| {
                if (file.stat(io)) |stat| {
                    self.current_file = file;
                    self.file_size = stat.size;
                } else |_| {
                    file.close(io);
                }
            } else |_| {}
        }

        return self;
    }

    pub fn deinit(self: *ReplWal) void {
        self.flush() catch {};
        if (self.current_file) |file| {
            file.close(self.io);
            self.current_file = null;
        }
        self.buffer.deinit();
        self.allocator.free(self.dir_path);
        self.allocator.destroy(self);
    }

    pub fn checkpoint(self: *ReplWal, confirmed_seq: u64) !void {
        const cp = CheckpointRecord{
            .file_seq = confirmed_seq,
            .last_flushed_lsn = self.last_lsn,
        };
        try cp.save(self.io, self.dir_path);
    }

    pub fn loadCheckpoint(self: *ReplWal) !CheckpointRecord {
        return CheckpointRecord.load(self.allocator, self.io, self.dir_path);
    }

    pub fn append(self: *ReplWal, data: []const u8) !void {
        if (self.current_file == null) {
            try self.openNewFile();
        }

        const frame_size: u64 = 4 + data.len;

        if (self.buffer.pos + frame_size > self.buffer.len) {
            try self.flush();
        }

        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(data.len), .little);
        _ = try self.buffer.write(&len_buf);
        _ = try self.buffer.write(data);

        self.file_size += frame_size;
        self.record_count += 1;
    }

    pub fn flush(self: *ReplWal) !void {
        if (self.buffer.pos == 0) return;
        const file = self.current_file orelse return;

        const write_offset = self.file_size - self.buffer.pos;
        file.writePositionalAll(self.io, self.buffer.slice(), write_offset) catch |err| {
            log.err("flush: write failed: {}", .{err});
            return err;
        };
        file.sync(self.io) catch |err| {
            log.err("flush: sync failed: {}", .{err});
            return err;
        };
        self.buffer.reset();
    }

    pub fn shouldRotate(self: *ReplWal) bool {
        if (self.current_file == null) return false;
        if (self.file_size >= self.max_file_size) return true;
        const elapsed: u64 = @intCast(@max(0, self.now.toMilliSeconds() - self.last_rotate_time));
        return elapsed >= self.sync_interval_ms and self.file_size > 0;
    }

    pub fn rotate(self: *ReplWal) !u64 {
        try self.flush();

        const rotated_seq = self.current_seq;

        if (self.current_file) |file| {
            file.close(self.io);
            self.current_file = null;
        }

        self.current_seq += 1;
        self.file_size = 0;
        self.record_count = 0;
        self.last_rotate_time = self.now.toMilliSeconds();

        return rotated_seq;
    }

    pub fn readFile(self: *ReplWal, seq: u64, allocator: Allocator) ![][]u8 {
        const file_path = try self.getFilePath(seq);
        defer self.allocator.free(file_path);

        const file = Dir.openFile(.cwd(), self.io, file_path, .{}) catch |err| {
            log.err("readFile: failed to open seq={d}: {}", .{ seq, err });
            return err;
        };
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        if (stat.size == 0) return try allocator.alloc([]u8, 0);

        const file_data = try allocator.alloc(u8, stat.size);
        defer allocator.free(file_data);
        _ = try file.readPositionalAll(self.io, file_data, 0);

        var frames: std.ArrayList([]u8) = .empty;
        var pos: usize = 0;

        while (pos + 4 <= file_data.len) {
            const frame_len = std.mem.readInt(u32, file_data[pos..][0..4], .little);
            pos += 4;
            if (pos + frame_len > file_data.len) break;
            const frame = try allocator.dupe(u8, file_data[pos..][0..frame_len]);
            try frames.append(allocator, frame);
            pos += frame_len;
        }

        return frames.toOwnedSlice(allocator) catch |err| {
            log.err("readFile: toOwnedSlice failed: {}", .{err});
            return err;
        };
    }

    pub fn deleteFile(self: *ReplWal, seq: u64) !void {
        const file_path = try self.getFilePath(seq);
        defer self.allocator.free(file_path);
        Dir.deleteFile(.cwd(), self.io, file_path) catch |err| {
            log.warn("deleteFile: failed to delete seq={d}: {}", .{ seq, err });
            return err;
        };
    }

    pub fn reset(self: *ReplWal) !void {
        try self.flush();
        if (self.current_file) |file| {
            file.close(self.io);
            self.current_file = null;
        }

        if (Dir.openDir(.cwd(), self.io, self.dir_path, .{ .iterate = true })) |dir| {
            var wal_dir = dir;
            defer wal_dir.close(self.io);
            var dir_iter = wal_dir.iterate();
            while (dir_iter.next(self.io) catch null) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".rwal")) {
                    const full_path = fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_path, entry.name }) catch continue;
                    defer self.allocator.free(full_path);
                    Dir.deleteFile(.cwd(), self.io, full_path) catch {};
                }
            }
        } else |_| {}

        self.current_seq = 1;
        self.file_size = 0;
        self.record_count = 0;
        self.last_rotate_time = self.now.toMilliSeconds();
        self.buffer.reset();
    }

    fn openNewFile(self: *ReplWal) !void {
        const file_path = try self.getFilePath(self.current_seq);
        defer self.allocator.free(file_path);
        self.current_file = try Dir.createFile(.cwd(), self.io, file_path, .{ .read = true, .truncate = false });
        self.file_size = 0;
        self.last_rotate_time = self.now.toMilliSeconds();
    }

    fn getFilePath(self: *ReplWal, seq: u64) ![]u8 {
        return try fmt.allocPrint(self.allocator, "{s}/{d:0>6}.rwal", .{ self.dir_path, seq });
    }
};
