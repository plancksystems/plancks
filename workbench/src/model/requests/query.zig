pub const QueryRequest = struct {
    query: []const u8 = "",
    service: ?[]const u8 = null,
    db: ?i32 = null,
};
