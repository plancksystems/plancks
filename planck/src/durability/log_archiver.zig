const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const fmt = std.fmt;

const log = std.log.scoped(.log_archiver);

const QUEUE_DEPTH = 64;

const CLEANUP_INTERVAL_MS: u64 = 3_600_000;

pub const LogArchiverConfig = struct {
    wal_path: []const u8,
    dest_path: []const u8,
    retain_logs_days: u32 = 15,
};

pub const LogArchiver = struct {
    allocator: Allocator,
    io: Io,
    wal_path: []const u8,
    dest_path: []const u8,
    retain_logs_days: u32,
    queue_buf: [][]u8,
    queue: std.Io.Queue([]u8),
    group: Io.Group,
    last_enqueued_seq: std.atomic.Value(u64),

    pub fn init(allocator: Allocator, io: Io, config: LogArchiverConfig) !*LogArchiver {
        const self = try allocator.create(LogArchiver);
        errdefer allocator.destroy(self);

        const queue_buf = try allocator.alloc([]u8, QUEUE_DEPTH);
        errdefer allocator.free(queue_buf);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .wal_path = try allocator.dupe(u8, config.wal_path),
            .dest_path = try allocator.dupe(u8, config.dest_path),
            .retain_logs_days = config.retain_logs_days,
            .queue_buf = queue_buf,
            .queue = std.Io.Queue([]u8).init(queue_buf),
            .group = Io.Group.init,
            .last_enqueued_seq = std.atomic.Value(u64).init(0),
        };

        return self;
    }

    pub fn deinit(self: *LogArchiver) void {
        self.queue.close(self.io);
        self.group.cancel(self.io);

        self.allocator.free(self.queue_buf);
        self.allocator.free(self.wal_path);
        self.allocator.free(self.dest_path);
        self.allocator.destroy(self);
    }

    pub fn enqueue(self: *LogArchiver, seq: u64, filename: []const u8) void {
        const copy = self.allocator.dupe(u8, filename) catch |err| {
            log.err("enqueue: OOM for {s}: {}", .{ filename, err });
            return;
        };
        self.last_enqueued_seq.store(seq, .release);
        self.queue.putOneUncancelable(self.io, copy) catch {
            self.allocator.free(copy);
        };
    }

    pub fn startTasks(self: *LogArchiver) void {
        self.group.async(self.io, runShipTask, .{self});
        self.group.async(self.io, runCleanupTask, .{self});
    }

    fn runShipTask(self: *LogArchiver) Io.Cancelable!void {
        Dir.createDirPath(.cwd(), self.io, self.dest_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                log.warn("ship: dest dir {s} not available yet: {} - will retry per-file", .{
                    self.dest_path, err,
                });
            }
        };

        while (true) {
            const filename = self.queue.getOne(self.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Closed => return,
            };
            defer self.allocator.free(filename);

            self.shipFile(filename) catch |err| {
                log.warn("ship: failed to copy {s} to {s}: {} - file stays for next restart", .{
                    filename, self.dest_path, err,
                });
            };
        }
    }

    fn shipFile(self: *LogArchiver, filename: []const u8) !void {
        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src_path = try fmt.bufPrint(&src_buf, "{s}/{s}", .{ self.wal_path, filename });

        Dir.createDirPath(.cwd(), self.io, self.dest_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dest_path = try fmt.bufPrint(&dest_buf, "{s}/{s}", .{ self.dest_path, filename });

        var src_file = try Dir.openFile(.cwd(), self.io, src_path, .{});
        defer src_file.close(self.io);

        var dest_file = try Dir.createFile(.cwd(), self.io, dest_path, .{ .truncate = true });
        defer dest_file.close(self.io);

        const stat = try src_file.stat(self.io);
        const chunk_size = @min(stat.size, 256 * 1024);
        if (chunk_size == 0) return;

        const copy_buf = try self.allocator.alloc(u8, chunk_size);
        defer self.allocator.free(copy_buf);

        var offset: usize = 0;
        while (offset < stat.size) {
            const len = @min(copy_buf.len, stat.size - offset);
            const chunk = copy_buf[0..len];
            _ = try src_file.readPositionalAll(self.io, chunk, offset);
            try dest_file.writePositionalAll(self.io, chunk, offset);
            offset += len;
        }
        try dest_file.sync(self.io);
    }

    fn runCleanupTask(self: *LogArchiver) Io.Cancelable!void {
        while (true) {
            self.io.sleep(Io.Duration.fromMilliseconds(CLEANUP_INTERVAL_MS), .awake) catch |err| {
                if (err == error.Canceled) return error.Canceled;
            };

            self.performCleanup() catch |err| {
                log.warn("cleanup: error during scan: {} - will retry next cycle", .{err});
            };
        }
    }

    fn performCleanup(self: *LogArchiver) !void {
        const now_ts = std.Io.Clock.now(.real, self.io);
        const now_secs = std.Io.Timestamp.toSeconds(now_ts);

        const threshold_secs: i64 = now_secs - @as(i64, self.retain_logs_days) * 86_400;

        const last_enqueued = self.last_enqueued_seq.load(.acquire);
        if (last_enqueued == 0) return;
        var wal_dir = Dir.openDir(.cwd(), self.io, self.wal_path, .{ .iterate = true }) catch |err| {
            log.warn("cleanup: cannot open WAL dir {s}: {}", .{ self.wal_path, err });
            return;
        };
        defer wal_dir.close(self.io);

        var dir_iter = wal_dir.iterate();
        while (dir_iter.next(self.io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".wal")) continue;

            const seq_str = entry.name[0 .. entry.name.len - 4];
            const seq = fmt.parseUnsigned(u64, seq_str, 10) catch continue;

            if (seq >= last_enqueued) continue;

            var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const file_path = fmt.bufPrint(&file_path_buf, "{s}/{s}", .{
                self.wal_path, entry.name,
            }) catch continue;

            const file = Dir.openFile(.cwd(), self.io, file_path, .{}) catch continue;
            const stat = file.stat(self.io) catch {
                file.close(self.io);
                continue;
            };
            file.close(self.io);

            const mtime_secs: i64 = stat.mtime.toSeconds();

            if (mtime_secs < threshold_secs) {
                Dir.deleteFile(.cwd(), self.io, file_path) catch |err| {
                    log.warn("cleanup: failed to delete {s}: {}", .{ entry.name, err });
                    continue;
                };
                log.info("cleanup: deleted {s} (seq {d}, age > {d} days)", .{
                    entry.name, seq, self.retain_logs_days,
                });
            }
        }
    }
};
