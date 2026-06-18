const std = @import("std");
const builtin = @import("builtin");
const schnell = @import("schnell");
const planck = @import("planck");

const Ctx = @import("ctx.zig").Ctx;

const DEFAULT_PORT: u16 = 4000;
const ADMIN_KEY = "UGxhbmNrX0RlZmF1bHRfQWRtaW5fS2V5XzAwMTA=";

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;
    defer if (builtin.mode == .Debug) {
        if (gpa.detectLeaks() > 0) std.process.exit(1);
    };

    var threaded: std.Io.Threaded = .init(allocator, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const io = threaded.io();

    const port = readShellPort(io, allocator) orelse DEFAULT_PORT;

    const client = try planck.Client.init(allocator, io);
    if (readFirstServicePlanckPort(io, allocator)) |svc_port| {
        const creds = readFirstServiceCredentials(io, allocator);
        defer if (creds) |c| {
            allocator.free(c.uid);
            allocator.free(c.key);
        };
        const conn_uid: []const u8 = if (creds) |c| c.uid else "admin";
        const conn_key: []const u8 = if (creds) |c| c.key else ADMIN_KEY;

        const conn_str = try std.fmt.allocPrint(
            allocator,
            "127.0.0.1:{d};uid={s};key={s};tls=false",
            .{ svc_port, conn_uid, conn_key },
        );
        defer allocator.free(conn_str);
        if (client.connect(conn_str)) |auth_const| {
            var auth = auth_const;
            auth.deinit();
        } else |err| {
            std.debug.print(
                "warning: planck DB at 127.0.0.1:{d} not reachable yet ({s}) — shell continues without DB connection; deploy services and restart to acquire it\n",
                .{ svc_port, @errorName(err) },
            );
        }
    } else {
        std.debug.print(
            "warning: no `services/<svc>/db.yaml` with a `port:` found — shell continues without DB connection\n",
            .{},
        );
    }

    var ctx = Ctx{ .client = client };
    _ = &ctx;

    var app = try schnell.App.init(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .static_dir = "public",
    });
    defer app.deinit();

    var cors = schnell.CorsMiddleware.init(.{});
    try app.use(cors.middleware());

    var reconnect_group: std.Io.Group = .init;
    defer reconnect_group.cancel(io);
    reconnect_group.async(io, reconnectWatchdog, .{ client, io });

    std.debug.print("shell on http://127.0.0.1:{d}\n", .{port});
    try app.run(io);
}

fn reconnectWatchdog(client: *planck.Client, io: std.Io) std.Io.Cancelable!void {
    while (true) {
        io.sleep(std.Io.Duration.fromMilliseconds(30_000), .awake) catch |err| {
            if (err == error.Canceled) return error.Canceled;
        };
        if (client.list(.User, null)) |data| {
            client.allocator.free(data);
        } else |err| {
            std.debug.print("planck health probe failed ({s}) — reconnecting\n", .{@errorName(err)});
            client.reconnect() catch |rerr| {
                std.debug.print("planck reconnect failed: {s} — retry in 30s\n", .{@errorName(rerr)});
            };
        }
    }
}

fn readShellPort(io: std.Io, allocator: std.mem.Allocator) ?u16 {
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, "app.yaml", allocator, .unlimited) catch return null;
    defer allocator.free(content);

    var in_app = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (line.len > 0 and line[0] != ' ' and line[0] != '\t') {
            in_app = std.mem.startsWith(u8, trimmed, "app:");
            continue;
        }
        if (in_app and std.mem.startsWith(u8, trimmed, "port:")) {
            const rest = std.mem.trim(u8, trimmed["port:".len..], " \t\"");
            return std.fmt.parseInt(u16, rest, 10) catch null;
        }
    }
    return null;
}

const Credentials = struct { uid: []u8, key: []u8 };

fn readFirstServiceCredentials(io: std.Io, allocator: std.mem.Allocator) ?Credentials {
    var svc_dir = std.Io.Dir.openDir(.cwd(), io, "services", .{ .iterate = true }) catch return null;
    defer svc_dir.close(io);

    var iter = svc_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        const path = std.fmt.allocPrint(allocator, "services/{s}/.credentials", .{entry.name}) catch continue;
        defer allocator.free(path);

        const content = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited) catch continue;
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        const uid_line = lines.next() orelse continue;
        const key_line = lines.next() orelse continue;
        const uid = std.mem.trim(u8, uid_line, " \t\r");
        const key = std.mem.trim(u8, key_line, " \t\r");
        if (uid.len == 0 or key.len == 0) continue;
        return .{
            .uid = allocator.dupe(u8, uid) catch continue,
            .key = allocator.dupe(u8, key) catch continue,
        };
    }
    return null;
}

fn readFirstServicePlanckPort(io: std.Io, allocator: std.mem.Allocator) ?u16 {
    var svc_dir = std.Io.Dir.openDir(.cwd(), io, "services", .{ .iterate = true }) catch return null;
    defer svc_dir.close(io);

    var iter = svc_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        const path = std.fmt.allocPrint(allocator, "services/{s}/db.yaml", .{entry.name}) catch continue;
        defer allocator.free(path);

        const content = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited) catch continue;
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            const is_top = line.len > 0 and line[0] != ' ' and line[0] != '\t';
            if (!is_top) continue;
            if (std.mem.startsWith(u8, trimmed, "port:")) {
                const rest = std.mem.trim(u8, trimmed["port:".len..], " \t\"");
                if (std.fmt.parseInt(u16, rest, 10)) |p| {
                    if (p > 0) return p;
                } else |_| {}
                break;
            }
        }
    }
    return null;
}
