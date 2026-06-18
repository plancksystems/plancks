pub const BackupRequest = struct {
    action: []const u8 = "list",
    service: []const u8 = "",
    backup_path: []const u8 = "",
    target_path: []const u8 = "",
};
