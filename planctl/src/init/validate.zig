const std = @import("std");

pub const Error = error{
    Empty,
    BadFirstChar,
    BadChar,
    Reserved,
};

pub fn check(name: []const u8) ?Error {
    if (name.len == 0) return Error.Empty;
    if (!isLowerAlpha(name[0])) return Error.BadFirstChar;
    for (name[1..]) |c| {
        if (!isLowerAlpha(c) and !isDigit(c) and c != '_') return Error.BadChar;
    }
    if (isReserved(name)) return Error.Reserved;
    return null;
}

pub fn messageFor(err: Error, name: []const u8) []const u8 {
    return switch (err) {
        Error.Empty => "name cannot be empty",
        Error.BadFirstChar => "name must start with a lowercase letter (a-z)",
        Error.BadChar => blk: {
            if (std.mem.indexOfScalar(u8, name, '-') != null) {
                break :blk "name cannot contain '-' (Zig package names disallow hyphens; use '_')";
            }
            break :blk "name may only contain [a-z0-9_]";
        },
        Error.Reserved => "name conflicts with a Zig reserved word or known identifier",
    };
}

fn isLowerAlpha(c: u8) bool {
    return c >= 'a' and c <= 'z';
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

const RESERVED = [_][]const u8{
    "addrspace",      "align",       "allowzero", "and",      "anyframe",
    "anytype",        "asm",         "async",     "await",    "break",
    "callconv",       "catch",       "comptime",  "const",    "continue",
    "defer",          "else",        "enum",      "errdefer", "error",
    "export",         "extern",      "fn",        "for",      "if",
    "inline",         "linksection", "noalias",   "noinline", "nosuspend",
    "opaque",         "or",          "orelse",    "packed",   "pub",
    "resume",         "return",      "struct",    "suspend",  "switch",
    "test",           "threadlocal", "try",       "union",    "unreachable",
    "usingnamespace", "var",         "volatile",  "while",    "std",
    "builtin",        "root",        "zig",       "planck",   "schnell",
};

fn isReserved(name: []const u8) bool {
    for (RESERVED) |r| if (std.mem.eql(u8, name, r)) return true;
    return false;
}

test "check: valid names" {
    try std.testing.expectEqual(@as(?Error, null), check("notes"));
    try std.testing.expectEqual(@as(?Error, null), check("notes_app"));
    try std.testing.expectEqual(@as(?Error, null), check("task_tracker_v2"));
    try std.testing.expectEqual(@as(?Error, null), check("a"));
}

test "check: invalid names" {
    try std.testing.expectEqual(@as(?Error, Error.Empty), check(""));
    try std.testing.expectEqual(@as(?Error, Error.BadFirstChar), check("2notes"));
    try std.testing.expectEqual(@as(?Error, Error.BadFirstChar), check("Notes"));
    try std.testing.expectEqual(@as(?Error, Error.BadFirstChar), check("_notes"));
    try std.testing.expectEqual(@as(?Error, Error.BadChar), check("notes-app"));
    try std.testing.expectEqual(@as(?Error, Error.BadChar), check("notes app"));
    try std.testing.expectEqual(@as(?Error, Error.Reserved), check("const"));
    try std.testing.expectEqual(@as(?Error, Error.Reserved), check("std"));
}
