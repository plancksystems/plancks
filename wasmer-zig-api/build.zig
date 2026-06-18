const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wasmer_dir_path = b.option([]const u8, "wasmer-dir", "Path to wasmer installation") orelse
    b.graph.environ_map.get("WASMER_DIR") orelse "/Users/kamlesh/.wasmer";
    const wasmer_lib_dir_path = b.pathJoin(&.{ wasmer_dir_path, "lib" });

    const wasmer_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasmer.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    wasmer_unit_tests.root_module.addLibraryPath(.{ .cwd_relative = wasmer_lib_dir_path });
    wasmer_unit_tests.root_module.linkSystemLibrary("wasmer", .{});

    const run_wasmer_unit_tests = b.addRunArtifact(wasmer_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_wasmer_unit_tests.step);

    const docs_step = b.step("docs", "Emit docs");
    const docs_obj = b.addObject(.{
        .name = "wasmer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasmer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs.step);
}
