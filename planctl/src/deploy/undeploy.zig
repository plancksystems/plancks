const std = @import("std");
const Io = std.Io;
const DeployClient = @import("client.zig").DeployClient;
const deploy_config = @import("config.zig");
const app_meta = @import("app_meta.zig");
const Profile = @import("config.zig").Profile;

const log = std.log.scoped(.undeploy);

pub fn runService(allocator: std.mem.Allocator, io: Io, service_name: []const u8, profile: Profile, force: bool) !void {
    std.debug.print("planctl undeploy --service {s}\n", .{service_name});

    const meta = try app_meta.loadFromCwd(allocator, io);

    for (profile.nodes) |node| {
        const prompt = try std.fmt.allocPrint(
            allocator,
            "This will undeploy service '{s}' from app '{s}' on {s}.",
            .{ service_name, meta.name, node.server },
        );
        defer allocator.free(prompt);
        if (!force and !try confirm(io, prompt)) {
            std.debug.print("Aborted.\n", .{});
            return;
        }

        var client = DeployClient.init(allocator, io, node.server);
        try authenticate(&client, node.uid, node.key);

        try undeployOneService(&client, meta.name, service_name);
        std.debug.print("Done! Service '{s}' undeployed.\n", .{service_name});
    }
}

pub fn runApp(allocator: std.mem.Allocator, io: Io, profile: Profile, force: bool) !void {
    std.debug.print("planctl undeploy --app\n", .{});

    const meta = try app_meta.loadFromCwd(allocator, io);

    for (profile.nodes) |node| {
        const prompt = try std.fmt.allocPrint(
            allocator,
            "This will delete app '{s}' from {s} (services must already be undeployed).",
            .{ meta.name, node.server },
        );
        defer allocator.free(prompt);
        if (!force and !try confirm(io, prompt)) {
            std.debug.print("Aborted.\n", .{});
            return;
        }

        var client = DeployClient.init(allocator, io, node.server);
        try authenticate(&client, node.uid, node.key);

        try deleteOneApp(&client, meta.name);
        std.debug.print("Done! App '{s}' deleted.\n", .{meta.name});
    }
}

pub fn runAll(allocator: std.mem.Allocator, io: Io, profile: Profile, force: bool) !void {
    std.debug.print("planctl undeploy --all\n", .{});

    const meta = try app_meta.loadFromCwd(allocator, io);

    for (profile.nodes) |node| {
        var svc_names: std.ArrayList([]const u8) = .empty;
        defer {
            for (svc_names.items) |n| allocator.free(n);
            svc_names.deinit(allocator);
        }

        var svc_dir = Io.Dir.openDir(.cwd(), io, "services", .{ .iterate = true }) catch {
            std.debug.print("No services/ directory found; only deleting the app.\n", .{});

            const prompt = try std.fmt.allocPrint(
                allocator,
                "This will delete app '{s}' from {s}.",
                .{ meta.name, node.server },
            );
            defer allocator.free(prompt);
            if (!force and !try confirm(io, prompt)) {
                std.debug.print("Aborted.\n", .{});
                return;
            }

            var client = DeployClient.init(allocator, io, node.server);
            try authenticate(&client, node.uid, node.key);
            try deleteOneApp(&client, meta.name);
            return;
        };
        defer svc_dir.close(io);

        var iter = svc_dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            try svc_names.append(allocator, try allocator.dupe(u8, entry.name));
        }

        const prompt = try std.fmt.allocPrint(
            allocator,
            "This will undeploy {d} service(s) and delete app '{s}' from {s}.",
            .{ svc_names.items.len, meta.name, node.server },
        );
        defer allocator.free(prompt);
        if (!force and !try confirm(io, prompt)) {
            std.debug.print("Aborted.\n", .{});
            return;
        }

        var client = DeployClient.init(allocator, io, node.server);
        try authenticate(&client, node.uid, node.key);

        var ok: usize = 0;
        var failed: usize = 0;
        for (svc_names.items) |name| {
            std.debug.print("\n--- {s} ---\n", .{name});
            undeployOneService(&client, meta.name, name) catch |err| {
                std.debug.print("  Failed: {}\n", .{err});
                failed += 1;
                continue;
            };
            ok += 1;
        }

        std.debug.print("\n=== Deleting app '{s}' ===\n", .{meta.name});
        deleteOneApp(&client, meta.name) catch |err| {
            std.debug.print("  Failed: {}\n", .{err});
        };

        std.debug.print("\nDone! {d}/{d} services undeployed", .{ ok, svc_names.items.len });
        if (failed > 0) std.debug.print(", {d} failed", .{failed});
        std.debug.print(".\n", .{});
    }
}

fn authenticate(client: *DeployClient, uid: []const u8, key: []const u8) !void {
    std.debug.print("  Authenticating with {s}...\n", .{client.server_url});
    if (!try client.authenticate(uid, key)) {
        std.debug.print("Error: Authentication failed\n", .{});
        return error.AuthFailed;
    }
}

fn undeployOneService(client: *DeployClient, app_name: []const u8, service_name: []const u8) !void {
    std.debug.print("  Undeploying service '{s}'...\n", .{service_name});
    const resp = try client.undeployService(app_name, service_name);
    defer client.allocator.free(resp);
    if (std.mem.indexOf(u8, resp, "\"success\":true") == null) {
        log.warn("undeploy response: {s}", .{resp});
    }
}

fn deleteOneApp(client: *DeployClient, app_name: []const u8) !void {
    std.debug.print("  Deleting app '{s}'...\n", .{app_name});
    const resp = try client.deleteApp(app_name);
    defer client.allocator.free(resp);
    if (std.mem.indexOf(u8, resp, "\"success\":true") == null) {
        log.warn("delete-app response: {s}", .{resp});
    }
}

fn confirm(io: Io, prompt: []const u8) !bool {
    std.debug.print("\n{s}\n", .{prompt});
    std.debug.print("Continue? [y/N] ", .{});

    const stdin = Io.File.stdin();
    var buf: [64]u8 = undefined;
    const n = stdin.readStreaming(io, &.{&buf}) catch return false;
    if (n == 0) return false;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return trimmed.len > 0 and (trimmed[0] == 'y' or trimmed[0] == 'Y');
}
