const types = @import("../types.zig");

pub const ListDatabasesResponse = struct {
    success: bool = true,
    databases: []const types.DbStatus = &.{},
    @"error": ?[]const u8 = null,
};
