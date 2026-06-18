const std = @import("std");
const Io = std.Io;
const yaml_pkg = @import("yaml");
const Yaml = yaml_pkg.Yaml;
const schnell = @import("schnell");

pub const BreakerConfig = struct {
    failure_threshold: u32 = 5,
    success_threshold: u32 = 2,
    open_duration_ms: u32 = 30_000,
};

pub const Upstream = struct {
    name: []const u8,
    url: []const u8,
    timeout_ms: u32 = 5_000,
    breaker: BreakerConfig = .{},
    max_in_flight: u32 = 16,
};

pub const Service = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    route: []const u8 = "",

    wasm: struct {
        enabled: bool = false,
        min_instances: u16 = 2,
        max_instances: u16 = 8,
        autoscale: bool = false,
        http: schnell.ServerConfig = .{},
    } = .{},

    upstreams: []const Upstream = &.{},

    pub fn load(allocator: std.mem.Allocator, io: Io, dir: Io.Dir) !*Service {
        const svc = try allocator.create(Service);
        svc.* = .{};

        const content = Io.Dir.readFileAlloc(dir, io, "service.yaml", allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return svc,
            else => {
                allocator.destroy(svc);
                return err;
            },
        };
        defer allocator.free(content);

        var yaml: Yaml = .{ .source = content };
        try yaml.load(allocator);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = try yaml.parse(arena.allocator(), Service);
        yaml.deinit(allocator);

        if (parsed.name.len > 0) svc.name = try allocator.dupe(u8, parsed.name);
        if (parsed.description.len > 0) svc.description = try allocator.dupe(u8, parsed.description);
        if (parsed.route.len > 0) svc.route = try allocator.dupe(u8, parsed.route);

        svc.wasm = parsed.wasm;
        if (parsed.wasm.http.host.len > 0) {
            svc.wasm.http.host = try allocator.dupe(u8, parsed.wasm.http.host);
        }
        if (parsed.wasm.http.static_dir) |sd| {
            svc.wasm.http.static_dir = try allocator.dupe(u8, sd);
        }

        if (parsed.upstreams.len > 0) {
            const owned = try allocator.alloc(Upstream, parsed.upstreams.len);
            for (parsed.upstreams, 0..) |u, i| {
                owned[i] = .{
                    .name = try allocator.dupe(u8, u.name),
                    .url = try allocator.dupe(u8, u.url),
                    .timeout_ms = u.timeout_ms,
                    .breaker = u.breaker,
                    .max_in_flight = u.max_in_flight,
                };
            }
            svc.upstreams = owned;
        }

        return svc;
    }

    pub fn deinit(self: *Service, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.description.len > 0) allocator.free(self.description);
        if (self.route.len > 0) allocator.free(self.route);
        if (self.wasm.http.host.len > 0) allocator.free(self.wasm.http.host);
        if (self.wasm.http.static_dir) |sd| {
            if (sd.len > 0) allocator.free(sd);
        }
        for (self.upstreams) |u| {
            if (u.name.len > 0) allocator.free(u.name);
            if (u.url.len > 0) allocator.free(u.url);
        }
        if (self.upstreams.len > 0) allocator.free(self.upstreams);
        allocator.destroy(self);
    }

    pub fn toYaml(self: *const Service, allocator: std.mem.Allocator) ![]const u8 {
        var w = Io.Writer.Allocating.init(allocator);
        errdefer w.deinit();
        const wr = &w.writer;

        if (self.name.len > 0) try wr.print("name: \"{s}\"\n", .{self.name});
        if (self.description.len > 0) try wr.print("description: \"{s}\"\n", .{self.description});
        if (self.route.len > 0) try wr.print("route: \"{s}\"\n", .{self.route});

        try wr.writeAll("wasm:\n");
        try wr.print("  enabled: {s}\n", .{if (self.wasm.enabled) "true" else "false"});
        try wr.print("  min_instances: {d}\n", .{self.wasm.min_instances});
        try wr.print("  max_instances: {d}\n", .{self.wasm.max_instances});
        try wr.print("  autoscale: {s}\n", .{if (self.wasm.autoscale) "true" else "false"});
        try wr.writeAll("  http:\n");
        try wr.print("    host: \"{s}\"\n", .{self.wasm.http.host});
        try wr.print("    port: {d}\n", .{self.wasm.http.port});
        try wr.print("    max_connections: {d}\n", .{self.wasm.http.max_connections});
        try wr.print("    max_body_size: {d}\n", .{self.wasm.http.max_body_size});
        try wr.print("    idle_timeout_ms: {d}\n", .{self.wasm.http.idle_timeout_ms});

        if (self.upstreams.len > 0) {
            try wr.writeAll("upstreams:\n");
            for (self.upstreams) |u| {
                try wr.print("  - name: \"{s}\"\n", .{u.name});
                try wr.print("    url: \"{s}\"\n", .{u.url});
                try wr.print("    timeout_ms: {d}\n", .{u.timeout_ms});
                try wr.print("    max_in_flight: {d}\n", .{u.max_in_flight});
                try wr.writeAll("    breaker:\n");
                try wr.print("      failure_threshold: {d}\n", .{u.breaker.failure_threshold});
                try wr.print("      success_threshold: {d}\n", .{u.breaker.success_threshold});
                try wr.print("      open_duration_ms: {d}\n", .{u.breaker.open_duration_ms});
            }
        }

        return try w.toOwnedSlice();
    }
};

test "Service - defaults when file missing" {
    const svc = Service{};
    try std.testing.expect(!svc.wasm.enabled);
    try std.testing.expectEqual(@as(u16, 2), svc.wasm.min_instances);
    try std.testing.expectEqual(@as(usize, 0), svc.upstreams.len);
}

test "Service - upstreams  via toYaml" {
    const allocator = std.testing.allocator;
    var svc = Service{
        .name = "cart",
        .route = "/cart*",
        .wasm = .{ .enabled = true, .min_instances = 4, .max_instances = 16 },
        .upstreams = &.{
            .{
                .name = "products",
                .url = "http://127.0.0.1:3042",
                .timeout_ms = 1500,
                .breaker = .{ .failure_threshold = 3, .success_threshold = 1, .open_duration_ms = 10_000 },
                .max_in_flight = 8,
            },
        },
    };
    const yaml_out = try svc.toYaml(allocator);
    defer allocator.free(yaml_out);

    try std.testing.expect(std.mem.indexOf(u8, yaml_out, "name: \"cart\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml_out, "route: \"/cart*\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml_out, "min_instances: 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml_out, "url: \"http://127.0.0.1:3042\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml_out, "failure_threshold: 3") != null);

    var yaml: Yaml = .{ .source = yaml_out };
    try yaml.load(allocator);
    defer yaml.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const reparsed = try yaml.parse(arena.allocator(), Service);
    try std.testing.expectEqualStrings("cart", reparsed.name);
    try std.testing.expectEqualStrings("/cart*", reparsed.route);
    try std.testing.expect(reparsed.wasm.enabled);
    try std.testing.expectEqual(@as(usize, 1), reparsed.upstreams.len);
    try std.testing.expectEqualStrings("products", reparsed.upstreams[0].name);
    try std.testing.expectEqual(@as(u32, 1500), reparsed.upstreams[0].timeout_ms);
}
