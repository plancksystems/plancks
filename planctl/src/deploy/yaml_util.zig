
const std = @import("std");

pub fn readServiceName(allocator: std.mem.Allocator, yaml: []const u8, default: []const u8) ![]u8 {
    var iter = std.mem.splitScalar(u8, yaml, '\n');
    while (iter.next()) |line| {
        if (!std.mem.startsWith(u8, line, "service_name:")) continue;
        const rest = std.mem.trim(u8, line["service_name:".len..], " \t\r\"'");
        if (rest.len > 0) return allocator.dupe(u8, rest);
        break;
    }
    return allocator.dupe(u8, default);
}

pub fn rewriteName(allocator: std.mem.Allocator, yaml: []const u8, new_name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var rewrote = false;
    var iter = std.mem.splitScalar(u8, yaml, '\n');
    while (iter.next()) |line| {
        if (!rewrote and std.mem.startsWith(u8, line, "name:")) {
            try out.appendSlice(allocator, "name: \"");
            try out.appendSlice(allocator, new_name);
            try out.appendSlice(allocator, "\"");
            rewrote = true;
        } else {
            try out.appendSlice(allocator, line);
        }
        if (iter.index != null) try out.append(allocator, '\n');
    }

    if (!rewrote) {
        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(allocator);
        try prefix.appendSlice(allocator, "name: \"");
        try prefix.appendSlice(allocator, new_name);
        try prefix.appendSlice(allocator, "\"\n");
        try prefix.appendSlice(allocator, out.items);
        return prefix.toOwnedSlice(allocator);
    }

    return out.toOwnedSlice(allocator);
}
