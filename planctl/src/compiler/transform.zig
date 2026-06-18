const std = @import("std");
const Compiler = @import("../zsx/compiler.zig").Compiler;
const Target = @import("../zsx/compiler.zig").Target;

pub fn transformSource(
    allocator: std.mem.Allocator,
    src: []const u8,
    src_file: []const u8,
    target: Target
) ![]u8 {
    var compiler = Compiler.init(allocator, src, src_file, target);
    const result = try compiler.compile();
    if (result.has_errors) {
        std.debug.print("planctl: {s} compiled with errors\n", .{src_file});
    }
    return result.code;
}

pub fn detectTargetFromExt(filename: []const u8) ?Target {
    if (std.mem.endsWith(u8, filename, ".rsx")) return .rust;
    if (std.mem.endsWith(u8, filename, ".gsx")) return .go;
    if (std.mem.endsWith(u8, filename, ".zsx")) return .zig;
    return null;
}

pub fn transformDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    in_dir_path: []const u8,
    out_dir_path: []const u8
) !void {
    var in_dir = try std.Io.Dir.openDir(.cwd(), io, in_dir_path, .{ .iterate = true });
    defer in_dir.close(io);
    try std.Io.Dir.createDirPath(.cwd(), io, out_dir_path);
    var out_dir = try std.Io.Dir.openDir(.cwd(), io, out_dir_path, .{ .iterate = true });
    defer out_dir.close(io);

    var subdirs = std.ArrayList([]const u8).empty;
    defer {
        for (subdirs.items) |s| allocator.free(s);
        subdirs.deinit(allocator);
    }

    var iter = in_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            try subdirs.append(allocator, try allocator.dupe(u8, entry.name));
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zsx")) continue;
        try transformFile(allocator, io, in_dir, entry.name, out_dir, in_dir_path, out_dir_path);
    }

    for (subdirs.items) |subdir_name| {
        const sub_in = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ in_dir_path, subdir_name });
        defer allocator.free(sub_in);
        const sub_out = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir_path, subdir_name });
        defer allocator.free(sub_out);
        try transformDir(allocator, io, sub_in, sub_out);
    }
}

pub fn transformFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    in_dir: std.Io.Dir,
    name: []const u8,
    out_dir: std.Io.Dir,
    in_dir_path: []const u8,
    out_dir_path: []const u8
) !void {
    const src = try in_dir.readFileAlloc(io, name, allocator, .unlimited);
    defer allocator.free(src);

    const src_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ in_dir_path, name });
    defer allocator.free(src_path);

    const file_target = detectTargetFromExt(name) orelse .zig;
    const code = try transformSource(allocator, src, src_path, file_target);
    defer allocator.free(code);

    const ext_len: usize = 4;
    const out_ext = switch (file_target) {
        .zig => ".zig",
        .rust => ".rs",
        .go => ".go",
    };
    const out_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name[0 .. name.len - ext_len], out_ext });
    defer allocator.free(out_name);
    try out_dir.writeFile(io, .{ .sub_path = out_name, .data = code });

    std.debug.print("planctl: {s}/{s} → {s}/{s}\n", .{ in_dir_path, name, out_dir_path, out_name });
}

pub fn writeFile(dir: std.Io.Dir, io: std.Io, path: []const u8, data: []const u8) !void {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}
