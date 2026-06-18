const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const deps = wireDeps(b, target, optimize);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.linkSystemLibrary("c", .{});

    exe_mod.addImport("schnell", deps.schnell);
    exe_mod.addImport("planck", deps.planck);
    exe_mod.addImport("bson", deps.bson);
    exe_mod.addImport("yaml", deps.yaml);
    exe_mod.addImport("utils", deps.utils);
    exe_mod.addImport("build_options", build_options.createModule());

    exe_mod.link_libc = true;

    if (target.result.os.tag == .windows) {
        exe_mod.linkSystemLibrary("ws2_32", .{});
    }

    const exe = b.addExecutable(.{
        .name = "workbench",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the workbench");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}

const Deps = struct {
    bson: *std.Build.Module,
    utils: *std.Build.Module,
    tls: *std.Build.Module,
    proto: *std.Build.Module,
    planck: *std.Build.Module,
    schnell: *std.Build.Module,
    yaml: *std.Build.Module,
};

fn wireDeps(b: *std.Build, target: anytype, optimize: anytype) Deps {
    const bson_dep = b.dependency("bson", .{});
    const bson = b.createModule(.{
        .root_source_file = bson_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const yaml_dep = b.dependency("yaml", .{});
    const yaml = b.createModule(.{
        .root_source_file = yaml_dep.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const utils_dep = b.dependency("utils", .{});
    const utils = b.createModule(.{
        .root_source_file = utils_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const tls_dep = b.dependency("tls", .{});
    const tls = b.createModule(.{
        .root_source_file = tls_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const proto_dep = b.dependency("proto", .{});
    const proto = b.createModule(.{
        .root_source_file = proto_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    proto.addImport("utils", utils);

    const planck_dep = b.dependency("planck_zig_client", .{});
    const planck = b.createModule(.{
        .root_source_file = planck_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    planck.addImport("bson", bson);
    planck.addImport("utils", utils);
    planck.addImport("tls", tls);
    planck.addImport("proto", proto);

    const schnell_dep = b.dependency("schnell", .{});
    const schnell = b.createModule(.{
        .root_source_file = schnell_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    schnell.addImport("bson", bson);
    schnell.addImport("utils", utils);
    schnell.addImport("tls", tls);
    schnell.addImport("proto", proto);
    schnell.addImport("planck_zig_client", planck);

    return .{
        .bson = bson,
        .utils = utils,
        .tls = tls,
        .proto = proto,
        .planck = planck,
        .schnell = schnell,
        .yaml = yaml,
    };
}
