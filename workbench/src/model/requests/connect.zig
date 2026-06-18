pub const ConnectRequest = struct {
    service: ?[]const u8 = null,
    db: ?i32 = null,
    uid: []const u8 = "",
    key: []const u8 = "",
};

pub const DisconnectRequest = struct {
    service: ?[]const u8 = null,
    db: ?i32 = null,
};
