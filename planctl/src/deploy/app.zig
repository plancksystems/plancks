const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const DeployClient = @import("client.zig").DeployClient;
const deploy_config = @import("config.zig");
const app_meta = @import("app_meta.zig");
const build_helper = @import("build_helper.zig");
const Profile = @import("config.zig").Profile;

const log = std.log.scoped(.deploy_app);

pub fn run(allocator: std.mem.Allocator, io: Io, profile: Profile) !void {


    const meta = app_meta.loadFromCwd(allocator, io) catch |err| {
        if (err == error.NoAppYaml) {
            std.debug.print("Create one with: planctl init --type app <name>\n", .{});
        }
        return err;
    };
    const name = meta.name;
    const description = meta.description;

    for (profile.nodes) |node| {
        var client = DeployClient.init(allocator, io, node.server);

        std.debug.print("  Authenticating with {s}...\n", .{node.server});
        if (!try client.authenticate(node.uid, node.key)) {
            std.debug.print("Error: Authentication failed\n", .{});
            return error.AuthFailed;
        }

        std.debug.print("  Ensuring app '{s}' exists...\n", .{name});
        try client.ensureApp(name, description);

        std.debug.print("  Building app (zig build in ./app/)...\n", .{});
        const build_result = build_helper.runBuild(allocator, io, "app", &.{"-Doptimize=ReleaseFast"}) catch {
            std.debug.print("Error: Failed to run zig build in app/\n", .{});
            return error.BuildFailed;
        };
        defer build_result.deinit(allocator);
        if (build_result.term == .exited and build_result.term.exited != 0) {
            std.debug.print("Error: app build failed\n{s}", .{build_result.stderr});
            return error.BuildFailed;
        }

        const exe_ext = if (comptime builtin.os.tag == .windows) ".exe" else "";
        const bin_path = try std.fmt.allocPrint(allocator, "app{s}zig-out{s}bin{s}{s}{s}", .{ std.fs.path.sep_str, std.fs.path.sep_str, std.fs.path.sep_str, name, exe_ext });
        defer allocator.free(bin_path);

        const binary = Io.Dir.readFileAlloc(.cwd(), io, bin_path, allocator, .unlimited) catch {
            std.debug.print("Error: Binary not found at {s}\n", .{bin_path});
            return error.NoBinary;
        };
        defer allocator.free(binary);

        std.debug.print("  Uploading binary ({d} KB)...\n", .{binary.len / 1024});
        try client.deployBinary(name, binary);

        const config_files = [_][]const u8{ "app.yaml", "Caddyfile" };
        for (config_files) |fname| {
            const data = Io.Dir.readFileAlloc(.cwd(), io, fname, allocator, .unlimited) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => {
                    std.debug.print("  Warning: could not read {s}: {}\n", .{ fname, err });
                    continue;
                },
            };
            defer allocator.free(data);

            std.debug.print("  Uploading {s} ({d} bytes)...\n", .{ fname, data.len });
            client.deployConfig(name, fname, data) catch |err| {
                std.debug.print("  Warning: deploy-config failed for {s}: {}\n", .{ fname, err });
            };
        }

        var public_dir = Io.Dir.openDir(.cwd(), io, "app/public", .{ .iterate = true }) catch {
            std.debug.print("  No app/public/ directory, skipping static files\n", .{});
            std.debug.print("Done! App '{s}' deployed.\n", .{name});
            return;
        };
        defer public_dir.close(io);

        var file_count: usize = 0;
        var walker = try public_dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;

            const rel_path = entry.path;
            const full_path = try std.fmt.allocPrint(allocator, "app/public/{s}", .{rel_path});
            defer allocator.free(full_path);

            const data = Io.Dir.readFileAlloc(.cwd(), io, full_path, allocator, .unlimited) catch |err| {
                std.debug.print("  Warning: could not read {s}: {}\n", .{ full_path, err });
                continue;
            };
            defer allocator.free(data);

            std.debug.print("  Uploading {s} ({d} bytes)...\n", .{ rel_path, data.len });
            try client.deployFile(name, rel_path, data);
            file_count += 1;
        }

        std.debug.print("  Starting shell app...\n", .{});
        const lifecycle_resp = client.appLifecycle(name, "restart") catch {
            std.debug.print("  Warning: could not start shell app (lifecycle endpoint not available)\n", .{});
            std.debug.print("Done! App '{s}' deployed to {s} ({d} static files)\n", .{ name, node.server, file_count });
            return;
        };
        defer allocator.free(lifecycle_resp);
        std.debug.print("Done! App '{s}' deployed and started on {s} ({d} static files)\n", .{ name, node.server, file_count });
    }
    
}
