pub const MonitorRequest = struct {
    service: ?[]const u8 = null,
};

pub const StatsRequest = struct {
    service: []const u8 = "",
    limit: []const u8 = "60",
};

pub const GcRequest = struct {
    vlogs: []const u8 = "",
    service: ?[]const u8 = null,
};
