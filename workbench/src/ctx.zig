
const std = @import("std");
const AppServices = @import("tasks/services.zig").AppServices;

pub const Ctx = struct {
    services: *AppServices,
    connected: *bool,

    inflight_queries: std.atomic.Value(u32) = .init(0),

    pub const MAX_INFLIGHT_QUERIES: u32 = 16;
};
