pub const BackupResponse = struct {
    success: bool = true,
    backups: ?[]const u8 = null,
    result: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};
