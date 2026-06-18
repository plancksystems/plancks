const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const Attribute = ast.Attribute;

pub const CodegenRust = struct {
    out: std.ArrayList(u8),

    allocator: std.mem.Allocator,

    const void_elements = std.StaticStringMap(void).initComptime(.{
        .{ "area", {} },
        .{ "base", {} },
        .{ "br", {} },
        .{ "col", {} },
        .{ "embed", {} },
        .{ "hr", {} },
        .{ "img", {} },
        .{ "input", {} },
        .{ "link", {} },
        .{ "meta", {} },
        .{ "param", {} },
        .{ "source", {} },
        .{ "track", {} },
        .{ "wbr", {} },
    });

    pub fn init(allocator: std.mem.Allocator) CodegenRust {
        return .{
            .out = std.ArrayList(u8).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CodegenRust) void {
        self.out.deinit(self.allocator);
    }

    fn write(self: *CodegenRust, s: []const u8) !void {
        try self.out.appendSlice(self.allocator, s);
    }

    fn writeFmt(self: *CodegenRust, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(self.allocator, fmt, args);
    }

    fn writeEscapedRustStr(self: *CodegenRust, s: []const u8) !void {
        for (s) |c| switch (c) {
            '"' => try self.write("\\\""),
            '\\' => try self.write("\\\\"),
            '\n' => try self.write("\\n"),
            '\r' => try self.write("\\r"),
            '\t' => try self.write("\\t"),
            else => try self.out.append(self.allocator, c),
        };
    }

 
    pub fn emit(self: *CodegenRust, node: Node) !void {
        try self.emitNode(node);
    }

    pub fn getOutput(self: *const CodegenRust) []const u8 {
        return self.out.items;
    }

 
    fn emitNode(self: *CodegenRust, node: Node) anyerror!void {
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

    fn emitElement(self: *CodegenRust, el: Node.Element) !void {
        try self.write("h.push_str(\"<");
        try self.writeEscapedRustStr(el.tag);

        for (el.attrs) |a| {
            if (a.is_spread) continue;
            try self.write(" ");
            try self.writeEscapedRustStr(a.name);
            switch (a.value) {
                .string => |v| {
                    try self.write("=\\\"");
                    try self.writeEscapedRustStr(v);
                    try self.write("\\\"");
                },
                .expression => |v| {
                    try self.write("=\\\"\");\nh.push_str(&html_escape(&format!(\"{}\", ");
                    try self.write(v);
                    try self.write(")));\nh.push_str(\"\\\"");
                },
                .bare => {},
            }
        }

        const is_void = void_elements.has(el.tag);

        if (is_void) {
            try self.write(" />\");\n");
            return;
        }

        try self.write(">\");\n");

         for (el.children) |child| {
            try self.emitNode(child);
        }

         try self.write("h.push_str(\"</");
        try self.writeEscapedRustStr(el.tag);
        try self.write(">\");\n");
    }

    fn emitText(self: *CodegenRust, t: Node.Text) !void {
        try self.write("h.push_str(\"");
        try self.writeEscapedRustStr(t.content);
        try self.write("\");\n");
    }

    fn emitExpression(self: *CodegenRust, e: Node.Expression) !void {
        try self.write("h.push_str(&html_escape(&format!(\"{}\", ");
        try self.write(e.value);
        try self.write(")));\n");
    }

    fn emitForLoop(self: *CodegenRust, f: Node.ForLoop) !void {
        try self.writeFmt("for {s} in &{s} {{\n", .{ f.iter_var, f.iter_expr });
        for (f.body) |child| {
            try self.emitNode(child);
        }
        try self.write("}\n");
    }

    fn emitIfBlock(self: *CodegenRust, ib: Node.IfBlock) !void {
        try self.writeFmt("if {s} {{\n", .{ib.condition});

        for (ib.then_body) |child| {
            try self.emitNode(child);
        }

        if (ib.else_body) |else_nodes| {
            try self.write("} else {\n");
            for (else_nodes) |child| {
                try self.emitNode(child);
            }
        }

        try self.write("}\n");
    }

    fn emitFragment(self: *CodegenRust, frag: Node.Fragment) !void {
        for (frag.children) |child| {
            try self.emitNode(child);
        }
    }

    fn emitComponent(self: *CodegenRust, comp: Node.Component) !void {
        try self.writeFmt("{s}::render(", .{comp.name});

         if (comp.props.len == 0) {
            try self.write("&Default::default()");
        } else {
            try self.writeFmt("&{s} {{\n", .{comp.name});
            for (comp.props) |a| {
                try self.writeFmt("    {s}: ", .{a.name});
                switch (a.value) {
                    .string => |v| {
                        try self.write("\"");
                        try self.writeEscapedRustStr(v);
                        try self.write("\".to_string(),\n");
                    },
                    .expression => |v| try self.writeFmt("{s},\n", .{v}),
                    .bare => try self.write("true,\n"),
                }
            }
            try self.write("    ..Default::default()\n}");
        }

        try self.write(", &mut h);\n");
    }
};
