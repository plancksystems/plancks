pub const EximResponse = struct {
    success: bool = true,
    message: ?[]const u8 = null,
    scheduled: ?bool = null,
    @"error": ?[]const u8 = null,
};
