pub const SchemaRequest = struct {
    action: []const u8 = "",
    ns: []const u8 = "",
    service: ?[]const u8 = null,
    db: ?i32 = null,
    field: []const u8 = "",
    field_type: []const u8 = "String",
    unique: []const u8 = "true",
    description: []const u8 = "",
};
