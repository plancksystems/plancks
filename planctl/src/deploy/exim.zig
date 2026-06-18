const std = @import("std");
const Io = std.Io;

const DeployClient = @import("client.zig").DeployClient;
const Profile = @import("config.zig").Profile;
const ddl = @import("ddl.zig");

const log = std.log.scoped(.ctl_exim);

pub const Action = enum { export_data, import_data };

pub const Options = struct {
    action: Action,
    manifest_path: []const u8,
    app: []const u8 = "",
    service: []const u8 = "",
    force: bool = false,
    profile: Profile,
};

pub fn run(allocator: std.mem.Allocator, io: Io, opts: Options) !void {
    if (opts.manifest_path.len == 0) {
        std.debug.print("planctl {s}: --manifest <file> is required.\n", .{verb(opts.action)});
        std.process.exit(1);
    }

    const manifest = Io.Dir.readFileAlloc(.cwd(), io, opts.manifest_path, allocator, .unlimited) catch |err| {
        std.debug.print("planctl {s}: could not read manifest '{s}': {s}\n", .{ verb(opts.action), opts.manifest_path, @errorName(err) });
        std.process.exit(1);
    };

    const slug = try ddl.resolveSlug(allocator, io, opts.app, opts.service);

    if (opts.action == .import_data and !opts.force) {
        std.debug.print(
            "\nAbout to import into service '{s}' from manifest '{s}'.\nThis can overwrite existing documents. Continue? [y/N] ",
            .{ slug, opts.manifest_path },
        );
        if (!ddl.readYes(io)) {
            std.debug.print("Aborted.\n", .{});
            return;
        }
    }

    if (opts.profile.nodes.len == 0) {
        std.debug.print("planctl: profile '{s}' has no nodes.\n", .{opts.profile.name});
        std.process.exit(1);
    }
    const node = opts.profile.nodes[0];

    var client = DeployClient.init(allocator, io, node.server);
    if (!try client.authenticate(node.uid, node.key)) {
        std.debug.print("planctl: auth failed at {s}\n", .{node.server});
        std.process.exit(1);
    }

    if (!try client.connectService(slug)) {
        std.debug.print("planctl: could not connect to service '{s}' on {s}.\n", .{ slug, node.server });
        ddl.printAvailableServices(allocator, &client);
        std.process.exit(1);
    }

    const enc = try percentEncode(allocator, manifest);
    const body = try std.fmt.allocPrint(allocator, "service={s}&manifest={s}", .{ slug, enc });

    const path = switch (opts.action) {
        .export_data => "/api/export",
        .import_data => "/api/import",
    };

    const resp = try client.post(path, body, "application/x-www-form-urlencoded");

    if (std.mem.indexOf(u8, resp, "\"success\":true") != null) {
        std.debug.print("{s}: service '{s}' on {s}: {s}\n", .{ verb(opts.action), slug, node.server, resp });
        return;
    }

    log.err("{s} failed: {s}", .{ verb(opts.action), resp });
    std.debug.print("planctl: {s} failed on {s}: {s}\n", .{ verb(opts.action), node.server, resp });
    std.process.exit(1);
}

fn verb(a: Action) []const u8 {
    return switch (a) {
        .export_data => "export",
        .import_data => "import",
    };
}

fn percentEncode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0F]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}
