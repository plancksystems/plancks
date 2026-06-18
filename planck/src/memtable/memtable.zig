const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const SkipList = @import("skiplist.zig").SkipList;
const SkipLists = @import("skiplists.zig").SkipLists;

const common = @import("../common/common.zig");
const Entry = common.Entry;
const Now = @import("utils").Now;

const log = std.log.scoped(.memtable);

pub const MemTable = struct {
    allocator: Allocator,
    active: *SkipList,
    lists: *SkipLists,
    size_threshold: u64,
    now: Now,
    io: std.Io,

    pub fn init(allocator: Allocator, io: std.Io, size_threshold: u64) !*MemTable {
        const memtable = try allocator.create(MemTable);

        memtable.allocator = allocator;
        memtable.size_threshold = size_threshold;
        memtable.io = io;
        memtable.now = Now{ .io = io };
        memtable.active = try SkipList.init(allocator, 64, @intCast(memtable.now.toMilliSeconds()));
        memtable.lists = try SkipLists.init(allocator);
        return memtable;
    }

    pub fn deinit(self: *MemTable) void {
        self.active.deinit();
        self.lists.deinit();
        self.allocator.destroy(self);
    }

    pub fn post(self: *MemTable, entry: Entry) !bool {
        var switched: bool = false;
        if (self.active.size >= self.size_threshold) {
            self.lists.push(self.active) catch |err| {
                log.err("Failed to push SkipList: {s}", .{@errorName(err)});
                return err;
            };
            self.active = try SkipList.init(self.allocator, 64, @intCast(self.now.toMilliSeconds()));
            switched = true;
        }
        _ = self.active.post(entry) catch |err| {
            log.err("Failed to post key in MemTable: {s}", .{@errorName(err)});
            return err;
        };

        return switched;
    }

    pub fn put(self: *MemTable, lsn: u64, key: u128, value: []const u8, timestamp: i64) !bool {
        return try self.post(.{
            .lsn = lsn,
            .key = key,
            .value = value,
            .timestamp = timestamp,
            .kind = .update,
        });
    }

    pub fn get(self: *MemTable, key: u128) ![]const u8 {
        if (self.active.get(key)) |node| {
            if (node.kind == .delete) {
                return error.NotFound;
            }
            return node.value;
        }

        var i: usize = self.lists.len;
        while (i > 0) {
            i -= 1;
            if (try self.lists.get(i)) |skl| {
                if (skl.get(key)) |node| {
                    if (node.kind == .delete) {
                        return error.NotFound;
                    }
                    return node.value;
                }
            }
        }

        return error.NotFound;
    }

    pub fn del(self: *MemTable, key: u128) !void {
        return self.active.del(key);
    }

    pub fn pendingDelete(self: *const MemTable, key: u128) bool {
        if (self.active.get(key)) |node| {
            return node.kind == .delete;
        }
        var i: usize = self.lists.len;
        while (i > 0) {
            i -= 1;
            if (self.lists.get(i) catch null) |skl| {
                if (skl.get(key)) |node| {
                    return node.kind == .delete;
                }
            }
        }
        return false;
    }

    pub fn activeSize(self: *const MemTable) u64 {
        return self.active.size;
    }

    pub fn pendingFlushCount(self: *const MemTable) usize {
        return self.lists.len;
    }

    pub fn switchActive(self: *MemTable) !void {
        if (self.active.count > 0) {
            try self.lists.push(self.active);
            self.active = try SkipList.init(self.allocator, 64, @intCast(self.now.toMilliSeconds()));
        }
    }
};

test "MemTable - init and deinit" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    try testing.expectEqual(@as(u64, 1000), mt.size_threshold);
    try testing.expectEqual(@as(u64, 0), mt.activeSize());
    try testing.expectEqual(@as(usize, 0), mt.pendingFlushCount());
}

test "MemTable - put and get" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    const value = "test_value";
    _ = try mt.put(0,42, value, 1000);

    const retrieved = try mt.get(42);
    try testing.expectEqualStrings(value, retrieved);
}

test "MemTable - get nonexistent key returns NotFound" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    const result = mt.get(999);
    try testing.expectError(error.NotFound, result);
}

test "MemTable - put updates existing key" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    _ = try mt.put(0,42, "first_value", 1000);
    _ = try mt.put(0,42, "second_value", 2000);

    const retrieved = try mt.get(42);
    try testing.expectEqualStrings("second_value", retrieved);
}

test "MemTable - del marks key as deleted" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    _ = try mt.put(0,42, "value", 1000);
    try mt.del(42);

    const result = mt.get(42);
    try testing.expectError(error.NotFound, result);
}

test "MemTable - multiple keys" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    _ = try mt.put(0,1, "one", 1000);
    _ = try mt.put(0,2, "two", 1001);
    _ = try mt.put(0,3, "three", 1002);

    try testing.expectEqualStrings("one", try mt.get(1));
    try testing.expectEqualStrings("two", try mt.get(2));
    try testing.expectEqualStrings("three", try mt.get(3));
}

test "MemTable - activeSize increases with puts" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    const initial_size = mt.activeSize();
    _ = try mt.put(0,1, "value", 1000);

    try testing.expect(mt.activeSize() > initial_size);
}

test "MemTable - empty value" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    _ = try mt.put(0,1, "", 1000);
    const retrieved = try mt.get(1);
    try testing.expectEqualStrings("", retrieved);
}

test "MemTable - large value" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,100000);
    defer mt.deinit();

    var large_value: [1024]u8 = undefined;
    @memset(&large_value, 'X');

    _ = try mt.put(0,1, &large_value, 1000);
    const retrieved = try mt.get(1);
    try testing.expectEqual(@as(usize, 1024), retrieved.len);
}

test "MemTable - large key" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    const large_key: u128 = 999999999999;
    _ = try mt.put(0, large_key, "large_key", 1000);
    const retrieved = try mt.get(large_key);
    try testing.expectEqualStrings("large_key", retrieved);
}

test "MemTable - zero key" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    _ = try mt.put(0,0, "zero", 1000);
    const retrieved = try mt.get(0);
    try testing.expectEqualStrings("zero", retrieved);
}

test "MemTable - max u128 key" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    const max_key: u128 = std.math.maxInt(u128);
    _ = try mt.put(0, max_key, "max", 1000);
    const retrieved = try mt.get(max_key);
    try testing.expectEqualStrings("max", retrieved);
}

test "MemTable - delete nonexistent key does not error" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    try testing.expectError(error.NotFound, mt.del(999));
}

test "MemTable - put same key multiple times" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    _ = try mt.put(0,1, "first", 1000);
    _ = try mt.put(0,1, "second", 2000);
    _ = try mt.put(0,1, "third", 3000);

    const retrieved = try mt.get(1);
    try testing.expectEqualStrings("third", retrieved);
}

test "MemTable - delete then reinsert" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    _ = try mt.put(0,1, "original", 1000);
    try mt.del(1);
    try testing.expectError(error.NotFound, mt.get(1));

    _ = try mt.put(0,1, "reinserted", 2000);
    const retrieved = try mt.get(1);
    try testing.expectEqualStrings("reinserted", retrieved);
}

test "MemTable - minimum size threshold" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1);
    defer mt.deinit();

    try testing.expectEqual(@as(u64, 1), mt.size_threshold);
}

test "MemTable - pendingFlushCount starts at zero" {
    const allocator = testing.allocator;
    var mt = try MemTable.init(allocator, std.testing.io,1000);
    defer mt.deinit();

    try testing.expectEqual(@as(usize, 0), mt.pendingFlushCount());
}
