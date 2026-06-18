const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const deps = wireDeps(b, target, optimize);

    const npm_install = b.addSystemCommand(&.{ "npm", "install", "--no-audit", "--no-fund" });
    npm_install.setCwd(b.path("frontend"));
    const npm_build = b.addSystemCommand(&.{ "npm", "run", "build" });
    npm_build.setCwd(b.path("frontend"));
    npm_build.step.dependOn(&npm_install.step);

    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm = b.addExecutable(.{
        .name = "__PROJECT_NAME__",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "web", .module = deps.web },
                .{ .name = "planck", .module = deps.planck_zig_client },
            },
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const wasm_install = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });

    const dev_exe = b.addExecutable(.{
        .name = "__PROJECT_NAME___dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "web", .module = deps.web },
                .{ .name = "schnell", .module = deps.schnell },
                .{ .name = "planck", .module = deps.planck_zig_client },
            },
        }),
    });
    const dev_install = b.addInstallArtifact(dev_exe, .{});
    const run_dev = b.addRunArtifact(dev_exe);
    run_dev.step.dependOn(&dev_install.step);

    const full_step = b.step("all", "Build WASM + frontend bundle (deploy-ready)");
    full_step.dependOn(&wasm_install.step);
    full_step.dependOn(&npm_build.step);

    const dev_build = b.step("dev-build", "Build the native dev server only (skip npm + wasm)");
    dev_build.dependOn(&dev_install.step);

    b.step("wasm", "Build WASM bundle").dependOn(&wasm_install.step);
    b.step("dev", "Run native dev server (no frontend rebuild)").dependOn(&run_dev.step);

    b.default_step = full_step;
}

const Deps = struct {
    bson: *std.Build.Module,
    utils: *std.Build.Module,
    tls: *std.Build.Module,
    proto: *std.Build.Module,
    planck_zig_client: *std.Build.Module,
    schnell: *std.Build.Module,
    web: *std.Build.Module,
};

fn wireDeps(b: *std.Build, target: anytype, optimize: anytype) Deps {
    const bson_dep = b.dependency("bson", .{});
    const bson = b.createModule(.{ .root_source_file = bson_dep.path("src/root.zig"), .target = target, .optimize = optimize });

    const utils_dep = b.dependency("utils", .{});
    const utils = b.createModule(.{ .root_source_file = utils_dep.path("src/root.zig"), .target = target, .optimize = optimize });

    const tls_dep = b.dependency("tls", .{});
    const tls = b.createModule(.{ .root_source_file = tls_dep.path("src/root.zig"), .target = target, .optimize = optimize });

    const proto_dep = b.dependency("proto", .{});
    const proto = b.createModule(.{ .root_source_file = proto_dep.path("src/root.zig"), .target = target, .optimize = optimize });
    proto.addImport("utils", utils);

    const planck_dep = b.dependency("planck_zig_client", .{});
    const planck_zig_client = b.createModule(.{ .root_source_file = planck_dep.path("src/root.zig"), .target = target, .optimize = optimize });
    planck_zig_client.addImport("tls", tls);
    planck_zig_client.addImport("bson", bson);
    planck_zig_client.addImport("utils", utils);
    planck_zig_client.addImport("proto", proto);

    const schnell_dep = b.dependency("schnell", .{});
    const schnell = b.createModule(.{ .root_source_file = schnell_dep.path("src/root.zig"), .target = target, .optimize = optimize });
    schnell.addImport("bson", bson);
    schnell.addImport("utils", utils);
    schnell.addImport("tls", tls);
    schnell.addImport("proto", proto);
    schnell.addImport("planck_zig_client", planck_zig_client);

    const web = b.createModule(.{ .root_source_file = schnell_dep.path("src/web/root.zig"), .target = target, .optimize = optimize });
    web.addImport("bson", bson);
    web.addImport("schnell", schnell);

    return .{ .bson = bson, .utils = utils, .tls = tls, .proto = proto, .planck_zig_client = planck_zig_client, .schnell = schnell, .web = web };
}
