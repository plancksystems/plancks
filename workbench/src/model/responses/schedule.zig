const types = @import("../types.zig");

pub const ListSchedulesResponse = struct {
    success: bool = true,
    schedules: []const types.Schedule = &.{},
    @"error": ?[]const u8 = null,
};

pub const ScheduleActionResponse = @import("common.zig").ActionResponse;
