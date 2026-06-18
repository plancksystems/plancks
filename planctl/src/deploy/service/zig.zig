const std = @import("std");
const Io = std.Io;
const DeployClient = @import("../client.zig").DeployClient;
const Profile = @import("../config.zig").Profile;

const app_meta = @import("../app_meta.zig");
const build_helper = @import("../build_helper.zig");
const yaml_util = @import("../yaml_util.zig");

const log = std.log.scoped(.deploy_service_zig);

pub fn run(allocator: std.mem.Allocator, io: Io, service_name: []const u8, profile: Profile) !void {

    for (profile.nodes) |node| {
        var client = DeployClient.init(allocator, io, node.server);

        std.debug.print("  Authenticating with {s}...\n", .{node.server});
        if (!try client.authenticate(node.uid, node.key)) {
            std.debug.print("Error: Authentication failed\n", .{});
            return error.AuthFailed;
        }

        const meta = try app_meta.loadFromCwd(allocator, io);
        const app_name = meta.name;
        const description = meta.description;

        std.debug.print("  Ensuring app '{s}' exists...\n", .{app_name});
        try client.ensureApp(app_name, description);

        const svc_dir = try std.fmt.allocPrint(allocator, "app/services/{s}", .{service_name});
        defer allocator.free(svc_dir);

        std.debug.print("  Building WASM in {s}...\n", .{svc_dir});
        const build_result = build_helper.runBuild(allocator, io, svc_dir, &.{"-Doptimize=ReleaseFast"}) catch {
            std.debug.print("Error: Failed to run zig build in {s}\n", .{svc_dir});
            return error.BuildFailed;
        };
        defer build_result.deinit(allocator);
        if (build_result.term == .exited and build_result.term.exited != 0) {
            std.debug.print("Error: Build failed\n{s}", .{build_result.stderr});
            return error.BuildFailed;
        }

        const wasm_path = try std.fmt.allocPrint(allocator, "{s}/zig-out/wasm/{s}.wasm", .{ svc_dir, service_name });
        defer allocator.free(wasm_path);
        const wasm_data = Io.Dir.readFileAlloc(.cwd(), io, wasm_path, allocator, .unlimited) catch {
            std.debug.print("Error: WASM file not found at {s}\n", .{wasm_path});
            return error.NoWasm;
        };
        defer allocator.free(wasm_data);

        const db_path = try std.fmt.allocPrint(allocator, "{s}/db.yaml", .{svc_dir});
        defer allocator.free(db_path);
        const db_yaml = Io.Dir.readFileAlloc(.cwd(), io, db_path, allocator, .unlimited) catch {
            std.debug.print("Error: {s} not found\n", .{db_path});
            return error.NoConfig;
        };
        defer allocator.free(db_yaml);

        const svc_path = try std.fmt.allocPrint(allocator, "{s}/service.yaml", .{svc_dir});
        defer allocator.free(svc_path);
        const service_yaml = Io.Dir.readFileAlloc(.cwd(), io, svc_path, allocator, .unlimited) catch {
            std.debug.print("Error: {s} not found\n", .{svc_path});
            return error.NoConfig;
        };
        defer allocator.free(service_yaml);

        const display_name = try yaml_util.readServiceName(allocator, db_yaml, service_name);
        defer allocator.free(display_name);

        const wasm_svc_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ app_name, display_name });
        defer allocator.free(wasm_svc_name);

        const service_yaml_rewritten = try yaml_util.rewriteName(allocator, service_yaml, wasm_svc_name);
        defer allocator.free(service_yaml_rewritten);

        std.debug.print("  Deploying service '{s}' under app '{s}' (display name: '{s}')...\n", .{ wasm_svc_name, app_name, display_name });
        const deploy_result = try client.deployService(app_name, wasm_svc_name, display_name, db_yaml, service_yaml_rewritten, node.uid, node.key);
        defer allocator.free(deploy_result);

        const already_exists = std.mem.indexOf(u8, deploy_result, "already exists") != null;
        if (std.mem.indexOf(u8, deploy_result, "\"success\":true") != null) {
            std.debug.print("  Service created\n", .{});
        } else if (already_exists) {
            std.debug.print("  Service already exists, updating WASM...\n", .{});
        } else {
            std.debug.print("  Deploy response: {s}\n", .{deploy_result});
        }

        std.debug.print("  Uploading WASM ({d} KB)...\n", .{wasm_data.len / 1024});
        try client.deployWasm(wasm_svc_name, app_name, wasm_data);

        if (Io.Dir.readFileAlloc(.cwd(), io, "Caddyfile", allocator, .unlimited)) |caddy| {
            defer allocator.free(caddy);
            std.debug.print("  Refreshing Caddyfile ({d} bytes)...\n", .{caddy.len});
            client.deployConfig(app_name, "Caddyfile", caddy) catch |err| {
                std.debug.print("  Warning: Caddyfile refresh failed: {}\n", .{err});
            };
        } else |_| {}

        std.debug.print("Done! Service '{s}' deployed with WASM to {s}\n", .{ service_name, node.server });
    }
}
