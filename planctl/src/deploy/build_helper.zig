
const std = @import("std");
const Io = std.Io;

pub const BuildResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: BuildResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn runBuild(
    allocator: std.mem.Allocator,
    io: Io,
    cwd: []const u8,
    extra_args: []const []const u8
) !BuildResult {
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, "zig");
    try argv_list.append(allocator, "build");
    try argv_list.appendSlice(allocator, extra_args);

    const first = try std.process.run(allocator, io, .{
        .argv = argv_list.items,
        .cwd = .{ .path = cwd },
    });

    const exited_ok = first.term == .exited and first.term.exited == 0;
    if (exited_ok) return .{ .stdout = first.stdout, .stderr = first.stderr, .term = first.term };

    const suggested = parseSuggestedFingerprint(first.stderr) orelse {
        return .{ .stdout = first.stdout, .stderr = first.stderr, .term = first.term };
    };

    const zon_path = try std.fmt.allocPrint(allocator, "{s}/build.zig.zon", .{cwd});
    defer allocator.free(zon_path);

    rewriteFingerprint(allocator, io, zon_path, suggested) catch |err| {
        std.debug.print("  Warning: auto-fingerprint rewrite failed ({s}) — leaving build error as-is.\n", .{@errorName(err)});
        return .{ .stdout = first.stdout, .stderr = first.stderr, .term = first.term };
    };
    std.debug.print("  Auto-filled fingerprint {s} in {s} (was 0x0...; see gaps.md §2.3).\n", .{ suggested, zon_path });

    allocator.free(first.stdout);
    allocator.free(first.stderr);

    const second = try std.process.run(allocator, io, .{
        .argv = argv_list.items,
        .cwd = .{ .path = cwd },
    });
    return .{ .stdout = second.stdout, .stderr = second.stderr, .term = second.term };
}

fn parseSuggestedFingerprint(stderr: []const u8) ?[]const u8 {
    const marker = "use this value: 0x";
    const idx = std.mem.indexOf(u8, stderr, marker) orelse return null;
    const start = idx + marker.len - 2;
    var end = start + 2;
    while (end < stderr.len) : (end += 1) {
        const c = stderr[end];
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!is_hex) break;
    }
    if (end - start <= 2) return null;
    return stderr[start..end];
}

fn rewriteFingerprint(allocator: std.mem.Allocator, io: Io, path: []const u8, new_value: []const u8) !void {
    const content = try Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .unlimited);
    defer allocator.free(content);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var replaced = false;
    while (lines.next()) |raw_line| {
        if (!replaced) {
            if (std.mem.indexOf(u8, raw_line, ".fingerprint")) |_| {
                if (std.mem.indexOf(u8, raw_line, "=")) |eq_idx| {
                    try out.appendSlice(allocator, raw_line[0 .. eq_idx + 1]);
                    try out.append(allocator, ' ');
                    try out.appendSlice(allocator, new_value);
                    try out.append(allocator, ',');
                    try out.append(allocator, '\n');
                    replaced = true;
                    continue;
                }
            }
        }
        try out.appendSlice(allocator, raw_line);
        try out.append(allocator, '\n');
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        _ = out.pop();
    }

    if (!replaced) return error.FingerprintLineNotFound;
    try Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = out.items });
}

const testing = std.testing;

test "parseSuggestedFingerprint extracts 0x... hex" {
    const stderr =
        \\error: invalid fingerprint: 0xb12d4a367f3846e4; if this is a new or forked package, use this value: 0xec224caa6cf4f0fd
        \\.{
        \\ ^
    ;
    const fp = parseSuggestedFingerprint(stderr) orelse return error.NotFound;
    try testing.expectEqualStrings("0xec224caa6cf4f0fd", fp);
}

test "parseSuggestedFingerprint missing marker → null" {
    const fp = parseSuggestedFingerprint("some other error");
    try testing.expect(fp == null);
}
