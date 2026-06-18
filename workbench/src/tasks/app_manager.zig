const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const builtin = @import("builtin");
const utils = @import("utils");
const Yaml = @import("yaml").Yaml;
const dev_supervisor = @import("dev_supervisor.zig");
const RunMode = @import("config.zig").RunMode;

const ServiceControl = utils.ServiceControl;
const labels = utils.labels;

const log = std.log.scoped(.app_manager);

pub const AppStatus = struct {
    state: []const u8,
    pid: ?i32 = null,
    port: u16 = 0,
};

const ProxySpec = struct {
    allocator: std.mem.Allocator,
    binary: []u8,
    config_file: ?[]u8,
    args: [][]u8,

    fn deinit(self: *ProxySpec) void {
        self.allocator.free(self.binary);
        if (self.config_file) |c| self.allocator.free(c);
        for (self.args) |a| self.allocator.free(a);
        self.allocator.free(self.args);
    }
};

pub const AppManager = struct {
    allocator: Allocator,
    io: Io,
    data_dir: []const u8,
    last_proxy_warning: ?[]u8 = null,

    pub fn init(allocator: Allocator, io: Io, data_dir: []const u8) !*AppManager {
        const self = try allocator.create(AppManager);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .data_dir = try allocator.dupe(u8, data_dir),
        };
        return self;
    }

    pub fn deinit(self: *AppManager) void {
        if (self.last_proxy_warning) |w| self.allocator.free(w);
        self.allocator.free(self.data_dir);
        self.allocator.destroy(self);
    }

    pub fn takeProxyWarning(self: *AppManager) ?[]u8 {
        const w = self.last_proxy_warning orelse return null;
        self.last_proxy_warning = null;
        return w;
    }

    fn setProxyWarning(self: *AppManager, msg: []const u8) void {
        if (self.last_proxy_warning) |old| self.allocator.free(old);
        self.last_proxy_warning = self.allocator.dupe(u8, msg) catch null;
    }

    fn clearProxyWarning(self: *AppManager) void {
        if (self.last_proxy_warning) |w| {
            self.allocator.free(w);
            self.last_proxy_warning = null;
        }
    }

    pub fn deploy(self: *AppManager, app: []const u8, binary: []const u8) !void {
        const app_dir = try self.appDir(app);
        defer self.allocator.free(app_dir);

        Dir.createDirPath(.cwd(), self.io, app_dir) catch |e| {
            if (e != error.PathAlreadyExists) return e;
        };
        const public_dir = try std.fmt.allocPrint(self.allocator, "{s}/public", .{app_dir});
        defer self.allocator.free(public_dir);
        Dir.createDirPath(.cwd(), self.io, public_dir) catch |e| {
            if (e != error.PathAlreadyExists) return e;
        };
        const logs_dir = try std.fmt.allocPrint(self.allocator, "{s}/logs", .{app_dir});
        defer self.allocator.free(logs_dir);
        Dir.createDirPath(.cwd(), self.io, logs_dir) catch |e| {
            if (e != error.PathAlreadyExists) return e;
        };

        const bin_path = try std.fmt.allocPrint(self.allocator, "{s}/planck-app-{s}", .{ app_dir, app });
        defer self.allocator.free(bin_path);
        try Dir.writeFile(.cwd(), self.io, .{ .sub_path = bin_path, .data = binary });

        if (comptime builtin.os.tag != .windows) {
            self.runCommand(&.{ "chmod", "+x", bin_path }) catch |err| {
                log.warn("chmod +x failed: {}", .{err});
            };
        }


        const label = try labels.shellApp(self.allocator, app);
        defer self.allocator.free(label);

        var sc = ServiceControl.init(self.allocator);
        sc.stop(self.io, label) catch {};
        sc.unregister(self.io, label) catch {};

        const stdout_log = try std.fmt.allocPrint(self.allocator, "{s}/logs/{s}.out.log", .{ self.data_dir, label });
        defer self.allocator.free(stdout_log);
        const stderr_log = try std.fmt.allocPrint(self.allocator, "{s}/logs/{s}.err.log", .{ self.data_dir, label });
        defer self.allocator.free(stderr_log);
        const log_dir = try std.fmt.allocPrint(self.allocator, "{s}/logs", .{self.data_dir});
        defer self.allocator.free(log_dir);
        Dir.createDirPath(.cwd(), self.io, log_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        try sc.register(self.io, .{
            .name = label,
            .binary = bin_path,
            .workdir = app_dir,
            .description = app,
            .stdout_log = stdout_log,
            .stderr_log = stderr_log,
        });
        try sc.start(self.io, label);

        log.info("deployed shell app '{s}' (label={s})", .{ app, label });

        self.ensureProxyRunning(app, app_dir);
    }

    fn readProxySpec(self: *AppManager, app_dir: []const u8) ?ProxySpec {
        const cfg_path = std.fmt.allocPrint(self.allocator, "{s}/app.yaml", .{app_dir}) catch return null;
        defer self.allocator.free(cfg_path);
        const content = Dir.readFileAlloc(.cwd(), self.io, cfg_path, self.allocator, .unlimited) catch return null;
        defer self.allocator.free(content);

        var binary: ?[]u8 = null;
        var config_file: ?[]u8 = null;
        var args: std.ArrayList([]u8) = .empty;
        errdefer {
            if (binary) |b| self.allocator.free(b);
            if (config_file) |c| self.allocator.free(c);
            for (args.items) |a| self.allocator.free(a);
            args.deinit(self.allocator);
        }

        const ProxyIndent = struct { args: i32 = -1 };
        var indent_state: ProxyIndent = .{};
        var in_proxy = false;
        var in_args = false;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var indent: i32 = 0;
            while (indent < line.len and (line[@intCast(indent)] == ' ' or line[@intCast(indent)] == '\t')) : (indent += 1) {}

            if (indent == 0) {
                in_proxy = std.mem.startsWith(u8, trimmed, "proxy:");
                in_args = false;
                indent_state.args = -1;
                continue;
            }
            if (!in_proxy) continue;

            if (in_args and indent <= indent_state.args) {
                in_args = false;
                indent_state.args = -1;
            }

            if (std.mem.startsWith(u8, trimmed, "binary:")) {
                const rest = std.mem.trim(u8, trimmed["binary:".len..], " \t\"");
                binary = self.allocator.dupe(u8, rest) catch return null;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "config:")) {
                const rest = std.mem.trim(u8, trimmed["config:".len..], " \t\"");
                config_file = self.allocator.dupe(u8, rest) catch return null;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "args:")) {
                in_args = true;
                indent_state.args = indent;
                continue;
            }
            if (in_args and std.mem.startsWith(u8, trimmed, "- ")) {
                const v = std.mem.trim(u8, trimmed[2..], " \t\"");
                const owned = self.allocator.dupe(u8, v) catch return null;
                args.append(self.allocator, owned) catch {
                    self.allocator.free(owned);
                    return null;
                };
            }
        }

        if (binary == null) {
            for (args.items) |a| self.allocator.free(a);
            args.deinit(self.allocator);
            if (config_file) |c| self.allocator.free(c);
            return null;
        }

        if (args.items.len == 0) {
            if (config_file) |cf| {
                args.append(self.allocator, self.allocator.dupe(u8, "run") catch return null) catch return null;
                args.append(self.allocator, self.allocator.dupe(u8, "--config") catch return null) catch return null;
                args.append(self.allocator, self.allocator.dupe(u8, cf) catch return null) catch return null;
                args.append(self.allocator, self.allocator.dupe(u8, "--adapter") catch return null) catch return null;
                args.append(self.allocator, self.allocator.dupe(u8, "caddyfile") catch return null) catch return null;
            }
        }

        return .{
            .allocator = self.allocator,
            .binary = binary.?,
            .config_file = config_file,
            .args = args.toOwnedSlice(self.allocator) catch return null,
        };
    }

    fn resolveProxyBinary(self: *AppManager, name: []const u8) ?[]u8 {
        if (std.fs.path.isAbsolute(name)) {
            return self.allocator.dupe(u8, name) catch null;
        }
        const candidates = [_][]const u8{
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        };
        for (candidates) |dir| {
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, name }) catch continue;
            if (Dir.statFile(.cwd(), self.io, path, .{})) |_| {
                return path;
            } else |_| {
                self.allocator.free(path);
            }
        }
        return null;
    }

    fn ensureProxyRunning(self: *AppManager, app: []const u8, app_dir: []const u8) void {
        var spec = self.readProxySpec(app_dir) orelse return;
        defer spec.deinit();

        const abs_binary = self.resolveProxyBinary(spec.binary) orelse {
            log.err(
                "proxy binary '{s}' not found in any of: " ++
                    "/opt/homebrew/bin, /usr/local/bin, /usr/bin, /bin, " ++
                    "/usr/sbin, /sbin. " ++
                    "App '{s}' will start without its reverse proxy. " ++
                    "Fix: set `proxy.binary:` in app.yaml to an absolute path " ++
                    "(e.g., for Nix users: ~/.nix-profile/bin/caddy; for asdf: " ++
                    "~/.asdf/shims/caddy). Verify with `which {s}` in your shell.",
                .{ spec.binary, app, spec.binary },
            );
            const warning = std.fmt.allocPrint(
                self.allocator,
                "proxy binary '{s}' not found on common paths. App started without its reverse proxy. Set `proxy.binary:` in app.yaml to an absolute path (e.g. ~/.nix-profile/bin/caddy or ~/.asdf/shims/caddy) and redeploy. Verify with `which {s}`.",
                .{ spec.binary, spec.binary },
            ) catch return;
            defer self.allocator.free(warning);
            self.setProxyWarning(warning);
            return;
        };
        defer self.allocator.free(abs_binary);
        self.clearProxyWarning();

        const label = labels.proxyApp(self.allocator, app) catch return;
        defer self.allocator.free(label);

        var sc = ServiceControl.init(self.allocator);
        sc.stop(self.io, label) catch {};
        sc.unregister(self.io, label) catch {};

        const stdout_log = std.fmt.allocPrint(self.allocator, "{s}/logs/{s}.out.log", .{ self.data_dir, label }) catch return;
        defer self.allocator.free(stdout_log);
        const stderr_log = std.fmt.allocPrint(self.allocator, "{s}/logs/{s}.err.log", .{ self.data_dir, label }) catch return;
        defer self.allocator.free(stderr_log);
        const log_dir = std.fmt.allocPrint(self.allocator, "{s}/logs", .{self.data_dir}) catch return;
        defer self.allocator.free(log_dir);
        Dir.createDirPath(.cwd(), self.io, log_dir) catch {};

        sc.register(self.io, .{
            .name = label,
            .binary = abs_binary,
            .workdir = app_dir,
            .description = spec.binary,
            .args = spec.args,
            .stdout_log = stdout_log,
            .stderr_log = stderr_log,
        }) catch |err| {
            log.warn("proxy register failed for app '{s}' (binary={s}): {}", .{ app, abs_binary, err });
            return;
        };
        sc.start(self.io, label) catch |err| {
            log.warn("proxy start failed for app '{s}': {}", .{ app, err });
            return;
        };
        log.info("started proxy for app '{s}' (binary={s}, label={s})", .{ app, abs_binary, label });
    }

    pub fn proxyLifecycle(self: *AppManager, app: []const u8, action: enum { start, stop, restart, undeploy }) void {
        const label = labels.proxyApp(self.allocator, app) catch return;
        defer self.allocator.free(label);
        var sc = ServiceControl.init(self.allocator);
        switch (action) {
            .start => sc.start(self.io, label) catch |err| log.warn("proxy start failed for '{s}': {}", .{ app, err }),
            .stop => sc.stop(self.io, label) catch |err| log.warn("proxy stop failed for '{s}': {}", .{ app, err }),
            .restart => sc.restart(self.io, label) catch |err| log.warn("proxy restart failed for '{s}': {}", .{ app, err }),
            .undeploy => {
                sc.stop(self.io, label) catch {};
                sc.unregister(self.io, label) catch {};
            },
        }
    }

    pub fn deployFile(self: *AppManager, app: []const u8, rel_path: []const u8, data: []const u8) !void {
        const app_dir = try self.appDir(app);
        defer self.allocator.free(app_dir);

        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/public/{s}", .{ app_dir, rel_path });
        defer self.allocator.free(file_path);

        if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |sep| {
            Dir.createDirPath(.cwd(), self.io, file_path[0..sep]) catch {};
        }

        try Dir.writeFile(.cwd(), self.io, .{ .sub_path = file_path, .data = data });
    }


    pub fn start(self: *AppManager, app: []const u8) !void {
        const label = try labels.shellApp(self.allocator, app);
        defer self.allocator.free(label);
        var sc = ServiceControl.init(self.allocator);
        std.debug.print("Starting App: {s} ", .{label});
        sc.start(self.io, label) catch |e| {
            std.debug.print("Error starting App: {s}, Error: {s}", .{ label, @errorName(e) });
            return;
        };

        log.info("started shell app '{s}'", .{app});

        self.proxyLifecycle(app, .start);
    }

    pub fn registerAppFromRestore(self: *AppManager, app: []const u8) !void {
        const app_dir = try self.appDir(app);
        defer self.allocator.free(app_dir);

        const bin_path = try std.fmt.allocPrint(self.allocator, "{s}/planck-app-{s}", .{ app_dir, app });
        defer self.allocator.free(bin_path);

        if (Dir.openFile(.cwd(), self.io, bin_path, .{ .mode = .read_only })) |f| {
            f.close(self.io);
        } else |_| {
            log.info("registerAppFromRestore: no shell binary for '{s}', skipping (mono app)", .{app});
            self.ensureProxyRunning(app, app_dir);
            return;
        }

        if (comptime builtin.os.tag != .windows) {
            self.runCommand(&.{ "chmod", "+x", bin_path }) catch {};
        }

        const label = try labels.shellApp(self.allocator, app);
        defer self.allocator.free(label);

        var sc = ServiceControl.init(self.allocator);
        sc.stop(self.io, label) catch {};
        sc.unregister(self.io, label) catch {};

        const stdout_log = try std.fmt.allocPrint(self.allocator, "{s}/logs/{s}.out.log", .{ self.data_dir, label });
        defer self.allocator.free(stdout_log);
        const stderr_log = try std.fmt.allocPrint(self.allocator, "{s}/logs/{s}.err.log", .{ self.data_dir, label });
        defer self.allocator.free(stderr_log);
        const log_dir = try std.fmt.allocPrint(self.allocator, "{s}/logs", .{self.data_dir});
        defer self.allocator.free(log_dir);
        Dir.createDirPath(.cwd(), self.io, log_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        try sc.register(self.io, .{
            .name = label,
            .binary = bin_path,
            .workdir = app_dir,
            .description = app,
            .stdout_log = stdout_log,
            .stderr_log = stderr_log,
        });
        try sc.start(self.io, label);

        log.info("re-registered shell app '{s}' from restore", .{app});

        self.ensureProxyRunning(app, app_dir);
    }

    pub fn stop(self: *AppManager, app: []const u8) !void {
        const label = try labels.shellApp(self.allocator, app);
        defer self.allocator.free(label);
        var sc = ServiceControl.init(self.allocator);
        try sc.stop(self.io, label);
        log.info("stopped shell app '{s}'", .{app});
        self.proxyLifecycle(app, .stop);
    }

    pub fn restart(self: *AppManager, app: []const u8) !void {

        const label = try labels.shellApp(self.allocator, app);
        defer self.allocator.free(label);
        var sc = ServiceControl.init(self.allocator);
        try sc.restart(self.io, label);
        log.info("restarted shell app '{s}'", .{app});

        const app_dir = self.appDir(app) catch return;
        defer self.allocator.free(app_dir);
        self.ensureProxyRunning(app, app_dir);
    }


    pub fn status(self: *AppManager, app: []const u8, kind: []const u8) AppStatus {
        const app_dir = self.appDir(app) catch return .{ .state = "not_deployed" };
        defer self.allocator.free(app_dir);

        const is_mono = std.mem.eql(u8, kind, "mono");
        const bin_path = if (is_mono)
            std.fmt.allocPrint(self.allocator, "{s}/planck.{s}.db", .{ app_dir, app }) catch return .{ .state = "not_deployed" }
        else
            std.fmt.allocPrint(self.allocator, "{s}/planck-app-{s}", .{ app_dir, app }) catch return .{ .state = "not_deployed" };
        defer self.allocator.free(bin_path);
        _ = Dir.statFile(.cwd(), self.io, bin_path, .{}) catch return .{ .state = "not_deployed" };

        const port = self.readPort(app_dir, is_mono);


        const label = labels.shellApp(self.allocator, app) catch return .{ .state = "stopped", .port = port };
        defer self.allocator.free(label);

        var sc = ServiceControl.init(self.allocator);
        const sc_status = sc.status(self.io, label) catch return .{ .state = "stopped", .port = port };

        const state_str: []const u8 = switch (sc_status.state) {
            .running => "running",
            .stopped => "stopped",
            .crashed => "crashed",
            .not_loaded => "not_deployed",
            .unknown => "stopped",
        };

        return .{ .state = state_str, .pid = sc_status.pid, .port = port };
    }

    pub fn undeploy(self: *AppManager, app: []const u8) !void {

        const label = try labels.shellApp(self.allocator, app);
        defer self.allocator.free(label);

        var sc = ServiceControl.init(self.allocator);
        sc.stop(self.io, label) catch {};
        sc.unregister(self.io, label) catch {};

        self.proxyLifecycle(app, .undeploy);

        log.info("undeployed shell app '{s}'", .{app});
    }


    pub const RestartPolicy = struct {
        enabled: bool = true,
        max_restarts: u32 = 5,
        backoff_base_ms: u64 = 1000,
        backoff_max_ms: u64 = 60000,
        backoff_multiplier: u64 = 2,
    };

    pub fn healthCheckAll(self: *AppManager, restart_counts: *std.StringHashMap(u32), policy: RestartPolicy) void {
        if (!policy.enabled) return;

        const apps_dir_path = std.fmt.allocPrint(self.allocator, "{s}/apps", .{self.data_dir}) catch return;
        defer self.allocator.free(apps_dir_path);

        var apps_dir = Dir.openDir(.cwd(), self.io, apps_dir_path, .{ .iterate = true }) catch return;
        defer apps_dir.close(self.io);

        var iter = apps_dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;

            const st = self.status(entry.name, "");
            if (!std.mem.eql(u8, st.state, "crashed")) {
                if (restart_counts.get(entry.name)) |_| {
                    _ = restart_counts.remove(entry.name);
                }
                continue;
            }

            const count = restart_counts.get(entry.name) orelse 0;
            if (count >= policy.max_restarts) {
                log.err("shell app '{s}' crashed {d} times, not restarting (max {d})", .{ entry.name, count, policy.max_restarts });
                continue;
            }

            var delay_ms = policy.backoff_base_ms;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                delay_ms *= policy.backoff_multiplier;
                if (delay_ms > policy.backoff_max_ms) {
                    delay_ms = policy.backoff_max_ms;
                    break;
                }
            }

            log.warn("shell app '{s}' crashed, restarting (attempt {d}/{d}, backoff {d}ms)", .{ entry.name, count + 1, policy.max_restarts, delay_ms });
            self.io.sleep(Io.Duration.fromMilliseconds(delay_ms), .awake) catch {};

            self.restart(entry.name) catch |err| {
                log.err("failed to restart shell app '{s}': {}", .{ entry.name, err });
            };

            restart_counts.put(entry.name, count + 1) catch {};
        }
    }


    fn appDir(self: *AppManager, app: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/apps/{s}", .{ self.data_dir, app });
    }

    fn readPort(self: *AppManager, app_dir: []const u8, is_mono: bool) u16 {
        if (is_mono) return 0;
        const config_path = std.fmt.allocPrint(self.allocator, "{s}/app.yaml", .{app_dir}) catch return 0;
        defer self.allocator.free(config_path);
        const content = Dir.readFileAlloc(.cwd(), self.io, config_path, self.allocator, .unlimited) catch return 0;
        defer self.allocator.free(content);
        return readShellAppPort(self.allocator, content);
    }

    fn copyFile(self: *AppManager, src: []const u8, dst: []const u8) !void {
        try self.runCommand(&.{ "cp", src, dst });
    }

    fn runCommand(self: *AppManager, argv: []const []const u8) !void {
        const result = try std.process.run(self.allocator, self.io, .{ .argv = argv });
        defer self.allocator.free(result.stderr);
        defer self.allocator.free(result.stdout);
        if (result.term == .exited and result.term.exited != 0) {
            log.err("command failed: {s}", .{result.stderr});
            return error.CommandFailed;
        }
    }
};

const ShellAppCfgSubset = struct {
    app: struct {
        port: u16 = 0,
    } = .{},
};

fn readShellAppPort(allocator: Allocator, content: []const u8) u16 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var yaml: Yaml = .{ .source = content };
    yaml.load(arena.allocator()) catch return 0;
    const parsed = yaml.parse(arena.allocator(), ShellAppCfgSubset) catch return 0;
    return parsed.app.port;
}
