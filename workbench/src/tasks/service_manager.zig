const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const builtin = @import("builtin");
const utils = @import("utils");
const paths = @import("paths.zig");
const dev_supervisor = @import("dev_supervisor.zig");
const RunMode = @import("config.zig").RunMode;

const ServiceControl = utils.ServiceControl;
const labels = utils.labels;

const log = std.log.scoped(.service_manager);

pub const ServiceState = utils.ServiceState;

pub const ServiceStatus = utils.ServiceStatus;

pub const ProcessMetrics = struct {
    rss_bytes: u64 = 0,
    cpu_time_us: u64 = 0,
};

pub fn getProcessMetrics(pid: i32) ProcessMetrics {
    if (comptime builtin.os.tag == .linux) {
        return getProcessMetricsLinux(pid);
    } else if (comptime builtin.os.tag == .macos) {
        return getProcessMetricsMacos(pid);
    } else {
        return .{};
    }
}

fn getProcessMetricsLinux(pid: i32) ProcessMetrics {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{pid}) catch return .{};

    const fd = std.posix.system.open(path, .{ .ACCMODE = .RDONLY }, @as(std.posix.mode_t, 0));
    if (fd < 0) return .{};
    defer _ = std.posix.system.close(fd);

    var buf: [1024]u8 = undefined;
    const rc = std.posix.system.read(fd, &buf, buf.len);
    if (rc < 0) return .{};
    const n: usize = @intCast(rc);
    const content = buf[0..n];

    const comm_end = std.mem.lastIndexOfScalar(u8, content, ')') orelse return .{};
    var rest = content[comm_end + 2 ..];

    var field_idx: usize = 0;
    var utime: u64 = 0;
    var stime: u64 = 0;
    var rss: u64 = 0;

    while (rest.len > 0) : (field_idx += 1) {
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const token = rest[0..space];

        if (field_idx == 11) {
            utime = std.fmt.parseUnsigned(u64, token, 10) catch 0;
        } else if (field_idx == 12) {
            stime = std.fmt.parseUnsigned(u64, token, 10) catch 0;
        } else if (field_idx == 21) {
            rss = std.fmt.parseUnsigned(u64, token, 10) catch 0;
            break;
        }

        if (space >= rest.len) break;
        rest = rest[space + 1 ..];
    }

    const page_size: u64 = 4096;
    const clock_ticks: u64 = 100;

    return .{
        .rss_bytes = rss * page_size,
        .cpu_time_us = (utime + stime) * (1_000_000 / clock_ticks),
    };
}

const proc_taskinfo_macos = extern struct {
    pti_virtual_size: u64,
    pti_resident_size: u64,
    pti_total_user: u64,
    pti_total_system: u64,
    pti_threads_user: u64,
    pti_threads_system: u64,
    pti_policy: i32,
    pti_faults: i32,
    pti_pageins: i32,
    pti_cow_faults: i32,
    pti_messages_sent: i32,
    pti_messages_received: i32,
    pti_syscalls_mach: i32,
    pti_syscalls_unix: i32,
    pti_csw: i32,
    pti_threadnum: i32,
    pti_numrunning: i32,
    pti_priority: i32,
};

const rusage_info_v2_macos = extern struct {
    ri_uuid: [16]u8,
    ri_user_time: u64,
    ri_system_time: u64,
    ri_pkg_idle_wkups: u64,
    ri_interrupt_wkups: u64,
    ri_pageins: u64,
    ri_wired_size: u64,
    ri_resident_size: u64,
    ri_phys_footprint: u64,
    ri_proc_start_abstime: u64,
    ri_proc_exit_abstime: u64,
    ri_child_user_time: u64,
    ri_child_system_time: u64,
    ri_child_pkg_idle_wkups: u64,
    ri_child_interrupt_wkups: u64,
    ri_child_pageins: u64,
    ri_child_elapsed_abstime: u64,
    ri_diskio_bytesread: u64,
    ri_diskio_byteswritten: u64,
};

const PROC_PIDTASKINFO_MACOS: c_int = 4;
const RUSAGE_INFO_V2_MACOS: c_int = 2;

extern "c" fn proc_pidinfo(
    pid: c_int,
    flavor: c_int,
    arg: u64,
    buffer: ?*anyopaque,
    buffersize: c_int
) c_int;

extern "c" fn proc_pid_rusage(
    pid: c_int,
    flavor: c_int,
    buffer: ?*anyopaque
) c_int;

fn getProcessMetricsMacos(pid: i32) ProcessMetrics {
    var info: proc_taskinfo_macos = undefined;
    const size = proc_pidinfo(pid, PROC_PIDTASKINFO_MACOS, 0, &info, @sizeOf(proc_taskinfo_macos));
    if (size <= 0) return .{};

    var footprint: u64 = info.pti_resident_size;
    var rusage: rusage_info_v2_macos = undefined;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2_MACOS, @ptrCast(&rusage)) == 0) {
        if (rusage.ri_phys_footprint > 0) {
            footprint = rusage.ri_phys_footprint;
        }
    }

    return .{
        .rss_bytes = footprint,
        .cpu_time_us = (info.pti_total_user + info.pti_total_system) / 1000,
    };
}

pub const ServiceManager = struct {
    allocator: Allocator,
    io: Io,
    planck_dir: []const u8,
    data_dir: []const u8,
    planck_bin: []const u8,

    pub fn init(allocator: Allocator, io: Io, planck_dir: []const u8, data_dir: []const u8, planck_bin: []const u8) !*ServiceManager {
        const self = try allocator.create(ServiceManager);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .planck_dir = planck_dir,
            .data_dir = try allocator.dupe(u8, data_dir),
            .planck_bin = try allocator.dupe(u8, planck_bin),
        };
        return self;
    }

    pub fn deinit(self: *ServiceManager) void {
        self.allocator.free(self.data_dir);
        self.allocator.free(self.planck_bin);
        self.allocator.destroy(self);
    }


    pub fn deploy(self: *ServiceManager, app: []const u8, name: []const u8, db_yaml: []const u8, service_yaml: []const u8) !void {
        const svc_dir = try self.serviceDir(app, name);
        defer self.allocator.free(svc_dir);

        {
            const label = try labels.service(self.allocator, app, name);
            defer self.allocator.free(label);
            var sc = ServiceControl.init(self.allocator);
            sc.stop(self.io, label) catch {};
            sc.unregister(self.io, label) catch {};
        }

        try self.runCommand(&.{ "mkdir", "-p", svc_dir });

        const wasm_dir = try std.fmt.allocPrint(self.allocator, "{s}/wasm", .{svc_dir});
        defer self.allocator.free(wasm_dir);
        try self.runCommand(&.{ "mkdir", "-p", wasm_dir });

        const logs_dir = try std.fmt.allocPrint(self.allocator, "{s}/logs", .{svc_dir});
        defer self.allocator.free(logs_dir);
        try self.runCommand(&.{ "mkdir", "-p", logs_dir });

        const db_path = try std.fmt.allocPrint(self.allocator, "{s}/db.yaml", .{svc_dir});
        defer self.allocator.free(db_path);
        try Dir.writeFile(.cwd(), self.io, .{ .sub_path = db_path, .data = db_yaml });

        const svc_yaml_path = try std.fmt.allocPrint(self.allocator, "{s}/service.yaml", .{svc_dir});
        defer self.allocator.free(svc_yaml_path);
        try Dir.writeFile(.cwd(), self.io, .{ .sub_path = svc_yaml_path, .data = service_yaml });

        const binary_name = try self.binaryName(app, name);
        defer self.allocator.free(binary_name);

        const binary_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ svc_dir, binary_name });
        defer self.allocator.free(binary_path);

        try self.copyFile(self.planck_bin, binary_path);

        if (builtin.os.tag == .macos) {
            const lib_path = try std.fmt.allocPrint(self.allocator, "{s}/libwasmer.dylib", .{svc_dir});
            defer self.allocator.free(lib_path);
            const lib_source_path = try std.fmt.allocPrint(self.allocator, "{s}/bin/libwasmer.dylib", .{self.planck_dir});
            defer self.allocator.free(lib_source_path);
            try self.copyFile(lib_source_path, lib_path);
        }

        if (comptime builtin.os.tag != .windows) {
            try self.runCommand(&.{ "chmod", "+x", binary_path });
        }

        const label = try labels.service(self.allocator, app, name);
        defer self.allocator.free(label);

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

        var sc = ServiceControl.init(self.allocator);
        try sc.register(self.io, .{
            .name = label,
            .binary = binary_path,
            .workdir = svc_dir,
            .description = name,
            .stdout_log = stdout_log,
            .stderr_log = stderr_log,
        });
        try sc.start(self.io, label);

        log.info("deployed service '{s}' (label={s})", .{ name, label });
    }

    pub fn deploySseService(self: *ServiceManager, app: []const u8, name: []const u8, sse_yaml: []const u8, binary_data: []const u8) !void {
        const svc_dir = try self.serviceDir(app, name);
        defer self.allocator.free(svc_dir);

        {
            const label = try labels.service(self.allocator, app, name);
            defer self.allocator.free(label);
            var sc = ServiceControl.init(self.allocator);
            sc.stop(self.io, label) catch {};
            sc.unregister(self.io, label) catch {};
        }

        try self.runCommand(&.{ "mkdir", "-p", svc_dir });

        const logs_dir = try std.fmt.allocPrint(self.allocator, "{s}/logs", .{svc_dir});
        defer self.allocator.free(logs_dir);
        try self.runCommand(&.{ "mkdir", "-p", logs_dir });

        const cfg_path = try std.fmt.allocPrint(self.allocator, "{s}/sse.yaml", .{svc_dir});
        defer self.allocator.free(cfg_path);
        try Dir.writeFile(.cwd(), self.io, .{ .sub_path = cfg_path, .data = sse_yaml });

        const binary_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ svc_dir, name });
        defer self.allocator.free(binary_path);
        try Dir.writeFile(.cwd(), self.io, .{ .sub_path = binary_path, .data = binary_data });

        if (comptime builtin.os.tag != .windows) {
            try self.runCommand(&.{ "chmod", "+x", binary_path });
        }

        const label = try labels.service(self.allocator, app, name);
        defer self.allocator.free(label);

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

        var sc = ServiceControl.init(self.allocator);
        try sc.register(self.io, .{
            .name = label,
            .binary = binary_path,
            .workdir = svc_dir,
            .description = name,
            .stdout_log = stdout_log,
            .stderr_log = stderr_log,
            .args = &.{},
        });
        try sc.start(self.io, label);

        log.info("deployed sse service '{s}' (label={s})", .{ name, label });
    }


    pub fn undeploy(self: *ServiceManager, app: []const u8, name: []const u8) !void {
        const label = try labels.service(self.allocator, app, name);
        defer self.allocator.free(label);

        var sc = ServiceControl.init(self.allocator);
        sc.stop(self.io, label) catch |err| log.warn("stop failed for '{s}': {}", .{ name, err });
        sc.unregister(self.io, label) catch |err| log.warn("unregister failed for '{s}': {}", .{ name, err });

        log.info("undeployed service '{s}'", .{name});
    }


    pub fn start(self: *ServiceManager, app: []const u8, name: []const u8) !void {
        const label = try labels.service(self.allocator, app, name);
        defer self.allocator.free(label);
        log.info("starting service '{s}'", .{label});

        var sc = ServiceControl.init(self.allocator);
        try sc.start(self.io, label);
        log.info("started service '{s}'", .{name});
    }

    pub fn stop(self: *ServiceManager, app: []const u8, name: []const u8) !void {
        const label = try labels.service(self.allocator, app, name);
        defer self.allocator.free(label);
        log.info("stopping service '{s}'", .{label});

        var sc = ServiceControl.init(self.allocator);
        try sc.stop(self.io, label);
        log.info("stopped service '{s}'", .{name});
    }

    pub fn restart(self: *ServiceManager, app: []const u8, name: []const u8) !void {

        const label = try labels.service(self.allocator, app, name);
        defer self.allocator.free(label);

        var sc = ServiceControl.init(self.allocator);
        try sc.restart(self.io, label);
        log.info("restarted service '{s}'", .{name});
    }


    pub fn status(self: *ServiceManager, app: []const u8, name: []const u8) !ServiceStatus {
        const label = try labels.service(self.allocator, app, name);
        defer self.allocator.free(label);

        var sc = ServiceControl.init(self.allocator);
        return try sc.status(self.io, label);
    }


    pub fn createAppDir(self: *ServiceManager, app: []const u8) !void {
        const p = paths.Paths{ .data_dir = self.data_dir };
        const svc_dir = try p.appServicesDir(self.allocator, app);
        defer self.allocator.free(svc_dir);
        try self.runCommand(&.{ "mkdir", "-p", svc_dir });
    }

    fn serviceDir(self: *ServiceManager, app: []const u8, name: []const u8) ![]u8 {
        const p = paths.Paths{ .data_dir = self.data_dir };
        return p.serviceDir(self.allocator, app, name);
    }

    fn binaryName(self: *ServiceManager, app: []const u8, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "planck.{s}.{s}.db", .{ app, name});
    }

    fn copyFile(self: *ServiceManager, src: []const u8, dst: []const u8) !void {
        try self.runCommand(&.{ "cp", src, dst });
    }

    pub fn copyBinary(self: *ServiceManager, dst: []const u8) !void {
        try self.copyFile(self.planck_bin, dst);
        if (comptime builtin.os.tag != .windows) {
            try self.runCommand(&.{ "chmod", "+x", dst });
        }
    }

    fn runCommand(self: *ServiceManager, argv: []const []const u8) !void {
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term == .exited and result.term.exited != 0) {
            if (result.stderr.len > 0) {
                log.err("command failed: {s}", .{result.stderr});
            }
            return error.CommandFailed;
        }
    }
};
