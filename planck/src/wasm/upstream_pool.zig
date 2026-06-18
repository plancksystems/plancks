
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const utils = @import("utils");
const Upstream = @import("../common/service.zig").Upstream;

const log = std.log.scoped(.upstream_pool);

pub const UpstreamState = struct {
    name: []const u8,
    url: []const u8,
    timeout_ms: u32,
    max_in_flight: u32,

    breaker: utils.CircuitBreaker,
    in_flight: std.atomic.Value(u32),
    mutex: Io.Mutex,
};

pub const UpstreamPool = struct {
    allocator: Allocator,
    states: std.StringHashMap(*UpstreamState),

    pub fn init(allocator: Allocator, io: Io, upstreams: []const Upstream) !*UpstreamPool {
        const pool = try allocator.create(UpstreamPool);
        errdefer allocator.destroy(pool);

        pool.* = .{
            .allocator = allocator,
            .states = std.StringHashMap(*UpstreamState).init(allocator),
        };
        errdefer pool.deinit();

        try pool.states.ensureTotalCapacity(@intCast(upstreams.len));

        for (upstreams) |u| {
            const st = try allocator.create(UpstreamState);
            errdefer allocator.destroy(st);

            st.* = .{
                .name = u.name,
                .url = u.url,
                .timeout_ms = u.timeout_ms,
                .max_in_flight = u.max_in_flight,
                .breaker = utils.CircuitBreaker.init(
                    io,
                    u.breaker.failure_threshold,
                    u.breaker.success_threshold,
                    u.breaker.open_duration_ms,
                ),
                .in_flight = std.atomic.Value(u32).init(0),
                .mutex = Io.Mutex.init,
            };

            try pool.states.put(u.name, st);
        }

        log.info("upstream pool initialised with {d} peers", .{upstreams.len});
        return pool;
    }

    pub fn deinit(self: *UpstreamPool) void {
        var it = self.states.valueIterator();
        while (it.next()) |state_ptr| {
            self.allocator.destroy(state_ptr.*);
        }
        self.states.deinit();
        self.allocator.destroy(self);
    }

    pub fn lookup(self: *UpstreamPool, name: []const u8) ?*UpstreamState {
        return self.states.get(name);
    }
};



const testing = std.testing;

test "UpstreamPool: init + lookup + deinit on empty config" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try UpstreamPool.init(testing.allocator, io, &.{});
    defer pool.deinit();

    try testing.expect(pool.lookup("anything") == null);
}

test "UpstreamPool: init from two upstreams returns stable pointers" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const ups = [_]Upstream{
        .{
            .name = "products",
            .url = "http://127.0.0.1:3042",
            .timeout_ms = 1500,
            .max_in_flight = 8,
            .breaker = .{ .failure_threshold = 3, .success_threshold = 1, .open_duration_ms = 10_000 },
        },
        .{
            .name = "users",
            .url = "http://127.0.0.1:3041",
        },
    };

    var pool = try UpstreamPool.init(testing.allocator, io, &ups);
    defer pool.deinit();

    const products_a = pool.lookup("products") orelse return error.MissingProducts;
    const products_b = pool.lookup("products") orelse return error.MissingProducts;
    try testing.expectEqual(products_a, products_b);
    try testing.expectEqualStrings("products", products_a.name);
    try testing.expectEqualStrings("http://127.0.0.1:3042", products_a.url);
    try testing.expectEqual(@as(u32, 1500), products_a.timeout_ms);
    try testing.expectEqual(@as(u32, 8), products_a.max_in_flight);
    try testing.expectEqual(utils.CircuitBreaker.State.closed, products_a.breaker.getState());

    const users = pool.lookup("users") orelse return error.MissingUsers;
    try testing.expectEqual(@as(u32, 5_000), users.timeout_ms);
    try testing.expectEqual(@as(u32, 16), users.max_in_flight);

    try testing.expect(pool.lookup("unknown") == null);
}
