
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

const utils = @import("utils");
const ServiceState = utils.ServiceState;
const ServiceStatus = utils.ServiceStatus;

const process_util = @import("process_util.zig");

const log = std.log.scoped(.dev_supervisor);

const stop_grace_ms: u64 = 5_000;

const stop_poll_ms: u64 = 100;

pub const SpawnOptions = struct {
    binary: []const u8,

    workdir: []const u8,

    args: []const []const u8 = &.{"run"},
};

pub const DevSupervisor = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) DevSupervisor {
        return .{ .allocator = allocator };
    }

    pub fn spawn(self: *DevSupervisor, io: Io, opts: SpawnOptions) !i32 {
        if (comptime builtin.os.tag == .windows) return error.NotImplemented;

        const logs_dir = try std.fmt.allocPrint(self.allocator, "{s}/logs", .{opts.workdir});
        defer self.allocator.free(logs_dir);
        Dir.createDirPath(.cwd(), io, logs_dir) catch {};

        const stdout_path = try std.fmt.allocPrint(self.allocator, "{s}/stdout.log", .{logs_dir});
        defer self.allocator.free(stdout_path);
        const stderr_path = try std.fmt.allocPrint(self.allocator, "{s}/stderr.log", .{logs_dir});
        defer self.allocator.free(stderr_path);

        var argv = try self.allocator.alloc([]const u8, opts.args.len + 1);
        defer self.allocator.free(argv);
        argv[0] = opts.binary;
        for (opts.args, 0..) |a, i| argv[i + 1] = a;

        const cmd = try buildShellCmd(self.allocator, argv, stdout_path, stderr_path);
        defer self.allocator.free(cmd);

        const child = try std.process.spawn(io, .{
            .argv = &.{ "/bin/sh", "-c", cmd },
            .cwd = .{ .path = opts.workdir },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });

        const pid_opt = process_util.pidFromChild(child.id);
        const pid = pid_opt orelse return error.SpawnFailed;

        try writePidFile(self.allocator, io, opts.workdir, pid);

        log.info("dev: spawned '{s}' pid={d} cwd={s}", .{ opts.binary, pid, opts.workdir });
        return pid;
    }

    pub fn stop(self: *DevSupervisor, io: Io, workdir: []const u8) !void {
        const pid_opt = readPidFile(self.allocator, io, workdir) catch null;
        const pid = pid_opt orelse {
            log.debug("dev: stop {s}: no pid file (already stopped)", .{workdir});
            return;
        };

        if (!process_util.isAliveByPid(pid)) {
            log.debug("dev: stop {s}: pid {d} already dead", .{ workdir, pid });
            try deletePidFile(self.allocator, io, workdir);
            return;
        }

        if (comptime builtin.os.tag != .windows) {
            std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch {};
        } else {
            process_util.killByPid(pid);
        }

        var waited: u64 = 0;
        while (waited < stop_grace_ms) : (waited += stop_poll_ms) {
            if (!process_util.isAliveByPid(pid)) break;
            io.sleep(Io.Duration.fromMilliseconds(stop_poll_ms), .awake) catch {};
        }

        if (process_util.isAliveByPid(pid)) {
            log.warn("dev: pid {d} did not exit on SIGTERM, sending SIGKILL", .{pid});
            process_util.killByPid(pid);
        }

        try deletePidFile(self.allocator, io, workdir);
        log.info("dev: stopped pid {d} ({s})", .{ pid, workdir });
    }

    pub fn restart(self: *DevSupervisor, io: Io, opts: SpawnOptions) !void {
        try self.stop(io, opts.workdir);
        _ = try self.spawn(io, opts);
    }

    pub fn status(self: *DevSupervisor, io: Io, workdir: []const u8) !ServiceStatus {
        const pid_opt = readPidFile(self.allocator, io, workdir) catch null;
        const pid = pid_opt orelse return .{ .state = .stopped, .pid = null, .exit_code = null };
        if (process_util.isAliveByPid(pid)) {
            return .{ .state = .running, .pid = pid, .exit_code = null };
        }
        return .{ .state = .stopped, .pid = null, .exit_code = null };
    }
};


fn pidPath(allocator: Allocator, workdir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/pid", .{workdir});
}

pub fn writePidFile(allocator: Allocator, io: Io, workdir: []const u8, pid: i32) !void {
    const path = try pidPath(allocator, workdir);
    defer allocator.free(path);

    var buf: [16]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}\n", .{pid});
    try Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = text });
}

pub fn readPidFile(allocator: Allocator, io: Io, workdir: []const u8) !?i32 {
    const path = try pidPath(allocator, workdir);
    defer allocator.free(path);

    const content = Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i32, trimmed, 10) catch null;
}

pub fn deletePidFile(allocator: Allocator, io: Io, workdir: []const u8) !void {
    const path = try pidPath(allocator, workdir);
    defer allocator.free(path);
    Dir.deleteFile(.cwd(), io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}


fn buildShellCmd(
    allocator: Allocator,
    argv: []const []const u8,
    stdout_path: []const u8,
    stderr_path: []const u8
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "exec");
    for (argv) |arg| {
        try buf.append(allocator, ' ');
        try appendShellQuoted(&buf, allocator, arg);
    }
    try buf.appendSlice(allocator, " >> ");
    try appendShellQuoted(&buf, allocator, stdout_path);
    try buf.appendSlice(allocator, " 2>> ");
    try appendShellQuoted(&buf, allocator, stderr_path);

    return try allocator.dupe(u8, buf.items);
}

fn appendShellQuoted(buf: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
    try buf.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try buf.appendSlice(allocator, "'\\''");
        } else {
            try buf.append(allocator, c);
        }
    }
    try buf.append(allocator, '\'');
}


const testing = std.testing;

test "buildShellCmd: simple argv" {
    const argv = [_][]const u8{ "/bin/echo", "hello", "world" };
    const out = try buildShellCmd(testing.allocator, &argv, "/tmp/o", "/tmp/e");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("exec '/bin/echo' 'hello' 'world' >> '/tmp/o' 2>> '/tmp/e'", out);
}

test "buildShellCmd: argv with single quote escaped" {
    const argv = [_][]const u8{ "/bin/echo", "it's fine" };
    const out = try buildShellCmd(testing.allocator, &argv, "/tmp/o", "/tmp/e");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("exec '/bin/echo' 'it'\\''s fine' >> '/tmp/o' 2>> '/tmp/e'", out);
}

test "buildShellCmd: empty argv still wires the redirects" {
    const argv = [_][]const u8{};
    const out = try buildShellCmd(testing.allocator, &argv, "/tmp/o", "/tmp/e");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("exec >> '/tmp/o' 2>> '/tmp/e'", out);
}

test "buildShellCmd: an argument with spaces stays one token" {
    const argv = [_][]const u8{ "run", "a b c" };
    const out = try buildShellCmd(testing.allocator, &argv, "/o", "/e");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("exec 'run' 'a b c' >> '/o' 2>> '/e'", out);
}
