const std = @import("std");
const Io = std.Io;
const DeployClient = @import("client.zig").DeployClient;
const deploy_config = @import("config.zig");
const app_meta = @import("app_meta.zig");
const Profile = @import("config.zig").Profile;

const log = std.log.scoped(.lifecycle);

pub const Target = union(enum) {
    app,
    service: []const u8,
    all,
};

pub const Action = enum {
    start,
    stop,
    restart,

    fn verb(self: Action) []const u8 {
        return switch (self) {
            .start => "start",
            .stop => "stop",
            .restart => "restart",
        };
    }

    fn label(self: Action) []const u8 {
        return switch (self) {
            .start => "Starting",
            .stop => "Stopping",
            .restart => "Restarting",
        };
    }
};

pub fn runAction(allocator: std.mem.Allocator, io: Io, target: Target, action: Action, profile: Profile) !void {
    const meta = try app_meta.loadFromCwd(allocator, io);
    for (profile.nodes) |node| {
        var client = DeployClient.init(allocator, io, node.server);
        std.debug.print("  Authenticating with {s}...\n", .{node.server});
        if (!try client.authenticate(node.uid, node.key)) {
            std.debug.print("Error: Authentication failed\n", .{});
            return error.AuthFailed;
        }

        switch (target) {
            .app => try actOnApp(&client, meta.name, action),
            .service => |name| try actOnService(&client,meta.name, name, action),
            .all => {
                try actOnApp(&client, meta.name, action);
                var svc_dir = Io.Dir.openDir(.cwd(), io, "services", .{ .iterate = true }) catch {
                    std.debug.print("No services/ directory found.\n", .{});
                    return;
                };
                defer svc_dir.close(io);

                var iter = svc_dir.iterate();
                while (iter.next(io) catch null) |entry| {
                    if (entry.kind != .directory) continue;
                    if (entry.name.len > 0 and entry.name[0] == '.') continue;
                    actOnService(&client, meta.name, entry.name, action) catch |err| {
                        std.debug.print("  {s} failed for '{s}': {}\n", .{ action.label(), entry.name, err });
                    };
                }
            },
        }
    }
}

fn actOnApp(client: *DeployClient, app_name: []const u8, action: Action) !void {
    std.debug.print("  {s} app '{s}'...\n", .{ action.label(), app_name });
    const resp = try client.appLifecycle(app_name, action.verb());
    defer client.allocator.free(resp);
    if (std.mem.indexOf(u8, resp, "\"success\":true") == null) {
        log.warn("app-lifecycle response: {s}", .{resp});
    }
}

fn actOnService(client: *DeployClient, app_name: []const u8, service_name: []const u8, action: Action) !void {
    std.debug.print("  {s} service '{s}'...\n", .{ action.label(), service_name });
    const resp = try client.serviceLifecycle(app_name, service_name, action.verb());
    defer client.allocator.free(resp);
    if (std.mem.indexOf(u8, resp, "\"success\":true") == null) {
        log.warn("service-lifecycle response: {s}", .{resp});
    }
}

const ServiceRow = struct {
    profile: []const u8 = "",
    name: []const u8 = "",
    app: []const u8 = "",
    service_type: []const u8 = "",
    port: i64 = 0,
    pid: i64 = 0,
    status: []const u8 = "",
    cpu_percent: f64 = 0,
    rss_mb: f64 = 0,
};

pub fn runStatus(allocator: std.mem.Allocator, io: Io, target: Target, profile: Profile) !void {
    for (profile.nodes) |node| {
        var client = DeployClient.init(allocator, io, node.server);
        if (!try client.authenticate(node.uid, node.key)) {
            std.debug.print("Error: Authentication failed\n", .{});
            return error.AuthFailed;
        }

        const json_body = try client.listServices();
        defer allocator.free(json_body);

        const parsed = std.json.parseFromSlice(
            []ServiceRow,
            allocator,
            json_body,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.debug.print("Error: failed to parse /api/services response: {s}\n", .{@errorName(err)});
            std.debug.print("Raw body: {s}\n", .{json_body});
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const rows = parsed.value;
        const filter_name: ?[]const u8 = switch (target) {
            .service => |n| n,
            else => null,
        };
        const show_all = switch (target) {
            .all => true,
            .app, .service => false,
        };

        std.debug.print("\n", .{});
        std.debug.print("{s:<20} {s:<20} {s:<10} {s:<10} {s:<8} {s:<8} {s:<8} {s}\n", .{
            "PROFILE", "SERVICE", "APP", "STATE", "PORT", "PID", "CPU%", "RSS(MB)",
        });
        std.debug.print("{s:-<20} {s:-<20} {s:-<10} {s:-<10} {s:-<8} {s:-<8} {s:-<8} {s:-<8}\n", .{
            "", "", "", "", "", "", "", "",
        });

        var shown: usize = 0;
        for (rows) |row| {
            if (filter_name) |fname| {
                if (!std.mem.eql(u8, row.name, fname)) continue;
            }
            if (!show_all and filter_name == null) {
                continue;
            }
            printRow(row);
            shown += 1;
        }

        if (shown == 0 and target == .service) {
            std.debug.print("(no service named '{s}' found)\n", .{filter_name.?});
        }

        switch (target) {
            .app, .all => {
                const apps_json = client.listApps() catch |err| {
                    std.debug.print("\n(failed to fetch /api/apps: {s})\n", .{@errorName(err)});
                    return;
                };
                defer allocator.free(apps_json);
                renderAppSummary(apps_json);
            },
            .service => {},
        }
    }
}

fn printRow(row: ServiceRow) void {
    var pid_buf: [16]u8 = undefined;
    const pid_str = if (row.pid > 0)
        std.fmt.bufPrint(&pid_buf, "{d}", .{row.pid}) catch "?"
    else
        "-";

    var port_buf: [16]u8 = undefined;
    const port_str = if (row.port > 0)
        std.fmt.bufPrint(&port_buf, "{d}", .{row.port}) catch "?"
    else
        "-";

    std.debug.print("{s:<20} {s:<20} {s:<10} {s:<10} {s:<8} {s:<8} {d:<8.1} {d:<8.1}\n", .{
        truncate(row.profile, 20),
        truncate(row.name, 20),
        truncate(row.app, 10),
        truncate(row.status, 10),
        port_str,
        pid_str,
        row.cpu_percent,
        row.rss_mb,
    });
}

fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

fn renderAppSummary(apps_json: []const u8) void {
    std.debug.print("\nAPPS:\n", .{});
    var i: usize = 0;
    var found_any = false;
    while (i < apps_json.len) {
        const start = std.mem.indexOfPos(u8, apps_json, i, "\"name\":\"") orelse break;
        const name_start = start + "\"name\":\"".len;
        const name_end = std.mem.indexOfScalarPos(u8, apps_json, name_start, '"') orelse break;
        std.debug.print("  {s}\n", .{apps_json[name_start..name_end]});
        i = name_end + 1;
        found_any = true;
    }
    if (!found_any) std.debug.print("  (none)\n", .{});
}
