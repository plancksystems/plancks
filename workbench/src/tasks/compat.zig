const std = @import("std");

pub const Logger = @import("utils").AppLogger;

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 2368,
};

pub const DbConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 23468,
};
