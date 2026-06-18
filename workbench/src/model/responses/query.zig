pub const QueryResponse = struct {
    success: bool = true,
    data: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};
