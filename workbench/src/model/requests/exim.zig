pub const EximRequest = struct {
    manifest: []const u8 = "",
    service: ?[]const u8 = null,
    db: ?i32 = null,
    cron_expr: []const u8 = "",
    name: []const u8 = "",
    description: []const u8 = "",
};
