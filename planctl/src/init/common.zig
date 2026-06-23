const std = @import("std");
const Target = @import("../zsx/compiler.zig").Target;

pub fn createProjectDirs(
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    lang: Target
) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();

    const template_dir = switch (lang) {
        .zig => "src/zsx",
        .rust => "src/rsx",
        .go => "src/gsx",
    };

    std.Io.Dir.createDirPath(cwd, io, name) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };
    const proj_dir = try std.Io.Dir.openDir(cwd, io, name, .{});

    const dirs = [_][]const u8{
        "src/domain",
        "src/api",
        template_dir,
        "src/ui",
        "tests",
    };
    for (dirs) |d| {
        std.Io.Dir.createDirPath(proj_dir, io, d) catch |e| {
            if (e != error.PathAlreadyExists) return e;
        };
    }

    _ = allocator;
    return proj_dir;
}

pub fn createShellDirs(
    io: std.Io,
    name: []const u8
) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();

    std.Io.Dir.createDirPath(cwd, io, name) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };
    const proj_dir = try std.Io.Dir.openDir(cwd, io, name, .{});

    const dirs = [_][]const u8{
        "src/api",
        "public",
        "services",
    };
    for (dirs) |d| {
        std.Io.Dir.createDirPath(proj_dir, io, d) catch |e| {
            if (e != error.PathAlreadyExists) return e;
        };
    }

    return proj_dir;
}

pub const Arch = enum { hda, spa };

pub fn detectArch(io: std.Io, cwd: std.Io.Dir, probe_path: []const u8) Arch {
    if (std.Io.Dir.openDir(cwd, io, probe_path, .{})) |existing| {
        var d = existing;
        d.close(io);
        return .spa;
    } else |_| {}
    return .hda;
}

pub fn pkgName(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name[i + 1 ..] else name;
}

pub fn writeFile(dir: std.Io.Dir, io: std.Io, path: []const u8, data: []const u8) !void {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

pub fn writeServiceManifest(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, name: []const u8) !void {
    const db_content =
        \\address: "0.0.0.0"
        \\primary: true
        \\max_sessions: 128
        \\port: 0
        \\session:
        \\  idle_timeout_ms: 604800000
        \\buffers:
        \\  memtable: 16777216
        \\  vlog: 4194304
        \\  wal: 262144
        \\durability:
        \\  enabled: true
        \\  flush_interval_in_ms: 1000
        \\  log_archive:
        \\    enabled: false
        \\    dest_path: ""
        \\    retain_logs_days: 15
        \\file_sizes:
        \\  vlog: 1073741824
        \\  wal: 16777216
        \\index:
        \\  primary:
        \\    pool_size: 64
        \\  secondary:
        \\    pool_size: 64
        \\cache:
        \\  enabled: false
        \\  capacity: 10000
        \\logging:
        \\  path: ""
        \\  level: info
        \\  max_size_mb: 10
        \\  max_files: 5
        \\gc:
        \\  dead_ratio: 30
        \\limits:
        \\  max_batch_size: 10000
        \\  max_message_size: 16777216
        \\security:
        \\  max_failed_attempts: 5
        \\  lockout_duration_ms: 900000
        \\  lockout_multiplier: 2
        \\replica:
        \\  enabled: false
        \\  sync_interval_ms: 5000
        \\  address: "127.0.0.1"
        \\  port: 0
        \\
    ;
    try writeFile(dir, io, "db.yaml", db_content);

    const svc_content = try std.fmt.allocPrint(allocator,
        \\name: {s}
        \\
        \\tls:
        \\  enabled: false
        \\  cert_file: ""
        \\  key_file: ""
        \\
        \\http:
        \\  host: "0.0.0.0"
        \\  port: 0
        \\  max_connections: 10000
        \\  max_header_size: 8192
        \\  max_body_size: 1048576
        \\  response_buffer_size: 65536
        \\  idle_timeout_ms: 30000
        \\  max_requests_per_connection: 10000
        \\  drain_timeout_ms: 5000
        \\
        \\wasm:
        \\  enabled: true
        \\  min_instances: 2
        \\  max_instances: 8
        \\  autoscale: false
        \\
    , .{name});
    defer allocator.free(svc_content);
    try writeFile(dir, io, "service.yaml", svc_content);
}
