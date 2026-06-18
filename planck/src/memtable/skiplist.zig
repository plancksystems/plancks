const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const common = @import("../common/common.zig");
const Entry = common.Entry;

const Node = struct {
    key: u128,
    entry: Entry,
    level: usize,
    forward: []?*Node,

    fn init(arena: Allocator, key: u128, entry: Entry, level: usize) !*Node {
        const node = try arena.create(Node);
        const fwd = try arena.alloc(?*Node, level + 1);
        @memset(fwd, null);
        node.* = .{
            .key = key,
            .entry = entry,
            .level = level,
            .forward = fwd,
        };
        return node;
    }
};

pub const SkipList = struct {
    backing: Allocator,
    arena: *std.heap.ArenaAllocator,

    max_level: usize,
    current_level: isize,
    header: ?*Node,
    rng: std.Random.DefaultPrng,
    count: usize,
    size: usize,

    pub fn init(backing: Allocator, max_level: usize, seed: u64) !*SkipList {
        const arena = try backing.create(std.heap.ArenaAllocator);
        errdefer backing.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();

        const self = try backing.create(SkipList);
        errdefer backing.destroy(self);

        self.* = .{
            .backing = backing,
            .arena = arena,
            .max_level = max_level,
            .current_level = -1,
            .header = null,
            .rng = std.Random.DefaultPrng.init(seed),
            .count = 0,
            .size = 0,
        };

        try self.createHeader();
        return self;
    }

    pub fn deinit(self: *SkipList) void {
        const backing = self.backing;
        const arena = self.arena;
        var iter = self.iterator();
        while (iter.next()) |entry| {
            arena.allocator().free(entry.value);
        }
        var diter = self.deliterator();
        while (diter.next()) |node| {
            self.arena.allocator().destroy(node);
        }
        _ = arena.reset(.free_all);

        arena.deinit();
        backing.destroy(arena);

        backing.destroy(self);
    }

    fn createHeader(self: *SkipList) !void {
        self.header = try Node.init(self.arena.allocator(), undefined, undefined, self.max_level);
    }

    fn randomLevel(self: *SkipList) usize {
        var lvl: usize = 0;
        while (lvl < self.max_level and self.rng.random().boolean()) lvl += 1;
        return lvl;
    }

    fn cmp(a_key: u128, b_key: u128) Order {
        return std.math.order(a_key, b_key);
    }

    pub fn post(self: *SkipList, entry: Entry) !bool {
        const arena = self.arena.allocator();

        if (self.header == null) try self.createHeader();

        const value_copy = try arena.dupe(u8, entry.value);
        var ec = entry;
        ec.value = value_copy;

        const update = try arena.alloc(?*Node, self.max_level + 1);
        @memset(update, null);

        var cur = self.header.?;
        var i: isize = if (self.current_level >= 0) self.current_level else @as(isize, @intCast(self.max_level));
        while (i >= 0) : (i -= 1) {
            const ui: usize = @intCast(i);
            if (ui >= cur.forward.len) continue;
            while (cur.forward[ui]) |nxt| {
                if (cmp(nxt.key, ec.key) != .lt) break;
                cur = nxt;
            }
            update[ui] = cur;
        }

        const next = if (cur.forward.len > 0) cur.forward[0] else null;

        if (next != null and cmp(next.?.key, ec.key) == .eq) {
            next.?.entry = ec;
            return false;
        }

        const new_level = self.randomLevel();
        if (@as(isize, @intCast(new_level)) > self.current_level) {
            var j: usize = @intCast(self.current_level + 1);
            while (j <= new_level and j <= self.max_level) : (j += 1) {
                update[j] = self.header.?;
            }
            self.current_level = @intCast(new_level);
        }

        const new_node = try Node.init(arena, ec.key, ec, new_level);

        var j: usize = 0;
        while (j <= new_level and j <= self.max_level) : (j += 1) {
            if (update[j]) |upd| {
                if (j < upd.forward.len) {
                    new_node.forward[j] = upd.forward[j];
                    upd.forward[j] = new_node;
                }
            }
        }

        self.count += 1;
        self.size += @sizeOf(Node) + ec.size();
        return true;
    }

    pub fn get(self: *SkipList, key: u128) ?Entry {
        if (self.header == null) return null;

        var cur = self.header.?;
        var i: isize = self.current_level;
        while (i >= 0) : (i -= 1) {
            const ui: usize = @intCast(i);
            if (ui >= cur.forward.len) continue;
            while (cur.forward[ui]) |nxt| {
                if (cmp(nxt.key, key) != .lt) break;
                cur = nxt;
            }
        }

        const candidate = if (cur.forward.len > 0) cur.forward[0] else null;
        if (candidate) |n| {
            if (cmp(n.key, key) == .eq) return n.entry;
        }
        return null;
    }

    pub fn del(self: *SkipList, key: u128) !void {
        if (self.header == null) return error.NotFound;

        const arena = self.arena.allocator();
        const update = try arena.alloc(?*Node, self.max_level + 1);
        @memset(update, null);

        var cur = self.header.?;
        var i: isize = self.current_level;
        while (i >= 0) : (i -= 1) {
            const ui: usize = @intCast(i);
            if (ui >= cur.forward.len) continue;
            while (cur.forward[ui]) |nxt| {
                if (cmp(nxt.key, key) != .lt) break;
                cur = nxt;
            }
            update[ui] = cur;
        }

        const target = if (cur.forward.len > 0) cur.forward[0] else null;
        if (target == null or cmp(target.?.key, key) != .eq) return error.NotFound;

        var j: usize = 0;
        while (j <= @as(usize, @intCast(self.current_level)) and j <= self.max_level) : (j += 1) {
            if (update[j]) |upd| {
                if (j < upd.forward.len and upd.forward[j] == target) {
                    upd.forward[j] = target.?.forward[j];
                }
            }
        }

        while (self.current_level > 0 and
            self.header.?.forward[@as(usize, @intCast(self.current_level))] == null)
        {
            self.current_level -= 1;
        }

        self.count -= 1;
    }

    pub fn len(self: *const SkipList) usize {
        return self.count;
    }

    pub fn isEmpty(self: *const SkipList) bool {
        return self.count == 0;
    }

    pub const DeleteIterator = struct {
        current: ?*Node,

        pub fn next(self: *DeleteIterator) ?*Node {
            if (self.current) |node| {
                self.current = node.forward[0];
                return node;
            }
            return null;
        }
    };

    pub fn deliterator(self: *SkipList) DeleteIterator {
        return .{ .current = if (self.header) |h| h.forward[0] else null };
    }

    pub const Iterator = struct {
        current: ?*Node,

        pub fn next(self: *Iterator) ?Entry {
            if (self.current) |node| {
                self.current = node.forward[0];
                return node.entry;
            }
            return null;
        }
    };

    pub fn iterator(self: *SkipList) Iterator {
        return .{ .current = if (self.header) |h| h.forward[0] else null };
    }

    pub fn seekIterator(self: *SkipList, seek_key: u128) Iterator {
        if (self.header == null) return .{ .current = null };

        var cur = self.header.?;
        var i: isize = self.current_level;
        while (i >= 0) : (i -= 1) {
            const ui: usize = @intCast(i);
            if (ui >= cur.forward.len) continue;
            while (cur.forward[ui]) |nxt| {
                if (cmp(nxt.key, seek_key) != .lt) break;
                cur = nxt;
            }
        }

        return .{ .current = if (cur.forward.len > 0) cur.forward[0] else null };
    }
};

const Now = @import("utils").Now;

test "basic operations" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const now = Now{ .io = std.testing.io };
    var sl = try SkipList.init(gpa.allocator(), 16, @intCast(now.toMilliSeconds()));
    defer sl.deinit();

    _ = try sl.post(.{ .key = 1, .kind = .insert, .value = "value1", .timestamp = 1, .lsn = 0 });
    _ = try sl.post(.{ .key = 2, .kind = .insert, .value = "value2", .timestamp = 2, .lsn = 0 });

    try std.testing.expect(sl.get(1) != null);
    try std.testing.expect(sl.get(2) != null);

    try sl.del(1);
    try std.testing.expect(sl.get(1) == null);
    try std.testing.expect(sl.get(2) != null);
}
