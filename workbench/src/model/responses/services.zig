const types = @import("../types.zig");

pub const ListServicesResponse = struct {
    success: bool = true,
    services: []const types.ServiceStatus = &.{},
    @"error": ?[]const u8 = null,
};
