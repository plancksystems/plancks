
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const manifest = @import("templates_manifest");
const validate = @import("../validate.zig");
const names = @import("../names.zig");
const patchers = @import("../patchers.zig");
const materialize = @import("../materialize.zig");
const common = @import("../common.zig");

pub const Arch = common.Arch;

pub const Options = struct {
    force: bool = false,
    arch_override: ?Arch = null,
    port_override: ?u16 = null,
};

pub const Error = error{
    NotMicroProject,
    ServiceExists,
    TemplateMissing,
    InvalidName,
};

pub fn add(
    allocator: Allocator,
    io: Io,
    service_name: []const u8,
    opts: Options
) anyerror!void {
    if (validate.check(service_name)) |err| {
        std.debug.print("planctl add: invalid service name '{s}': {s}\n", .{ service_name, validate.messageFor(err, service_name) });
        return error.InvalidName;
    }

    const cwd = Io.Dir.cwd();
    try ensureMicroRoot(io, cwd);

    const dest_rel = try std.fmt.allocPrint(allocator, "services/{s}", .{service_name});
    defer allocator.free(dest_rel);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_abs = blk: {
        if (std.c.getcwd(&cwd_buf, cwd_buf.len) == null) return error.GetCwdFailed;
        const len = std.mem.indexOfScalar(u8, &cwd_buf, 0) orelse cwd_buf.len;
        break :blk cwd_buf[0..len];
    };

    var existing_port: ?u16 = null;
    if (Io.Dir.openDir(cwd, io, dest_rel, .{})) |existing| {
        var d = existing;
        d.close(io);
        if (!opts.force) {
            std.debug.print("planctl add: '{s}/' already exists (use --force to overwrite)\n", .{dest_rel});
            return error.ServiceExists;
        }
        const cfg_path = try std.fmt.allocPrint(allocator, "{s}/db.yaml", .{dest_rel});
        defer allocator.free(cfg_path);
        if (Io.Dir.readFileAlloc(cwd, io, cfg_path, allocator, .unlimited)) |cfg| {
            defer allocator.free(cfg);
            existing_port = parsePortLine(cfg);
        } else |_| {}
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const arch = opts.arch_override orelse common.detectArch(io, cwd, "frontend");
    const tmpl: manifest.Template = switch (arch) {
        .hda => manifest.hda_micro,
        .spa => manifest.spa_micro,
    };

    const port: u16 = opts.port_override orelse existing_port orelse (try pickNextPort(allocator, io, cwd));
    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_str);

    const forms = try names.forms(allocator, service_name);
    defer forms.deinit(allocator);

    const tasks_prefix = "services/tasks/";
    var written: usize = 0;
    for (tmpl.files) |entry| {
        if (!std.mem.startsWith(u8, entry.path, tasks_prefix)) continue;
        const sub = entry.path[tasks_prefix.len..];

        const sub_renamed = try names.substitute(allocator, sub, forms);
        defer allocator.free(sub_renamed);
        const out_rel = try std.fmt.allocPrint(allocator, "services/{s}/{s}", .{ service_name, sub_renamed });
        defer allocator.free(out_rel);

        if (std.mem.lastIndexOfScalar(u8, out_rel, '/')) |sep| {
            try Io.Dir.createDirPath(cwd, io, out_rel[0..sep]);
        }

        const step1 = try names.substitute(allocator, entry.bytes, forms);
        defer allocator.free(step1);
        const step2 = try names.replaceAll(allocator, step1, "4001", port_str);
        defer allocator.free(step2);
        const route_old = "\"/tasks*\"";
        const route_new = try std.fmt.allocPrint(allocator, "\"/{s}*\"", .{service_name});
        defer allocator.free(route_new);
        const step2b = try names.replaceAll(allocator, step2, route_old, route_new);
        defer allocator.free(step2b);
        const final = if (std.mem.endsWith(u8, out_rel, "build.zig.zon"))
            try materialize.rewriteBytes(allocator, out_rel, step2b, service_name, cwd_abs)
        else
            try allocator.dupe(u8, step2b);
        defer allocator.free(final);

        try Io.Dir.writeFile(cwd, io, .{ .sub_path = out_rel, .data = final });
        written += 1;
    }

    if (written == 0) return error.TemplateMissing;


    std.debug.print(
        \\Added service '{s}' to services/{s}/ ({d} files, arch={s}, dev_port={d}).
        \\
        \\Before deploying:
        \\  - Set `port:` in services/{s}/db.yaml and `http.port:` in
        \\    services/{s}/service.yaml (templates ship with `port: 0` per
        \\    the manual-port rule — pick unique values; the validator
        \\    refuses zero).
        \\  - The dev_port above is the local native binary's port only
        \\    (used by `zig build run` in services/{s}/). The deployed
        \\    planck/db reads `db.yaml` and binds whatever you set there.
        \\
        \\Next steps:
        \\  cd services/{s} && zig build dev-build
        \\  cd - && ./dev.sh         # start the stack
        \\
    , .{ service_name, service_name, written, @tagName(arch), port, service_name, service_name, service_name, service_name });
}


fn ensureMicroRoot(io: Io, cwd: Io.Dir) !void {
    var services = Io.Dir.openDir(cwd, io, "services", .{}) catch {
        std.debug.print("planctl add: cwd is not a micro project root (no services/ dir found)\n", .{});
        return error.NotMicroProject;
    };
    services.close(io);

    var f = Io.Dir.openFile(cwd, io, "app.yaml", .{}) catch {
        std.debug.print("planctl add: cwd is missing app.yaml (micro project marker)\n", .{});
        return error.NotMicroProject;
    };
    f.close(io);
}

fn pickNextPort(allocator: Allocator, io: Io, cwd: Io.Dir) !u16 {
    var services = try Io.Dir.openDir(cwd, io, "services", .{ .iterate = true });
    defer services.close(io);

    var max_port: u16 = 4000;
    var iter = services.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const cfg_rel = try std.fmt.allocPrint(allocator, "{s}/db.yaml", .{entry.name});
        defer allocator.free(cfg_rel);

        const cfg = Io.Dir.readFileAlloc(services, io, cfg_rel, allocator, .unlimited) catch continue;
        defer allocator.free(cfg);

        if (parsePortLine(cfg)) |p| {
            if (p > max_port) max_port = p;
        }
    }
    return max_port + 1;
}

fn parsePortLine(cfg: []const u8) ?u16 {
    var lines = std.mem.splitScalar(u8, cfg, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "port:")) continue;
        const rest = std.mem.trim(u8, trimmed["port:".len..], " \t");
        return std.fmt.parseInt(u16, rest, 10) catch null;
    }
    return null;
}


test "parsePortLine: basic" {
    const cfg =
        \\service:
        \\  name: tasks
        \\  port: 4001
    ;
    try std.testing.expectEqual(@as(?u16, 4001), parsePortLine(cfg));
}

test "parsePortLine: missing" {
    const cfg = "service:\n  name: tasks\n";
    try std.testing.expectEqual(@as(?u16, null), parsePortLine(cfg));
}
