pub const ActionResponse = struct {
    success: bool = true,
    @"error": ?[]const u8 = null,
};
