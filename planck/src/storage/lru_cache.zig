const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Mutex = @import("utils").Mutex;

pub fn LruCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            key: K,
            value: V,
            prev: ?*Node,
            next: ?*Node,
        };

        allocator: Allocator,
        capacity: usize,
        map: std.AutoHashMap(K, *Node),

        head: ?*Node,
        tail: ?*Node,

        hits: u64,
        misses: u64,

        mutex: Mutex,
        io: Io,

        pub fn init(allocator: Allocator, capacity: usize, io: Io) Self {
            return .{
                .allocator = allocator,
                .capacity = capacity,
                .map = std.AutoHashMap(K, *Node).init(allocator),
                .head = null,
                .tail = null,
                .hits = 0,
                .misses = 0,
                .mutex = .{},
                .io = io,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            var node = self.head;
            while (node) |n| {
                const next = n.next;
                if (@typeInfo(V) == .pointer) {
                    if (@typeInfo(V).pointer.size == .slice) {
                        self.allocator.free(n.value);
                    }
                }
                self.allocator.destroy(n);
                node = next;
            }
            self.map.deinit();
        }

        pub fn get(self: *Self, key: K) ?V {
            self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            if (self.map.get(key)) |node| {
                self.hits += 1;
                self.moveToFront(node);
                return node.value;
            }
            self.misses += 1;
            return null;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            if (self.map.get(key)) |node| {
                if (@typeInfo(V) == .pointer) {
                    if (@typeInfo(V).pointer.size == .slice) {
                        self.allocator.free(node.value);
                    }
                }
                node.value = value;
                self.moveToFront(node);
                return;
            }

            if (self.map.count() >= self.capacity) {
                try self.evictLru();
            }

            const node = try self.allocator.create(Node);
            node.* = .{
                .key = key,
                .value = value,
                .prev = null,
                .next = null,
            };

            try self.map.put(key, node);
            self.addToFront(node);
        }

        pub fn remove(self: *Self, key: K) void {
            self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            if (self.map.fetchRemove(key)) |kv| {
                const node = kv.value;
                self.unlinkNode(node);
                if (@typeInfo(V) == .pointer) {
                    if (@typeInfo(V).pointer.size == .slice) {
                        self.allocator.free(node.value);
                    }
                }
                self.allocator.destroy(node);
            }
        }

        pub fn clear(self: *Self) void {
            self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            var node = self.head;
            while (node) |n| {
                const next = n.next;
                if (@typeInfo(V) == .pointer) {
                    if (@typeInfo(V).pointer.size == .slice) {
                        self.allocator.free(n.value);
                    }
                }
                self.allocator.destroy(n);
                node = next;
            }
            self.map.clearRetainingCapacity();
            self.head = null;
            self.tail = null;
        }

        pub fn getStats(self: *Self) struct { hits: u64, misses: u64, size: usize, capacity: usize } {
            self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            return .{
                .hits = self.hits,
                .misses = self.misses,
                .size = self.map.count(),
                .capacity = self.capacity,
            };
        }

        pub fn getHitRate(self: *Self) f64 {
            self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            const total = self.hits + self.misses;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
        }

        fn moveToFront(self: *Self, node: *Node) void {
            if (self.head == node) return;

            self.unlinkNode(node);
            self.addToFront(node);
        }

        fn addToFront(self: *Self, node: *Node) void {
            node.prev = null;
            node.next = self.head;

            if (self.head) |h| {
                h.prev = node;
            }
            self.head = node;

            if (self.tail == null) {
                self.tail = node;
            }
        }

        fn unlinkNode(self: *Self, node: *Node) void {
            if (node.prev) |p| {
                p.next = node.next;
            } else {
                self.head = node.next;
            }

            if (node.next) |n| {
                n.prev = node.prev;
            } else {
                self.tail = node.prev;
            }

            node.prev = null;
            node.next = null;
        }

        fn evictLru(self: *Self) !void {
            if (self.tail) |tail| {
                _ = self.map.remove(tail.key);
                self.unlinkNode(tail);
                if (@typeInfo(V) == .pointer) {
                    if (@typeInfo(V).pointer.size == .slice) {
                        self.allocator.free(tail.value);
                    }
                }
                self.allocator.destroy(tail);
            }
        }
    };
}

test "LruCache basic operations" {
    const allocator = std.testing.allocator;
    var cache = LruCache(u32, u32).init(allocator, 3, std.testing.io);
    defer cache.deinit();

    try cache.put(1, 100);
    try cache.put(2, 200);
    try cache.put(3, 300);

    try std.testing.expectEqual(@as(?u32, 100), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 200), cache.get(2));
    try std.testing.expectEqual(@as(?u32, 300), cache.get(3));

    try std.testing.expectEqual(@as(?u32, null), cache.get(4));
}

test "LruCache eviction" {
    const allocator = std.testing.allocator;
    var cache = LruCache(u32, u32).init(allocator, 2, std.testing.io);
    defer cache.deinit();

    try cache.put(1, 100);
    try cache.put(2, 200);
    try cache.put(3, 300);

    try std.testing.expectEqual(@as(?u32, null), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 200), cache.get(2));
    try std.testing.expectEqual(@as(?u32, 300), cache.get(3));
}

test "LruCache LRU ordering" {
    const allocator = std.testing.allocator;
    var cache = LruCache(u32, u32).init(allocator, 2, std.testing.io);
    defer cache.deinit();

    try cache.put(1, 100);
    try cache.put(2, 200);
    _ = cache.get(1);
    try cache.put(3, 300);

    try std.testing.expectEqual(@as(?u32, 100), cache.get(1));
    try std.testing.expectEqual(@as(?u32, null), cache.get(2));
    try std.testing.expectEqual(@as(?u32, 300), cache.get(3));
}

test "LruCache remove" {
    const allocator = std.testing.allocator;
    var cache = LruCache(u32, u32).init(allocator, 3, std.testing.io);
    defer cache.deinit();

    try cache.put(1, 100);
    try cache.put(2, 200);

    cache.remove(1);

    try std.testing.expectEqual(@as(?u32, null), cache.get(1));
    try std.testing.expectEqual(@as(?u32, 200), cache.get(2));
}

test "LruCache stats" {
    const allocator = std.testing.allocator;
    var cache = LruCache(u32, u32).init(allocator, 3, std.testing.io);
    defer cache.deinit();

    try cache.put(1, 100);
    _ = cache.get(1);
    _ = cache.get(2);

    const stats = cache.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
    try std.testing.expectEqual(@as(usize, 1), stats.size);
}

test "LruCache concurrent reads" {
    const allocator = std.testing.allocator;
    var cache = LruCache(u32, u32).init(allocator, 100, std.testing.io);
    defer cache.deinit();

    for (0..50) |i| {
        try cache.put(@intCast(i), @intCast(i * 100));
    }

    const num_threads = 4;
    var threads: [num_threads]std.Thread = undefined;

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(c: *LruCache(u32, u32)) void {
                for (0..100) |j| {
                    _ = c.get(@intCast(j % 50));
                }
            }
        }.run, .{&cache});
    }

    for (&threads) |*t| {
        t.join();
    }

    const stats = cache.getStats();
    try std.testing.expectEqual(@as(usize, 50), stats.size);
}

test "LruCache concurrent writes" {
    const allocator = std.testing.allocator;
    var cache = LruCache(u32, u32).init(allocator, 1000, std.testing.io);
    defer cache.deinit();

    const num_threads = 4;
    var threads: [num_threads]std.Thread = undefined;

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(c: *LruCache(u32, u32), thread_id: usize) void {
                const base = @as(u32, @intCast(thread_id * 100));
                for (0..50) |j| {
                    c.put(base + @as(u32, @intCast(j)), @as(u32, @intCast(j))) catch {};
                }
            }
        }.run, .{ &cache, i });
    }

    for (&threads) |*t| {
        t.join();
    }

    const stats = cache.getStats();
    try std.testing.expect(stats.size <= 1000);
}

test "LruCache concurrent read-write" {
    const allocator = std.testing.allocator;
    var cache = LruCache(u32, u32).init(allocator, 100, std.testing.io);
    defer cache.deinit();

    for (0..50) |i| {
        try cache.put(@intCast(i), @intCast(i));
    }

    const num_threads = 4;
    var threads: [num_threads]std.Thread = undefined;

    for (0..num_threads) |i| {
        if (i % 2 == 0) {
            threads[i] = try std.Thread.spawn(.{}, struct {
                fn run(c: *LruCache(u32, u32)) void {
                    for (0..100) |j| {
                        _ = c.get(@intCast(j % 100));
                    }
                }
            }.run, .{&cache});
        } else {
            threads[i] = try std.Thread.spawn(.{}, struct {
                fn run(c: *LruCache(u32, u32)) void {
                    for (0..50) |j| {
                        c.put(@intCast(j + 50), @intCast(j)) catch {};
                    }
                }
            }.run, .{&cache});
        }
    }

    for (&threads) |*t| {
        t.join();
    }

    const stats = cache.getStats();
    try std.testing.expect(stats.size <= 100);
}

test "LruCache concurrent remove" {
    const allocator = std.testing.allocator;
    var cache = LruCache(u32, u32).init(allocator, 100, std.testing.io);
    defer cache.deinit();

    for (0..100) |i| {
        try cache.put(@intCast(i), @intCast(i));
    }

    const num_threads = 4;
    var threads: [num_threads]std.Thread = undefined;

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(c: *LruCache(u32, u32), thread_id: usize) void {
                const start = @as(u32, @intCast(thread_id * 25));
                for (0..25) |j| {
                    c.remove(start + @as(u32, @intCast(j)));
                }
            }
        }.run, .{ &cache, i });
    }

    for (&threads) |*t| {
        t.join();
    }

    const stats = cache.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.size);
}
