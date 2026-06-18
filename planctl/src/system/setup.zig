const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils");
const Io = std.Io;
const ServiceControl = utils.ServiceControl;
const labels = utils.labels;

const Role = enum {
    standalone,
    command,
    query,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .standalone => "standalone",
            .command => "command",
            .query => "query",
        };
    }

    pub fn fromString(role: []const u8) !Role {
        if (std.ascii.eqlIgnoreCase(role, "standalone")) return .standalone;
        if (std.ascii.eqlIgnoreCase(role, "command")) return .command;
        if (std.ascii.eqlIgnoreCase(role, "query")) return .query;
        return error.InvalidRole;
    }
};

const Mode = enum {
    dev,
    prod,

    pub fn toString(self: Mode) []const u8 {
        return switch (self) {
            .dev => "dev",
            .prod => "prod",
        };
    }
};

fn modeFromArgs(args: []const [:0]const u8) Mode {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--mode")) {
            const v = args[i + 1];
            if (std.ascii.eqlIgnoreCase(v, "dev")) return .dev;
            if (std.ascii.eqlIgnoreCase(v, "prod")) return .prod;
        }
    }
    return if (comptime builtin.target.os.tag == .macos) .dev else .prod;
}

const Action = enum { install, uninstall, start, stop, upgrade };

const Service = struct {
    name: []const u8,
    description: []const u8,
};

const InstallOpts = struct {
    home: []const u8,
    base: []const u8,
    bin: []const u8,
    apps: []const u8,
    logs: []const u8,
    system: []const u8,
    wb: []const u8,
    sysdb: []const u8 = "",
    sysdb_port: u16 = 23469,
    services: std.StringHashMap(Service),
    action: Action = .install,

    pub fn init(allocator: std.mem.Allocator, home: []const u8) !*InstallOpts {
        var opts = try allocator.create(InstallOpts);

        opts.services = std.StringHashMap(Service).init(allocator);
        opts.home = try allocator.dupe(u8, home);

        try setServices(opts, allocator);
        try setPaths(opts, allocator);
        return opts;
    }

    pub fn reinit(self: *InstallOpts, allocator: std.mem.Allocator) !void {
        try setServices(self, allocator);
        try setPaths(self, allocator);
    }

    fn setServices(self: *InstallOpts, allocator: std.mem.Allocator) !void {
        try self.services.put("workbench", .{
            .name = try labels.workbench(allocator),
            .description = "Planck Workbench",
        });
        try self.services.put("systemdb", .{
            .name = try labels.sysdb(allocator),
            .description = "Planck System DB",
        });
    }

    fn setPaths(self: *InstallOpts, allocator: std.mem.Allocator) !void {
        switch (builtin.os.tag) {
            .macos => {
                const home = self.home;
                self.base = try std.fmt.allocPrint(allocator, "{s}/.planck", .{home});
                self.bin = try std.fmt.allocPrint(allocator, "{s}/.planck/bin", .{home});
                self.apps = try std.fmt.allocPrint(allocator, "{s}/.planck/apps", .{home});
                self.logs = try std.fmt.allocPrint(allocator, "{s}/.planck/logs", .{home});
                self.system = try std.fmt.allocPrint(allocator, "{s}/.planck/system", .{home});
                self.wb = try std.fmt.allocPrint(allocator, "{s}/.planck/workbench", .{home});
                self.sysdb = "planck.system.db";
            },
            .linux => {
                self.base = "/opt/planck";
                self.bin = "/opt/planck/bin";
                self.apps = try std.fmt.allocPrint(allocator, "/opt/planck/apps", .{});
                self.logs = try std.fmt.allocPrint(allocator, "/opt/planck/logs", .{});
                self.system = try std.fmt.allocPrint(allocator, "/opt/planck/system", .{});
                self.wb = try std.fmt.allocPrint(allocator, "/opt/planck/workbench", .{});
                self.sysdb = "planck.system.db";
            },
            .windows => {
                self.base = "C:\\Program Files\\Planck";
                self.bin = "C:\\Program Files\\Planck\\bin";
                self.apps = try std.fmt.allocPrint(allocator, "C:\\Program Files\\Planck\\apps", .{});
                self.logs = try std.fmt.allocPrint(allocator, "C:\\Program Files\\Planck\\logs", .{});
                self.system = try std.fmt.allocPrint(allocator, "C:\\Program Files\\Planck\\system", .{});
                self.wb = try std.fmt.allocPrint(allocator, "C:\\Program Files\\Planck\\workbench", .{});
                self.sysdb = "planck.system.db";
            },
            else => return error.UnsupportedOS,
        }
    }

    pub fn deinit(self: *InstallOpts, allocator: std.mem.Allocator) void {
        allocator.free(self.home);
        allocator.free(self.apps);
        allocator.free(self.logs);
        allocator.free(self.system);
        allocator.free(self.wb);

        if (builtin.os.tag == .macos) {
            allocator.free(self.base);
            allocator.free(self.bin);
        }
    }
};

fn install(allocator: std.mem.Allocator, io: Io, opts: *InstallOpts) !void {
    try createDirs(io, opts);
    try copySystemDb(allocator, io, opts);

    const sysdb_config_path = try std.fmt.allocPrint(allocator, "{s}/db.yaml", .{opts.system});
    defer allocator.free(sysdb_config_path);

    const sysdb_config = try std.fmt.allocPrint(allocator,
        \\name: "systemdb"
        \\node_type: system
        \\primary: true
        \\address: "127.0.0.1"
        \\port: 23469
        \\base_dir: "{s}"
        \\backup_dir: ""
        \\max_sessions: 128
        \\tls:
        \\  enabled: false
        \\session:
        \\  idle_timeout_ms: 0
        \\buffers:
        \\  memtable: 16777216
        \\  vlog: 4194304
        \\  wal: 262144
        \\durability:
        \\  enabled: true
        \\  flush_interval_in_ms: 1000
        \\  log_archive:
        \\      enabled: false
        \\      dest_path: ""
        \\      retain_logs_days: 15
        \\file_sizes:
        \\  vlog: 1073741824
        \\  wal: 16777216
        \\index:
        \\  primary:
        \\      pool_size: 64
        \\  secondary:
        \\      pool_size: 64
        \\cache:
        \\  enabled: false
        \\  capacity: 10000
        \\logging:
        \\  path: "{s}"
        \\  level: info
        \\  max_size_mb: 10
        \\  max_files: 5
        \\gc:
        \\  dead_ratio: 30
        \\limits:
        \\  max_batch_size: 10000
        \\  max_message_size: 16777216
        \\security:
        \\  max_failed_attempts: 5
        \\  lockout_duration_ms: 900000
        \\  lockout_multiplier: 2
        \\replica:
        \\  enabled: false
        \\  sync_interval_ms: 5000
        \\  address: "0.0.0.0"
        \\  port: 0
        \\wasm:
        \\  enabled: false
        \\  min_instances: 2
        \\  max_instances: 8
        \\  autoscale: false
        \\  http:
        \\      port: 3000
        \\      max_connections: 10000
        \\      max_header_size: 8192
        \\      max_body_size: 1048576
        \\      response_buffer_size: 65536
        \\      idle_timeout_ms: 30000
        \\      max_requests_per_connection: 10000
        \\      drain_timeout_ms: 5000
        \\
    , .{
        opts.system,
        opts.logs,
    });
    defer allocator.free(sysdb_config);
    try writeFile(sysdb_config_path, io, sysdb_config);

    const wb_config_path = try std.fmt.allocPrint(allocator, "{s}/config.yaml", .{opts.wb});
    defer allocator.free(wb_config_path);
    const sysdb_binary = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
        opts.system,
        opts.sysdb,
    });
    defer allocator.free(sysdb_binary);

    const wb_config = try std.fmt.allocPrint(allocator,
        \\data_dir: "{s}"
        \\planck_dir: {s}
        \\planck_bin: "{s}/planck"
        \\listen_port: 2369
        \\
        \\logging:
        \\  path: "{s}/workbench.log"
        \\  level: info
        \\  max_size_mb: 10
        \\  max_files: 5
        \\
        \\system_db:
        \\  host: "127.0.0.1"
        \\  port: 23469
        \\
    , .{
        opts.base,
        opts.base,
        opts.bin,
        opts.logs,
    });
    defer allocator.free(wb_config);
    try writeFile(wb_config_path, io, wb_config);

    var sc = ServiceControl.init(allocator);
    const exe_ext: []const u8 = if (comptime builtin.os.tag == .windows) ".exe" else "";

    if (opts.services.get("workbench")) |service| {
        const binary = try std.fmt.allocPrint(allocator, "{s}/planck.workbench{s}", .{ opts.wb, exe_ext });
        defer allocator.free(binary);

        const stdout_log = try std.fmt.allocPrint(allocator, "{s}/logs/workbench.out.log", .{opts.base});
        defer allocator.free(stdout_log);
        const stderr_log = try std.fmt.allocPrint(allocator, "{s}/logs/workbench.err.log", .{opts.base});
        defer allocator.free(stderr_log);

        try sc.register(io, .{
            .name = service.name,
            .binary = binary,
            .workdir = opts.wb,
            .description = service.description,
            .stdout_log = stdout_log,
            .stderr_log = stderr_log,
        });
        try sc.start(io, service.name);
    }

    if (opts.services.get("systemdb")) |service| {
        const binary = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ opts.system, opts.sysdb, exe_ext });
        defer allocator.free(binary);

        const stdout_log = try std.fmt.allocPrint(allocator, "{s}/logs/system.db.out.log", .{opts.base});
        defer allocator.free(stdout_log);
        const stderr_log = try std.fmt.allocPrint(allocator, "{s}/logs/system.db.err.log", .{opts.base});
        defer allocator.free(stderr_log);

        try sc.register(io, .{
            .name = service.name,
            .binary = binary,
            .workdir = opts.system,
            .description = service.description,
            .stdout_log = stdout_log,
            .stderr_log = stderr_log,
        });
        try sc.start(io, service.name);
    }
    std.debug.print("\nInstallation Complete!!!\nNow set the path in environment vars.", .{});
}

fn createDirs(io: Io, opts: *InstallOpts) !void {
    _ = switch (builtin.os.tag) {
        .macos, .linux => {
            try runCmd(io, &.{ "mkdir", "-p", opts.apps });
            try runCmd(io, &.{ "mkdir", "-p", opts.logs });
            try runCmd(io, &.{ "mkdir", "-p", opts.system });
            try runCmd(io, &.{ "mkdir", "-p", opts.wb });
        },
        .windows => {
            try runCmd(io, &.{ "md", opts.apps });
            try runCmd(io, &.{ "md", opts.logs });
            try runCmd(io, &.{ "md", opts.system });
            try runCmd(io, &.{ "md", opts.wb });
        },
        else => return error.UnsupportedOS,
    };
}

fn copySystemDb(allocator: std.mem.Allocator, io: Io, opts: *InstallOpts) !void {
    switch (builtin.os.tag) {
        .macos => {
            const src_sdb = try std.fmt.allocPrint(allocator, "{s}/planck", .{opts.bin});
            defer allocator.free(src_sdb);

            const src_wb = try std.fmt.allocPrint(allocator, "{s}/workbench", .{opts.bin});
            defer allocator.free(src_wb);

            const src_lib = try std.fmt.allocPrint(allocator, "{s}/libwasmer.dylib", .{opts.bin});
            defer allocator.free(src_lib);

            const dest_sdb = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ opts.system, opts.sysdb });
            defer allocator.free(dest_sdb);

            const dest_wb = try std.fmt.allocPrint(allocator, "{s}/planck.workbench", .{opts.wb});
            defer allocator.free(dest_wb);

            const dest_lib = try std.fmt.allocPrint(allocator, "{s}/libwasmer.dylib", .{opts.system});
            defer allocator.free(dest_lib);

            try runCmd(io, &.{ "cp", src_lib, dest_lib });
            try runCmd(io, &.{ "cp", src_sdb, dest_sdb });
            try runCmd(io, &.{ "cp", src_wb, dest_wb });
        },
        .linux => {
            const dest = try std.fmt.allocPrint(allocator, "/opt/planck/system/system.db", .{});
            defer allocator.free(dest);
            try runCmd(io, &.{ "cp", "/opt/planck/bin/planck", dest });

            const wb = try std.fmt.allocPrint(allocator, "/opt/planck/workbench/workbench", .{});
            defer allocator.free(wb);
            try runCmd(io, &.{ "cp", "/opt/planck/bin/workbench", wb });

            const lib = try std.fmt.allocPrint(allocator, "/usr/local/lib/libwasmer.so", .{});
            defer allocator.free(lib);
            try runCmd(io, &.{ "cp", "/opt/planck/bin/libwasmer.so", lib });
        },
        .windows => {
            const dest = try std.fmt.allocPrint(allocator, "C:\\Program Files\\Planck\\System\\system.db.exe", .{});
            defer allocator.free(dest);
            try runCmd(io, &.{ "cp", "C:\\Program Files\\Planck\\bin\\planck.exe", dest });

            const wb = try std.fmt.allocPrint(allocator, "C:\\Program Files\\Planck\\Workbench\\workbench.exe", .{});
            defer allocator.free(wb);
            try runCmd(io, &.{ "cp", "C:\\Program Files\\Planck\\bin\\workbench.exe", wb });
        },
        else => return error.UnsupportedOS,
    }
}

fn writeFile(path: []const u8, io: Io, content: []const u8) !void {
    var file = try Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    var fw = file.writer(io, &.{});
    try fw.interface.writeAll(content);
}

fn isKnownRole(name: []const u8) bool {
    return std.mem.eql(u8, name, "standalone") or
        std.mem.eql(u8, name, "command") or
        std.mem.eql(u8, name, "query");
}

fn start(allocator: std.mem.Allocator, io: Io) !void {
    var sc = ServiceControl.init(allocator);
    const sdb_svc = try labels.sysdb(allocator);
    defer allocator.free(sdb_svc);
    const wb_svc = try labels.workbench(allocator);
    defer allocator.free(wb_svc);
    try sc.start(io, sdb_svc);
    try sc.start(io, wb_svc);
}

fn stop(allocator: std.mem.Allocator, io: Io) !void {
    var sc = ServiceControl.init(allocator);
    const wb_svc = try labels.workbench(allocator);
    defer allocator.free(wb_svc);
    const sdb_svc = try labels.sysdb(allocator);
    defer allocator.free(sdb_svc);
    sc.stop(io, wb_svc) catch {};
    sc.stop(io, sdb_svc) catch {};
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

const LAUNCH_DAEMONS_DIR = "/Library/LaunchDaemons";
const PLANCK_PLIST_PREFIX = "com.planck.";
const PLIST_SUFFIX = ".plist";

fn walkPlanckPlists(
    allocator: std.mem.Allocator,
    io: Io,
    action: *const fn (io: Io, plist_path: []const u8) void,
) !void {
    var dir = Io.Dir.openDir(.cwd(), io, LAUNCH_DAEMONS_DIR, .{ .iterate = true }) catch |err| {
        std.debug.print("  Could not open {s}: {}\n", .{ LAUNCH_DAEMONS_DIR, err });
        return;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, PLANCK_PLIST_PREFIX)) continue;
        if (!std.mem.endsWith(u8, entry.name, PLIST_SUFFIX)) continue;

        const plist_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ LAUNCH_DAEMONS_DIR, entry.name });
        defer allocator.free(plist_path);

        action(io, plist_path);
    }
}

fn bootoutOne(io: Io, plist_path: []const u8) void {
    std.debug.print("  bootout: {s}\n", .{plist_path});
    runCmd(io, &.{ "launchctl", "bootout", "system", plist_path }) catch {};
}

fn bootstrapOne(io: Io, plist_path: []const u8) void {
    std.debug.print("  bootstrap: {s}\n", .{plist_path});
    runCmd(io, &.{ "launchctl", "bootstrap", "system", plist_path }) catch {};
}

fn bootoutAllPlanckPlists(allocator: std.mem.Allocator, io: Io) !void {
    try walkPlanckPlists(allocator, io, bootoutOne);
}

fn bootstrapAllPlanckPlists(allocator: std.mem.Allocator, io: Io) !void {
    try walkPlanckPlists(allocator, io, bootstrapOne);
}

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8, home: []const u8) !void {
    var threaded: Io.Threaded = .init(allocator, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const io = threaded.io();

    var opts: *InstallOpts = try InstallOpts.init(allocator, home);
    errdefer opts.deinit(allocator);

    const cmd = args[2];

    if (std.mem.eql(u8, cmd, "init")) {
        if (args.len < 3) {
            std.debug.print("\nUsage: planctl init \n", .{});
            std.process.exit(1);
        }

        try opts.reinit(allocator);
        try install(allocator, io, opts);
        std.debug.print("\nInstalled,\nStart with: planctl system start\n", .{});
    }

    if (std.mem.eql(u8, cmd, "deinit")) {
        std.debug.print("\nDeInit would just delete the services, binaries and data files would stay as is on the disk. You can delete it using OS commands.\n", .{});
        var base_dir = try Io.Dir.openDir(.cwd(), io, opts.base, .{ .iterate = true });
        defer base_dir.close(io);

        var walker = try base_dir.walk(allocator);
        defer walker.deinit();

        var sc = ServiceControl.init(allocator);

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) {
                const rel_path = entry.path;
                const full_path = try std.fmt.allocPrint(allocator, "{s}", .{rel_path});
                defer allocator.free(full_path);

                if (std.mem.eql(u8, full_path, "workbench")) {
                    const wb_svc: []const u8 = try labels.workbench(allocator);
                    try sc.stop(io, wb_svc);
                    try sc.unregister(io, wb_svc);
                }
                if (std.mem.eql(u8, full_path, "system")) {
                    const sdb_svc: []const u8 = try labels.sysdb(allocator);
                    try sc.stop(io, sdb_svc);
                    try sc.unregister(io, sdb_svc);
                }
            }
        }
    }

    if (std.mem.eql(u8, cmd, "stop")) {
        std.debug.print("\nStopping all Planck Services!!!\n", .{});
        switch (builtin.os.tag) {
            .macos => try bootoutAllPlanckPlists(allocator, io),
            else => std.debug.print("  system stop is only implemented for macOS so far.\n", .{}),
        }
    }

    if (std.mem.eql(u8, cmd, "start")) {
        std.debug.print("\nStarting all Planck Services!!!\n", .{});
        switch (builtin.os.tag) {
            .macos => try bootstrapAllPlanckPlists(allocator, io),
            else => std.debug.print("  system start is only implemented for macOS so far.\n", .{}),
        }
    }

}









