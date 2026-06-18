pub const ConnectResponse = struct {
    success: bool = true,
    role: []const u8 = "",
    @"error": ?[]const u8 = null,
};

pub const DisconnectResponse = @import("common.zig").ActionResponse;
