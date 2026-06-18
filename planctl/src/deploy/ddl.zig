const std = @import("std");
const Io = std.Io;

const DeployClient = @import("client.zig").DeployClient;
const Profile = @import("config.zig").Profile;
const app_meta = @import("app_meta.zig");
const yaml_util = @import("yaml_util.zig");

const log = std.log.scoped(.ctl_ddl);

pub const Kind = enum { store, index };
pub const Action = enum { create, drop };

pub const Options = struct {
    action: Action,
    kind: Kind,
    ns: []const u8,
    field: []const u8 = "",
    field_type: []const u8 = "string",
    unique: bool = false,
    description: []const u8 = "",
    app: []const u8 = "",
    service: []const u8 = "",
    force: bool = false,
    profile: Profile,
};

pub fn run(allocator: std.mem.Allocator, io: Io, opts: Options) !void {
    if (opts.ns.len == 0) {
        std.debug.print("planctl {s} {s}: a name is required.\n", .{ @tagName(opts.action), @tagName(opts.kind) });
        std.process.exit(1);
    }
    if (opts.kind == .index and opts.action == .create and opts.field.len == 0) {
        std.debug.print("planctl create index: a field is required (use <store>.<field> or --field).\n", .{});
        std.process.exit(1);
    }

    const slug = try resolveSlug(allocator, io, opts.app, opts.service);

    if (std.mem.indexOf(u8, opts.ns, "systemdb") != null or
        std.mem.indexOf(u8, slug, "systemdb") != null)
    {
        std.debug.print("planctl: schema operations on the system database are not allowed.\n", .{});
        std.process.exit(1);
    }

    if (opts.action == .drop and !opts.force) {
        std.debug.print(
            "\nAbout to drop {s} '{s}' in service '{s}'. This is destructive.\nContinue? [y/N] ",
            .{ @tagName(opts.kind), opts.ns, slug },
        );
        if (!readYes(io)) {
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
        printAvailableServices(allocator, &client);
        std.process.exit(1);
    }

    const action_str = switch (opts.action) {
        .create => switch (opts.kind) {
            .store => "create-store",
            .index => "create-index",
        },
        .drop => switch (opts.kind) {
            .store => "drop-store",
            .index => "drop-index",
        },
    };

    const body = try buildBody(allocator, opts, slug, action_str);

    const resp = try client.post("/api/schema", body, "application/x-www-form-urlencoded");

    if (std.mem.indexOf(u8, resp, "\"success\":true") != null) {
        std.debug.print("{s}: {s} '{s}' in service '{s}' ({s})\n", .{
            action_str, @tagName(opts.kind), opts.ns, slug, node.server,
        });
        return;
    }

    log.err("{s} failed: {s}", .{ action_str, resp });
    std.debug.print("planctl: {s} failed on {s}: {s}\n", .{ action_str, node.server, resp });
    std.process.exit(1);
}

fn buildBody(allocator: std.mem.Allocator, opts: Options, slug: []const u8, action_str: []const u8) ![]u8 {
    return switch (opts.kind) {
        .store => switch (opts.action) {
            .create => std.fmt.allocPrint(allocator, "action={s}&ns={s}&service={s}&description={s}", .{ action_str, opts.ns, slug, opts.description }),
            .drop => std.fmt.allocPrint(allocator, "action={s}&ns={s}&service={s}", .{ action_str, opts.ns, slug }),
        },
        .index => switch (opts.action) {
            .create => std.fmt.allocPrint(allocator, "action={s}&ns={s}&service={s}&field={s}&field_type={s}&unique={s}&description={s}", .{
                action_str,                    opts.ns,
                slug,                          opts.field,
                mapFieldType(opts.field_type), if (opts.unique) "true" else "false",
                opts.description,
            }),
            .drop => std.fmt.allocPrint(allocator, "action={s}&ns={s}&service={s}", .{ action_str, opts.ns, slug }),
        },
    };
}

fn mapFieldType(t: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, t, "string")) return "String";
    if (eql(u8, t, "i32")) return "I32";
    if (eql(u8, t, "i64") or eql(u8, t, "int") or eql(u8, t, "integer")) return "I64";
    if (eql(u8, t, "u32")) return "U32";
    if (eql(u8, t, "u64")) return "U64";
    if (eql(u8, t, "f32")) return "F32";
    if (eql(u8, t, "f64") or eql(u8, t, "double") or eql(u8, t, "float")) return "F64";
    if (eql(u8, t, "bool") or eql(u8, t, "boolean")) return "Boolean";
    return "String";
}

pub fn resolveSlug(allocator: std.mem.Allocator, io: Io, app_override: []const u8, service_override: []const u8) ![]u8 {
    const app: []const u8 = if (app_override.len > 0) app_override else blk: {
        const meta = try app_meta.loadFromCwd(allocator, io);
        break :blk meta.name;
    };
    const service_name: []const u8 = if (service_override.len > 0)
        service_override
    else
        readServiceNameFromCwd(allocator, io);

    return std.fmt.allocPrint(allocator, "{s}_{s}", .{ app, service_name });
}

fn readServiceNameFromCwd(allocator: std.mem.Allocator, io: Io) []const u8 {
    const paths = [_][]const u8{ "app/db.yaml", "db.yaml" };
    for (paths) |p| {
        const y = Io.Dir.readFileAlloc(.cwd(), io, p, allocator, .unlimited) catch continue;
        return yaml_util.readServiceName(allocator, y, "db") catch "db";
    }
    return "db";
}

pub fn printAvailableServices(allocator: std.mem.Allocator, client: *DeployClient) void {
    const resp = client.listDatabases() catch return;
    defer allocator.free(resp);
    std.debug.print("Registered services on this workbench:\n", .{});
    var found = false;
    var rest: []const u8 = resp;
    while (std.mem.indexOf(u8, rest, "\"name\":\"")) |i| {
        const start = i + "\"name\":\"".len;
        const end = std.mem.indexOfScalarPos(u8, rest, start, '"') orelse break;
        std.debug.print("  - {s}\n", .{rest[start..end]});
        found = true;
        rest = rest[end..];
    }
    if (!found) std.debug.print("  (none deployed)\n", .{});
}

pub fn readYes(io: Io) bool {
    const stdin = Io.File.stdin();
    var buf: [64]u8 = undefined;
    const n = stdin.readStreaming(io, &.{&buf}) catch return false;
    if (n == 0) return false;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return trimmed.len > 0 and (trimmed[0] == 'y' or trimmed[0] == 'Y');
}
