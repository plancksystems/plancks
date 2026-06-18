const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const deps = wireDeps(b, target, optimize);

    const home = b.graph.environ_map.get("HOME") orelse
        b.graph.environ_map.get("USERPROFILE") orelse "";
    const default_wasmer_dir = b.fmt("{s}/.wasmer", .{home});
    const wasmer_dir = b.option(
        []const u8,
        "wasmer-dir",
        "Path to wasmer installation (expects lib/libwasmer.a inside)",
    ) orelse b.graph.environ_map.get("WASMER_DIR") orelse default_wasmer_dir;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    wireExeImports(exe_mod, deps);
    wireWasmer(exe_mod, b, wasmer_dir);

    const exe = b.addExecutable(.{
        .name = "planck",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    wireExeImports(test_mod, deps);
    wireWasmer(test_mod, b, wasmer_dir);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn wireExeImports(mod: *std.Build.Module, deps: Deps) void {
    mod.link_libc = true;
    mod.addImport("utils", deps.utils);
    mod.addImport("yaml", deps.yaml);
    mod.addImport("proto", deps.proto);
    mod.addImport("bson", deps.bson);
    mod.addImport("tls", deps.tls);
    mod.addImport("wasmer", deps.wasmer);
    mod.addImport("schnell", deps.schnell);
}

fn wireWasmer(mod: *std.Build.Module, b: *std.Build, wasmer_dir: []const u8) void {
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ wasmer_dir, "lib" }) });
    mod.linkSystemLibrary("wasmer", .{ .preferred_link_mode = .dynamic });

    const tag = mod.resolved_target.?.result.os.tag;
    switch (tag) {
        .linux => {
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("m", .{});
            mod.linkSystemLibrary("rt", .{});
            mod.linkSystemLibrary("gcc_s", .{});
        },
        .macos => {
            if (b.graph.environ_map.get("SDKROOT")) |sdk| {
                mod.addSystemFrameworkPath(.{
                    .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}),
                });
                mod.addSystemIncludePath(.{
                    .cwd_relative = b.fmt("{s}/usr/include", .{sdk}),
                });
                mod.addLibraryPath(.{
                    .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}),
                });
            }
            mod.linkFramework("Security", .{});
            mod.linkFramework("CoreFoundation", .{});
            mod.linkFramework("SystemConfiguration", .{});
        },
        .windows => {
            for ([_][]const u8{
                "ws2_32",   "advapi32", "bcrypt",  "kernel32",
                "userenv",  "ntdll",    "secur32", "crypt32",
                "iphlpapi", "pdh",      "psapi",   "dbghelp",
                "ole32",    "oleaut32", "shell32", "user32",
                "rpcrt4",
            }) |lib| mod.linkSystemLibrary(lib, .{});
        },
        else => {},
    }
}

const Deps = struct {
    bson: *std.Build.Module,
    utils: *std.Build.Module,
    tls: *std.Build.Module,
    proto: *std.Build.Module,
    yaml: *std.Build.Module,
    wasmer: *std.Build.Module,
    schnell: *std.Build.Module,
};

fn wireDeps(b: *std.Build, target: anytype, optimize: anytype) Deps {
    const bson_dep = b.dependency("bson", .{});
    const bson = b.createModule(.{
        .root_source_file = bson_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const utils_dep = b.dependency("utils", .{});
    const utils = b.createModule(.{
        .root_source_file = utils_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tls_dep = b.dependency("tls", .{});
    const tls = b.createModule(.{
        .root_source_file = tls_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const yaml_dep = b.dependency("yaml", .{});
    const yaml = b.createModule(.{
        .root_source_file = yaml_dep.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const wasmer_dep = b.dependency("wasmer", .{});
    const wasmer = b.createModule(.{
        .root_source_file = wasmer_dep.path("src/wasmer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const proto_dep = b.dependency("proto", .{});
    const proto = b.createModule(.{
        .root_source_file = proto_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    proto.addImport("utils", utils);

    const schnell_dep = b.dependency("schnell", .{});
    const planck_dep = schnell_dep.builder.dependency("planck_zig_client", .{});
    const planck_zig_client = b.createModule(.{
        .root_source_file = planck_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    planck_zig_client.addImport("bson", bson);
    planck_zig_client.addImport("utils", utils);
    planck_zig_client.addImport("tls", tls);
    planck_zig_client.addImport("proto", proto);

    const schnell = b.createModule(.{
        .root_source_file = schnell_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    schnell.addImport("bson", bson);
    schnell.addImport("utils", utils);
    schnell.addImport("tls", tls);
    schnell.addImport("proto", proto);
    schnell.addImport("planck_zig_client", planck_zig_client);

    return .{
        .bson = bson,
        .utils = utils,
        .tls = tls,
        .proto = proto,
        .yaml = yaml,
        .wasmer = wasmer,
        .schnell = schnell,
    };
}
