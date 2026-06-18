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
