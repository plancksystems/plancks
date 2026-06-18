const types = @import("../types.zig");

pub const LeftPaneResponse = struct {
    success: bool = true,
    stores: []const types.StoreInfo = &.{},
    services: []const types.ServiceStatus = &.{},
    @"error": ?[]const u8 = null,
};
