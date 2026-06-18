pub const ScheduleRequest = struct {
    action: []const u8 = "list",
    name: []const u8 = "",

    app: []const u8 = "",
    service: []const u8 = "",

    task_type: []const u8 = "",
    cron_expr: []const u8 = "",
    enabled: []const u8 = "true",
    backup_path: []const u8 = "",
    description: []const u8 = "",
    manifest: []const u8 = "",
};
