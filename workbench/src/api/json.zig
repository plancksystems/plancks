const std = @import("std");

pub fn serialize(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try writeValue(&buf, allocator, value);
    return buf.toOwnedSlice(allocator);
}

fn writeValue(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .@"struct" => |s| {
            try buf.append(allocator, '{');
            var first = true;
            inline for (s.fields) |field| {
                const field_val = @field(value, field.name);
                const field_info = @typeInfo(field.type);

                if (comptime field_info == .optional) {
                    if (field_val) |unwrapped| {
                        if (!first) try buf.append(allocator, ',');
                        first = false;
                        try buf.append(allocator, '"');
                        try buf.appendSlice(allocator, field.name);
                        try buf.appendSlice(allocator, "\":");
                        try writeValue(buf, allocator, unwrapped);
                    }
                } else {
                    if (!first) try buf.append(allocator, ',');
                    first = false;
                    try buf.append(allocator, '"');
                    try buf.appendSlice(allocator, field.name);
                    try buf.appendSlice(allocator, "\":");
                    try writeValue(buf, allocator, field_val);
                }
            }
            try buf.append(allocator, '}');
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                if (ptr.child == u8) {
                    try writeString(buf, allocator, value);
                } else {
                    try buf.append(allocator, '[');
                    for (value, 0..) |item, i| {
                        if (i > 0) try buf.append(allocator, ',');
                        try writeValue(buf, allocator, item);
                    }
                    try buf.append(allocator, ']');
                }
            } else {
                try buf.appendSlice(allocator, "null");
            }
        },
        .bool => {
            try buf.appendSlice(allocator, if (value) "true" else "false");
        },
        .int => {
            var num_buf: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch "0";
            try buf.appendSlice(allocator, s);
        },
        .float => {
            var num_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d:.2}", .{value}) catch "0";
            try buf.appendSlice(allocator, s);
        },
        .@"enum" => {
            try buf.append(allocator, '"');
            try buf.appendSlice(allocator, @tagName(value));
            try buf.append(allocator, '"');
        },
        else => {
            try buf.appendSlice(allocator, "null");
        },
    }
}

fn writeString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.appendSlice(allocator, "\\u00");
                    const hex = "0123456789abcdef";
                    try buf.append(allocator, hex[c >> 4]);
                    try buf.append(allocator, hex[c & 0x0f]);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}
