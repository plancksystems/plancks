const std = @import("std");
const Io = std.Io;

const Yaml = @import("yaml").Yaml;

pub const Node = struct {
    server: []const u8,
    uid: []const u8,
    key: []const u8,
};

pub const Profile = struct {
    name: []const u8,
    nodes: []Node,
};

pub const Config = struct {
    profiles: []Profile,

    pub fn load(allocator: std.mem.Allocator, io: Io, home: []const u8) !*Config {
        const path = try std.fmt.allocPrint(allocator, "{s}/.planctl/config.yaml", .{home});
        defer allocator.free(path);

        const content = try Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited);
        defer allocator.free(content);

        var yaml: Yaml = .{ .source = content };
        try yaml.load(allocator);

        const parsed = try yaml.parse(allocator, Config);
        yaml.deinit(allocator);

        const cfg = try allocator.create(Config);
        cfg.* = parsed;

        return cfg;
    }

    pub fn profile(self: *Config, name: []const u8) ?Profile {
        for (self.profiles) |p| {
            if (std.mem.eql(u8, name, p.name)) {
                return p;
            }
        }
        return null;
    }
};
