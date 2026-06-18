const types = @import("../types.zig");

pub const AdminResponse = struct {
    success: bool = true,
    @"error": ?[]const u8 = null,
    data: ?[]const u8 = null,
    users: ?[]const types.UserInfo = null,
    key: ?[]const u8 = null,
};
