const std = @import("std");


pub const Pos = struct {
    line: u32 = 1,
    col: u32 = 1,
    offset: u32 = 0,

    pub fn format(self: Pos, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{d}:{d}", .{ self.line, self.col });
    }
};

pub const Span = struct {
    start: Pos,
    end: Pos,
};


pub const AttrValue = union(enum) {
    string: []const u8,
    expression: []const u8,
    bare,
};

pub const Attribute = struct {
    name: []const u8,
    value: AttrValue,
    pos: Pos,
    is_spread: bool = false,
};


pub const Node = union(enum) {
    element: Element,
    component: Component,
    text: Text,
    expression: Expression,
    for_loop: ForLoop,
    if_block: IfBlock,
    fragment: Fragment,

    pub const Element = struct {
        tag: []const u8,
        attrs: []Attribute,
        children: []Node,
        self_closing: bool,
        pos: Pos,
    };

    pub const Component = struct {
        name: []const u8,
        props: []Attribute,
        children: []Node,
        self_closing: bool,
        pos: Pos,
    };

    pub const Text = struct {
        content: []const u8,
        pos: Pos,
    };

    pub const Expression = struct {
        value: []const u8,
        pos: Pos,
    };

    pub const ForLoop = struct {
        iter_var: []const u8,
        iter_expr: []const u8,
        body: []Node,
        pos: Pos,
    };

    pub const IfBlock = struct {
        condition: []const u8,
        then_body: []Node,
        else_body: ?[]Node,
        pos: Pos,
    };

    pub const Fragment = struct {
        children: []Node,
        pos: Pos,
    };

    pub fn pos(self: Node) Pos {
        return switch (self) {
            .element => |e| e.pos,
            .component => |c| c.pos,
            .text => |t| t.pos,
            .expression => |e| e.pos,
            .for_loop => |f| f.pos,
            .if_block => |i| i.pos,
            .fragment => |f| f.pos,
        };
    }
};


pub const HttpMethod = enum {
    get,
    post,
    put,
    delete,
    patch,

    pub fn toUpperStr(self: HttpMethod) []const u8 {
        return switch (self) {
            .get => "GET",
            .post => "POST",
            .put => "PUT",
            .delete => "DELETE",
            .patch => "PATCH",
        };
    }
};

pub const RouteAttr = struct {
    name: []const u8,
    method: HttpMethod,
    params_type: ?[]const u8 = null,
    body_type: ?[]const u8 = null,
    handler_type: ?[]const u8 = null,
    fn_name: []const u8 = "",
};


pub const Chunk = union(enum) {
    zig_code: []const u8,
    jsx_return: JsxReturn,
};

pub const JsxReturn = struct {
    root: Node,
    pos: Pos,
    has_allocator_param: bool,
};

pub const Document = struct {
    chunks: []Chunk,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.chunks);
    }
};


pub const Severity = enum {
    err,
    warn,
};

pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    pos: Pos,
    src_file: []const u8,

    pub fn format(self: Diagnostic, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const sev = if (self.severity == .err) "error" else "warning";
        try writer.print("{s}:{}: {s}: {s}", .{ self.src_file, self.pos, sev, self.message });
    }
};
