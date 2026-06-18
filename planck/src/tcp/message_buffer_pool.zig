const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const Mutex = @import("utils").Mutex;
const Engine = @import("../engine/engine.zig").Engine;
const Session = @import("server.zig").Session;
const SecurityManager = @import("../storage/security.zig").SecurityManager;
const common = @import("../common/common.zig");

const log = std.log.scoped(.message_buffer_pool);

pub const MessageBufferPool = struct {
    allocator: Allocator,
    pool: std.ArrayList([]u8),
    mutex: Mutex,
    io: Io,
    buffer_size: usize,
    max_size: usize,

    pub fn init(allocator: Allocator, io: Io, buffer_size: usize, pool_size: usize) !MessageBufferPool {
        var pool: std.ArrayList([]u8) = .empty;
        errdefer pool.deinit(allocator);

        try pool.ensureTotalCapacity(allocator, pool_size);

        return MessageBufferPool{
            .allocator = allocator,
            .pool = pool,
            .mutex = .{},
            .io = io,
            .buffer_size = buffer_size,
            .max_size = pool_size,
        };
    }

    pub fn deinit(self: *MessageBufferPool) void {
        self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        for (self.pool.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.pool.deinit(self.allocator);
    }

    pub fn acquire(self: *MessageBufferPool, needed_size: usize) ![]u8 {
        self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.pool.items.len > 0) {
            const buffer = self.pool.pop().?;
            if (buffer.len >= needed_size and buffer.len <= needed_size * 2) {
                return buffer;
            }
            self.allocator.free(buffer);
        }

        return try self.allocator.alloc(u8, needed_size);
    }

    pub fn release(self: *MessageBufferPool, buffer: []u8) void {
        self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.pool.items.len < self.max_size) {
            self.pool.append(self.allocator, buffer) catch {
                self.allocator.free(buffer);
            };
        } else {
            self.allocator.free(buffer);
        }
    }
};

test "MessageBufferPool - init and deinit" {
    const allocator = std.testing.allocator;
    var pool = try MessageBufferPool.init(allocator, std.testing.io, 1024, 10);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 1024), pool.buffer_size);
    try std.testing.expectEqual(@as(usize, 10), pool.max_size);
}

test "MessageBufferPool - acquire and release" {
    const allocator = std.testing.allocator;
    var pool = try MessageBufferPool.init(allocator, std.testing.io, 1024, 10);
    defer pool.deinit();

    const buf = try pool.acquire(512);
    try std.testing.expect(buf.len >= 512);

    pool.release(buf);
}

test "MessageBufferPool - reuse buffers" {
    const allocator = std.testing.allocator;
    var pool = try MessageBufferPool.init(allocator, std.testing.io, 1024, 10);
    defer pool.deinit();

    const buf1 = try pool.acquire(512);
    pool.release(buf1);

    const buf2 = try pool.acquire(256);
    defer pool.release(buf2);

    try std.testing.expect(buf2.len >= 256);
}

test "MessageBufferPool - pool size limit" {
    const allocator = std.testing.allocator;
    var pool = try MessageBufferPool.init(allocator, std.testing.io, 1024, 2);
    defer pool.deinit();

    const buf1 = try pool.acquire(512);
    const buf2 = try pool.acquire(512);
    const buf3 = try pool.acquire(512);

    pool.release(buf1);
    pool.release(buf2);
    pool.release(buf3);
    pool.mutex.lock(pool.io);
    const pool_size = pool.pool.items.len;
    pool.mutex.unlock(pool.io);
    try std.testing.expect(pool_size <= 2);
}

test "MessageBufferPool - variable size allocations" {
    const allocator = std.testing.allocator;
    var pool = try MessageBufferPool.init(allocator, std.testing.io, 1024, 10);
    defer pool.deinit();

    const small = try pool.acquire(64);
    defer pool.release(small);
    try std.testing.expect(small.len >= 64);

    const medium = try pool.acquire(512);
    defer pool.release(medium);
    try std.testing.expect(medium.len >= 512);

    const large = try pool.acquire(4096);
    defer pool.release(large);
    try std.testing.expect(large.len >= 4096);
}

test "MessageBufferPool - concurrent access" {
    const allocator = std.testing.allocator;
    var pool = try MessageBufferPool.init(allocator, std.testing.io, 1024, 100);
    defer pool.deinit();

    const num_threads = 4;
    var threads: [num_threads]std.Thread = undefined;

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(p: *MessageBufferPool) void {
                for (0..10) |_| {
                    const buf = p.acquire(256) catch continue;
                    @memset(buf[0..256], 0xAB);
                    p.release(buf);
                }
            }
        }.run, .{&pool});
    }

    for (&threads) |*t| {
        t.join();
    }

    pool.mutex.lock(pool.io);
    const pool_size = pool.pool.items.len;
    pool.mutex.unlock(pool.io);
    try std.testing.expect(pool_size <= 100);
}

test "MessageBufferPool - zero size request" {
    const allocator = std.testing.allocator;
    var pool = try MessageBufferPool.init(allocator, std.testing.io, 1024, 10);
    defer pool.deinit();

    const buf = try pool.acquire(0);
    defer pool.release(buf);
    try std.testing.expect(buf.len == 0);
}

test "MessageBufferPool - exact size match" {
    const allocator = std.testing.allocator;
    var pool = try MessageBufferPool.init(allocator, std.testing.io, 1024, 10);
    defer pool.deinit();

    const buf = try pool.acquire(1024);
    defer pool.release(buf);
    try std.testing.expect(buf.len >= 1024);
}
