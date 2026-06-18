
const std = @import("std");
const Io = std.Io;

const DeployClient = @import("client.zig").DeployClient;
const Profile = @import("config.zig").Profile;

const log = std.log.scoped(.ctl_backup);

pub const Options = struct {
    profile: Profile,
    output_dir: []const u8 = "",
};

pub fn runBackup(allocator: std.mem.Allocator, io: Io, app_name: []const u8, opts: Options) !void {
    if (app_name.len == 0) {
        std.debug.print("planctl backup: --app <name> is required.\n", .{});
        std.process.exit(1);
    }

    for (opts.profile.nodes) |node| {
        var client = DeployClient.init(allocator, io, node.server);

        if (!try client.authenticate(node.uid, node.key)) {
            std.debug.print("planctl backup: auth failed at {s}\n", .{node.server});
            std.process.exit(1);
        }

        const body = try std.fmt.allocPrint(
            allocator,
            "action=create-backup&app={s}&backup_path={s}",
            .{ app_name, opts.output_dir },
        );
        defer allocator.free(body);

        const resp = try client.post("/api/admin", body, "application/x-www-form-urlencoded");
        defer allocator.free(resp);

        if (std.mem.indexOf(u8, resp, "\"success\":true") == null) {
            log.err("create-backup failed: {s}", .{resp});
            std.process.exit(1);
        }
        std.debug.print("Backup of '{s}' on {s}: {s}\n", .{ app_name, node.server, resp });
    }
}
