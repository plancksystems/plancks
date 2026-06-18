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
