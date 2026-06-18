const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Yaml = @import("yaml").Yaml;

pub const RunMode = enum {
    dev,
    qa,
    prod,
    pub fn fromString(role: []const u8) !RunMode {
        if (std.ascii.eqlIgnoreCase(role, "dev")) return .dev;
        if (std.ascii.eqlIgnoreCase(role, "qa")) return .qa;
        if (std.ascii.eqlIgnoreCase(role, "prod")) return .prod;
        return error.InvalidMode;
    }
};

pub const QueryNodeConfig = struct {
    address: []const u8 = "",
    port: u16 = 2369,
};

pub const WbConfig = struct {
    node: []const u8 = "",
    mode: []const u8 = "",
    planck_dir: []const u8 = "",
    data_dir: []const u8 = "",
    planck_bin: []const u8 = "",
    listen_port: u16 = 2369,
    query: ?QueryNodeConfig = null,
    system_db: struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 23469,
    } = .{},
    logging: struct {
        path: []const u8 = "",
        level: []const u8 = "info",
        max_size_mb: u32 = 10,
        max_files: u32 = 5,
    } = .{},

    pub fn getQueryNodeUrl(self: *const WbConfig, allocator: std.mem.Allocator) !?[]const u8 {
        const qn = self.query orelse return null;
        if (qn.address.len == 0) return null;
        return try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ qn.address, qn.port });
    }

    pub fn load(allocator: std.mem.Allocator, io: Io) !*WbConfig {
        const content = try Io.Dir.readFileAlloc(.cwd(), io, "config.yaml", allocator, .unlimited);
        defer allocator.free(content);

        var yaml: Yaml = .{ .source = content };
        try yaml.load(allocator);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = try yaml.parse(allocator, WbConfig);
        yaml.deinit(allocator);

        const cfg = try allocator.create(WbConfig);
        cfg.* = parsed;

        return cfg;
    }

    pub fn deinit(self: *WbConfig, allocator: std.mem.Allocator) void {
        const a = allocator;
        if (self.data_dir.len > 0) a.free(self.data_dir);
        if (self.planck_bin.len > 0) a.free(self.planck_bin);
        if (self.query) |qn| {
            if (qn.address.len > 0) a.free(qn.address);
        }
        a.destroy(self);
    }
};
