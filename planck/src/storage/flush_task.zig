const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;

const log = std.log.scoped(.flush_task);

const QUEUE_DEPTH = 16;

pub const FlushTask = struct {
    allocator: Allocator,
    io: Io,
    db: *Db,
    queue_buf: []u8,
    queue: Io.Queue(u8),
    group: Io.Group,

    pub fn init(allocator: Allocator, io: Io, db: *Db) !*FlushTask {
        const self = try allocator.create(FlushTask);
        errdefer allocator.destroy(self);

        const queue_buf = try allocator.alloc(u8, QUEUE_DEPTH);
        errdefer allocator.free(queue_buf);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .db = db,
            .queue_buf = queue_buf,
            .queue = Io.Queue(u8).init(queue_buf),
            .group = Io.Group.init,
        };

        return self;
    }

    pub fn deinit(self: *FlushTask) void {
        self.queue.close(self.io);
        self.group.cancel(self.io);
        self.allocator.free(self.queue_buf);
        self.allocator.destroy(self);
    }

    pub fn startTasks(self: *FlushTask) void {
        self.group.async(self.io, runFlushTask, .{self});
    }

    pub fn triggerFlush(self: *FlushTask) void {
        self.queue.putOneUncancelable(self.io, 1) catch {
            log.warn("flush queue full - back-pressure applied", .{});
        };
    }

    fn runFlushTask(self: *FlushTask) Io.Cancelable!void {
        while (true) {
            _ = self.queue.getOne(self.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Closed => return,
            };

            self.db.flush() catch |e| {
                log.err("async flush failed: {s}", .{@errorName(e)});
            };
        }
    }
};
