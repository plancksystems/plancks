
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    AnchorNotFound,
} || Allocator.Error || Io.Dir.ReadFileError || Io.Dir.WriteFileError;

pub fn insertAfterLast(
    allocator: Allocator,
    contents: []const u8,
    anchor: []const u8,
    block: []const u8
) ![]u8 {
    const block_trimmed = std.mem.trimEnd(u8, block, "\n");
    if (block_trimmed.len > 0 and std.mem.indexOf(u8, contents, block_trimmed) != null) {
        return allocator.dupe(u8, contents);
    }

    const anchor_idx = lastLineContaining(contents, anchor) orelse return error.AnchorNotFound;
    const insert_at = endOfLine(contents, anchor_idx);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, contents[0..insert_at]);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, block);
    if (insert_at < contents.len) try out.appendSlice(allocator, contents[insert_at..]);
    return out.toOwnedSlice(allocator);
}

pub fn insertBeforeFirst(
    allocator: Allocator,
    contents: []const u8,
    anchor: []const u8,
    block: []const u8
) ![]u8 {
    const block_trimmed = std.mem.trimEnd(u8, block, "\n");
    if (block_trimmed.len > 0 and std.mem.indexOf(u8, contents, block_trimmed) != null) {
        return allocator.dupe(u8, contents);
    }

    const anchor_idx = firstLineContaining(contents, anchor) orelse return error.AnchorNotFound;
    const insert_at = startOfLine(contents, anchor_idx);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, contents[0..insert_at]);
    try out.appendSlice(allocator, block);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, contents[insert_at..]);
    return out.toOwnedSlice(allocator);
}

pub fn readFile(allocator: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8) ![]u8 {
    return Io.Dir.readFileAlloc(dir, io, sub_path, allocator, .unlimited);
}

pub fn writeFile(io: Io, dir: Io.Dir, sub_path: []const u8, data: []const u8) !void {
    try Io.Dir.writeFile(dir, io, .{ .sub_path = sub_path, .data = data });
}


fn firstLineContaining(s: []const u8, needle: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        const line_end = endOfLine(s, i);
        if (std.mem.indexOf(u8, s[i..line_end], needle) != null) return i;
        i = if (line_end < s.len) line_end + 1 else line_end;
    }
    return null;
}

fn lastLineContaining(s: []const u8, needle: []const u8) ?usize {
    var last: ?usize = null;
    var i: usize = 0;
    while (i < s.len) {
        const line_end = endOfLine(s, i);
        if (std.mem.indexOf(u8, s[i..line_end], needle) != null) last = i;
        i = if (line_end < s.len) line_end + 1 else line_end;
    }
    return last;
}

fn startOfLine(s: []const u8, pos: usize) usize {
    _ = s;
    return pos;
}

fn endOfLine(s: []const u8, from: usize) usize {
    if (std.mem.indexOfScalarPos(u8, s, from, '\n')) |nl| return nl;
    return s.len;
}


test "insertAfterLast: appends to last match" {
    const a = std.testing.allocator;
    const src =
        \\const x_routes = @import("a/routes.zig");
        \\const y_routes = @import("b/routes.zig");
        \\
        \\pub fn main() void {}
    ;
    const out = try insertAfterLast(a, src, "_routes = @import(", "const z_routes = @import(\"c/routes.zig\");\n");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "const z_routes") != null);
    const expected =
        \\const x_routes = @import("a/routes.zig");
        \\const y_routes = @import("b/routes.zig");
        \\const z_routes = @import("c/routes.zig");
        \\
        \\
        \\pub fn main() void {}
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "insertAfterLast: idempotent on second call" {
    const a = std.testing.allocator;
    const src =
        \\const x_routes = @import("a/routes.zig");
        \\const y_routes = @import("b/routes.zig");
    ;
    const first = try insertAfterLast(a, src, "y_routes = @import(", "const z_routes = @import(\"c/routes.zig\");\n");
    defer a.free(first);
    const second = try insertAfterLast(a, first, "y_routes = @import(", "const z_routes = @import(\"c/routes.zig\");\n");
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "insertBeforeFirst: prepends ahead of catch-all" {
    const a = std.testing.allocator;
    const src =
        \\handle /tasks* {
        \\    reverse_proxy 127.0.0.1:4001
        \\}
        \\
        \\handle {
        \\    reverse_proxy 127.0.0.1:4000
        \\}
    ;
    const block = "\thandle /notes* {\n\t\treverse_proxy 127.0.0.1:4002\n\t}";
    const out = try insertBeforeFirst(a, src, "handle {", block);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "/notes*") != null);
    const notes_at = std.mem.indexOf(u8, out, "/notes*").?;
    const catchall_at = std.mem.indexOf(u8, out, "handle {").?;
    try std.testing.expect(notes_at < catchall_at);
}

test "insertAfterLast: anchor not found" {
    const a = std.testing.allocator;
    const out = insertAfterLast(a, "nothing here", "missing", "ignored\n");
    try std.testing.expectError(error.AnchorNotFound, out);
}
