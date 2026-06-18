const std = @import("std");
const common = @import("../common.zig");
const writeFile = common.writeFile;

pub fn create(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const pkg_name = common.pkgName(name);
    var proj_dir = try common.createShellDirs(io, name);
    defer proj_dir.close(io);

    const dirs = [_][]const u8{
        "src/api",
        "src/zsx",
        "src/ui",
        "public",
        "services",
    };
    for (dirs) |d| {
        std.Io.Dir.createDirPath(proj_dir, io, d) catch |e| {
            if (e != error.PathAlreadyExists) return e;
        };
    }

    {
        const content = try std.fmt.allocPrint(allocator,
            \\.{{
            \\    .name = .{s},
            \\    .version = "0.1.0",
            \\    .fingerprint = 0x0000000000000000,
            \\    .dependencies = .{{
            \\        .schnell = .{{
            \\            .url = "https://github.com/plancksystems/schnell/archive/refs/tags/v0.1.0.tar.gz",
            \\            .hash = "schnell-0.1.0-qlxSCpedBgCm_KfPDKoG1coC0FImc_GupGaiZQ87swfH",
            \\        }},
            \\    }},
            \\    .paths = .{{ "build.zig", "build.zig.zon", "src" }},
            \\}}
            \\
        , .{pkg_name});
        try writeFile(proj_dir, io, "build.zig.zon", content);
    }

    {
        const content = try std.fmt.allocPrint(allocator,
            \\const std = @import("std");
            \\
            \\pub fn build(b: *std.Build) void {{
            \\    const target = b.standardTargetOptions(.{{}});
            \\    const optimize = b.standardOptimizeOption(.{{}});
            \\
            \\    const schnell_dep = b.dependency("schnell", .{{ .target = target, .optimize = optimize }});
            \\    const schnell_mod = schnell_dep.module("schnell");
            \\
            \\    // PreProcess .zsx → .zig 
            \\    // `planctl` is expected on PATH (installed via the planck
            \\    // installer or `zig build install` from the planctl repo).
            \\    const clean_ui = b.addSystemCommand(&.{{ "planctl", "clean", "src/ui/" }});
            \\    const preprocess_ui = b.addSystemCommand(&.{{ "planctl", "src/zsx/", "src/ui/" }});
            \\    preprocess_ui.step.dependOn(&clean_ui.step);
            \\
            \\    // Native Shell Server 
            \\    const exe = b.addExecutable(.{{
            \\        .name = "{s}",
            \\        .root_module = b.createModule(.{{
            \\            .root_source_file = b.path("src/main.zig"),
            \\            .target = target,
            \\            .optimize = optimize,
            \\            .imports = &.{{
            \\                .{{ .name = "schnell", .module = schnell_mod }},
            \\            }},
            \\        }}),
            \\    }});
            \\    exe.step.dependOn(&preprocess_ui.step);
            \\    b.installArtifact(exe);
            \\
            \\    const run = b.addRunArtifact(exe);
            \\    run.step.dependOn(b.getInstallStep());
            \\    b.step("run", "Run shell server").dependOn(&run.step);
            \\    b.default_step = &b.addInstallArtifact(exe, .{{}}).step;
            \\}}
            \\
        , .{pkg_name});
        try writeFile(proj_dir, io, "build.zig", content);
    }

    {
        try writeFile(proj_dir, io, "src/main.zig",
            \\const std = @import("std");
            \\const schnell = @import("schnell");
            \\const example = @import("api/example.zig");
            \\
            \\pub fn main() !void {
            \\    const allocator = std.heap.smp_allocator;
            \\    var threaded: std.Io.Threaded = .init(allocator, .{});
            \\    defer threaded.deinit();
            \\    const io = threaded.io();
            \\
            \\    var app = try schnell.App.init(allocator, .{
            \\        .port = 8000,
            \\        .static_dir = "public",
            \\    });
            \\    defer app.deinit();
            \\
            \\    var handler: example.ExampleHandler = .{};
            \\    try app.route(example.ExampleHandler, example.EmptyParams, null, .get, "/api/status", &handler, null);
            \\
            \\    std.debug.print("Shell running on http://127.0.0.1:8000\n", .{});
            \\    try app.run(io);
            \\}
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "src/api/example.zig",
            \\const std = @import("std");
            \\const schnell = @import("schnell");
            \\
            \\pub const EmptyParams = struct {};
            \\
            \\pub const ExampleHandler = struct {
            \\    pub fn handle(self: *ExampleHandler, allocator: std.mem.Allocator, request: *anyopaque) ![]const u8 {
            \\        _ = self;
            \\        _ = request;
            \\        // Example: call external API via schnell.Client
            \\        // var resp = try schnell.Client.get(allocator, io, "https://api.example.com/status");
            \\        // defer resp.deinit();
            \\        return try allocator.dupe(u8, "<span>OK</span>");
            \\    }
            \\};
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "public/index.html",
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\    <meta charset="UTF-8" />
            \\    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            \\    <title>Shell App</title>
            \\    <link href="index.css" rel="stylesheet" />
            \\    <script src="https://unpkg.com/htmx.org@2.0.4"></script>
            \\    <script src="https://unpkg.com/htmx-ext-sse@2.2.2/sse.js"></script>
            \\</head>
            \\<body>
            \\    <h1>Shell App</h1>
            \\    <p>Edit src/api/ handlers and src/zsx/ templates.</p>
            \\    <p>Create WASM services in services/ folder.</p>
            \\</body>
            \\</html>
            \\
        );
    }

    try writeFile(proj_dir, io, "public/index.css", "/* Generated by: tailwindcss -i input.css -o public/index.css --watch */\n");

    {
        try writeFile(proj_dir, io, "tailwind.config.js",
            \\/** @type {import('tailwindcss').Config} */
            \\module.exports = {
            \\  content: [
            \\    "./src/zsx/**/*.zsx",
            \\    "./src/ui/**/*.zig",
            \\    "./services/*/src/zsx/**/*.zsx",
            \\    "./services/*/src/ui/**/*.zig",
            \\    "./public/**/*.html",
            \\  ],
            \\  theme: {
            \\    extend: {},
            \\  },
            \\  plugins: [],
            \\}
            \\
        );
    }

    {
        try writeFile(proj_dir, io, "input.css",
            \\@tailwind base;
            \\@tailwind components;
            \\@tailwind utilities;
            \\
        );
    }

    try writeFile(proj_dir, io, "src/ui/.gitkeep", "");
    try writeFile(proj_dir, io, "services/.gitkeep", "");

    std.debug.print(
        \\
        \\Created shell project: {s}
        \\
        \\  {s}/
        \\    build.zig
        \\    build.zig.zon
        \\    tailwind.config.js
        \\    input.css
        \\    src/
        \\      main.zig                   <- shell server (schnell.App + routes)
        \\      api/
        \\        example.zig              <- example handler with schnell.Client
        \\      zsx/                       <- .zsx templates
        \\      ui/                        <- auto-generated from zsx/
        \\    public/
        \\      index.html
        \\      index.css                  <- Tailwind output
        \\    services/                    <- WASM apps (planctl init orders, etc.)
        \\
        \\Develop:
        \\  cd {s}
        \\  tailwindcss -i input.css -o public/index.css --watch
        \\  zig build run
        \\
    , .{ name, name, name });
}
