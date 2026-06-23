const std = @import("std");

pub const Paths = struct {
    data_dir: []const u8,


    pub fn appDir(self: Paths, allocator: std.mem.Allocator, app: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/apps/{s}", .{ self.data_dir, app });
    }

    pub fn appPublic(self: Paths, allocator: std.mem.Allocator, app: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/apps/{s}/public", .{ self.data_dir, app });
    }

    pub fn appConfig(self: Paths, allocator: std.mem.Allocator, app: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/apps/{s}/app.yaml", .{ self.data_dir, app });
    }

    pub fn appServicesDir(self: Paths, allocator: std.mem.Allocator, app: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/apps/{s}/services", .{ self.data_dir, app });
    }


    pub fn serviceDir(self: Paths, allocator: std.mem.Allocator, app: []const u8, service: []const u8) ![]u8 {
        if (app.len == 0) {
            return std.fmt.allocPrint(allocator, "{s}/services/{s}", .{ self.data_dir, service });
        }
        return std.fmt.allocPrint(allocator, "{s}/apps/{s}/services/{s}", .{ self.data_dir, app, service });
    }

    pub fn serviceConfig(self: Paths, allocator: std.mem.Allocator, app: []const u8, service: []const u8) ![]u8 {
        const dir = try self.serviceDir(allocator, app, service);
        defer allocator.free(dir);
        return std.fmt.allocPrint(allocator, "{s}/db.yaml", .{dir});
    }

    pub fn serviceBinary(self: Paths, allocator: std.mem.Allocator, app: []const u8, service: []const u8) ![]u8 {
        const dir = try self.serviceDir(allocator, app, service);
        defer allocator.free(dir);
        return std.fmt.allocPrint(allocator, "{s}/planck-{s}", .{ dir, service });
    }

    pub fn serviceWasmDir(self: Paths, allocator: std.mem.Allocator, app: []const u8, service: []const u8) ![]u8 {
        const dir = try self.serviceDir(allocator, app, service);
        defer allocator.free(dir);
        return std.fmt.allocPrint(allocator, "{s}/wasm", .{dir});
    }

    pub fn serviceWasm(self: Paths, allocator: std.mem.Allocator, app: []const u8, service: []const u8) ![]u8 {
        const base = baseName(service);
        const dir = try self.serviceDir(allocator, app, service);
        defer allocator.free(dir);
        return std.fmt.allocPrint(allocator, "{s}/wasm/planck.{s}.wasm", .{ dir, base });
    }

    pub fn servicePid(self: Paths, allocator: std.mem.Allocator, app: []const u8, service: []const u8) ![]u8 {
        const dir = try self.serviceDir(allocator, app, service);
        defer allocator.free(dir);
        return std.fmt.allocPrint(allocator, "{s}/pid", .{dir});
    }


    pub fn standaloneDir(self: Paths, allocator: std.mem.Allocator, service: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/services/{s}", .{ self.data_dir, service });
    }


    pub fn baseName(service: []const u8) []const u8 {
        if (std.mem.indexOf(u8, service, ".db.")) |idx| return service[0..idx];
        return service;
    }
};

test "app directory lives under the data dir" {
    const p = Paths{ .data_dir = "/var/planck" };
    const got = try p.appDir(std.testing.allocator, "shop");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/var/planck/apps/shop", got);
}

test "app public directory points at the public folder" {
    const p = Paths{ .data_dir = "/data" };
    const got = try p.appPublic(std.testing.allocator, "shop");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/data/apps/shop/public", got);
}

test "app config points at app yaml" {
    const p = Paths{ .data_dir = "/data" };
    const got = try p.appConfig(std.testing.allocator, "shop");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/data/apps/shop/app.yaml", got);
}

test "service directory nests under its app" {
    const p = Paths{ .data_dir = "/data" };
    const got = try p.serviceDir(std.testing.allocator, "shop", "orders");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/data/apps/shop/services/orders", got);
}

test "service directory without an app sits under top level services" {
    const p = Paths{ .data_dir = "/data" };
    const got = try p.serviceDir(std.testing.allocator, "", "orders");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/data/services/orders", got);
}

test "service config is db yaml inside the service directory" {
    const p = Paths{ .data_dir = "/data" };
    const got = try p.serviceConfig(std.testing.allocator, "shop", "orders");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/data/apps/shop/services/orders/db.yaml", got);
}

test "service binary is prefixed with planck" {
    const p = Paths{ .data_dir = "/data" };
    const got = try p.serviceBinary(std.testing.allocator, "shop", "orders");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/data/apps/shop/services/orders/planck-orders", got);
}

test "service wasm path uses the base name without the db suffix" {
    const p = Paths{ .data_dir = "/data" };
    const got = try p.serviceWasm(std.testing.allocator, "shop", "orders.db.primary");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/data/apps/shop/services/orders.db.primary/wasm/planck.orders.wasm", got);
}

test "service pid file lives in the service directory" {
    const p = Paths{ .data_dir = "/data" };
    const got = try p.servicePid(std.testing.allocator, "shop", "orders");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/data/apps/shop/services/orders/pid", got);
}

test "standalone directory ignores any app" {
    const p = Paths{ .data_dir = "/data" };
    const got = try p.standaloneDir(std.testing.allocator, "metrics");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/data/services/metrics", got);
}

test "base name keeps a plain service unchanged" {
    try std.testing.expectEqualStrings("orders", Paths.baseName("orders"));
}

test "base name drops the db suffix" {
    try std.testing.expectEqualStrings("orders", Paths.baseName("orders.db.primary"));
}
