
const std = @import("std");
const Io = std.Io;
const DeployClient = @import("client.zig").DeployClient;
const Profile = @import("config.zig").Profile;
const app_meta = @import("app_meta.zig");
const yaml_util = @import("yaml_util.zig");
const build_helper = @import("build_helper.zig");

const log = std.log.scoped(.deploy_mono);

pub fn run(allocator: std.mem.Allocator, io: Io, profile: Profile) !void {
    const meta = app_meta.loadFromCwd(allocator, io) catch |err| {
        if (err == error.NoAppYaml) {
            std.debug.print("Create a project first: planctl new <name> --type <hda|spa> --arch mono\n", .{});
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

        std.debug.print("  Building app (zig build -Doptimize=ReleaseFast in ./app/)...\n", .{});
        const build_result = build_helper.runBuild(allocator, io, "app", &.{"-Doptimize=ReleaseFast"}) catch {
            std.debug.print("Error: Failed to run zig build in app/\n", .{});
            return error.BuildFailed;
        };
        defer build_result.deinit(allocator);
        if (build_result.term == .exited and build_result.term.exited != 0) {
            std.debug.print("Error: app build failed\n{s}", .{build_result.stderr});
            return error.BuildFailed;
        }

        const wasm_path = try std.fmt.allocPrint(allocator, "app/zig-out/wasm/{s}.wasm", .{name});
        defer allocator.free(wasm_path);
        const wasm = Io.Dir.readFileAlloc(.cwd(), io, wasm_path, allocator, .unlimited) catch {
            std.debug.print("Error: WASM not found at {s} — confirm `zig build` produced it\n", .{wasm_path});
            return error.NoWasm;
        };
        defer allocator.free(wasm);

        const db_yaml = Io.Dir.readFileAlloc(.cwd(), io, "app/db.yaml", allocator, .unlimited) catch {
            std.debug.print("Error: app/db.yaml not found\n", .{});
            return error.NoConfig;
        };
        defer allocator.free(db_yaml);

        const service_yaml_raw = Io.Dir.readFileAlloc(.cwd(), io, "app/service.yaml", allocator, .unlimited) catch {
            std.debug.print("Error: app/service.yaml not found\n", .{});
            return error.NoConfig;
        };
        defer allocator.free(service_yaml_raw);

        const service_name = try yaml_util.readServiceName(allocator, db_yaml, "db");
        defer allocator.free(service_name);

        const wasm_svc_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ name, service_name });
        defer allocator.free(wasm_svc_name);

        const service_yaml = try yaml_util.rewriteName(allocator, service_yaml_raw, wasm_svc_name);
        defer allocator.free(service_yaml);

        std.debug.print("  Deploying service '{s}' under app '{s}' (display name: '{s}')...\n", .{ wasm_svc_name, name, service_name });
        const deploy_result = client.deployService(name, wasm_svc_name, service_name, db_yaml, service_yaml, node.uid, node.key) catch |err| {
            std.debug.print("Error: deployService failed: {}\n", .{err});
            return err;
        };
        defer allocator.free(deploy_result);

        const already_exists = std.mem.indexOf(u8, deploy_result, "already exists") != null;
        if (std.mem.indexOf(u8, deploy_result, "\"success\":true") != null) {
            std.debug.print("  Service created\n", .{});
        } else if (already_exists) {
            std.debug.print("  Service already exists, will update WASM\n", .{});
        } else {
            std.debug.print("  Deploy response: {s}\n", .{deploy_result});
        }

        std.debug.print("  Uploading WASM ({d} KB)...\n", .{wasm.len / 1024});
        try client.deployWasm(wasm_svc_name, name, wasm);

        const file_count = uploadPublic(allocator, io, &client, name) catch |err| switch (err) {
            error.FileNotFound => 0,
            else => return err,
        };

        const sse_deployed = deploySseIfPresent(allocator, io, &client, name) catch |err| switch (err) {
            error.NoSseSubproject => false,
            else => return err,
        };

        std.debug.print(
            "Done! Mono app '{s}' deployed to {s} ({d} static files{s})\n",
            .{ name, node.server, file_count, if (sse_deployed) ", sse service" else "" },
        );
    }
}

pub fn deploySseStandalone(allocator: std.mem.Allocator, io: Io, profile: Profile) !void {
    const meta = app_meta.loadFromCwd(allocator, io) catch |err| {
        if (err == error.NoAppYaml) {
            std.debug.print("Error: app.yaml not found — run from project root\n", .{});
        }
        return err;
    };
    const name = meta.name;

    for (profile.nodes) |node| {
        var client = DeployClient.init(allocator, io, node.server);

        std.debug.print("  Authenticating with {s}...\n", .{node.server});
        if (!try client.authenticate(node.uid, node.key)) {
            std.debug.print("Error: Authentication failed\n", .{});
            return error.AuthFailed;
        }

        _ = deploySseIfPresent(allocator, io, &client, name) catch |err| switch (err) {
            error.NoSseSubproject => {
                std.debug.print("  No ./sse/ subproject — skipping SSE deploy\n", .{});
                return;
            },
            else => return err,
        };
    }
}

fn deploySseIfPresent(allocator: std.mem.Allocator, io: Io, client: *DeployClient, app_name: []const u8) !bool {
    Io.Dir.access(.cwd(), io, "sse/build.zig", .{ .read = true }) catch return error.NoSseSubproject;

    std.debug.print("  Building sse subproject (zig build -Doptimize=ReleaseFast in ./sse/)...\n", .{});
    const sse_build = build_helper.runBuild(allocator, io, "sse", &.{"-Doptimize=ReleaseFast"}) catch {
        std.debug.print("Error: failed to run sse zig build\n", .{});
        return error.BuildFailed;
    };
    defer sse_build.deinit(allocator);
    if (sse_build.term == .exited and sse_build.term.exited != 0) {
        std.debug.print("Error: sse build failed\n{s}", .{sse_build.stderr});
        return error.BuildFailed;
    }

    const sse_yaml_for_name = Io.Dir.readFileAlloc(.cwd(), io, "sse/sse.yaml", allocator, .unlimited) catch |err| {
        std.debug.print("Error: sse/sse.yaml not readable: {s}\n", .{@errorName(err)});
        return error.NoSseConfig;
    };
    defer allocator.free(sse_yaml_for_name);

    const display_name = try yaml_util.readServiceName(allocator, sse_yaml_for_name, "sse");
    defer allocator.free(display_name);

    const svc_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ app_name, display_name });
    defer allocator.free(svc_name);

    const binary_path = (try findSingleFile(allocator, io, "sse/zig-out/bin")) orelse {
        std.debug.print(
            "Error: no sse binary in sse/zig-out/bin/ — confirm `zig build` in sse/ produced one\n",
            .{},
        );
        return error.NoSseBinary;
    };
    defer allocator.free(binary_path);

    const binary = Io.Dir.readFileAlloc(.cwd(), io, binary_path, allocator, .unlimited) catch |err| {
        std.debug.print("Error: sse binary read failed at {s}: {s}\n", .{ binary_path, @errorName(err) });
        return error.NoSseBinary;
    };
    defer allocator.free(binary);

    const sse_yaml = sse_yaml_for_name;

    std.debug.print("  Deploying sse service '{s}' under app '{s}' (display name: '{s}', {d} KB)...\n", .{ svc_name, app_name, display_name, binary.len / 1024 });
    const sse_resp = client.deploySseService(app_name, svc_name, display_name, sse_yaml, binary) catch |err| {
        std.debug.print("Error: deploySseService failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(sse_resp);

    if (std.mem.indexOf(u8, sse_resp, "\"success\":true") != null) {
        std.debug.print("  SSE service deployed\n", .{});
    } else {
        std.debug.print("  SSE deploy response: {s}\n", .{sse_resp});
    }
    return true;
}

fn findSingleFile(allocator: std.mem.Allocator, io: Io, dir_path: []const u8) !?[]u8 {
    var d = Io.Dir.openDir(.cwd(), io, dir_path, .{ .iterate = true }) catch return null;
    defer d.close(io);

    var picked: ?[]u8 = null;
    var count: usize = 0;
    var iter = d.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        count += 1;
        if (picked == null) {
            picked = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        }
    }
    if (count > 1) {
        std.debug.print("  Warning: multiple files in {s}/, picking '{s}'\n", .{ dir_path, picked.? });
    }
    return picked;
}

fn uploadPublic(allocator: std.mem.Allocator, io: Io, client: *DeployClient, name: []const u8) !usize {
    var public_dir = Io.Dir.openDir(.cwd(), io, "app/public", .{ .iterate = true }) catch {
        std.debug.print("  No app/public/ directory, skipping static files\n", .{});
        return 0;
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
    return file_count;
}

