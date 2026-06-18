const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const Attribute = ast.Attribute;

pub const CodegenZig = struct {
    out: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    const void_elements = std.StaticStringMap(void).initComptime(.{
        .{ "area", {} },  .{ "base", {} }, .{ "br", {} },    .{ "col", {} },
        .{ "embed", {} }, .{ "hr", {} },   .{ "img", {} },   .{ "input", {} },
        .{ "link", {} },  .{ "meta", {} }, .{ "param", {} }, .{ "source", {} },
        .{ "track", {} }, .{ "wbr", {} },
    });

    pub fn init(allocator: std.mem.Allocator) CodegenZig {
        return .{ .out = std.ArrayList(u8).empty, .allocator = allocator };
    }

    pub fn deinit(self: *CodegenZig) void {
        self.out.deinit(self.allocator);
    }

    fn write(self: *CodegenZig, s: []const u8) !void {
        try self.out.appendSlice(self.allocator, s);
    }

    fn writeFmt(self: *CodegenZig, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(self.allocator, fmt, args);
    }

    fn writeEscZig(self: *CodegenZig, s: []const u8) !void {
        for (s) |c| switch (c) {
            '"' => try self.write("\\\""),
            '\\' => try self.write("\\\\"),
            '\n' => try self.write("\\n"),
            '\r' => try self.write("\\r"),
            '\t' => try self.write("\\t"),
            else => try self.out.append(self.allocator, c),
        };
    }

    pub fn emit(self: *CodegenZig, node: Node) !void {
        try self.emitNode(node);
    }

    pub fn getOutput(self: *const CodegenZig) []const u8 {
        return self.out.items;
    }

    fn emitNode(self: *CodegenZig, node: Node) anyerror!void {
        switch (node) {
            .element => |el| try self.emitElement(el),
            .component => |comp| try self.emitComponent(comp),
            .text => |t| try self.emitText(t),
            .expression => |e| try self.emitExpression(e),
            .for_loop => |f| try self.emitForLoop(f),
            .if_block => |i| try self.emitIfBlock(i),
            .fragment => |f| try self.emitFragment(f),
        }
    }

    fn emitElement(self: *CodegenZig, el: Node.Element) !void {
        try self.write("    try out.appendSlice(allocator, \"<");
        try self.writeEscZig(el.tag);

        for (el.attrs) |a| {
            if (a.is_spread) continue;
            try self.write(" ");
            try self.writeEscZig(a.name);
            switch (a.value) {
                .string => |v| {
                    try self.write("=\\\"");
                    try self.writeAttrInterpolated(v);
                    try self.write("\\\"");
                },
                .expression => |v| {
                    try self.write("=\\\"\");\n");
                    try self.writeFmt("    try appendValue(out, allocator, {s});\n", .{v});
                    try self.write("    try out.appendSlice(allocator, \"\\\"");
                },
                .bare => {},
            }
        }

        if (void_elements.has(el.tag)) {
            try self.write(" />\");\n");
            return;
        }

        try self.write(">\");\n");

        for (el.children) |child| {
            try self.emitNode(child);
        }

        try self.write("    try out.appendSlice(allocator, \"</");
        try self.writeEscZig(el.tag);
        try self.write(">\");\n");
    }

    fn writeAttrInterpolated(self: *CodegenZig, v: []const u8) !void {
        var i: usize = 0;
        while (i < v.len) {
            const sigil = std.mem.indexOfPos(u8, v, i, "${");
            if (sigil == null) {
                try self.writeEscZig(v[i..]);
                return;
            }
            const open = sigil.?;
            const expr_start = open + 2;

            var depth: usize = 1;
            var j: usize = expr_start;
            while (j < v.len) : (j += 1) {
                const ch = v[j];
                if (ch == '{') {
                    depth += 1;
                } else if (ch == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (depth != 0) {
                try self.writeEscZig(v[i..]);
                return;
            }

            if (open > i) try self.writeEscZig(v[i..open]);

            const expr = v[expr_start..j];
            try self.write("\");\n");
            try self.writeFmt("    try appendValue(out, allocator, {s});\n", .{expr});
            try self.write("    try out.appendSlice(allocator, \"");

            i = j + 1;
        }
    }

    fn emitText(self: *CodegenZig, t: Node.Text) !void {
        const trimmed = std.mem.trim(u8, t.content, " \t\r\n");
        if (trimmed.len == 0) return;
        try self.write("    try out.appendSlice(allocator, \"");
        try self.writeEscZig(trimmed);
        try self.write("\");\n");
    }

    fn emitExpression(self: *CodegenZig, e: Node.Expression) !void {
        try self.writeFmt("    try appendValue(out, allocator, {s});\n", .{e.value});
    }

    fn emitForLoop(self: *CodegenZig, f: Node.ForLoop) !void {
        try self.writeFmt("    for ({s}) |{s}| {{\n", .{ f.iter_expr, f.iter_var });
        for (f.body) |child| {
            try self.emitNode(child);
        }
        try self.write("    }\n");
    }

    fn emitIfBlock(self: *CodegenZig, ib: Node.IfBlock) !void {
        try self.writeFmt("    if ({s}) {{\n", .{ib.condition});
        for (ib.then_body) |child| {
            try self.emitNode(child);
        }
        if (ib.else_body) |else_nodes| {
            try self.write("    } else {\n");
            for (else_nodes) |child| {
                try self.emitNode(child);
            }
        }
        try self.write("    }\n");
    }

    fn emitFragment(self: *CodegenZig, frag: Node.Fragment) !void {
        for (frag.children) |child| {
            try self.emitNode(child);
        }
    }

    fn emitComponent(self: *CodegenZig, comp: Node.Component) !void {
        try self.writeFmt("    try {s}.render(&out, allocator);\n", .{comp.name});
    }
};
