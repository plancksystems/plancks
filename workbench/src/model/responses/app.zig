const types = @import("../types.zig");

pub const ListAppsResponse = struct {
    success: bool = true,
    apps: []const types.AppInfo = &.{},
    @"error": ?[]const u8 = null,
};

pub const AppActionResponse = struct {
    success: bool = true,
    port: ?i32 = null,
    @"error": ?[]const u8 = null,
};
