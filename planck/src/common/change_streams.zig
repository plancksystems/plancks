const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("config.zig").Config;
const OpKind = @import("common.zig").OpKind;

pub fn opBit(op: OpKind) u8 {
    return switch (op) {
        .insert => 0b001,
        .update => 0b010,
        .delete => 0b100,
        .read, .sequence => 0,
    };
}

pub const StreamStore = struct {
    ns: []const u8,
    op_mask: u8,

    pub fn matches(self: StreamStore, op: OpKind) bool {
        const bit = opBit(op);
        return bit != 0 and (self.op_mask & bit) != 0;
    }
};

pub fn compile(allocator: Allocator, section: @TypeOf(@as(Config, undefined).change_streams)) ![]StreamStore {
    if (section.stores.len == 0) return &.{};

    const out = try allocator.alloc(StreamStore, section.stores.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |s| if (s.ns.len > 0) allocator.free(s.ns);
        allocator.free(out);
    }
    for (section.stores, 0..) |rs, i| {
        var mask: u8 = 0;
        for (rs.operations) |op_str| {
            const op = parseOp(op_str) orelse return error.UnknownOperation;
            mask |= opBit(op);
        }
        out[i] = .{
            .ns = try allocator.dupe(u8, rs.ns),
            .op_mask = mask,
        };
        built = i + 1;
    }
    return out;
}

pub fn freeStores(allocator: Allocator, stores: []StreamStore) void {
    for (stores) |s| if (s.ns.len > 0) allocator.free(s.ns);
    if (stores.len > 0) allocator.free(stores);
}

fn parseOp(s: []const u8) ?OpKind {
    if (std.mem.eql(u8, s, "insert")) return .insert;
    if (std.mem.eql(u8, s, "update")) return .update;
    if (std.mem.eql(u8, s, "delete")) return .delete;
    return null;
}


const testing = std.testing;

test "opBit: DML ops set distinct bits, non-DML return 0" {
    try testing.expectEqual(@as(u8, 0b001), opBit(.insert));
    try testing.expectEqual(@as(u8, 0b010), opBit(.update));
    try testing.expectEqual(@as(u8, 0b100), opBit(.delete));
    try testing.expectEqual(@as(u8, 0), opBit(.read));
    try testing.expectEqual(@as(u8, 0), opBit(.sequence));
}

test "StreamStore.matches: respects mask + skips non-DML" {
    const s = StreamStore{ .ns = "orders", .op_mask = 0b011 };
    try testing.expect(s.matches(.insert));
    try testing.expect(s.matches(.update));
    try testing.expect(!s.matches(.delete));
    try testing.expect(!s.matches(.read));
}

test "compile: builds op_mask + dupes ns strings" {
    var section: @TypeOf(@as(Config, undefined).change_streams) = .{};
    section.stores = &.{
        .{ .ns = "orders", .operations = &.{ "insert", "update", "delete" } },
        .{ .ns = "payments", .operations = &.{ "insert", "update" } },
    };

    const stores = try compile(testing.allocator, section);
    defer freeStores(testing.allocator, stores);

    try testing.expectEqual(@as(usize, 2), stores.len);
    try testing.expectEqualStrings("orders", stores[0].ns);
    try testing.expectEqual(@as(u8, 0b111), stores[0].op_mask);
    try testing.expectEqualStrings("payments", stores[1].ns);
    try testing.expectEqual(@as(u8, 0b011), stores[1].op_mask);
}

test "compile: empty stores returns empty slice (no alloc)" {
    const section: @TypeOf(@as(Config, undefined).change_streams) = .{};
    const stores = try compile(testing.allocator, section);
    try testing.expectEqual(@as(usize, 0), stores.len);
    freeStores(testing.allocator, stores);
}

test "compile: unknown operation errors" {
    var section: @TypeOf(@as(Config, undefined).change_streams) = .{};
    section.stores = &.{
        .{ .ns = "orders", .operations = &.{ "insert", "bogus" } },
    };
    try testing.expectError(error.UnknownOperation, compile(testing.allocator, section));
}
