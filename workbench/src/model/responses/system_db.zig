pub const SystemDbStatusResponse = struct {
    success: bool = true,
    connected: bool = false,
    role: []const u8 = "",
    version: []const u8 = "",
    @"error": ?[]const u8 = null,
};

pub const SystemDbConnectResponse = struct {
    success: bool = true,
    role: []const u8 = "",
    newKey: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

pub const SystemDbLogoutResponse = @import("common.zig").ActionResponse;
