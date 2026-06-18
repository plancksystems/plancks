const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const Attribute = ast.Attribute;

pub const CodegenGo = struct {
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

    pub fn init(allocator: std.mem.Allocator) CodegenGo {
        return .{
            .out = std.ArrayList(u8).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CodegenGo) void {
        self.out.deinit(self.allocator);
    }

    fn write(self: *CodegenGo, s: []const u8) !void {
        try self.out.appendSlice(self.allocator, s);
    }

    fn writeFmt(self: *CodegenGo, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(self.allocator, fmt, args);
    }

    fn writeEscapedGoStr(self: *CodegenGo, s: []const u8) !void {
        for (s) |c| switch (c) {
            '"' => try self.write("\\\""),
            '\\' => try self.write("\\\\"),
            '\n' => try self.write("\\n"),
            '\r' => try self.write("\\r"),
            '\t' => try self.write("\\t"),
            else => try self.out.append(self.allocator, c),
        };
    }

 
    pub fn emit(self: *CodegenGo, node: Node) !void {
        try self.emitNode(node);
    }

    pub fn getOutput(self: *const CodegenGo) []const u8 {
        return self.out.items;
    }

 
    fn emitNode(self: *CodegenGo, node: Node) anyerror!void {
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

    fn emitElement(self: *CodegenGo, el: Node.Element) !void {
        try self.write("b.WriteString(\"<");
        try self.writeEscapedGoStr(el.tag);

        for (el.attrs) |a| {
            if (a.is_spread) continue;
            try self.write(" ");
            try self.writeEscapedGoStr(a.name);
            switch (a.value) {
                .string => |v| {
                    try self.write("=\\\"");
                    try self.writeEscapedGoStr(v);
                    try self.write("\\\"");
                },
                .expression => |v| {
                    try self.write("=\\\"\")\nb.WriteString(html.EscapeString(fmt.Sprintf(\"%v\", ");
                    try self.write(v);
                    try self.write(")))\nb.WriteString(\"\\\"");
                },
                .bare => {},
            }
        }

        const is_void = void_elements.has(el.tag);

        if (is_void) {
            try self.write(" />\")\n");
            return;
        }

        try self.write(">\")\n");

        for (el.children) |child| {
            try self.emitNode(child);
        }

        try self.write("b.WriteString(\"</");
        try self.writeEscapedGoStr(el.tag);
        try self.write(">\")\n");
    }

    fn emitText(self: *CodegenGo, t: Node.Text) !void {
        try self.write("b.WriteString(\"");
        try self.writeEscapedGoStr(t.content);
        try self.write("\")\n");
    }

    fn emitExpression(self: *CodegenGo, e: Node.Expression) !void {
        try self.write("b.WriteString(html.EscapeString(fmt.Sprintf(\"%v\", ");
        try self.write(e.value);
        try self.write(")))\n");
    }

    fn emitForLoop(self: *CodegenGo, f: Node.ForLoop) !void {
        try self.writeFmt("for _, {s} := range {s} {{\n", .{ f.iter_var, f.iter_expr });
        for (f.body) |child| {
            try self.emitNode(child);
        }
        try self.write("}\n");
    }

    fn emitIfBlock(self: *CodegenGo, ib: Node.IfBlock) !void {
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

    fn emitFragment(self: *CodegenGo, frag: Node.Fragment) !void {
        for (frag.children) |child| {
            try self.emitNode(child);
        }
    }

    fn emitComponent(self: *CodegenGo, comp: Node.Component) !void {
        if (comp.props.len == 0) {
            try self.writeFmt("{s}{{}}.Render(&b)\n", .{comp.name});
        } else {
            try self.writeFmt("{s}{{\n", .{comp.name});
            for (comp.props) |a| {
                if (a.name.len > 0) {
                    var upper: [1]u8 = .{std.ascii.toUpper(a.name[0])};
                    try self.writeFmt("    {s}{s}: ", .{ &upper, a.name[1..] });
                }
                switch (a.value) {
                    .string => |v| {
                        try self.write("\"");
                        try self.writeEscapedGoStr(v);
                        try self.write("\",\n");
                    },
                    .expression => |v| try self.writeFmt("{s},\n", .{v}),
                    .bare => try self.write("true,\n"),
                }
            }
            try self.write("}.Render(&b)\n");
        }
    }
};
