const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("proto");
const FieldType = proto.FieldType;
const bson = @import("bson");

pub const FieldExtractor = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) FieldExtractor {
        return .{ .allocator = allocator };
    }

    pub fn extractString(self: *FieldExtractor, bson_value: []const u8, field_name: []const u8) !?[]const u8 {
        const doc = try bson.BsonDocument.init(self.allocator, bson_value, false);
        if (try doc.getNestedField(field_name)) |val| {
            return switch (val) {
                .string => |s| s,
                else => return error.TypeMismatch,
            };
        }
        return null;
    }

    pub fn extractU64(self: *FieldExtractor, bson_value: []const u8, field_name: []const u8) !?u64 {
        const doc = try bson.BsonDocument.init(self.allocator, bson_value, false);
        if (try doc.getNestedField(field_name)) |val| {
            return switch (val) {
                .int64 => |v| if (v >= 0) @intCast(v) else return error.TypeMismatch,
                .int32 => |v| if (v >= 0) @intCast(v) else return error.TypeMismatch,
                else => return error.TypeMismatch,
            };
        }
        return null;
    }

    pub fn extractI64(self: *FieldExtractor, bson_value: []const u8, field_name: []const u8) !?i64 {
        const doc = try bson.BsonDocument.init(self.allocator, bson_value, false);
        if (try doc.getNestedField(field_name)) |val| {
            return switch (val) {
                .int64 => |v| v,
                .int32 => |v| @intCast(v),
                else => return error.TypeMismatch,
            };
        }
        return null;
    }

    pub fn extractU32(self: *FieldExtractor, bson_value: []const u8, field_name: []const u8) !?u32 {
        const doc = try bson.BsonDocument.init(self.allocator, bson_value, false);
        if (try doc.getNestedField(field_name)) |val| {
            return switch (val) {
                .int32 => |v| if (v >= 0) @intCast(v) else return error.TypeMismatch,
                else => return error.TypeMismatch,
            };
        }
        return null;
    }

    pub fn extractI32(self: *FieldExtractor, bson_value: []const u8, field_name: []const u8) !?i32 {
        const doc = try bson.BsonDocument.init(self.allocator, bson_value, false);
        if (try doc.getNestedField(field_name)) |val| {
            return switch (val) {
                .int32 => |v| v,
                else => return error.TypeMismatch,
            };
        }
        return null;
    }

    pub fn extractBool(self: *FieldExtractor, bson_value: []const u8, field_name: []const u8) !?bool {
        const doc = try bson.BsonDocument.init(self.allocator, bson_value, false);
        if (try doc.getNestedField(field_name)) |val| {
            return switch (val) {
                .boolean => |v| v,
                else => return error.TypeMismatch,
            };
        }
        return null;
    }

    pub fn extractF64(self: *FieldExtractor, bson_value: []const u8, field_name: []const u8) !?f64 {
        const doc = try bson.BsonDocument.init(self.allocator, bson_value, false);
        if (try doc.getNestedField(field_name)) |val| {
            return switch (val) {
                .double => |v| v,
                .int64 => |v| @floatFromInt(v),
                .int32 => |v| @floatFromInt(v),
                else => return error.TypeMismatch,
            };
        }
        return null;
    }

    pub fn extract(self: *FieldExtractor, bson_value: []const u8, field_name: []const u8, field_type: FieldType) !?FieldValue {
        return switch (field_type) {
            .String => blk: {
                if (try self.extractString(bson_value, field_name)) |val| {
                    break :blk FieldValue{ .string = val };
                }
                break :blk null;
            },
            .U64 => blk: {
                if (try self.extractU64(bson_value, field_name)) |val| {
                    break :blk FieldValue{ .u64_val = val };
                }
                break :blk null;
            },
            .I64 => blk: {
                if (try self.extractI64(bson_value, field_name)) |val| {
                    break :blk FieldValue{ .i64_val = val };
                }
                break :blk null;
            },
            .U32 => blk: {
                if (try self.extractU32(bson_value, field_name)) |val| {
                    break :blk FieldValue{ .u32_val = val };
                }
                break :blk null;
            },
            .I32 => blk: {
                if (try self.extractI32(bson_value, field_name)) |val| {
                    break :blk FieldValue{ .i32_val = val };
                }
                break :blk null;
            },
            .Boolean => blk: {
                if (try self.extractBool(bson_value, field_name)) |val| {
                    break :blk FieldValue{ .bool_val = val };
                }
                break :blk null;
            },
            .F64 => blk: {
                if (try self.extractF64(bson_value, field_name)) |val| {
                    break :blk FieldValue{ .f64_val = val };
                }
                break :blk null;
            },
            else => null,
        };
    }
};

pub const FieldValue = union(enum) {
    string: []const u8,
    u64_val: u64,
    i64_val: i64,
    u32_val: u32,
    i32_val: i32,
    f64_val: f64,
    bool_val: bool,

    pub fn deinit(self: FieldValue, allocator: Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }

    pub fn toF64(self: FieldValue) ?f64 {
        return switch (self) {
            .i64_val => |v| @floatFromInt(v),
            .u64_val => |v| @floatFromInt(v),
            .i32_val => |v| @floatFromInt(v),
            .u32_val => |v| @floatFromInt(v),
            .f64_val => |v| v,
            else => null,
        };
    }
};


const testing = std.testing;

fn makeBsonDoc(allocator: Allocator) ![]const u8 {
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

test "FieldExtractor - extractString" {
    const allocator = testing.allocator;
    const doc_bytes = try makeBsonDoc(allocator);
    defer allocator.free(doc_bytes);
    var fe = FieldExtractor.init(allocator);
    const val = try fe.extractString(doc_bytes, "name");
    defer allocator.free(val.?);
    try testing.expectEqualStrings("Alice", val.?);
}

test "FieldExtractor - extractString missing field" {
    const allocator = testing.allocator;
    const doc_bytes = try makeBsonDoc(allocator);
    defer allocator.free(doc_bytes);
    var fe = FieldExtractor.init(allocator);
    const val = try fe.extractString(doc_bytes, "nonexistent");
    try testing.expect(val == null);
}

test "FieldExtractor - extractString type mismatch" {
    const allocator = testing.allocator;
    const doc_bytes = try makeBsonDoc(allocator);
    defer allocator.free(doc_bytes);
    var fe = FieldExtractor.init(allocator);
    try testing.expectError(error.TypeMismatch, fe.extractString(doc_bytes, "age"));
}

test "FieldExtractor - extractI64" {
    const allocator = testing.allocator;
    const doc_bytes = try makeBsonDoc(allocator);
    defer allocator.free(doc_bytes);
    var fe = FieldExtractor.init(allocator);
    const val = try fe.extractI64(doc_bytes, "score");
    try testing.expectEqual(@as(i64, 9500), val.?);
}

test "FieldExtractor - extractI64 from int32" {
    const allocator = testing.allocator;
    const doc_bytes = try makeBsonDoc(allocator);
    defer allocator.free(doc_bytes);
    var fe = FieldExtractor.init(allocator);
    const val = try fe.extractI64(doc_bytes, "age");
    try testing.expectEqual(@as(i64, 30), val.?);
}

test "FieldExtractor - extractU64 from positive int32" {
    const allocator = testing.allocator;
    const doc_bytes = try makeBsonDoc(allocator);
    defer allocator.free(doc_bytes);
    var fe = FieldExtractor.init(allocator);
    const val = try fe.extractU64(doc_bytes, "age");
    try testing.expectEqual(@as(u64, 30), val.?);
}

test "FieldExtractor - extractI32" {
    const allocator = testing.allocator;
    const doc_bytes = try makeBsonDoc(allocator);
    defer allocator.free(doc_bytes);
    var fe = FieldExtractor.init(allocator);
    const val = try fe.extractI32(doc_bytes, "age");
    try testing.expectEqual(@as(i32, 30), val.?);
}

test "FieldExtractor - extractBool" {
    const allocator = testing.allocator;
    const doc_bytes = try makeBsonDoc(allocator);
    defer allocator.free(doc_bytes);
    var fe = FieldExtractor.init(allocator);
    const val = try fe.extractBool(doc_bytes, "active");
    try testing.expect(val.?);
}

test "FieldExtractor - extractF64" {
    const allocator = testing.allocator;
    const doc_bytes = try makeBsonDoc(allocator);
    defer allocator.free(doc_bytes);
    var fe = FieldExtractor.init(allocator);
    const val = try fe.extractF64(doc_bytes, "rating");
    try testing.expectEqual(@as(f64, 4.5), val.?);
}

test "FieldExtractor - extractF64 from int" {
    const allocator = testing.allocator;
    const doc_bytes = try makeBsonDoc(allocator);
    defer allocator.free(doc_bytes);
    var fe = FieldExtractor.init(allocator);
    const val = try fe.extractF64(doc_bytes, "age");
    try testing.expectEqual(@as(f64, 30.0), val.?);
}

test "FieldExtractor - extract with FieldType" {
    const allocator = testing.allocator;
    const doc_bytes = try makeBsonDoc(allocator);
    defer allocator.free(doc_bytes);
    var fe = FieldExtractor.init(allocator);

    const str_val = try fe.extract(doc_bytes, "name", .String);
    defer str_val.?.deinit(allocator);
    try testing.expectEqualStrings("Alice", str_val.?.string);

    const i32_val = try fe.extract(doc_bytes, "age", .I32);
    try testing.expectEqual(@as(i32, 30), i32_val.?.i32_val);

    const bool_val = try fe.extract(doc_bytes, "active", .Boolean);
    try testing.expect(bool_val.?.bool_val);

    const missing = try fe.extract(doc_bytes, "missing", .String);
    try testing.expect(missing == null);
}

test "FieldValue - toF64" {
    try testing.expectEqual(@as(f64, 42.0), (FieldValue{ .i64_val = 42 }).toF64().?);
    try testing.expectEqual(@as(f64, 100.0), (FieldValue{ .u64_val = 100 }).toF64().?);
    try testing.expectEqual(@as(f64, -5.0), (FieldValue{ .i32_val = -5 }).toF64().?);
    try testing.expectEqual(@as(f64, 10.0), (FieldValue{ .u32_val = 10 }).toF64().?);
    try testing.expectEqual(@as(f64, 3.14), (FieldValue{ .f64_val = 3.14 }).toF64().?);
    try testing.expect((FieldValue{ .string = "hello" }).toF64() == null);
    try testing.expect((FieldValue{ .bool_val = true }).toF64() == null);
}
