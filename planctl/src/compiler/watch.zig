const std = @import("std");
const transform = @import("transform.zig");

pub fn watchMode(allocator: std.mem.Allocator, io: std.Io, in_dir_path: []const u8, out_dir_path: []const u8) !void {
    std.debug.print("planctl --watch: watching {s} (recursive)...\n", .{in_dir_path});

    try transform.transformDir(allocator, io, in_dir_path, out_dir_path);

    var mtimes = std.StringHashMap(i128).init(allocator);
    defer freeMtimeMap(allocator, &mtimes);
    try collectMtimes(allocator, io, in_dir_path, "", &mtimes);

    while (true) {
        try io.sleep(.{ .nanoseconds = 200 * std.time.ns_per_ms }, .real);

        var new_mtimes = std.StringHashMap(i128).init(allocator);
        collectMtimes(allocator, io, in_dir_path, "", &new_mtimes) catch {
            freeMtimeMap(allocator, &new_mtimes);
            continue;
        };

        var nit = new_mtimes.iterator();
        while (nit.next()) |kv| {
            const old_mtime = mtimes.get(kv.key_ptr.*);
            if (old_mtime == null) {
                std.debug.print("planctl: new {s}\n", .{kv.key_ptr.*});
                watchRecompile(allocator, io, in_dir_path, out_dir_path, kv.key_ptr.*) catch |e| {
                    std.debug.print("planctl: error compiling {s}: {}\n", .{ kv.key_ptr.*, e });
                };
            } else if (kv.value_ptr.* > old_mtime.?) {
                std.debug.print("planctl: changed {s}\n", .{kv.key_ptr.*});
                watchRecompile(allocator, io, in_dir_path, out_dir_path, kv.key_ptr.*) catch |e| {
                    std.debug.print("planctl: error compiling {s}: {}\n", .{ kv.key_ptr.*, e });
                };
            }
        }

        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(allocator);
        var oit = mtimes.iterator();
        while (oit.next()) |kv| {
            if (!new_mtimes.contains(kv.key_ptr.*)) {
                std.debug.print("planctl: source deleted {s}\n", .{kv.key_ptr.*});
                watchDeleteOutput(allocator, io, out_dir_path, kv.key_ptr.*) catch {};
                to_remove.append(allocator, kv.key_ptr.*) catch {};
            }
        }
        for (to_remove.items) |key| {
            if (mtimes.fetchRemove(key)) |removed| {
                allocator.free(removed.key);
            }
        }

        freeMtimeMap(allocator, &mtimes);
        mtimes = new_mtimes;
    }
}

fn freeMtimeMap(allocator: std.mem.Allocator, map: *std.StringHashMap(i128)) void {
    var it = map.iterator();
    while (it.next()) |kv| allocator.free(kv.key_ptr.*);
    map.deinit();
}

fn collectMtimes(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    rel_prefix: []const u8,
    mtimes: *std.StringHashMap(i128)
) !void {
    const alloc_path = if (rel_prefix.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, rel_prefix })
    else
        null;
    defer if (alloc_path) |p| allocator.free(p);
    const full_path = alloc_path orelse base_path;

    var dir = try std.Io.Dir.openDir(.cwd(), io, full_path, .{ .iterate = true });
    defer dir.close(io);

    var subdirs = std.ArrayList([]const u8).empty;
    defer {
        for (subdirs.items) |s| allocator.free(s);
        subdirs.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            try subdirs.append(allocator, try allocator.dupe(u8, entry.name));
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zsx")) continue;

        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        const rel_path = if (rel_prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        mtimes.put(rel_path, stat.mtime.nanoseconds) catch |e| {
            allocator.free(rel_path);
            return e;
        };
    }

    for (subdirs.items) |subdir_name| {
        const alloc_sub = if (rel_prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_prefix, subdir_name })
        else
            try allocator.dupe(u8, subdir_name);
        defer allocator.free(alloc_sub);
        try collectMtimes(allocator, io, base_path, alloc_sub, mtimes);
    }
}

fn watchRecompile(
    allocator: std.mem.Allocator,
    io: std.Io,
    in_dir_path: []const u8,
    out_dir_path: []const u8,
    rel_path: []const u8
) !void {
    const sep = std.mem.lastIndexOfScalar(u8, rel_path, '/');
    const dir_part = if (sep) |s| rel_path[0..s] else "";
    const file_name = if (sep) |s| rel_path[s + 1 ..] else rel_path;

    const alloc_in = if (dir_part.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ in_dir_path, dir_part })
    else
        null;
    defer if (alloc_in) |p| allocator.free(p);
    const in_full = alloc_in orelse in_dir_path;

    const alloc_out = if (dir_part.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir_path, dir_part })
    else
        null;
    defer if (alloc_out) |p| allocator.free(p);
    const out_full = alloc_out orelse out_dir_path;

    if (dir_part.len > 0) {
        std.Io.Dir.createDirPath(.cwd(), io, out_full) catch {};
    }

    var in_dir = try std.Io.Dir.openDir(.cwd(), io, in_full, .{ .iterate = true });
    defer in_dir.close(io);
    var out_dir = std.Io.Dir.openDir(.cwd(), io, out_full, .{}) catch blk: {
        try std.Io.Dir.createDirPath(.cwd(), io, out_full);
        break :blk try std.Io.Dir.openDir(.cwd(), io, out_full, .{});
    };
    defer out_dir.close(io);

    try transform.transformFile(allocator, io, in_dir, file_name, out_dir, in_full, out_full);
}

fn watchDeleteOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir_path: []const u8,
    rel_path: []const u8
) !void {
    if (!std.mem.endsWith(u8, rel_path, ".zsx")) return;
    const stem = rel_path[0 .. rel_path.len - 5];
    const out_rel = try std.fmt.allocPrint(allocator, "{s}.zig", .{stem});
    defer allocator.free(out_rel);

    const sep = std.mem.lastIndexOfScalar(u8, out_rel, '/');
    const dir_part = if (sep) |s| out_rel[0..s] else "";
    const file_name = if (sep) |s| out_rel[s + 1 ..] else out_rel;

    const alloc_dir = if (dir_part.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir_path, dir_part })
    else
        null;
    defer if (alloc_dir) |p| allocator.free(p);
    const dir_full = alloc_dir orelse out_dir_path;

    var dir = std.Io.Dir.openDir(.cwd(), io, dir_full, .{}) catch return;
    defer dir.close(io);
    dir.deleteFile(io, file_name) catch return;

    std.debug.print("planctl: removed {s}/{s}\n", .{ out_dir_path, out_rel });
}
