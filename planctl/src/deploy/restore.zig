
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const utils = @import("utils");
const DeployClient = @import("client.zig").DeployClient;
const deploy_config = @import("config.zig");
const Profile = @import("config.zig").Profile;

const log = std.log.scoped(.ctl_restore);

pub const Mode = union(enum) {
    app: []const u8,
    app_service: struct { app: []const u8, service: []const u8 },
    system,
};

pub const Options = struct {
    profile: ?Profile = null,
};

pub fn runRestore(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    backup_path: []const u8,
    mode: Mode,
    opts: Options
) !void {
    if (backup_path.len == 0) {
        std.debug.print("planctl restore: --backup <path> is required.\n", .{});
        std.process.exit(1);
    }

    const data_dir = try std.fmt.allocPrint(allocator, "{s}/.planck", .{home});
    defer allocator.free(data_dir);

    switch (mode) {
        .system => try restoreSystem(allocator, io, backup_path, data_dir),
        .app => |name| try restoreApp(allocator, io, backup_path, data_dir, name, null, opts),
        .app_service => |as| try restoreApp(allocator, io, backup_path, data_dir, as.app, as.service, opts),
    }
}

fn restoreApp(
    allocator: Allocator,
    io: Io,
    backup_path: []const u8,
    data_dir: []const u8,
    app_name: []const u8,
    service_filter: ?[]const u8,
    opts: Options
) !void {
    if (app_name.len == 0) {
        std.debug.print("planctl restore: --app <name> is required.\n", .{});
        std.process.exit(1);
    }

    const target_app_dir = try std.fmt.allocPrint(allocator, "{s}/apps/{s}", .{ data_dir, app_name });
    defer allocator.free(target_app_dir);

    const staging = try std.fmt.allocPrint(allocator, "{s}/.restore-staging-{s}", .{ data_dir, app_name });
    defer allocator.free(staging);

    std.debug.print("→ Restoring app '{s}' from {s}\n", .{ app_name, backup_path });
    if (service_filter) |f| std.debug.print("  Service filter: '{s}' (app-level files preserved)\n", .{f});

    if (service_filter == null) {
        bootoutAllForApp(allocator, io, app_name);
    } else if (service_filter) |f| {
        const label = try utils.labels.service(allocator, app_name, f);
        defer allocator.free(label);
        runCmdQuiet(io, &.{ "sudo", "launchctl", "bootout", "system", try plistPathForLabel(allocator, label) }) catch {};
    }

    const r = try utils.backup.restoreAppArchive(allocator, io, .{
        .archive_path = backup_path,
        .target_app_dir = target_app_dir,
        .service_filter = service_filter,
        .wipe_before_extract = service_filter == null,
        .app_name = app_name,
        .staging_dir = staging,
    });
    defer allocator.free(r.app_name);
    std.debug.print("  Restored {d} service(s)\n", .{r.services_restored});

    try registerPlistsIfMissing(allocator, io, data_dir, target_app_dir, app_name, service_filter);

    try bootstrapAllForApp(allocator, io, target_app_dir, app_name, service_filter);

    if (opts.profile) |profile| {
        callEnsureFromRestore(allocator, io, profile, target_app_dir, app_name, service_filter) catch |err| {
            std.debug.print("  Warning: wb ensure-from-restore failed: {s} (services are up; sysapps may need manual sync)\n", .{@errorName(err)});
        };
    }

    std.debug.print("Done. App '{s}' restored.\n", .{app_name});
}

fn restoreSystem(allocator: Allocator, io: Io, backup_path: []const u8, data_dir: []const u8) !void {
    const sysdb_dir = try std.fmt.allocPrint(allocator, "{s}/system", .{data_dir});
    defer allocator.free(sysdb_dir);

    const staging = try std.fmt.allocPrint(allocator, "{s}/.restore-staging-system", .{data_dir});
    defer allocator.free(staging);

    std.debug.print("→ Restoring sysdb from {s}\n", .{backup_path});
    std.debug.print("  (Make sure sysdb + wb are bootout'd before continuing.)\n", .{});

    const r = try utils.backup.restoreAppArchive(allocator, io, .{
        .archive_path = backup_path,
        .target_app_dir = sysdb_dir,
        .service_filter = null,
        .wipe_before_extract = true,
        .app_name = "system",
        .staging_dir = staging,
    });
    defer allocator.free(r.app_name);

    std.debug.print("  Extracted sysdb data into %s.\n", .{});
    std.debug.print("  Bring sysdb + wb back with:\n", .{});
    std.debug.print("    sudo launchctl bootstrap system /Library/LaunchDaemons/com.planck.sysdb.db.plist\n", .{});
    std.debug.print("    sudo launchctl bootstrap system /Library/LaunchDaemons/com.planck.workbench.ui.plist\n", .{});
}


fn plistPathForLabel(allocator: Allocator, label: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "/Library/LaunchDaemons/{s}.plist", .{label});
}

fn runCmd(io: Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn runCmdQuiet(io: Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn bootoutAllForApp(allocator: Allocator, io: Io, app_name: []const u8) void {
    var sc = utils.ServiceControl.init(allocator);
    const prefix = std.fmt.allocPrint(allocator, "com.planck.svc.{s}.", .{app_name}) catch return;
    defer allocator.free(prefix);
    const matches = sc.listMatching(io, prefix) catch return;
    defer {
        for (matches) |m| allocator.free(m);
        allocator.free(matches);
    }
    for (matches) |label| {
        const plist = plistPathForLabel(allocator, label) catch continue;
        defer allocator.free(plist);
        runCmdQuiet(io, &.{ "sudo", "launchctl", "bootout", "system", plist }) catch {};
    }
    const proxy_label = std.fmt.allocPrint(allocator, "com.planck.proxy.{s}", .{app_name}) catch return;
    defer allocator.free(proxy_label);
    const proxy_plist = plistPathForLabel(allocator, proxy_label) catch return;
    defer allocator.free(proxy_plist);
    runCmdQuiet(io, &.{ "sudo", "launchctl", "bootout", "system", proxy_plist }) catch {};
}

fn registerPlistsIfMissing(
    allocator: Allocator,
    io: Io,
    data_dir: []const u8,
    app_dir: []const u8,
    app_name: []const u8,
    service_filter: ?[]const u8
) !void {
    var sc = utils.ServiceControl.init(allocator);

    const global_log_dir = try std.fmt.allocPrint(allocator, "{s}/logs", .{data_dir});
    defer allocator.free(global_log_dir);
    Dir.createDirPath(.cwd(), io, global_log_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var services_dir = Dir.openDir(.cwd(), io, try std.fmt.allocPrint(allocator, "{s}/services", .{app_dir}), .{ .iterate = true }) catch return;
    defer services_dir.close(io);

    var it = services_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (service_filter) |f| if (!std.mem.eql(u8, entry.name, f)) continue;

        const label = try utils.labels.service(allocator, app_name, entry.name);
        defer allocator.free(label);

        const svc_dir = try std.fmt.allocPrint(allocator, "{s}/services/{s}", .{ app_dir, entry.name });
        defer allocator.free(svc_dir);
        const binary = try std.fmt.allocPrint(allocator, "{s}/planck.{s}.{s}.db", .{ svc_dir, app_name, entry.name });
        defer allocator.free(binary);

        chmodExec(io, binary) catch |err| {
            std.debug.print("  Warning: chmod +x '{s}' failed: {s}\n", .{ binary, @errorName(err) });
        };

        sc.register(io, .{
            .name = label,
            .description = "Restored Planck service",
            .binary = binary,
            .args = &.{"run"},
            .workdir = svc_dir,
            .stdout_log = try std.fmt.allocPrint(allocator, "{s}/{s}.out.log", .{ global_log_dir, label }),
            .stderr_log = try std.fmt.allocPrint(allocator, "{s}/{s}.err.log", .{ global_log_dir, label }),
        }) catch |err| {
            std.debug.print("  Warning: register plist for '{s}' failed: {s}\n", .{ label, @errorName(err) });
        };
    }

    const shell_bin = try std.fmt.allocPrint(allocator, "{s}/planck-app-{s}", .{ app_dir, app_name });
    defer allocator.free(shell_bin);
    if (Dir.openFile(.cwd(), io, shell_bin, .{ .mode = .read_only })) |f| {
        f.close(io);
        chmodExec(io, shell_bin) catch |err| {
            std.debug.print("  Warning: chmod +x '{s}' failed: {s}\n", .{ shell_bin, @errorName(err) });
        };
    } else |_| {}
}

fn chmodExec(io: Io, path: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "chmod", "+x", path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn bootstrapAllForApp(
    allocator: Allocator,
    io: Io,
    app_dir: []const u8,
    app_name: []const u8,
    service_filter: ?[]const u8
) !void {
    var services_dir = Dir.openDir(.cwd(), io, try std.fmt.allocPrint(allocator, "{s}/services", .{app_dir}), .{ .iterate = true }) catch return;
    defer services_dir.close(io);

    var it = services_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (service_filter) |f| if (!std.mem.eql(u8, entry.name, f)) continue;

        const label = try utils.labels.service(allocator, app_name, entry.name);
        defer allocator.free(label);
        const plist = try plistPathForLabel(allocator, label);
        defer allocator.free(plist);
        runCmd(io, &.{ "sudo", "launchctl", "bootstrap", "system", plist }) catch {};
    }
}

fn callEnsureFromRestore(
    allocator: Allocator,
    io: Io,
    profile: Profile,
    app_dir: []const u8,
    app_name: []const u8,
    service_filter: ?[]const u8
) !void {
    var services_dir = Dir.openDir(.cwd(), io, try std.fmt.allocPrint(allocator, "{s}/services", .{app_dir}), .{ .iterate = true }) catch return;
    defer services_dir.close(io);

    for (profile.nodes) |node| {
        var client = DeployClient.init(allocator, io, node.server);
        if (!try client.authenticate(node.uid, node.key)) {
            std.debug.print("  Warning: wb auth failed at {s}\n", .{node.server});
            continue;
        }

        var it = services_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (service_filter) |f| if (!std.mem.eql(u8, entry.name, f)) continue;

            const svc_dir = try std.fmt.allocPrint(allocator, "{s}/services/{s}", .{ app_dir, entry.name });
            defer allocator.free(svc_dir);

            const port = readPortFromDbYaml(allocator, io, svc_dir) catch 0;
            const wasm_port = readWasmPortFromServiceYaml(allocator, io, svc_dir) catch 0;
            const creds = readCredentials(allocator, io, svc_dir) catch Creds{ .uid = "admin", .key = "" };

            const body = try std.fmt.allocPrint(allocator,
                "action=ensure-from-restore&app={s}&service={s}&username={s}&key={s}&role={d}&mode={d}",
                .{ app_name, entry.name, creds.uid, creds.key, port, wasm_port });
            defer allocator.free(body);

            const resp = client.post("/api/admin", body, "application/x-www-form-urlencoded") catch |err| {
                std.debug.print("  ensure-from-restore '{s}/{s}' failed: {s}\n", .{ app_name, entry.name, @errorName(err) });
                continue;
            };
            defer allocator.free(resp);
            if (std.mem.indexOf(u8, resp, "\"success\":true") == null) {
                std.debug.print("  ensure-from-restore '{s}/{s}' reply: {s}\n", .{ app_name, entry.name, resp });
            }
        }

        if (service_filter == null) {
            const shell_body = try std.fmt.allocPrint(allocator, "action=register-app-shell&app={s}", .{app_name});
            defer allocator.free(shell_body);
            const shell_resp = client.post("/api/admin", shell_body, "application/x-www-form-urlencoded") catch |err| {
                std.debug.print("  register-app-shell '{s}' failed: {s}\n", .{ app_name, @errorName(err) });
                continue;
            };
            defer allocator.free(shell_resp);
            if (std.mem.indexOf(u8, shell_resp, "\"success\":true") == null) {
                std.debug.print("  register-app-shell '{s}' reply: {s}\n", .{ app_name, shell_resp });
            }
        }

        const sched_body = try std.fmt.allocPrint(allocator, "action=ensure-backup-schedule&app={s}", .{app_name});
        defer allocator.free(sched_body);
        const sched_resp = client.post("/api/admin", sched_body, "application/x-www-form-urlencoded") catch |err| {
            std.debug.print("  ensure-backup-schedule '{s}' failed: {s}\n", .{ app_name, @errorName(err) });
            continue;
        };
        defer allocator.free(sched_resp);
        if (std.mem.indexOf(u8, sched_resp, "\"success\":true") == null) {
            std.debug.print("  ensure-backup-schedule '{s}' reply: {s}\n", .{ app_name, sched_resp });
        }
    }
}

fn readPortFromDbYaml(allocator: Allocator, io: Io, svc_dir: []const u8) !u16 {
    const path = try std.fmt.allocPrint(allocator, "{s}/db.yaml", .{svc_dir});
    defer allocator.free(path);
    const content = try Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited);
    defer allocator.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (line.len > 0 and line[0] != ' ' and line[0] != '\t' and std.mem.startsWith(u8, trimmed, "port:")) {
            const v = std.mem.trim(u8, trimmed["port:".len..], " \t\"");
            return std.fmt.parseInt(u16, v, 10) catch 0;
        }
    }
    return 0;
}

fn readWasmPortFromServiceYaml(allocator: Allocator, io: Io, svc_dir: []const u8) !u16 {
    const path = try std.fmt.allocPrint(allocator, "{s}/service.yaml", .{svc_dir});
    defer allocator.free(path);
    const content = try Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited);
    defer allocator.free(content);
    var in_http = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "http:")) {
            in_http = true;
            continue;
        }
        if (in_http and std.mem.startsWith(u8, trimmed, "port:")) {
            const v = std.mem.trim(u8, trimmed["port:".len..], " \t\"");
            return std.fmt.parseInt(u16, v, 10) catch 0;
        }
    }
    return 0;
}

const Creds = struct { uid: []const u8, key: []const u8 };

fn readCredentials(allocator: Allocator, io: Io, svc_dir: []const u8) !Creds {
    const path = try std.fmt.allocPrint(allocator, "{s}/.credentials", .{svc_dir});
    defer allocator.free(path);
    const content = try Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited);
    var lines = std.mem.splitScalar(u8, content, '\n');
    const uid_line = lines.next() orelse return error.MissingUid;
    const key_line = lines.next() orelse return error.MissingKey;
    return .{
        .uid = std.mem.trim(u8, uid_line, " \t\r"),
        .key = std.mem.trim(u8, key_line, " \t\r"),
    };
}
