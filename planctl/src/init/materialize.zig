const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const manifest = @import("templates_manifest");
const build_info = @import("build_info");
const names = @import("names.zig");

pub const Options = struct {
    force: bool = false,
};

pub const Error = error{
    ProjectExists,
} || Io.Dir.OpenError || Io.Dir.WriteFileError || Io.Dir.CreateDirPathError || Allocator.Error;

pub fn materialize(allocator: Allocator, io: Io, template: manifest.Template, project_name: []const u8, opts: Options) !void {
    const cwd = Io.Dir.cwd();

    if (!opts.force) {
        if (Io.Dir.openDir(cwd, io, project_name, .{})) |existing| {
            var d = existing;
            d.close(io);
            return error.ProjectExists;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }
    try Io.Dir.createDirPath(cwd, io, project_name);

    var proj = try Io.Dir.openDir(cwd, io, project_name, .{});
    defer proj.close(io);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_abs = try getCwdAbs(&cwd_buf);
    const project_abs = try std.fs.path.join(allocator, &.{ cwd_abs, project_name });
    defer allocator.free(project_abs);

    for (template.files) |entry| {
        if (std.mem.lastIndexOfScalar(u8, entry.path, '/')) |sep| {
            try Io.Dir.createDirPath(proj, io, entry.path[0..sep]);
        }

        const bytes = try rewriteBytes(allocator, entry.path, entry.bytes, project_name, project_abs);
        defer allocator.free(bytes);

         
        const perms: Io.File.Permissions = if (std.mem.endsWith(u8, entry.path, ".sh"))
            .executable_file
        else
            .default_file;

        try Io.Dir.writeFile(proj, io, .{
            .sub_path = entry.path,
            .data = bytes,
            .flags = .{ .permissions = perms },
        });
    }
}


pub fn rewriteBytes(allocator: Allocator, path: []const u8, bytes: []const u8, project_name: []const u8, project_abs: []const u8) ![]u8 {
    const step1 = try names.replaceAll(allocator, bytes, "__PROJECT_NAME__", project_name);
    errdefer allocator.free(step1);

    if (isZon(path)) {
        const build_root = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep|
            try std.fs.path.join(allocator, &.{ project_abs, path[0..sep] })
        else
            try allocator.dupe(u8, project_abs);
        defer allocator.free(build_root);

        const step2 = try rewriteZon(allocator, step1, build_root);
        allocator.free(step1);
        return step2;
    }
    return step1;
}

fn isZon(path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(path), "build.zig.zon");
}

fn getCwdAbs(buf: []u8) ![]const u8 {
    if (std.c.getcwd(buf.ptr, buf.len) == null) return error.GetCwdFailed;
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..len];
}

fn rewriteZon(allocator: Allocator, bytes: []const u8, build_root: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        if (std.mem.indexOf(u8, raw_line, ".fingerprint")) |_| {
            try out.appendSlice(allocator, "    .fingerprint = 0x0000000000000000,\n");
            continue;
        }

        if (try maybeRewritePathLine(allocator, raw_line, build_root)) |rewritten| {
            defer allocator.free(rewritten);
            try out.appendSlice(allocator, rewritten);
            try out.append(allocator, '\n');
            continue;
        }

        try out.appendSlice(allocator, raw_line);
        try out.append(allocator, '\n');
    }

    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}

fn maybeRewritePathLine(allocator: Allocator, line: []const u8, build_root: []const u8) !?[]u8 {
    if (build_root.len == 0) return null;

    const trimmed = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, ".path = \"")) return null;
    const open_quote = std.mem.indexOf(u8, line, "\"") orelse return null;
    const close_quote = std.mem.lastIndexOfScalar(u8, line, '"') orelse return null;
    if (close_quote <= open_quote + 1) return null;

    const old_value = line[open_quote + 1 .. close_quote];
    const dep_name = std.fs.path.basename(old_value);
    if (dep_name.len == 0) return null;

    const dep_abs = try std.fs.path.join(allocator, &.{ build_info.monorepo_root, dep_name });
    defer allocator.free(dep_abs);
    const rel = try std.fs.path.relativePosix(allocator, "/", build_root, dep_abs);
    defer allocator.free(rel);

    const indent_end = std.mem.indexOfNone(u8, line, " \t") orelse return null;
    const indent = line[0..indent_end];
    const tail = line[close_quote + 1 ..];

    return try std.fmt.allocPrint(allocator, "{s}.path = \"{s}\"{s}", .{
        indent,
        rel,
        tail,
    });
}


test "rewriteZon: relative path-dep rewrite + fingerprint zero" {
    const a = std.testing.allocator;
    const input =
        \\.{
        \\    .name = .app,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0xc96e70cff490eee6,
        \\    .dependencies = .{
        \\        .planck_zig_client = .{
        \\            .path = "../../../../planck-zig-client",
        \\        },
        \\        .bson = .{
        \\            .url = "https://github.com/plancksystems/bson/archive/refs/tags/v0.1.0.tar.gz",
        \\            .hash = "bson-0.1.0-QwoLYQNWAQD7PNOL2uyJacKGneUmsih-_8PrvAT3Mskz",
        \\        },
        \\    },
        \\}
    ;
    const build_root = try std.fs.path.join(a, &.{ build_info.monorepo_root, "tests", "demo" });
    defer a.free(build_root);
    const out = try rewriteZon(a, input, build_root);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, ".fingerprint = 0x0000000000000000,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "../../planck-zig-client\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "../../../../planck-zig-client") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "github.com/plancksystems/bson") != null);
}

test "replaceAll: project-name substitution" {
    const a = std.testing.allocator;
    const out = try names.replaceAll(a, "name: __PROJECT_NAME__", "__PROJECT_NAME__", "demo");
    defer a.free(out);
    try std.testing.expectEqualStrings("name: demo", out);
}
