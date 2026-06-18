const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const TokenTag = @import("lexer.zig").TokenTag;
const Token = @import("lexer.zig").Token;
const Pos = ast.Pos;
const Node = ast.Node;
const Attribute = ast.Attribute;
const Diagnostic = ast.Diagnostic;

pub const Parser = struct {
    lexer: Lexer,

    allocator: std.mem.Allocator,

    diagnostics: std.ArrayList(Diagnostic),

    src_file: []const u8,

    pub fn init(allocator: std.mem.Allocator, src: []const u8, src_file: []const u8) Parser {
        return .{
            .lexer = Lexer.init(src),
            .allocator = allocator,
            .diagnostics = std.ArrayList(Diagnostic).empty,
            .src_file = src_file,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.diagnostics.deinit(self.allocator);
    }

    fn err(self: *Parser, pos: Pos, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.diagnostics.append(self.allocator, .{
            .severity = .err,
            .message = msg,
            .pos = pos,
            .src_file = self.src_file,
        });
    }

    fn warn(self: *Parser, pos: Pos, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.diagnostics.append(self.allocator, .{
            .severity = .warn,
            .message = msg,
            .pos = pos,
            .src_file = self.src_file,
        });
    }

    fn isComponent(name: []const u8) bool {
        return name.len > 0 and std.ascii.isUpper(name[0]);
    }


    pub fn parseRoot(self: *Parser) !Node {
        self.lexer.skipWhitespace();
        if (self.lexer.pos >= self.lexer.src.len) {
            try self.err(self.lexer.currentPos(), "expected JSX content", .{});
            return Node{ .text = .{ .content = "", .pos = self.lexer.currentPos() } };
        }

        return try self.parseNode();
    }


    pub fn parseNode(self: *Parser) anyerror!Node {
        self.lexer.skipWhitespace();

        if (self.lexer.pos >= self.lexer.src.len) {
            return Node{ .text = .{ .content = "", .pos = self.lexer.currentPos() } };
        }

        const c = self.lexer.peek() orelse {
            return Node{ .text = .{ .content = "", .pos = self.lexer.currentPos() } };
        };

        if (c == '<') return self.parseTag();
        if (c == '{') return self.parseCurly();

        return self.parseText();
    }

    fn parseTag(self: *Parser) anyerror!Node {
        const tok = try self.lexer.next();
        switch (tok.tag) {
            .fragment_open => return self.parseFragment(tok.pos),
            .open_tag_start => return self.parseElement(tok.text, tok.pos),
            else => {
                try self.err(tok.pos, "unexpected token: {s}", .{tok.text});
                return Node{ .text = .{ .content = "", .pos = tok.pos } };
            },
        }
    }

    fn parseCurly(self: *Parser) anyerror!Node {
        const tok = try self.lexer.next();
        switch (tok.tag) {
            .expression => return Node{ .expression = .{ .value = tok.text, .pos = tok.pos } },
            .for_open => return self.parseForBlock(tok),
            .if_open => return self.parseIfBlock(tok),
            else => {
                try self.err(tok.pos, "unexpected control token", .{});
                return Node{ .text = .{ .content = "", .pos = tok.pos } };
            },
        }
    }

    fn parseText(self: *Parser) anyerror!Node {
        const p = self.lexer.currentPos();
        const start = self.lexer.pos;
        while (self.lexer.peek()) |c| {
            if (c == '<' or c == '{') break;
            _ = self.lexer.advance();
        }
        const raw = self.lexer.src[start..self.lexer.pos];

        const ltrimmed = std.mem.trimStart(u8, raw, " \t\n\r");
        const has_trailing_space = ltrimmed.len > 0 and
            (ltrimmed[ltrimmed.len - 1] == ' ' or ltrimmed[ltrimmed.len - 1] == '\t');
        var trimmed = std.mem.trimEnd(u8, ltrimmed, " \t\n\r");
        if (trimmed.len == 0) {
            return self.parseNode();
        }
        if (has_trailing_space and self.lexer.pos < self.lexer.src.len) {
            trimmed = ltrimmed[0 .. ltrimmed.len - std.mem.trimEnd(u8, ltrimmed, " \t\n\r").len + trimmed.len];
            const with_space = try self.allocator.alloc(u8, trimmed.len + 1);
            @memcpy(with_space[0..trimmed.len], trimmed);
            with_space[trimmed.len] = ' ';
            trimmed = with_space;
        }
        return Node{ .text = .{ .content = trimmed, .pos = p } };
    }


    fn parseElement(self: *Parser, name: []const u8, pos: Pos) anyerror!Node {
        const attrs = try self.lexer.readAttrs(self.allocator);
        const end_tag = try self.lexer.expectTagEnd();

        if (end_tag == .self_close_end) {
            if (isComponent(name)) {
                return Node{ .component = .{
                    .name = name,
                    .props = attrs,
                    .children = &.{},
                    .self_closing = true,
                    .pos = pos,
                } };
            }
            return Node{ .element = .{
                .tag = name,
                .attrs = attrs,
                .children = &.{},
                .self_closing = true,
                .pos = pos,
            } };
        }

        const children = try self.parseChildren(name);

        if (isComponent(name)) {
            return Node{ .component = .{
                .name = name,
                .props = attrs,
                .children = children,
                .self_closing = false,
                .pos = pos,
            } };
        }
        return Node{ .element = .{
            .tag = name,
            .attrs = attrs,
            .children = children,
            .self_closing = false,
            .pos = pos,
        } };
    }

    fn parseChildren(self: *Parser, close_name: []const u8) anyerror![]Node {
        var children = std.ArrayList(Node).empty;

        while (self.lexer.pos < self.lexer.src.len) {
            self.lexer.skipWhitespace();
            if (self.lexer.pos >= self.lexer.src.len) break;

            const c = self.lexer.peek() orelse break;

            if (c == '<') {
                if (self.lexer.peekAt(1) == '/') {
                    if (self.lexer.peekAt(2) == '>') {
                        break;
                    }
                    const saved_pos = self.lexer.pos;
                    const saved_line = self.lexer.line;
                    const saved_col = self.lexer.col;
                    _ = self.lexer.advance();
                    _ = self.lexer.advance();
                    const tag_name = self.lexer.readName();
                    self.lexer.skipWhitespace();
                    if (self.lexer.peek() == '>') _ = self.lexer.advance();

                    if (std.mem.eql(u8, tag_name, close_name)) {
                        break;
                    } else {
                        try self.err(
                            .{ .line = saved_line, .col = saved_col, .offset = @intCast(saved_pos) },
                            "expected </{s}>, found </{s}>",
                            .{ close_name, tag_name },
                        );
                        break;
                    }
                }

                const node = try self.parseTag();
                try children.append(self.allocator, node);
            } else if (c == '{') {
                const node = try self.parseCurly();
                try children.append(self.allocator, node);
            } else {
                const node = try self.parseText();
                try children.append(self.allocator, node);
            }
        }

        return children.toOwnedSlice(self.allocator);
    }

    fn parseFragment(self: *Parser, pos: Pos) anyerror!Node {
        var children = std.ArrayList(Node).empty;

        while (self.lexer.pos < self.lexer.src.len) {
            self.lexer.skipWhitespace();
            if (self.lexer.pos >= self.lexer.src.len) {
                try self.err(pos, "unclosed fragment <>", .{});
                break;
            }

            const c = self.lexer.peek() orelse break;

            if (c == '<') {
                if (self.lexer.peekAt(1) == '/' and self.lexer.peekAt(2) == '>') {
                    _ = self.lexer.advance();
                    _ = self.lexer.advance();
                    _ = self.lexer.advance();
                    break;
                }
                if (self.lexer.peekAt(1) == '/') break;

                const node = try self.parseTag();
                try children.append(self.allocator, node);
            } else if (c == '{') {
                const node = try self.parseCurly();
                try children.append(self.allocator, node);
            } else {
                const node = try self.parseText();
                try children.append(self.allocator, node);
            }
        }

        return Node{ .fragment = .{
            .children = try children.toOwnedSlice(self.allocator),
            .pos = pos,
        } };
    }


    fn parseForBlock(self: *Parser, tok: Token) anyerror!Node {
        const inner = std.mem.trim(u8, tok.text, "{}");
        const rest = std.mem.trimStart(u8, inner, " \t\n\r");
        const after_for = if (std.mem.startsWith(u8, rest, "for ")) rest[4..] else rest;
        const trimmed = std.mem.trimStart(u8, after_for, " \t\n\r");

        var iter_var: []const u8 = "";
        var iter_expr: []const u8 = "";
        if (std.mem.indexOf(u8, trimmed, " in ")) |in_pos| {
            iter_var = std.mem.trim(u8, trimmed[0..in_pos], " \t\n\r");
            iter_expr = std.mem.trim(u8, trimmed[in_pos + 4 ..], " \t\n\r");
        }

        var body = std.ArrayList(Node).empty;
        while (self.lexer.pos < self.lexer.src.len) {
            self.lexer.skipWhitespace();
            if (self.lexer.pos >= self.lexer.src.len) {
                try self.err(tok.pos, "unclosed {{for}} block - missing {{/for}}", .{});
                break;
            }

            const c = self.lexer.peek() orelse break;
            if (c == '{') {
                if (self.isControlClose("for")) {
                    const close = try self.lexer.next();
                    _ = close;
                    break;
                }
                const node = try self.parseCurly();
                try body.append(self.allocator, node);
            } else if (c == '<') {
                const node = try self.parseTag();
                try body.append(self.allocator, node);
            } else {
                const node = try self.parseText();
                try body.append(self.allocator, node);
            }
        }

        return Node{ .for_loop = .{
            .iter_var = iter_var,
            .iter_expr = iter_expr,
            .body = try body.toOwnedSlice(self.allocator),
            .pos = tok.pos,
        } };
    }

    fn parseIfBlock(self: *Parser, tok: Token) anyerror!Node {
        const inner = std.mem.trim(u8, tok.text, "{}");
        const rest = std.mem.trimStart(u8, inner, " \t\n\r");
        const cond = if (std.mem.startsWith(u8, rest, "if "))
            std.mem.trim(u8, rest[3..], " \t\n\r")
        else
            rest;

        var then_body = std.ArrayList(Node).empty;
        var else_body: ?std.ArrayList(Node) = null;
        var current = &then_body;

        while (self.lexer.pos < self.lexer.src.len) {
            self.lexer.skipWhitespace();
            if (self.lexer.pos >= self.lexer.src.len) {
                try self.err(tok.pos, "unclosed {{if}} block - missing {{/if}}", .{});
                break;
            }

            const c = self.lexer.peek() orelse break;
            if (c == '{') {
                if (self.isControlClose("if")) {
                    const close = try self.lexer.next();
                    _ = close;
                    break;
                }
                if (self.isElseTag()) {
                    const etag = try self.lexer.next();
                    _ = etag;
                    else_body = std.ArrayList(Node).empty;
                    current = &else_body.?;
                    continue;
                }
                const node = try self.parseCurly();
                try current.append(self.allocator, node);
            } else if (c == '<') {
                const node = try self.parseTag();
                try current.append(self.allocator, node);
            } else {
                const node = try self.parseText();
                try current.append(self.allocator, node);
            }
        }

        return Node{ .if_block = .{
            .condition = cond,
            .then_body = try then_body.toOwnedSlice(self.allocator),
            .else_body = if (else_body) |*eb| try eb.toOwnedSlice(self.allocator) else null,
            .pos = tok.pos,
        } };
    }


    fn isControlClose(self: *Parser, comptime tag: []const u8) bool {
        if (self.lexer.peek() != '{') return false;
        const saved = self.lexer.pos;
        var i = saved + 1;
        while (i < self.lexer.src.len and (self.lexer.src[i] == ' ' or self.lexer.src[i] == '\t'))
            i += 1;
        if (i + 1 + tag.len > self.lexer.src.len) return false;
        if (self.lexer.src[i] != '/') return false;
        return std.mem.eql(u8, self.lexer.src[i + 1 ..][0..tag.len], tag);
    }

    fn isElseTag(self: *Parser) bool {
        if (self.lexer.peek() != '{') return false;
        const saved = self.lexer.pos;
        var i = saved + 1;
        while (i < self.lexer.src.len and (self.lexer.src[i] == ' ' or self.lexer.src[i] == '\t'))
            i += 1;
        if (i + 4 > self.lexer.src.len) return false;
        if (!std.mem.eql(u8, self.lexer.src[i..][0..4], "else")) return false;
        const after = if (i + 4 < self.lexer.src.len) self.lexer.src[i + 4] else '}';
        return after == '}' or after == ' ' or after == '\n' or after == '\r';
    }

    pub fn printDiagnostics(self: *const Parser) void {
        for (self.diagnostics.items) |d| {
            std.debug.print("{}\n", .{d});
        }
    }

    pub fn hasErrors(self: *const Parser) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .err) return true;
        }
        return false;
    }
};
