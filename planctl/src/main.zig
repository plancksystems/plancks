
const std = @import("std");
const builtin = @import("builtin");

const Target = @import("zsx/compiler.zig").Target;

pub const std_options: std.Options = .{
    .log_level = .info,
};

const transform = @import("compiler/transform.zig");
const watch = @import("compiler/watch.zig");
const clean = @import("compiler/clean.zig");
const init_zig_wasm = @import("init/zig/wasm.zig");
const init_zig_shell = @import("init/zig/shell.zig");
const validate = @import("init/validate.zig");
const materialize = @import("init/materialize.zig");
const templates_manifest = @import("templates_manifest");
const add_feature = @import("init/zig/feature.zig");
const add_service = @import("init/zig/service.zig");
const deploy_app = @import("deploy/app.zig");
const deploy_mono = @import("deploy/mono.zig");
const deploy_zig = @import("deploy/service/zig.zig");
const deploy_validate = @import("deploy/validate.zig");
const undeploy_mod = @import("deploy/undeploy.zig");
const lifecycle = @import("deploy/lifecycle.zig");
const deploy_config = @import("deploy/config.zig");
const backup_cmd = @import("deploy/backup.zig");
const restore_cmd = @import("deploy/restore.zig");
const ddl_cmd = @import("deploy/ddl.zig");
const exim_cmd = @import("deploy/exim.zig");
const setup_cmd = @import("system/setup.zig");
const Config = @import("deploy/config.zig").Config;
const Profile = @import("deploy/config.zig").Profile;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    const home: []const u8 = switch (builtin.os.tag) {
        .macos, .linux => init.environ_map.get("HOME") orelse "",
        .windows => init.environ_map.get("USERPROFILE") orelse "",
        else => return error.UnsupportedOS,
    };

    if (args.len < 2) return showUsage();

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "system")) {

        try setup_cmd.run(allocator, args, home);
        return;
    }

    if (std.mem.eql(u8, cmd, "new")) {
        try runNew(allocator, init.io, args);
        return;
    }

    if (std.mem.eql(u8, cmd, "add")) {
        try runAdd(allocator, init.io, args);
        return;
    }

    if (std.mem.eql(u8, cmd, "init")) {
        std.debug.print("note: `planctl init` is deprecated — use `planctl new <name> --type hda --arch mono` (etc.). See `planctl new --help`.\n\n", .{});

        if (args.len < 3) {
            std.debug.print("Usage: planctl init <project_name> [--type wasm|app]\n", .{});
            std.process.exit(1);
        }
        var project_type: enum { wasm, app } = .wasm;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--type") and i + 1 < args.len) {
                if (std.mem.eql(u8, args[i + 1], "app")) project_type = .app;
                i += 1;
            }
        }
        if (project_type == .app) {
            try init_zig_shell.create(allocator, init.io, args[2]);
        } else {
            try init_zig_wasm.create(allocator, init.io, args[2]);
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "clean") and args.len == 3) {
        try clean.cleanDir(allocator, init.io, args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "--watch") and args.len == 4) {
        try watch.watchMode(allocator, init.io, args[2], args[3]);
        return;
    }

    if (std.mem.eql(u8, cmd, "deploy")) {
        const config = try Config.load(allocator, init.io, home);

        const parsed = parseDeployArgs(args) catch {
            std.debug.print("Usage: planctl deploy --app | --service <name> | --sse | --all [--arch mono|micro] --profile <name>\n", .{});
            std.process.exit(1);
        };
        const profile_name = parsed.profile orelse {
            std.debug.print("planctl deploy: --profile <name> is required\n", .{});
            std.process.exit(1);
        };
        const profile = config.profile(profile_name) orelse return error.ProfileNotFound;

        const validate_arch: deploy_validate.Arch = switch (parsed.arch) {
            .mono => .mono,
            .micro => .micro,
        };
        if (parsed.target != .sse) {
            deploy_validate.validate(allocator, init.io, validate_arch, &profile) catch |err| {
                std.debug.print("\nDeploy aborted: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        }

        switch (parsed.target) {
            .app => switch (parsed.arch) {
                .mono => try deploy_mono.run(allocator, init.io, profile),
                .micro => try deploy_app.run(allocator, init.io, profile),
            },
            .service => |svc| try deploy_zig.run(allocator, init.io, svc, profile),
            .sse => deploy_mono.deploySseStandalone(allocator, init.io, profile) catch |e| {
                std.debug.print("SSE deploy failed: {}\n", .{e});
                std.process.exit(1);
            },
            .all => switch (parsed.arch) {
                .mono => {
                    try deploy_mono.run(allocator, init.io, profile);
                },
                .micro => {
                    std.debug.print("=== Deploying shell ===\n", .{});
                    deploy_app.run(allocator, init.io, profile) catch |e| {
                        std.debug.print("Shell deploy failed: {}\n", .{e});
                    };

                    std.debug.print("\n=== Deploying services ===\n", .{});
                    var svc_dir = std.Io.Dir.openDir(.cwd(), init.io, "app/services", .{ .iterate = true }) catch {
                        std.debug.print("No services/ directory found\n", .{});
                        return;
                    };
                    defer svc_dir.close(init.io);

                    var iter = svc_dir.iterate();
                    while (iter.next(init.io) catch null) |entry| {
                        if (entry.kind != .directory) continue;
                        if (entry.name.len > 0 and entry.name[0] == '.') continue;

                        std.debug.print("\n--- {s} ---\n", .{entry.name});
                        deploy_zig.run(allocator, init.io, entry.name, profile) catch |e| {
                            std.debug.print("  Failed: {}\n", .{e});
                        };
                    }

                    std.debug.print("\n=== Deploying sse service (if present) ===\n", .{});
                    deploy_mono.deploySseStandalone(allocator, init.io, profile) catch |e| {
                        std.debug.print("SSE deploy failed: {}\n", .{e});
                    };
                },
            },
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "start") or std.mem.eql(u8, cmd, "stop") or
        std.mem.eql(u8, cmd, "restart") or std.mem.eql(u8, cmd, "status"))
    {


        const config = try Config.load(allocator, init.io, home);

        const profile = try switch (args.len) {
            5 => config.profile(args[4]),
            6 => config.profile(args[5]),
            else => error.ProfileNotFound,
        };

        const target = parseLifecycleTarget(args[2..]) orelse {
            std.debug.print("Usage: planctl {s} --app | --service <name> | --sse <app> | --all [common flags]\n", .{cmd});
            std.process.exit(1);
        };

        if (profile) |prof| {
            if (std.mem.eql(u8, cmd, "start")) {
                try lifecycle.runAction(allocator, init.io, target, .start, prof);
            } else if (std.mem.eql(u8, cmd, "stop")) {
                try lifecycle.runAction(allocator, init.io, target, .stop, prof);
            } else if (std.mem.eql(u8, cmd, "restart")) {
                try lifecycle.runAction(allocator, init.io, target, .restart, prof);
            } else {
                try lifecycle.runStatus(allocator, init.io, target, prof);
            }
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "backup")) {
        const config = try Config.load(allocator, init.io, home);
        var app_name: []const u8 = "";
        var output_dir: []const u8 = "";
        var profile: ?Profile = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--app") and i + 1 < args.len) {
                app_name = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
                output_dir = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--profile") and i + 1 < args.len) {
                profile = config.profile(args[i + 1]);
                i += 1;
            }
        }
        const prof = profile orelse {
            std.debug.print("Usage: planctl backup --app <name> --profile <p> [--output <dir>]\n", .{});
            std.process.exit(1);
        };
        try backup_cmd.runBackup(allocator, init.io, app_name, .{ .profile = prof, .output_dir = output_dir });
        return;
    }

    if (std.mem.eql(u8, cmd, "restore")) {
        const config = try Config.load(allocator, init.io, home);

        var app_name: []const u8 = "";
        var svc_name: []const u8 = "";
        var backup_path: []const u8 = "";
        var system_mode = false;
        var profile: ?Profile = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--app") and i + 1 < args.len) {
                app_name = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--service") and i + 1 < args.len) {
                svc_name = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--backup") and i + 1 < args.len) {
                backup_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--system")) {
                system_mode = true;
            } else if (std.mem.eql(u8, args[i], "--profile") and i + 1 < args.len) {
                profile = config.profile(args[i + 1]);
                i += 1;
            }
        }

        if (backup_path.len == 0) {
            std.debug.print("Usage: planctl restore --app <name> [--service <svc>] --backup <path> --profile <p>\n       planctl restore --system --backup <path>\n", .{});
            std.process.exit(1);
        }

        const mode: restore_cmd.Mode = if (system_mode)
            .system
        else if (svc_name.len > 0)
            .{ .app_service = .{ .app = app_name, .service = svc_name } }
        else
            .{ .app = app_name };

        try restore_cmd.runRestore(allocator, init.io, home, backup_path, mode, .{ .profile = profile });
        return;
    }

    if (std.mem.eql(u8, cmd, "create")) {
        try runDdl(allocator, init.io, home, .create, args);
        return;
    }
    if (std.mem.eql(u8, cmd, "drop")) {
        try runDdl(allocator, init.io, home, .drop, args);
        return;
    }

    if (std.mem.eql(u8, cmd, "export")) {
        try runExim(allocator, init.io, home, .export_data, args);
        return;
    }
    if (std.mem.eql(u8, cmd, "import")) {
        try runExim(allocator, init.io, home, .import_data, args);
        return;
    }

    if (std.mem.eql(u8, cmd, "undeploy")) {
        const config = try Config.load(allocator, init.io, home);

        const UndeployTarget = union(enum) { app, service: []const u8, all };
        var target: ?UndeployTarget = null;
        var profile_name: ?[]const u8 = null;
        var force: bool = false;

        var ui: usize = 2;
        while (ui < args.len) : (ui += 1) {
            const a = args[ui];
            if (std.mem.eql(u8, a, "--app")) {
                target = .app;
            } else if (std.mem.eql(u8, a, "--all")) {
                target = .all;
            } else if (std.mem.eql(u8, a, "--service") and ui + 1 < args.len) {
                target = .{ .service = args[ui + 1] };
                ui += 1;
            } else if (std.mem.eql(u8, a, "--profile") and ui + 1 < args.len) {
                profile_name = args[ui + 1];
                ui += 1;
            } else if (std.mem.eql(u8, a, "--force") or std.mem.eql(u8, a, "-f")) {
                force = true;
            } else {
                std.debug.print("planctl undeploy: unknown arg '{s}'\n", .{a});
                std.debug.print("Usage: planctl undeploy --app | --service <name> | --all --profile <name> [--force]\n", .{});
                std.process.exit(1);
            }
        }

        const tgt = target orelse {
            std.debug.print("Usage: planctl undeploy --app | --service <name> | --all --profile <name> [--force]\n", .{});
            std.process.exit(1);
        };
        const prof_name = profile_name orelse {
            std.debug.print("planctl undeploy: --profile <name> is required\n", .{});
            std.process.exit(1);
        };
        const profile = config.profile(prof_name) orelse return error.ProfileNotFound;

        switch (tgt) {
            .app => try undeploy_mod.runApp(allocator, init.io, profile, force),
            .service => |svc| try undeploy_mod.runService(allocator, init.io, svc, profile, force),
            .all => try undeploy_mod.runAll(allocator, init.io, profile, force),
        }
        return;
    }

    var explicit_target: ?Target = null;
    var filtered_args = std.ArrayList([]const u8).empty;
    defer filtered_args.deinit(allocator);
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--target") and i + 1 < args.len) {
                const tv = args[i + 1];
                if (std.mem.eql(u8, tv, "zig")) explicit_target = .zig else if (std.mem.eql(u8, tv, "rust")) explicit_target = .rust else if (std.mem.eql(u8, tv, "go")) explicit_target = .go else {
                    std.debug.print("planctl: unknown target '{s}'\n", .{tv});
                    std.process.exit(1);
                }
                i += 1;
            } else {
                try filtered_args.append(allocator, args[i]);
            }
        }
    }
    const positional = filtered_args.items;

    if (positional.len == 1) {
        const filename = positional[0];
        const src = try std.Io.Dir.readFileAlloc(.cwd(), init.io, filename, allocator, .unlimited);
        defer allocator.free(src);
        const target = transform.detectTargetFromExt(filename) orelse (explicit_target orelse .zig);
        const code = try transform.transformSource(allocator, src, filename, target);
        defer allocator.free(code);
        std.debug.print("{s}", .{code});
        return;
    }
    if (positional.len == 2) {
        try transform.transformDir(allocator, init.io, positional[0], positional[1]);
        return;
    }

    showUsage();
}

fn runNew(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len < 3) {
        std.debug.print(
            \\Usage: planctl new <name> --type <hda|spa> --arch <mono|micro>
            \\
            \\Examples:
            \\  planctl new notes --type hda --arch mono
            \\  planctl new shop  --type spa --arch micro
            \\
            \\No reverse proxy is scaffolded. By default the app, the SSE
            \\service, and any per-feature services each bind their own
            \\port and the browser reaches them directly via CORS. For
            \\production behind a single origin, add your own Caddyfile /
            \\nginx.conf / etc. — we don't pick one for you.
            \\
        , .{});
        std.process.exit(1);
    }

    const name = args[2];
    if (validate.check(name)) |err| {
        std.debug.print("planctl new: invalid project name '{s}': {s}\n", .{ name, validate.messageFor(err, name) });
        std.process.exit(1);
    }

    var ptype: ?[]const u8 = null;
    var arch: ?[]const u8 = null;
    var force: bool = false;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--type") and i + 1 < args.len) {
            ptype = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--arch") and i + 1 < args.len) {
            arch = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--force") or std.mem.eql(u8, args[i], "-f")) {
            force = true;
        } else {
            std.debug.print("planctl new: unknown flag '{s}'\n", .{args[i]});
            std.process.exit(1);
        }
    }

    const t = ptype orelse {
        std.debug.print("planctl new: missing --type (hda|spa)\n", .{});
        std.process.exit(1);
    };
    const a = arch orelse {
        std.debug.print("planctl new: missing --arch (mono|micro)\n", .{});
        std.process.exit(1);
    };

    if (!std.mem.eql(u8, t, "hda") and !std.mem.eql(u8, t, "spa")) {
        std.debug.print("planctl new: --type must be 'hda' or 'spa' (got '{s}')\n", .{t});
        std.process.exit(1);
    }
    if (!std.mem.eql(u8, a, "mono") and !std.mem.eql(u8, a, "micro")) {
        std.debug.print("planctl new: --arch must be 'mono' or 'micro' (got '{s}')\n", .{a});
        std.process.exit(1);
    }

    const tmpl_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ t, a });
    defer allocator.free(tmpl_name);

    const template = templates_manifest.byName(tmpl_name) orelse {
        std.debug.print("planctl new: no template '{s}' (known: hda-mono, hda-micro, spa-mono, spa-micro)\n", .{tmpl_name});
        std.process.exit(1);
    };

    materialize.materialize(allocator, io, template, name, .{
        .force = force,
    }) catch |err| switch (err) {
        error.ProjectExists => {
            std.debug.print("planctl new: directory '{s}/' already exists (use --force to overwrite)\n", .{name});
            std.process.exit(1);
        },
        else => return err,
    };

    std.debug.print(
        \\Created {s}/ from template '{s}' ({d} files).
        \\
        \\Next steps:
        \\  cd {s}
        \\  zig build run
        \\
        \\First build will print a fingerprint suggestion — paste it into
        \\build.zig.zon's .fingerprint line and rebuild.
        \\
    , .{ name, tmpl_name, template.files.len, name });
}

fn runAdd(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len < 3) {
        std.debug.print(
            \\Usage: planctl add <name> --type <feature|service> [--arch <hypermedia|rest>] [--force]
            \\
            \\Examples:
            \\  planctl add notes --type feature      (run inside a mono project)
            \\  planctl add orders --type service     (run inside a micro project)
            \\
        , .{});
        std.process.exit(1);
    }

    const name = args[2];

    var ptype: ?[]const u8 = null;
    var arch_str: ?[]const u8 = null;
    var force: bool = false;
    var port_override: ?u16 = null;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--type") and i + 1 < args.len) {
            ptype = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--arch") and i + 1 < args.len) {
            arch_str = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            port_override = std.fmt.parseInt(u16, args[i + 1], 10) catch {
                std.debug.print("planctl add: --port must be a number 0..65535 (got '{s}')\n", .{args[i + 1]});
                std.process.exit(1);
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--force") or std.mem.eql(u8, args[i], "-f")) {
            force = true;
        } else {
            std.debug.print("planctl add: unknown flag '{s}'\n", .{args[i]});
            std.process.exit(1);
        }
    }

    const t = ptype orelse {
        std.debug.print("planctl add: missing --type (feature|service)\n", .{});
        std.process.exit(1);
    };

    if (std.mem.eql(u8, t, "feature")) {
        const arch: ?add_feature.Arch = if (arch_str) |a|
            (if (std.mem.eql(u8, a, "hypermedia") or std.mem.eql(u8, a, "hda"))
                .hda
            else if (std.mem.eql(u8, a, "rest") or std.mem.eql(u8, a, "spa"))
                .spa
            else
                null)
        else
            null;
        if (arch_str != null and arch == null) {
            std.debug.print("planctl add: --arch must be 'hypermedia' or 'rest' (got '{s}')\n", .{arch_str.?});
            std.process.exit(1);
        }
        add_feature.add(allocator, io, name, .{ .force = force, .arch_override = arch }) catch |err| switch (err) {
            error.NotMonoProject, error.FeatureExists, error.InvalidName => std.process.exit(1),
            else => return err,
        };
    } else if (std.mem.eql(u8, t, "service")) {
        const arch: ?add_service.Arch = if (arch_str) |a|
            (if (std.mem.eql(u8, a, "hypermedia") or std.mem.eql(u8, a, "hda"))
                .hda
            else if (std.mem.eql(u8, a, "rest") or std.mem.eql(u8, a, "spa"))
                .spa
            else
                null)
        else
            null;
        if (arch_str != null and arch == null) {
            std.debug.print("planctl add: --arch must be 'hypermedia' or 'rest' (got '{s}')\n", .{arch_str.?});
            std.process.exit(1);
        }
        add_service.add(allocator, io, name, .{
            .force = force,
            .arch_override = arch,
            .port_override = port_override,
        }) catch |err| switch (err) {
            error.NotMicroProject, error.ServiceExists, error.InvalidName => std.process.exit(1),
            else => return err,
        };
    } else {
        std.debug.print("planctl add: --type must be 'feature' or 'service' (got '{s}')\n", .{t});
        std.process.exit(1);
    }
}

fn runDdl(allocator: std.mem.Allocator, io: std.Io, home: []const u8, action: ddl_cmd.Action, args: []const []const u8) !void {
    const action_str = @tagName(action);
    if (args.len < 4) {
        std.debug.print(
            \\Usage:
            \\  planctl {s} store <store>          [--app <a>] [--service <s>] [--description <d>] --profile <p>
            \\  planctl {s} index <store>.<index>  [--type <t>] [--unique] [--field <f>] [--app <a>] [--service <s>] --profile <p>
            \\
        , .{ action_str, action_str });
        std.process.exit(1);
    }

    const kind: ddl_cmd.Kind = if (std.mem.eql(u8, args[2], "store"))
        .store
    else if (std.mem.eql(u8, args[2], "index"))
        .index
    else {
        std.debug.print("planctl {s}: object must be 'store' or 'index' (got '{s}')\n", .{ action_str, args[2] });
        std.process.exit(1);
    };

    const name = args[3];

    var field: []const u8 = "";
    var ftype: []const u8 = "string";
    var unique = false;
    var description: []const u8 = "";
    var app: []const u8 = "";
    var service: []const u8 = "";
    var force = false;
    var profile_name: ?[]const u8 = null;

    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--field") and i + 1 < args.len) {
            field = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--type") and i + 1 < args.len) {
            ftype = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--unique")) {
            unique = true;
        } else if (std.mem.eql(u8, a, "--description") and i + 1 < args.len) {
            description = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--app") and i + 1 < args.len) {
            app = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--service") and i + 1 < args.len) {
            service = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--force") or std.mem.eql(u8, a, "-f")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--profile") and i + 1 < args.len) {
            profile_name = args[i + 1];
            i += 1;
        } else {
            std.debug.print("planctl {s}: unknown arg '{s}'\n", .{ action_str, a });
            std.process.exit(1);
        }
    }

    if (kind == .index and action == .create and field.len == 0) {
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
            field = name[dot + 1 ..];
        } else {
            std.debug.print("planctl create index: name must be <store>.<index> (got '{s}')\n", .{name});
            std.process.exit(1);
        }
    }

    const prof_name = profile_name orelse {
        std.debug.print("planctl {s}: --profile <name> is required\n", .{action_str});
        std.process.exit(1);
    };

    const config = try Config.load(allocator, io, home);
    const profile = config.profile(prof_name) orelse return error.ProfileNotFound;

    try ddl_cmd.run(allocator, io, .{
        .action = action,
        .kind = kind,
        .ns = name,
        .field = field,
        .field_type = ftype,
        .unique = unique,
        .description = description,
        .app = app,
        .service = service,
        .force = force,
        .profile = profile,
    });
}

fn runExim(allocator: std.mem.Allocator, io: std.Io, home: []const u8, action: exim_cmd.Action, args: []const []const u8) !void {
    const v = if (action == .export_data) "export" else "import";

    var manifest_path: []const u8 = "";
    var app: []const u8 = "";
    var service: []const u8 = "";
    var force = false;
    var profile_name: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--manifest") and i + 1 < args.len) {
            manifest_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--app") and i + 1 < args.len) {
            app = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--service") and i + 1 < args.len) {
            service = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--force") or std.mem.eql(u8, a, "-f")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--profile") and i + 1 < args.len) {
            profile_name = args[i + 1];
            i += 1;
        } else {
            std.debug.print("planctl {s}: unknown arg '{s}'\n", .{ v, a });
            std.process.exit(1);
        }
    }

    if (manifest_path.len == 0) {
        std.debug.print(
            \\Usage:
            \\  planctl {s} --manifest <file.yaml> [--app <a>] [--service <s>] [--force] --profile <p>
            \\
        , .{v});
        std.process.exit(1);
    }

    const prof_name = profile_name orelse {
        std.debug.print("planctl {s}: --profile <name> is required\n", .{v});
        std.process.exit(1);
    };

    const config = try Config.load(allocator, io, home);
    const profile = config.profile(prof_name) orelse return error.ProfileNotFound;

    try exim_cmd.run(allocator, io, .{
        .action = action,
        .manifest_path = manifest_path,
        .app = app,
        .service = service,
        .force = force,
        .profile = profile,
    });
}

const DeployTarget = union(enum) {
    app,
    service: []const u8,
    sse,
    all,
};
const DeployArch = enum { mono, micro };
const DeployArgs = struct {
    target: DeployTarget,
    arch: DeployArch = .micro,
    profile: ?[]const u8 = null,
};
fn parseDeployArgs(args: []const []const u8) !DeployArgs {
    if (args.len < 3) return error.ParseError;

    var target: ?DeployTarget = null;
    var arch: DeployArch = .micro;
    var profile: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--app")) {
            target = .app;
        } else if (std.mem.eql(u8, a, "--all")) {
            target = .all;
        } else if (std.mem.eql(u8, a, "--sse")) {
            target = .sse;
        } else if (std.mem.eql(u8, a, "--service") and i + 1 < args.len) {
            target = .{ .service = args[i + 1] };
            i += 1;
        } else if (std.mem.eql(u8, a, "--arch") and i + 1 < args.len) {
            const v = args[i + 1];
            if (std.mem.eql(u8, v, "mono")) {
                arch = .mono;
            } else if (std.mem.eql(u8, v, "micro")) {
                arch = .micro;
            } else return error.ParseError;
            i += 1;
        } else if (std.mem.eql(u8, a, "--profile") and i + 1 < args.len) {
            profile = args[i + 1];
            i += 1;
        } else {
            return error.ParseError;
        }
    }

    return .{
        .target = target orelse return error.ParseError,
        .arch = arch,
        .profile = profile,
    };
}

fn parseLifecycleTarget(sub_args: []const []const u8) ?lifecycle.Target {
    if (sub_args.len == 0) return .all;
    if (std.mem.eql(u8, sub_args[0], "--app")) return .app;
    if (std.mem.eql(u8, sub_args[0], "--all")) return .all;
    if (std.mem.eql(u8, sub_args[0], "--service") and sub_args.len >= 2) {
        return .{ .service = sub_args[1] };
    }
    if (std.mem.eql(u8, sub_args[0], "--sse") and sub_args.len >= 2) {
        const buf = std.fmt.allocPrint(std.heap.page_allocator, "{s}_sse", .{sub_args[1]}) catch return null;
        return .{ .service = buf };
    }
    return null;
}

fn showUsage() void {
    std.debug.print(
        \\Usage:
        \\  planctl new  <name> --type <hda|spa> --arch <mono|micro>   scaffold a new project
        \\  planctl add  <name> --type <feature|service> [--arch <hypermedia|rest>]   augment a project
        \\  planctl system <init|start|stop|deinit>  host setup (layout: macOS dev, Linux prod)
        \\
        \\  planctl <file.zsx>                       transform single file → stdout
        \\  planctl <in_dir> <out_dir>               transform all .zsx files
        \\  planctl clean <out_dir>                  remove generated .zig files
        \\  planctl --watch <in_dir> <out_dir>       watch mode
        \\               [--target zig|rust|go]      codegen backend for transforms (default: zig)
        \\
        \\  planctl deploy   --app   [--arch mono|micro]   build + deploy shell/app
        \\  planctl deploy   --service <name>              build + deploy WASM service
        \\  planctl deploy   --sse                         build + deploy SSE subproject only
        \\  planctl deploy   --all   [--arch mono|micro]   deploy app + all services + SSE
        \\
        \\  planctl undeploy --app                   delete shell app (services must be removed first)
        \\  planctl undeploy --service <name>        undeploy a single WASM service
        \\  planctl undeploy --all                   undeploy all services + delete app
        \\               [--force | -f]              skip confirmation prompts
        \\
        \\  planctl start    --app | --service <name> | --sse <app> | --all
        \\  planctl stop     --app | --service <name> | --sse <app> | --all
        \\  planctl restart  --app | --service <name> | --sse <app> | --all
        \\  planctl status   [--app | --service <name> | --sse <app> | --all]   default: --all
        \\
        \\  planctl backup   --app <name> --profile <p> [--output <dir>]
        \\  planctl restore  --app <name> [--service <svc>] --backup <path> --profile <p>
        \\  planctl restore  --system --backup <path>
        \\
        \\  planctl create store <store>          [--app <a>] [--service <s>] [--description <d>] --profile <p>
        \\  planctl create index <store>.<index>  [--type <t>] [--unique] [--field <f>] [--app <a>] [--service <s>] --profile <p>
        \\  planctl drop   store <store>          [--app <a>] [--service <s>] [--force] --profile <p>
        \\  planctl drop   index <store>.<index>  [--app <a>] [--service <s>] [--force] --profile <p>
        \\
        \\  planctl export   --manifest <file.yaml> [--app <a>] [--service <s>] --profile <p>
        \\  planctl import   --manifest <file.yaml> [--app <a>] [--service <s>] [--force] --profile <p>
        \\
        \\  planctl init <name> [--type wasm|app]    (deprecated) use `planctl new` instead
        \\
        \\Profiles:
        \\  Commands that talk to a Workbench require --profile <name>, which
        \\  selects a profile from ~/.planctl/config.yaml.
        \\
    , .{});
    std.process.exit(1);
}
