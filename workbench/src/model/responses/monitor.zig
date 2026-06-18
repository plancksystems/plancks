const types = @import("../types.zig");

pub const MonitorResponse = struct {
    success: bool = true,
    history: []const types.StatsSnapshot = &.{},
    current: ?[]const u8 = null,
    vlogs: ?[]const u8 = null,
    cpu_percent: f64 = 0,
    rss_mb: f64 = 0,
    cpu_time_us: u64 = 0,
    process_history: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

pub const StatsResponse = struct {
    success: bool = true,
    snapshots: []const types.StatsSnapshot = &.{},
    @"error": ?[]const u8 = null,
};

pub const GcResponse = @import("common.zig").ActionResponse;
