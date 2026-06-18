const std = @import("std");
const query_engine = @import("../storage/query_engine.zig");
const bson = @import("bson");
const FieldValue = @import("../storage/field_extractor.zig").FieldValue;
const ParsedQuery = @import("../storage/query_engine.zig").ParsedQuery;

pub fn matchesPredicate(doc_bson: []const u8, pred: query_engine.Predicate) bool {
     const doc_result = bson.BsonDocument.init(std.heap.page_allocator, doc_bson, false);

    if (doc_result) |doc| {
        var mutable_doc = doc;
        defer mutable_doc.deinit();

         if (pred.operator == .exists) {
            const field_exists = blk: {
                if (doc.getNestedField(pred.field_name)) |field_value_opt| {
                    break :blk field_value_opt != null;
                } else |_| {
                    break :blk false;
                }
            };
             const want_exists = if (pred.value == .bool_val) pred.value.bool_val else true;
            return field_exists == want_exists;
        }

         if (doc.getNestedField(pred.field_name)) |field_value_opt| {
            if (field_value_opt) |field_value| {
                 return compareBsonValue(field_value, pred.value, pred.operator, pred);
            }
        } else |_| {
             return false;
        }
        return false;
    } else |_| {
         return false;
    }
}

pub fn matchesAllPredicates(doc_bson: []const u8, parsed: *const ParsedQuery) bool {
     for (parsed.predicates.items) |pred| {
        if (!matchesPredicate(doc_bson, pred)) return false;
    }
     if (parsed.or_predicates.items.len > 0) {
        var any_group_matched = false;
        for (parsed.or_predicates.items) |group| {
            var group_matches = true;
            for (group.items) |pred| {
                if (!matchesPredicate(doc_bson, pred)) {
                    group_matches = false;
                    break;
                }
            }
            if (group_matches) {
                any_group_matched = true;
                break;
            }
        }
        if (!any_group_matched) return false;
    }
    return true;
}

pub fn compareByMultiFields(a_bson: []const u8, b_bson: []const u8, specs: []const query_engine.SortSpec) bool {
    const allocator = std.heap.page_allocator;

    const a_doc = bson.BsonDocument.init(allocator, a_bson, false) catch return false;
    var a_mut = a_doc;
    defer a_mut.deinit();

    const b_doc = bson.BsonDocument.init(allocator, b_bson, false) catch return true;
    var b_mut = b_doc;
    defer b_mut.deinit();

    for (specs) |spec| {
        const a_val_opt = a_doc.getNestedField(spec.field) catch null;
        const b_val_opt = b_doc.getNestedField(spec.field) catch null;

        const a_val = a_val_opt orelse continue;
        const b_val = b_val_opt orelse continue;

        const cmp = compareBsonValues(a_val, b_val);
        if (cmp == .eq) continue;
        return if (spec.ascending) cmp == .lt else cmp == .gt;
    }
    return false;  
}

pub fn compareBsonValue(bson_val: bson.Value, field_val: FieldValue, op: query_engine.Operator, pred: query_engine.Predicate) bool {
     if (op == .in) {
        const in_vals = pred.in_values orelse return false;
        for (in_vals) |v| {
            if (compareBsonValue(bson_val, v, .eq, pred)) return true;
        }
        return false;
    }

     if (op == .regex) {
        const pattern = pred.regex_pattern orelse return false;
        return switch (bson_val) {
            .string => |s| query_engine.simpleRegexMatch(s, pattern),
            else => false,
        };
    }

    if (op == .between) {
        const upper = pred.upper_value orelse return false;
        const gte_lower = compareBsonValue(bson_val, pred.value, .gte, pred);
        const lte_upper = compareBsonValue(bson_val, upper, .lte, pred);
        return gte_lower and lte_upper;
    }

    return switch (bson_val) {
        .string => |s| blk: {
            if (field_val == .string) {
                break :blk switch (op) {
                    .eq => std.mem.eql(u8, s, field_val.string),
                    .ne => !std.mem.eql(u8, s, field_val.string),
                    .gt => std.mem.order(u8, s, field_val.string) == .gt,
                    .gte => std.mem.order(u8, s, field_val.string) != .lt,
                    .lt => std.mem.order(u8, s, field_val.string) == .lt,
                    .lte => std.mem.order(u8, s, field_val.string) != .gt,
                    .contains => std.mem.indexOf(u8, s, field_val.string) != null,
                    .starts_with => std.mem.startsWith(u8, s, field_val.string),
                    .in, .exists, .regex, .between => false,
                };
            }
            break :blk false;
        },
        .int32 => |i| {
            const i64_val: i64 = i;
            return compareInt64Value(i64_val, field_val, op);
        },
        .int64 => |i| {
            return compareInt64Value(i, field_val, op);
        },
        .double => |d| blk: {
            const expected: f64 = switch (field_val) {
                .f64_val => |v| v,
                .i64_val => |v| @as(f64, @floatFromInt(v)),
                .i32_val => |v| @as(f64, @floatFromInt(v)),
                .u64_val => |v| @as(f64, @floatFromInt(v)),
                .u32_val => |v| @as(f64, @floatFromInt(v)),
                else => break :blk false,
            };
            break :blk switch (op) {
                .eq => d == expected,
                .ne => d != expected,
                .gt => d > expected,
                .gte => d >= expected,
                .lt => d < expected,
                .lte => d <= expected,
                else => false,
            };
        },
        .boolean => |b| blk: {
            if (field_val != .bool_val) break :blk false;
            break :blk switch (op) {
                .eq => b == field_val.bool_val,
                .ne => b != field_val.bool_val,
                else => false,
            };
        },
        .null => false,
        else => false,
    };
}

pub fn compareInt64Value(i64_val: i64, field_val: FieldValue, op: query_engine.Operator) bool {
    return switch (field_val) {
        .i64_val => |expected| blk: {
            break :blk switch (op) {
                .eq => i64_val == expected,
                .ne => i64_val != expected,
                .gt => i64_val > expected,
                .gte => i64_val >= expected,
                .lt => i64_val < expected,
                .lte => i64_val <= expected,
                else => false,
            };
        },
        .i32_val => |expected| blk: {
            const expected_i64: i64 = expected;
            break :blk switch (op) {
                .eq => i64_val == expected_i64,
                .ne => i64_val != expected_i64,
                .gt => i64_val > expected_i64,
                .gte => i64_val >= expected_i64,
                .lt => i64_val < expected_i64,
                .lte => i64_val <= expected_i64,
                else => false,
            };
        },
        .u64_val => |expected| blk: {
            if (i64_val < 0) break :blk false;
            const u64_val: u64 = @intCast(i64_val);
            break :blk switch (op) {
                .eq => u64_val == expected,
                .ne => u64_val != expected,
                .gt => u64_val > expected,
                .gte => u64_val >= expected,
                .lt => u64_val < expected,
                .lte => u64_val <= expected,
                else => false,
            };
        },
        .u32_val => |expected| blk: {
            if (i64_val < 0) break :blk false;
            const u32_val: u32 = @intCast(i64_val);
            break :blk switch (op) {
                .eq => u32_val == expected,
                .ne => u32_val != expected,
                .gt => u32_val > expected,
                .gte => u32_val >= expected,
                .lt => u32_val < expected,
                .lte => u32_val <= expected,
                else => false,
            };
        },
        .f64_val => |expected| blk: {
            const d: f64 = @floatFromInt(i64_val);
            break :blk switch (op) {
                .eq => d == expected,
                .ne => d != expected,
                .gt => d > expected,
                .gte => d >= expected,
                .lt => d < expected,
                .lte => d <= expected,
                else => false,
            };
        },
        else => false,
    };
}

pub const CompareOp = enum { eq, gt, lt };

pub fn compareJsonValue(json_val: std.json.Value, field_val: FieldValue, op: CompareOp) bool {
    return switch (field_val) {
        .string => |s| blk: {
            if (json_val != .string) break :blk false;
            break :blk switch (op) {
                .eq => std.mem.eql(u8, json_val.string, s),
                .gt => std.mem.order(u8, json_val.string, s) == .gt,
                .lt => std.mem.order(u8, json_val.string, s) == .lt,
            };
        },
        .i64_val => |i| blk: {
            if (json_val != .integer) break :blk false;
            break :blk switch (op) {
                .eq => json_val.integer == i,
                .gt => json_val.integer > i,
                .lt => json_val.integer < i,
            };
        },
        .u64_val => |u| blk: {
            if (json_val != .integer) break :blk false;
            if (json_val.integer < 0) break :blk false;
            const ju: u64 = @intCast(json_val.integer);
            break :blk switch (op) {
                .eq => ju == u,
                .gt => ju > u,
                .lt => ju < u,
            };
        },
        .i32_val => |i| blk: {
            if (json_val != .integer) break :blk false;
            break :blk switch (op) {
                .eq => json_val.integer == i,
                .gt => json_val.integer > i,
                .lt => json_val.integer < i,
            };
        },
        .u32_val => |u| blk: {
            if (json_val != .integer) break :blk false;
            if (json_val.integer < 0) break :blk false;
            const ju: u32 = @intCast(json_val.integer);
            break :blk switch (op) {
                .eq => ju == u,
                .gt => ju > u,
                .lt => ju < u,
            };
        },
        .bool_val => |b| blk: {
            if (json_val != .bool) break :blk false;
            break :blk switch (op) {
                .eq => json_val.bool == b,
                else => false,
            };
        },
        .f64_val => |f| blk: {
            if (json_val != .float) break :blk false;
            break :blk switch (op) {
                .eq => json_val.float == f,
                .gt => json_val.float > f,
                .lt => json_val.float < f,
            };
        },
    };
}

pub fn containsString(json_val: std.json.Value, field_val: FieldValue) bool {
    if (json_val != .string) return false;
    if (field_val != .string) return false;
    return std.mem.indexOf(u8, json_val.string, field_val.string) != null;
}

pub fn startsWithString(json_val: std.json.Value, field_val: FieldValue) bool {
    if (json_val != .string) return false;
    if (field_val != .string) return false;
    return std.mem.startsWith(u8, json_val.string, field_val.string);
}

pub fn compareByField(a_bson: []const u8, b_bson: []const u8, field: []const u8, ascending: bool) bool {
    const allocator = std.heap.page_allocator;

    const a_doc = bson.BsonDocument.init(allocator, a_bson, false) catch return false;
    var a_mut = a_doc;
    defer a_mut.deinit();

    const b_doc = bson.BsonDocument.init(allocator, b_bson, false) catch return true;
    var b_mut = b_doc;
    defer b_mut.deinit();

    const a_val_opt = blk: {
        const result = a_doc.getNestedField(field) catch break :blk null;
        break :blk result;
    };
    const b_val_opt = blk: {
        const result = b_doc.getNestedField(field) catch break :blk null;
        break :blk result;
    };

    const a_val = a_val_opt orelse return false;
    const b_val = b_val_opt orelse return true;

    const cmp = compareBsonValues(a_val, b_val);
    return if (ascending) cmp == .lt else cmp == .gt;
}

pub fn compareBsonValues(a: bson.Value, b: bson.Value) std.math.Order {
    const a_num = bsonToF64(a);
    const b_num = bsonToF64(b);
    if (a_num != null and b_num != null) {
        return std.math.order(a_num.?, b_num.?);
    }
    if (a == .string and b == .string) {
        return std.mem.order(u8, a.string, b.string);
    }
    if (a == .boolean and b == .boolean) {
        return std.math.order(@as(u1, @intFromBool(a.boolean)), @as(u1, @intFromBool(b.boolean)));
    }
    return .eq;
}

pub fn bsonToF64(val: bson.Value) ?f64 {
    return switch (val) {
        .int32 => |v| @as(f64, @floatFromInt(v)),
        .int64 => |v| @as(f64, @floatFromInt(v)),
        .double => |v| v,
        else => null,
    };
}

pub fn applyProjection(allocator: std.mem.Allocator, doc_bson: []const u8, fields: [][]const u8) ![]const u8 {
    const src_doc = try bson.BsonDocument.init(allocator, doc_bson, false);
    var src_mut = src_doc;
    defer src_mut.deinit();

    var out_doc = bson.BsonDocument.empty(allocator);
    errdefer out_doc.deinit();

    for (fields) |field| {
        if (try src_doc.getNestedField(field)) |val| {
            try out_doc.put(field, val);
        }
    }

    const result = try allocator.dupe(u8, out_doc.toBytes());
    out_doc.deinit();
    return result;
}


const testing = std.testing;

fn makeTestDoc(allocator: std.mem.Allocator) ![]const u8 {
    var doc = bson.BsonDocument.empty(allocator);
    try doc.put("name", .{ .string = "Alice" });
    try doc.put("age", .{ .int32 = 30 });
    try doc.put("score", .{ .int64 = 9500 });
    try doc.put("active", .{ .boolean = true });
    try doc.put("rating", .{ .double = 4.5 });
    const bytes = try allocator.dupe(u8, doc.toBytes());
    doc.deinit();
    return bytes;
}

test "bsonToF64 - int32" {
    try testing.expectEqual(@as(f64, 42.0), bsonToF64(.{ .int32 = 42 }).?);
}

test "bsonToF64 - int64" {
    try testing.expectEqual(@as(f64, 1000.0), bsonToF64(.{ .int64 = 1000 }).?);
}

test "bsonToF64 - double" {
    try testing.expectEqual(@as(f64, 3.14), bsonToF64(.{ .double = 3.14 }).?);
}

test "bsonToF64 - string returns null" {
    try testing.expect(bsonToF64(.{ .string = "hello" }) == null);
}

test "bsonToF64 - boolean returns null" {
    try testing.expect(bsonToF64(.{ .boolean = true }) == null);
}

test "compareBsonValues - int ordering" {
    try testing.expectEqual(std.math.Order.lt, compareBsonValues(.{ .int32 = 10 }, .{ .int32 = 20 }));
    try testing.expectEqual(std.math.Order.gt, compareBsonValues(.{ .int32 = 20 }, .{ .int32 = 10 }));
    try testing.expectEqual(std.math.Order.eq, compareBsonValues(.{ .int32 = 10 }, .{ .int32 = 10 }));
}

test "compareBsonValues - cross-type numeric" {
    try testing.expectEqual(std.math.Order.eq, compareBsonValues(.{ .int32 = 100 }, .{ .int64 = 100 }));
    try testing.expectEqual(std.math.Order.lt, compareBsonValues(.{ .int32 = 99 }, .{ .double = 100.0 }));
}

test "compareBsonValues - string ordering" {
    try testing.expectEqual(std.math.Order.lt, compareBsonValues(.{ .string = "abc" }, .{ .string = "def" }));
    try testing.expectEqual(std.math.Order.gt, compareBsonValues(.{ .string = "xyz" }, .{ .string = "abc" }));
    try testing.expectEqual(std.math.Order.eq, compareBsonValues(.{ .string = "same" }, .{ .string = "same" }));
}

test "compareBsonValues - boolean ordering" {
    try testing.expectEqual(std.math.Order.lt, compareBsonValues(.{ .boolean = false }, .{ .boolean = true }));
    try testing.expectEqual(std.math.Order.eq, compareBsonValues(.{ .boolean = true }, .{ .boolean = true }));
}

test "compareInt64Value - i64 eq/ne/gt/lt" {
    try testing.expect(compareInt64Value(10, FieldValue{ .i64_val = 10 }, .eq));
    try testing.expect(!compareInt64Value(10, FieldValue{ .i64_val = 11 }, .eq));
    try testing.expect(compareInt64Value(10, FieldValue{ .i64_val = 11 }, .ne));
    try testing.expect(compareInt64Value(20, FieldValue{ .i64_val = 10 }, .gt));
    try testing.expect(compareInt64Value(5, FieldValue{ .i64_val = 10 }, .lt));
    try testing.expect(compareInt64Value(10, FieldValue{ .i64_val = 10 }, .gte));
    try testing.expect(compareInt64Value(10, FieldValue{ .i64_val = 10 }, .lte));
}

test "compareInt64Value - cross-type u64" {
    try testing.expect(compareInt64Value(100, FieldValue{ .u64_val = 100 }, .eq));
    try testing.expect(compareInt64Value(50, FieldValue{ .u64_val = 100 }, .lt));
}

test "compareInt64Value - negative vs u64 returns false" {
    try testing.expect(!compareInt64Value(-1, FieldValue{ .u64_val = 0 }, .eq));
    try testing.expect(!compareInt64Value(-1, FieldValue{ .u64_val = 0 }, .lt));
}

test "compareInt64Value - f64" {
    try testing.expect(compareInt64Value(10, FieldValue{ .f64_val = 10.0 }, .eq));
    try testing.expect(compareInt64Value(11, FieldValue{ .f64_val = 10.5 }, .gt));
}

test "compareBsonValue - string operators" {
    const pred = query_engine.Predicate{
        .field_name = "f",
        .operator = .eq,
        .value = FieldValue{ .string = "hello" },
        .in_values = null,
        .regex_pattern = null,
    };
    try testing.expect(compareBsonValue(.{ .string = "hello" }, FieldValue{ .string = "hello" }, .eq, pred));
    try testing.expect(!compareBsonValue(.{ .string = "world" }, FieldValue{ .string = "hello" }, .eq, pred));
    try testing.expect(compareBsonValue(.{ .string = "world" }, FieldValue{ .string = "hello" }, .ne, pred));
    try testing.expect(compareBsonValue(.{ .string = "xyz" }, FieldValue{ .string = "abc" }, .gt, pred));
    try testing.expect(compareBsonValue(.{ .string = "abc" }, FieldValue{ .string = "xyz" }, .lt, pred));
}

test "compareBsonValue - contains and starts_with" {
    const pred = query_engine.Predicate{
        .field_name = "f",
        .operator = .contains,
        .value = FieldValue{ .string = "ell" },
        .in_values = null,
        .regex_pattern = null,
    };
    try testing.expect(compareBsonValue(.{ .string = "hello world" }, FieldValue{ .string = "ell" }, .contains, pred));
    try testing.expect(!compareBsonValue(.{ .string = "goodbye" }, FieldValue{ .string = "ell" }, .contains, pred));
    try testing.expect(compareBsonValue(.{ .string = "hello" }, FieldValue{ .string = "hel" }, .starts_with, pred));
    try testing.expect(!compareBsonValue(.{ .string = "hello" }, FieldValue{ .string = "llo" }, .starts_with, pred));
}

test "compareBsonValue - boolean" {
    const pred = query_engine.Predicate{
        .field_name = "f",
        .operator = .eq,
        .value = FieldValue{ .bool_val = true },
        .in_values = null,
        .regex_pattern = null,
    };
    try testing.expect(compareBsonValue(.{ .boolean = true }, FieldValue{ .bool_val = true }, .eq, pred));
    try testing.expect(!compareBsonValue(.{ .boolean = false }, FieldValue{ .bool_val = true }, .eq, pred));
    try testing.expect(compareBsonValue(.{ .boolean = false }, FieldValue{ .bool_val = true }, .ne, pred));
}

test "compareBsonValue - double" {
    const pred = query_engine.Predicate{
        .field_name = "f",
        .operator = .eq,
        .value = FieldValue{ .f64_val = 3.14 },
        .in_values = null,
        .regex_pattern = null,
    };
    try testing.expect(compareBsonValue(.{ .double = 3.14 }, FieldValue{ .f64_val = 3.14 }, .eq, pred));
    try testing.expect(compareBsonValue(.{ .double = 5.0 }, FieldValue{ .f64_val = 3.14 }, .gt, pred));
    try testing.expect(compareBsonValue(.{ .double = 1.0 }, FieldValue{ .f64_val = 3.14 }, .lt, pred));
}

test "compareBsonValue - int32 vs i64 field" {
    const pred = query_engine.Predicate{
        .field_name = "f",
        .operator = .eq,
        .value = FieldValue{ .i64_val = 42 },
        .in_values = null,
        .regex_pattern = null,
    };
    try testing.expect(compareBsonValue(.{ .int32 = 42 }, FieldValue{ .i64_val = 42 }, .eq, pred));
    try testing.expect(!compareBsonValue(.{ .int32 = 43 }, FieldValue{ .i64_val = 42 }, .eq, pred));
}

test "compareBsonValue - null returns false" {
    const pred = query_engine.Predicate{
        .field_name = "f",
        .operator = .eq,
        .value = FieldValue{ .i64_val = 0 },
        .in_values = null,
        .regex_pattern = null,
    };
    try testing.expect(!compareBsonValue(.null, FieldValue{ .i64_val = 0 }, .eq, pred));
}

test "compareJsonValue - string" {
    try testing.expect(compareJsonValue(.{ .string = "hello" }, FieldValue{ .string = "hello" }, .eq));
    try testing.expect(!compareJsonValue(.{ .string = "world" }, FieldValue{ .string = "hello" }, .eq));
    try testing.expect(compareJsonValue(.{ .string = "z" }, FieldValue{ .string = "a" }, .gt));
    try testing.expect(compareJsonValue(.{ .string = "a" }, FieldValue{ .string = "z" }, .lt));
}

test "compareJsonValue - integer" {
    try testing.expect(compareJsonValue(.{ .integer = 42 }, FieldValue{ .i64_val = 42 }, .eq));
    try testing.expect(compareJsonValue(.{ .integer = 100 }, FieldValue{ .i64_val = 50 }, .gt));
    try testing.expect(compareJsonValue(.{ .integer = 10 }, FieldValue{ .i64_val = 50 }, .lt));
}

test "compareJsonValue - bool" {
    try testing.expect(compareJsonValue(.{ .bool = true }, FieldValue{ .bool_val = true }, .eq));
    try testing.expect(!compareJsonValue(.{ .bool = false }, FieldValue{ .bool_val = true }, .eq));
}

test "compareJsonValue - float" {
    try testing.expect(compareJsonValue(.{ .float = 3.14 }, FieldValue{ .f64_val = 3.14 }, .eq));
    try testing.expect(compareJsonValue(.{ .float = 5.0 }, FieldValue{ .f64_val = 3.0 }, .gt));
}

test "compareJsonValue - type mismatch returns false" {
    try testing.expect(!compareJsonValue(.{ .string = "hello" }, FieldValue{ .i64_val = 42 }, .eq));
    try testing.expect(!compareJsonValue(.{ .integer = 42 }, FieldValue{ .string = "hello" }, .eq));
}

test "containsString" {
    try testing.expect(containsString(.{ .string = "hello world" }, FieldValue{ .string = "world" }));
    try testing.expect(!containsString(.{ .string = "hello" }, FieldValue{ .string = "xyz" }));
    try testing.expect(!containsString(.{ .integer = 42 }, FieldValue{ .string = "42" }));
}

test "startsWithString" {
    try testing.expect(startsWithString(.{ .string = "hello world" }, FieldValue{ .string = "hello" }));
    try testing.expect(!startsWithString(.{ .string = "hello" }, FieldValue{ .string = "world" }));
    try testing.expect(!startsWithString(.{ .integer = 42 }, FieldValue{ .string = "4" }));
}

test "matchesPredicate - string equality" {
    const allocator = std.heap.page_allocator;
    const doc_bytes = try makeTestDoc(allocator);
    defer allocator.free(doc_bytes);
    const pred = query_engine.Predicate{
        .field_name = "name",
        .operator = .eq,
        .value = FieldValue{ .string = "Alice" },
        .in_values = null,
        .regex_pattern = null,
    };
    try testing.expect(matchesPredicate(doc_bytes, pred));
}

test "matchesPredicate - int comparison" {
    const allocator = std.heap.page_allocator;
    const doc_bytes = try makeTestDoc(allocator);
    defer allocator.free(doc_bytes);
    const pred_gt = query_engine.Predicate{
        .field_name = "age",
        .operator = .gt,
        .value = FieldValue{ .i64_val = 25 },
        .in_values = null,
        .regex_pattern = null,
    };
    try testing.expect(matchesPredicate(doc_bytes, pred_gt));
    const pred_lt = query_engine.Predicate{
        .field_name = "age",
        .operator = .lt,
        .value = FieldValue{ .i64_val = 25 },
        .in_values = null,
        .regex_pattern = null,
    };
    try testing.expect(!matchesPredicate(doc_bytes, pred_lt));
}

test "matchesPredicate - missing field returns false" {
    const allocator = std.heap.page_allocator;
    const doc_bytes = try makeTestDoc(allocator);
    defer allocator.free(doc_bytes);
    const pred = query_engine.Predicate{
        .field_name = "nonexistent",
        .operator = .eq,
        .value = FieldValue{ .string = "x" },
        .in_values = null,
        .regex_pattern = null,
    };
    try testing.expect(!matchesPredicate(doc_bytes, pred));
}

test "compareByField - ascending" {
    const allocator = std.heap.page_allocator;

    var doc_a = bson.BsonDocument.empty(allocator);
    try doc_a.put("val", .{ .int32 = 10 });
    const a_bytes = try allocator.dupe(u8, doc_a.toBytes());
    defer allocator.free(a_bytes);
    doc_a.deinit();

    var doc_b = bson.BsonDocument.empty(allocator);
    try doc_b.put("val", .{ .int32 = 20 });
    const b_bytes = try allocator.dupe(u8, doc_b.toBytes());
    defer allocator.free(b_bytes);
    doc_b.deinit();

    try testing.expect(compareByField(a_bytes, b_bytes, "val", true));
    try testing.expect(!compareByField(b_bytes, a_bytes, "val", true));
    try testing.expect(compareByField(b_bytes, a_bytes, "val", false));
}
