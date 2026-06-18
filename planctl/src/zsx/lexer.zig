const std = @import("std");
const ast = @import("ast.zig");
const Pos = ast.Pos;

pub const TokenTag = enum {

    open_tag_start,

    close_tag_start,

    tag_end,

    self_close_end,

    fragment_open,

    fragment_close,


    attr_name,

    attr_eq,

    attr_string,

    attr_expr,

    spread,


    text,

    expression,


    for_open,

    for_close,

    if_open,

    else_tag,

    if_close,


    tag_name,


    eof,
};

pub const Token = struct {
    tag: TokenTag,
    text: []const u8,
    pos: Pos,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize,
    line: u32,
    col: u32,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src, .pos = 0, .line = 1, .col = 1 };
    }

    pub fn currentPos(self: *const Lexer) Pos {
        return .{ .line = self.line, .col = self.col, .offset = @intCast(self.pos) };
    }

    pub fn peek(self: *const Lexer) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    pub fn peekAt(self: *const Lexer, offset: usize) ?u8 {
        const i = self.pos + offset;
        if (i >= self.src.len) return null;
        return self.src[i];
    }

    pub fn advance(self: *Lexer) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c;
    }

    pub fn skipWhitespace(self: *Lexer) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r')
                _ = self.advance()
            else
                break;
        }
    }

    fn readBraceContent(self: *Lexer) ![]const u8 {
        const start = self.pos;
        var depth: usize = 1;
        while (self.peek()) |c| {
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) {
                    const content = self.src[start..self.pos];
                    _ = self.advance();
                    return content;
                }
            }
            _ = self.advance();
        }
        return error.UnterminatedExpr;
    }

    fn readQuotedString(self: *Lexer) ![]const u8 {
        const quote = self.advance();
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == quote) {
                const content = self.src[start..self.pos];
                _ = self.advance();
                return content;
            }
            _ = self.advance();
        }
        return error.UnterminatedString;
    }

    pub fn readName(self: *Lexer) []const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == ':')
                _ = self.advance()
            else
                break;
        }
        return self.src[start..self.pos];
    }

    fn readText(self: *Lexer) []const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '<' or c == '{') break;
            _ = self.advance();
        }
        return self.src[start..self.pos];
    }

    pub fn next(self: *Lexer) !Token {
        self.skipWhitespace();

        if (self.pos >= self.src.len) {
            return .{ .tag = .eof, .text = "", .pos = self.currentPos() };
        }

        const c = self.peek().?;
        const p = self.currentPos();

        if (c == '<') {
            return self.lexTag();
        }

        if (c == '{') {
            return self.lexCurly();
        }

        const text = self.readText();
        const trimmed = std.mem.trim(u8, text, " \t\n\r");
        if (trimmed.len == 0) return self.next();
        return .{ .tag = .text, .text = text, .pos = p };
    }

    fn lexTag(self: *Lexer) !Token {
        const p = self.currentPos();
        _ = self.advance();

        if (self.peek() == '/' and self.peekAt(1) == '>') {
            _ = self.advance();
            _ = self.advance();
            return .{ .tag = .fragment_close, .text = "</>", .pos = p };
        }

        if (self.peek() == '/') {
            _ = self.advance();
            const name = self.readName();
            self.skipWhitespace();
            if (self.peek() == '>') _ = self.advance();
            return .{ .tag = .close_tag_start, .text = name, .pos = p };
        }

        if (self.peek() == '>') {
            _ = self.advance();
            return .{ .tag = .fragment_open, .text = "<>", .pos = p };
        }

        const name = self.readName();
        return .{ .tag = .open_tag_start, .text = name, .pos = p };
    }

    fn lexCurly(self: *Lexer) !Token {
        const p = self.currentPos();
        _ = self.advance();
        self.skipWhitespace();

        const rest = self.src[self.pos..];

        if (std.mem.startsWith(u8, rest, "/for")) {
            self.pos += 4;
            self.col += 4;
            self.skipWhitespace();
            if (self.peek() == '}') _ = self.advance();
            return .{ .tag = .for_close, .text = "/for", .pos = p };
        }

        if (std.mem.startsWith(u8, rest, "/if")) {
            self.pos += 3;
            self.col += 3;
            self.skipWhitespace();
            if (self.peek() == '}') _ = self.advance();
            return .{ .tag = .if_close, .text = "/if", .pos = p };
        }

        if (std.mem.startsWith(u8, rest, "else")) {
            const after = if (rest.len > 4) rest[4] else '}';
            if (after == '}' or after == ' ' or after == '\n' or after == '\r') {
                self.pos += 4;
                self.col += 4;
                self.skipWhitespace();
                if (self.peek() == '}') _ = self.advance();
                return .{ .tag = .else_tag, .text = "else", .pos = p };
            }
        }

        if (std.mem.startsWith(u8, rest, "for ")) {
            self.pos += 4;
            self.col += 4;
            self.skipWhitespace();
            const iter_var = self.readName();
            self.skipWhitespace();
            if (std.mem.startsWith(u8, self.src[self.pos..], "in ")) {
                self.pos += 3;
                self.col += 3;
            }
            self.skipWhitespace();
            const expr_start = self.pos;
            var depth: usize = 1;
            while (self.peek()) |ch| {
                if (ch == '{') depth += 1;
                if (ch == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
                _ = self.advance();
            }
            const iter_expr = std.mem.trim(u8, self.src[expr_start..self.pos], " \t\n\r");
            if (self.peek() == '}') _ = self.advance();
            _ = iter_var;
            _ = iter_expr;
            return .{ .tag = .for_open, .text = self.src[p.offset..self.pos], .pos = p };
        }

        if (std.mem.startsWith(u8, rest, "if ")) {
            self.pos += 3;
            self.col += 3;
            self.skipWhitespace();
            const cond_start = self.pos;
            var depth: usize = 1;
            while (self.peek()) |ch| {
                if (ch == '{') depth += 1;
                if (ch == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
                _ = self.advance();
            }
            const cond = std.mem.trim(u8, self.src[cond_start..self.pos], " \t\n\r");
            if (self.peek() == '}') _ = self.advance();
            _ = cond;
            return .{ .tag = .if_open, .text = self.src[p.offset..self.pos], .pos = p };
        }

        if (std.mem.startsWith(u8, rest, "...")) {
            self.pos += 3;
            self.col += 3;
            const content = try self.readBraceContent();
            return .{ .tag = .spread, .text = content, .pos = p };
        }

        const content = try self.readBraceContent();
        return .{ .tag = .expression, .text = content, .pos = p };
    }

    pub fn readAttrs(self: *Lexer, allocator: std.mem.Allocator) ![]ast.Attribute {
        var attrs = std.ArrayList(ast.Attribute).empty;
        while (true) {
            self.skipWhitespace();
            const c = self.peek() orelse break;
            if (c == '>' or c == '/') break;

            if (c == '{' and self.peekAt(1) == '.' and self.peekAt(2) == '.' and self.peekAt(3) == '.') {
                const p = self.currentPos();
                _ = self.advance();
                _ = self.advance();
                _ = self.advance();
                _ = self.advance();
                const spread_expr = try self.readBraceContent();
                try attrs.append(allocator, .{
                    .name = "...",
                    .value = .{ .expression = spread_expr },
                    .pos = p,
                    .is_spread = true,
                });
                continue;
            }

            const p = self.currentPos();
            const name = self.readName();
            if (name.len == 0) break;
            self.skipWhitespace();

            if (self.peek() == '=') {
                _ = self.advance();
                self.skipWhitespace();
                const val: ast.AttrValue = if (self.peek() == '"' or self.peek() == '\'')
                    .{ .string = try self.readQuotedString() }
                else if (self.peek() == '{') blk: {
                    _ = self.advance();
                    break :blk .{ .expression = try self.readBraceContent() };
                } else return error.InvalidAttrValue;
                try attrs.append(allocator, .{ .name = name, .value = val, .pos = p });
            } else {
                try attrs.append(allocator, .{ .name = name, .value = .bare, .pos = p });
            }
        }
        return attrs.toOwnedSlice(allocator);
    }

    pub fn expectTagEnd(self: *Lexer) !TokenTag {
        self.skipWhitespace();
        if (self.peek() == '/') {
            _ = self.advance();
            if (self.peek() == '>') _ = self.advance();
            return .self_close_end;
        }
        if (self.peek() == '>') {
            _ = self.advance();
            return .tag_end;
        }
        return error.ExpectedTagEnd;
    }
};
