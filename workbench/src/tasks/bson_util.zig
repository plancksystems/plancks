const std = @import("std");
const bson = @import("bson");

pub fn getString(allocator: std.mem.Allocator, data: []const u8, field: []const u8) ?[]const u8 {
    const doc = bson.BsonDocument.init(allocator, data, false) catch return null;
    return doc.getString(field) catch null;
}

pub fn getInt32(allocator: std.mem.Allocator, data: []const u8, field: []const u8) ?i32 {
    const doc = bson.BsonDocument.init(allocator, data, false) catch return null;
    return doc.getInt32(field) catch null;
}

pub fn getInt64(allocator: std.mem.Allocator, data: []const u8, field: []const u8) ?i64 {
    const doc = bson.BsonDocument.init(allocator, data, false) catch return null;
    return doc.getInt64(field) catch null;
}

pub fn getBool(allocator: std.mem.Allocator, data: []const u8, field: []const u8) ?bool {
    const doc = bson.BsonDocument.init(allocator, data, false) catch return null;
    return doc.getBool(field) catch null;
}

fn testSampleDoc(a: std.mem.Allocator) ![]const u8 {
    var doc = bson.BsonDocument.empty(a);
    defer doc.deinit();
    try doc.putString("name", "alice");
    try doc.putInt32("age", 30);
    try doc.putInt64("score", 9000);
    try doc.putBool("active", true);
    return a.dupe(u8, doc.toBytes());
}

test "string field is read from a document" {
    const a = std.testing.allocator;
    const data = try testSampleDoc(a);
    defer a.free(data);
    const v = getString(a, data, "name").?;
    defer a.free(v);
    try std.testing.expectEqualStrings("alice", v);
}

test "int32 field is read from a document" {
    const a = std.testing.allocator;
    const data = try testSampleDoc(a);
    defer a.free(data);
    try std.testing.expectEqual(@as(?i32, 30), getInt32(a, data, "age"));
}

test "int64 field is read from a document" {
    const a = std.testing.allocator;
    const data = try testSampleDoc(a);
    defer a.free(data);
    try std.testing.expectEqual(@as(?i64, 9000), getInt64(a, data, "score"));
}

test "bool field is read from a document" {
    const a = std.testing.allocator;
    const data = try testSampleDoc(a);
    defer a.free(data);
    try std.testing.expectEqual(@as(?bool, true), getBool(a, data, "active"));
}

test "missing field reads as null" {
    const a = std.testing.allocator;
    const data = try testSampleDoc(a);
    defer a.free(data);
    try std.testing.expect(getString(a, data, "absent") == null);
}

test "malformed bytes read as null" {
    try std.testing.expect(getString(std.testing.allocator, &[_]u8{ 1, 2, 3 }, "x") == null);
}
