const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fragments_clean = b.addSystemCommand(&.{ "planctl", "clean", "src/fragments/" });
    const fragments_preprocess = b.addSystemCommand(&.{ "planctl", "src/zsx/", "src/fragments/" });
    fragments_preprocess.step.dependOn(&fragments_clean.step);

    const bson = b.createModule(.{
        .root_source_file = b.dependency("bson", .{}).path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const utils = b.createModule(.{
        .root_source_file = b.dependency("utils", .{}).path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tls = b.createModule(.{
        .root_source_file = b.dependency("tls", .{}).path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const proto = b.createModule(.{
        .root_source_file = b.dependency("proto", .{}).path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    proto.addImport("utils", utils);

    const planck_zig_client = b.createModule(.{
        .root_source_file = b.dependency("planck_zig_client", .{}).path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    planck_zig_client.addImport("tls", tls);
    planck_zig_client.addImport("bson", bson);
    planck_zig_client.addImport("utils", utils);
    planck_zig_client.addImport("proto", proto);

    const schnell = b.createModule(.{
        .root_source_file = b.dependency("schnell", .{}).path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    schnell.addImport("bson", bson);
    schnell.addImport("utils", utils);
    schnell.addImport("tls", tls);
    schnell.addImport("proto", proto);
    schnell.addImport("planck_zig_client", planck_zig_client);

    const web = b.createModule(.{
        .root_source_file = b.dependency("schnell", .{}).path("src/web/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    web.addImport("bson", bson);
    web.addImport("schnell", schnell);

    const ssehub = b.createModule(.{
        .root_source_file = b.dependency("ssehub", .{}).path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ssehub.addImport("planck", planck_zig_client);
    ssehub.addImport("utils", utils);

    const exe = b.addExecutable(.{
        .name = "__PROJECT_NAME___sse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "schnell", .module = schnell },
                .{ .name = "ssehub", .module = ssehub },
                .{ .name = "utils", .module = utils },
                .{ .name = "bson", .module = bson },
                .{ .name = "web", .module = web },
                .{ .name = "planck", .module = planck_zig_client },
            },
        }),
    });
    exe.step.dependOn(&fragments_preprocess.step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the __PROJECT_NAME__ SSE service");
    run_step.dependOn(&run_cmd.step);
}
