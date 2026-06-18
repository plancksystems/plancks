const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const schnell = @import("schnell");
const AppServices = @import("../tasks/services.zig").AppServices;
const Ctx = @import("../ctx.zig").Ctx;
const json = @import("json.zig");

pub const LogsParams = struct {
    app: ?[]const u8 = null,
    service: ?[]const u8 = null,
    file: ?[]const u8 = null,
    offset: ?[]const u8 = null,
    limit: ?[]const u8 = null,
    q: ?[]const u8 = null,
};

pub const LogsResponse = struct {
    success: bool = true,
    apps: ?[]const AppInfo = null,
    files: ?[]const FileInfo = null,
    content: ?[]const u8 = null,
    total_lines: ?u64 = null,
    @"error": ?[]const u8 = null,
};

pub const AppInfo = struct {
    name: []const u8,
    services: []const []const u8,
};

pub const FileInfo = struct {
    name: []const u8,
    size: u64,
    modified: i64,
};

pub fn handle(ctx_ptr: ?*anyopaque, allocator: Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const services = ctx.services;
    const params = req.getParams(LogsParams);

    if (params.service == null) {
        const body = try listAppsAndServices(services, allocator);
        try res.json(body);
        return;
    }

    const service_name = params.service.?;

    if (params.file == null) {
        const body = try listLogFiles(services, allocator, service_name);
        try res.json(body);
        return;
    }

    const filename = params.file.?;

    if (std.mem.indexOfScalar(u8, filename, '/') != null or
        std.mem.indexOfScalar(u8, filename, '\\') != null or
        std.mem.eql(u8, filename, ".."))
    {
        try res.json(try json.serialize(allocator, LogsResponse{ .success = false, .@"error" = "Invalid filename" }));
        return;
    }

    if (params.q) |query| {
        const body = try searchLogFile(services, allocator, service_name, filename, query);
        try res.json(body);
        return;
    }

    const offset = if (params.offset) |o| std.fmt.parseInt(u64, o, 10) catch 0 else 0;
    const limit = if (params.limit) |l| std.fmt.parseInt(u64, l, 10) catch 1000 else 1000;

    const body = try readLogFile(services, allocator, service_name, filename, offset, limit);
    try res.json(body);
}

fn listAppsAndServices(services: *AppServices, allocator: Allocator) ![]const u8 {
    var app_map = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
    defer {
        var it = app_map.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(allocator);
        app_map.deinit();
    }

    for (services.databases) |entry| {
        const app_name = if (entry.app.len > 0) entry.app else "default";
        const result = try app_map.getOrPut(app_name);
        if (!result.found_existing) {
            result.value_ptr.* = .empty;
        }
        try result.value_ptr.append(allocator, entry.name);
    }

    var apps: std.ArrayList(AppInfo) = .empty;
    defer apps.deinit(allocator);

    var it = app_map.iterator();
    while (it.next()) |entry| {
        try apps.append(allocator, .{
            .name = entry.key_ptr.*,
            .services = entry.value_ptr.items,
        });
    }

    return json.serialize(allocator, LogsResponse{
        .success = true,
        .apps = apps.items,
    });
}

fn listLogFiles(services: *AppServices, allocator: Allocator, service_name: []const u8) ![]const u8 {
    const svc_dir_path = getServiceDir(services, allocator, service_name) orelse {
        return json.serialize(allocator, LogsResponse{ .success = false, .@"error" = "Service not found" });
    };
    defer allocator.free(svc_dir_path);

    var files: std.ArrayList(FileInfo) = .empty;
    defer files.deinit(allocator);

    const io = services.io;

    var dir = Dir.openDir(.cwd(), io, svc_dir_path, .{ .iterate = true }) catch {
        return json.serialize(allocator, LogsResponse{ .success = true, .files = &.{} });
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log")) continue;

        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        try files.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .size = @intCast(stat.size),
            .modified = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s)),
        });
    }

    return json.serialize(allocator, LogsResponse{
        .success = true,
        .files = files.items,
    });
}

fn forEachLine(
    buf: []const u8,
    context: anytype,
    comptime callback: fn (@TypeOf(context), line_num: u64, line: []const u8) anyerror!void,
) !void {
    var line_num: u64 = 0;
    var line_start: usize = 0;
    for (buf, 0..) |c, i| {
        if (c == '\n' or i == buf.len - 1) {
            line_num += 1;
            const line_end = if (c == '\n') i else i + 1;
            try callback(context, line_num, buf[line_start..line_end]);
            line_start = i + 1;
        }
    }
}

fn readLogFile(services: *AppServices, allocator: Allocator, service_name: []const u8, filename: []const u8, offset: u64, limit: u64) ![]const u8 {
    const file_path = try getLogFilePath(services, allocator, service_name, filename);
    defer allocator.free(file_path);

    const io = services.io;
    const content = Dir.readFileAlloc(.cwd(), io, file_path, allocator, .unlimited) catch {
        return json.serialize(allocator, LogsResponse{ .success = false, .@"error" = "File not found" });
    };
    defer allocator.free(content);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    var ctx = ReadLineCtx{
        .allocator = allocator,
        .result = &result,
        .offset = offset,
        .limit = limit,
    };
    try forEachLine(content, &ctx, ReadLineCtx.onLine);

    return json.serialize(allocator, LogsResponse{
        .success = true,
        .content = result.items,
        .total_lines = ctx.line_num,
    });
}

const ReadLineCtx = struct {
    allocator: Allocator,
    result: *std.ArrayList(u8),
    offset: u64,
    limit: u64,
    line_num: u64 = 0,
    lines_read: u64 = 0,

    fn onLine(self: *ReadLineCtx, line_num: u64, line: []const u8) !void {
        self.line_num = line_num;
        if (line_num > self.offset and self.lines_read < self.limit) {
            const formatted = try std.fmt.allocPrint(self.allocator, "{d}\t{s}\n", .{ line_num, line });
            defer self.allocator.free(formatted);
            try self.result.appendSlice(self.allocator, formatted);
            self.lines_read += 1;
        }
    }
};

fn searchLogFile(services: *AppServices, allocator: Allocator, service_name: []const u8, filename: []const u8, query: []const u8) ![]const u8 {
    const file_path = try getLogFilePath(services, allocator, service_name, filename);
    defer allocator.free(file_path);

    const io = services.io;
    const content = Dir.readFileAlloc(.cwd(), io, file_path, allocator, .unlimited) catch {
        return json.serialize(allocator, LogsResponse{ .success = false, .@"error" = "File not found" });
    };
    defer allocator.free(content);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    var ctx = SearchLineCtx{
        .allocator = allocator,
        .result = &result,
        .query = query,
    };
    try forEachLine(content, &ctx, SearchLineCtx.onLine);

    return json.serialize(allocator, LogsResponse{
        .success = true,
        .content = result.items,
        .total_lines = ctx.matches,
    });
}

const SearchLineCtx = struct {
    allocator: Allocator,
    result: *std.ArrayList(u8),
    query: []const u8,
    matches: u64 = 0,
    const max_matches: u64 = 500;

    fn onLine(self: *SearchLineCtx, line_num: u64, line: []const u8) !void {
        if (self.matches < max_matches and std.mem.indexOf(u8, line, self.query) != null) {
            const formatted = try std.fmt.allocPrint(self.allocator, "{d}\t{s}\n", .{ line_num, line });
            defer self.allocator.free(formatted);
            try self.result.appendSlice(self.allocator, formatted);
            self.matches += 1;
        }
    }
};

fn getServiceDir(services: *AppServices, allocator: Allocator, service_name: []const u8) ?[]const u8 {
    const sm = services.service_manager orelse return null;

    for (services.databases) |entry| {
        if (!std.mem.eql(u8, entry.name, service_name)) continue;
        if (entry.app.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/apps/{s}/services/{s}", .{ sm.data_dir, entry.app, service_name }) catch null;
        }
        return std.fmt.allocPrint(allocator, "{s}/services/{s}", .{ sm.data_dir, service_name }) catch null;
    }
    return null;
}

fn getLogFilePath(services: *AppServices, allocator: Allocator, service_name: []const u8, filename: []const u8) ![]const u8 {
    const svc_dir = getServiceDir(services, allocator, service_name) orelse return error.ServiceNotFound;
    defer allocator.free(svc_dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ svc_dir, filename });
}
