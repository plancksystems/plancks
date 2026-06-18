
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
};

pub const Error = error{
    NotMonoProject,
    FeatureExists,
    TemplateMissing,
    InvalidName,
};

pub fn add(
    allocator: Allocator,
    io: Io,
    feature_name: []const u8,
    opts: Options
) anyerror!void {
    if (validate.check(feature_name)) |err| {
        std.debug.print("planctl add: invalid feature name '{s}': {s}\n", .{ feature_name, validate.messageFor(err, feature_name) });
        return error.InvalidName;
    }

    const cwd = Io.Dir.cwd();
    try ensureMonoRoot(io, cwd);

    const dest_rel = try std.fmt.allocPrint(allocator, "app/src/features/{s}", .{feature_name});
    defer allocator.free(dest_rel);

    if (!opts.force) {
        if (Io.Dir.openDir(cwd, io, dest_rel, .{})) |existing| {
            var d = existing;
            d.close(io);
            std.debug.print("planctl add: '{s}/' already exists (use --force to overwrite)\n", .{dest_rel});
            return error.FeatureExists;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    const arch = opts.arch_override orelse common.detectArch(io, cwd, "app/frontend");
    const tmpl: manifest.Template = switch (arch) {
        .hda => manifest.hda_mono,
        .spa => manifest.spa_mono,
    };

    const forms = try names.forms(allocator, feature_name);
    defer forms.deinit(allocator);

    const tasks_prefix = "app/src/features/tasks/";
    var written: usize = 0;
    for (tmpl.files) |entry| {
        if (!std.mem.startsWith(u8, entry.path, tasks_prefix)) continue;
        const sub = entry.path[tasks_prefix.len..];

        const sub_renamed = try names.substitute(allocator, sub, forms);
        defer allocator.free(sub_renamed);
        const out_rel = try std.fmt.allocPrint(allocator, "app/src/features/{s}/{s}", .{ feature_name, sub_renamed });
        defer allocator.free(out_rel);

        if (std.mem.lastIndexOfScalar(u8, out_rel, '/')) |sep| {
            try Io.Dir.createDirPath(cwd, io, out_rel[0..sep]);
        }

        const bytes = try names.substitute(allocator, entry.bytes, forms);
        defer allocator.free(bytes);

        try Io.Dir.writeFile(cwd, io, .{ .sub_path = out_rel, .data = bytes });
        written += 1;
    }

    if (written == 0) return error.TemplateMissing;

    try patchMain(allocator, io, cwd, feature_name);
    if (arch == .hda) {
        try patchAppZig(allocator, io, cwd, feature_name);
        try patchBuildZsx(allocator, io, cwd, feature_name);
    }

    std.debug.print(
        \\Added feature '{s}' to app/src/features/{s}/ ({d} files, arch={s}).
        \\
        \\Next steps:
        \\  cd app
        \\  zig build dev-build   # native dev binary
        \\  zig build run         # start the dev server
        \\
    , .{ feature_name, feature_name, written, @tagName(arch) });
}


fn ensureMonoRoot(io: Io, cwd: Io.Dir) !void {
    var features = Io.Dir.openDir(cwd, io, "app/src/features", .{}) catch {
        std.debug.print("planctl add: cwd is not a mono project root (no app/src/features/ dir found)\n", .{});
        return error.NotMonoProject;
    };
    features.close(io);

    if (Io.Dir.openDir(cwd, io, "app/services", .{})) |existing| {
        var d = existing;
        d.close(io);
        std.debug.print("planctl add: cwd looks like a micro project (app/services/ peer present); use `planctl add <name> --type service` instead\n", .{});
        return error.NotMonoProject;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
}

fn patchMain(allocator: Allocator, io: Io, cwd: Io.Dir, feature: []const u8) !void {
    const path = "app/src/main.zig";
    const src = patchers.readFile(allocator, io, cwd, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(src);

    const import_line = try std.fmt.allocPrint(allocator, "const {s}_routes = @import(\"features/{s}/routes.zig\");\n", .{ feature, feature });
    defer allocator.free(import_line);

    const register_line = try std.fmt.allocPrint(allocator, "    try {s}_routes.register(&app, &ctx);\n", .{feature});
    defer allocator.free(register_line);

    const step1 = try patchers.insertAfterLast(allocator, src, "_routes = @import(", import_line);
    defer allocator.free(step1);
    const step2 = try patchers.insertAfterLast(allocator, step1, "_routes.register(&app, &ctx)", register_line);
    defer allocator.free(step2);

    try patchers.writeFile(io, cwd, path, step2);
}

fn patchAppZig(allocator: Allocator, io: Io, cwd: Io.Dir, feature: []const u8) !void {
    const path = "app/src/app.zig";
    const src = patchers.readFile(allocator, io, cwd, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(src);

    const import_line = try std.fmt.allocPrint(allocator, "const {s}_routes = @import(\"features/{s}/routes.zig\");\n", .{ feature, feature });
    defer allocator.free(import_line);

    const register_line = try std.fmt.allocPrint(allocator, "    {s}_routes.register(&app, &ctx) catch return -1;\n", .{feature});
    defer allocator.free(register_line);

    const step1 = try patchers.insertAfterLast(allocator, src, "_routes = @import(", import_line);
    defer allocator.free(step1);
    const step2 = try patchers.insertAfterLast(allocator, step1, "_routes.register(&app, &ctx)", register_line);
    defer allocator.free(step2);

    try patchers.writeFile(io, cwd, path, step2);
}

fn patchBuildZsx(allocator: Allocator, io: Io, cwd: Io.Dir, feature: []const u8) !void {
    const path = "app/build.zig";
    const src = patchers.readFile(allocator, io, cwd, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(src);

    const clean_pair = try std.fmt.allocPrint(allocator,
        \\    const {s}_clean = b.addSystemCommand(&.{{ "planctl", "clean", "src/features/{s}/fragments/" }});
        \\    const {s}_preprocess = b.addSystemCommand(&.{{ "planctl", "src/features/{s}/zsx/", "src/features/{s}/fragments/" }});
        \\    {s}_preprocess.step.dependOn(&{s}_clean.step);
        \\
    , .{ feature, feature, feature, feature, feature, feature, feature });
    defer allocator.free(clean_pair);

    const wasm_dep = try std.fmt.allocPrint(allocator, "    wasm.step.dependOn(&{s}_preprocess.step);\n", .{feature});
    defer allocator.free(wasm_dep);

    const dev_dep = try std.fmt.allocPrint(allocator, "    dev_exe.step.dependOn(&{s}_preprocess.step);\n", .{feature});
    defer allocator.free(dev_dep);

    const step1 = try patchers.insertAfterLast(allocator, src, "_preprocess.step.dependOn(&", clean_pair);
    defer allocator.free(step1);
    const step2 = try patchers.insertAfterLast(allocator, step1, "wasm.step.dependOn(&", wasm_dep);
    defer allocator.free(step2);
    const step3 = try patchers.insertAfterLast(allocator, step2, "dev_exe.step.dependOn(&", dev_dep);
    defer allocator.free(step3);

    try patchers.writeFile(io, cwd, path, step3);
}
