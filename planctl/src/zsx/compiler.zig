const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast.zig");
const Parser = @import("parser.zig").Parser;
const CodegenZig = @import("codegen_zig.zig").CodegenZig;
const CodegenRust = @import("codegen_rust.zig").CodegenRust;
const CodegenGo = @import("codegen_go.zig").CodegenGo;
const AttrParser = @import("attr_parser.zig");
const Pos = ast.Pos;
const RouteAttr = ast.RouteAttr;

const PROTOCOL_VERSION: u32 = 1;

pub const Target = enum { zig, rust, go };

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    src: []const u8,
    src_file: []const u8,
    target: Target,

    pub fn init(allocator: std.mem.Allocator, src: []const u8, src_file: []const u8, target: Target) Compiler {
        return .{
            .allocator = allocator,
            .src = src,
            .src_file = src_file,
            .target = target,
        };
    }

    pub fn compile(self: *Compiler) !CompileResult {
        var strip = try stripZsxImports(self.src, self.allocator);
        defer strip.deinit(self.allocator);
        const clean_src = strip.code;

        var final = std.ArrayList(u8).empty;
        var all_props = std.ArrayList(u8).empty;
        var has_errors = false;

        var route_attrs = std.ArrayList(RouteAttr).empty;
        defer route_attrs.deinit(self.allocator);

        var pos: usize = 0;

        while (pos < clean_src.len) {
            if (tryMatchRouteAttr(clean_src, pos)) |attr_match| {
                try final.appendSlice(self.allocator, clean_src[pos..attr_match.attr_start]);

                const attr_content = clean_src[attr_match.content_start..attr_match.content_end];
                var route_attr = AttrParser.parse(attr_content) catch |e| {
                    if (!builtin.is_test) std.debug.print("{s}: route attribute parse error: {s}\n", .{ self.src_file, @errorName(e) });
                    has_errors = true;
                    pos = attr_match.end;
                    continue;
                };

                const after_attr = clean_src[attr_match.end..];
                if (findNextFnName(after_attr)) |fn_name| {
                    route_attr.fn_name = fn_name;
                }

                try route_attrs.append(self.allocator, route_attr);
                pos = attr_match.end;
                continue;
            }

            if (tryMatchReturnParen(clean_src, pos)) |match| {
                try final.appendSlice(self.allocator, clean_src[pos..match.return_start]);

                const jsx_orig_line = offsetToOrigLine(clean_src, match.jsx_start, strip.line_map);
                try final.print(self.allocator, "// #line {d} \"{s}\"\n    ", .{ jsx_orig_line, self.src_file });

                const jsx_start = match.jsx_start;
                const jsx_end = findMatchingParen(clean_src, match.paren_start) orelse clean_src.len;
                const jsx_src = clean_src[jsx_start..jsx_end];

                var parser = Parser.init(self.allocator, jsx_src, self.src_file);
                defer parser.deinit();

                const root_node = parser.parseRoot() catch |e| {
                    if (!builtin.is_test) std.debug.print("{s}: parse error: {s}\n", .{ self.src_file, @errorName(e) });
                    has_errors = true;
                    try final.appendSlice(self.allocator, "// parse error\n");
                    pos = jsx_end + 1;
                    continue;
                };

                if (parser.hasErrors()) {
                    if (!builtin.is_test) parser.printDiagnostics();
                    has_errors = true;
                }

                switch (self.target) {
                    .zig => {
                        var codegen = CodegenZig.init(self.allocator);
                        defer codegen.deinit();

                        codegen.emit(root_node) catch |e| {
                            if (!builtin.is_test) std.debug.print("{s}: codegen error: {s}\n", .{ self.src_file, @errorName(e) });
                            try final.appendSlice(self.allocator, "// codegen error\n");
                            pos = jsx_end + 1;
                            continue;
                        };

                        try final.appendSlice(self.allocator, codegen.getOutput());
                    },
                    .rust => {
                        var codegen_rust = CodegenRust.init(self.allocator);
                        defer codegen_rust.deinit();

                        codegen_rust.emit(root_node) catch |e| {
                            if (!builtin.is_test) std.debug.print("{s}: codegen error: {s}\n", .{ self.src_file, @errorName(e) });
                            try final.appendSlice(self.allocator, "// codegen error\n");
                            pos = jsx_end + 1;
                            continue;
                        };

                        try final.appendSlice(self.allocator, codegen_rust.getOutput());
                    },
                    .go => {
                        var codegen_go = CodegenGo.init(self.allocator);
                        defer codegen_go.deinit();

                        codegen_go.emit(root_node) catch |e| {
                            if (!builtin.is_test) std.debug.print("{s}: codegen error: {s}\n", .{ self.src_file, @errorName(e) });
                            try final.appendSlice(self.allocator, "// codegen error\n");
                            pos = jsx_end + 1;
                            continue;
                        };

                        try final.appendSlice(self.allocator, codegen_go.getOutput());
                    },
                }

                pos = jsx_end + 1;
                if (pos < clean_src.len and clean_src[pos] == ';') {
                    pos += 1;
                }

                const resume_orig_line = offsetToOrigLine(clean_src, pos, strip.line_map);
                try final.print(self.allocator, "\n// #line {d} \"{s}\"\n", .{ resume_orig_line, self.src_file });
            } else {
                const c = clean_src[pos];
                switch (c) {
                    '"' => {
                        const end = skipStringLiteral(clean_src, pos);
                        try final.appendSlice(self.allocator, clean_src[pos..end]);
                        pos = end;
                    },
                    '/' => {
                        if (pos + 1 < clean_src.len and clean_src[pos + 1] == '/') {
                            const end = skipLineComment(clean_src, pos);
                            try final.appendSlice(self.allocator, clean_src[pos..end]);
                            pos = end;
                        } else {
                            try final.append(self.allocator, c);
                            pos += 1;
                        }
                    },
                    '\\' => {
                        if (pos + 1 < clean_src.len and clean_src[pos + 1] == '\\') {
                            const end = skipLineString(clean_src, pos);
                            try final.appendSlice(self.allocator, clean_src[pos..end]);
                            pos = end;
                        } else {
                            try final.append(self.allocator, c);
                            pos += 1;
                        }
                    },
                    else => {
                        try final.append(self.allocator, c);
                        pos += 1;
                    },
                }
            }
        }

        var result = std.ArrayList(u8).empty;
        switch (self.target) {
            .zig => {
                try result.print(self.allocator,
                    \\// AUTO-GENERATED by planctl v2, do not edit
                    \\// Source: {s}
                    \\const std = @import("std");
                    \\const web = @import("web");
                    \\
                    \\fn appendValue(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) !void {{
                    \\    const T = @TypeOf(value);
                    \\    const info = @typeInfo(T);
                    \\    if (T == []const u8 or T == []u8) {{
                    \\        try web.appendEscaped(out, allocator, value);
                    \\    }} else if (info == .optional) {{
                    \\        if (value) |v| try appendValue(out, allocator, v);
                    \\    }} else if (info == .int or info == .comptime_int) {{
                    \\        try out.print(allocator, "{{d}}", .{{value}});
                    \\    }} else if (info == .float or info == .comptime_float) {{
                    \\        try out.print(allocator, "{{d}}", .{{value}});
                    \\    }} else if (info == .bool) {{
                    \\        try out.appendSlice(allocator, if (value) "true" else "false");
                    \\    }} else {{
                    \\        try out.appendSlice(allocator, "[unsupported]");
                    \\    }}
                    \\}}
                    \\
                    \\
                , .{self.src_file});
            },
            .rust => {
                try result.print(self.allocator,
                    \\// AUTO-GENERATED by planctl, do not edit
                    \\// Source: {s}
                    \\// Target: Rust
                    \\
                    \\
                , .{self.src_file});
            },
            .go => {
                try result.print(self.allocator,
                    \\// AUTO-GENERATED by planctl, do not edit
                    \\// Source: {s}
                    \\// Target: Go
                    \\
                    \\
                , .{self.src_file});
            },
        }

        try result.appendSlice(self.allocator, final.items);

        if (route_attrs.items.len > 0) {
            const gen = try emitRouteHandlerCode(self.allocator, route_attrs.items);
            defer self.allocator.free(gen.fields);
            defer self.allocator.free(gen.methods);

            if (std.mem.indexOf(u8, result.items, "struct {")) |s| {
                const insert_after = s + "struct {".len;
                try result.insertSlice(self.allocator, insert_after, gen.fields);
            }

            if (findLastStructClose(result.items)) |insert_pos| {
                try result.insertSlice(self.allocator, insert_pos, gen.methods);
            }
        }

        all_props.deinit(self.allocator);
        final.deinit(self.allocator);

        return .{
            .code = try result.toOwnedSlice(self.allocator),
            .has_errors = has_errors,
        };
    }
};

pub const CompileResult = struct {
    code: []u8,
    has_errors: bool,
};


const ReturnMatch = struct {
    return_start: usize,
    paren_start: usize,
    jsx_start: usize,
};

fn tryMatchReturnParen(src: []const u8, start: usize) ?ReturnMatch {
    var i = start;
    if (i + 6 > src.len) return null;
    if (!std.mem.eql(u8, src[i..][0..6], "return")) return null;

    const after_kw = if (i + 6 < src.len) src[i + 6] else '(';
    if (after_kw != '(' and after_kw != ' ' and after_kw != '\n' and
        after_kw != '\t' and after_kw != '\r') return null;

    if (start > 0) {
        var j: usize = start - 1;
        while (j > 0 and (src[j] == ' ' or src[j] == '\t' or src[j] == '\n' or src[j] == '\r'))
            j -= 1;
        const prev = src[j];
        if (prev != ';' and prev != '{' and prev != '}' and prev != ')' and
            prev != ' ' and prev != '\t' and prev != '\n' and prev != '\r')
            return null;
    }

    i += 6;

    while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\n' or src[i] == '\r'))
        i += 1;

    if (i >= src.len or src[i] != '(') return null;
    const paren_start = i;
    i += 1;

    while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\n' or src[i] == '\r'))
        i += 1;

    if (i >= src.len or src[i] != '<') return null;
    const next = if (i + 1 < src.len) src[i + 1] else 0;
    if (!std.ascii.isAlphabetic(next) and next != '/' and next != '>') return null;

    return .{
        .return_start = start,
        .paren_start = paren_start,
        .jsx_start = i,
    };
}

fn findMatchingParen(src: []const u8, start: usize) ?usize {
    var depth: u32 = 0;
    var i = start;
    var in_string = false;
    var in_line_comment = false;

    while (i < src.len) : (i += 1) {
        if (in_line_comment) {
            if (src[i] == '\n') in_line_comment = false;
            continue;
        }
        if (in_string) {
            if (src[i] == '\\') {
                i += 1;
                continue;
            }
            if (src[i] == '"') in_string = false;
            continue;
        }
        switch (src[i]) {
            '"' => in_string = true,
            '/' => if (i + 1 < src.len and src[i + 1] == '/') {
                in_line_comment = true;
            },
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn hasAllocatorParam(output: []const u8) bool {
    if (output.len < 3) return false;
    var i: usize = output.len - 3;
    while (true) {
        if (std.mem.eql(u8, output[i..][0..3], "fn ")) break;
        if (i == 0) return false;
        i -= 1;
    }

    var paren_open = i + 3;
    while (paren_open < output.len and output[paren_open] != '(') paren_open += 1;
    if (paren_open >= output.len) return false;

    var depth: u32 = 1;
    var paren_close = paren_open + 1;
    while (paren_close < output.len and depth > 0) : (paren_close += 1) {
        if (output[paren_close] == '(') depth += 1;
        if (output[paren_close] == ')') depth -= 1;
    }
    if (depth != 0) return false;
    paren_close -= 1;

    const params = output[paren_open + 1 .. paren_close];
    return std.mem.indexOf(u8, params, "allocator") != null;
}

fn injectAllocatorParam(out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const output = out.items;
    if (output.len < 3) return;
    var i: usize = output.len - 3;
    while (true) {
        if (output[i] == '"') {
            if (i == 0) return;
            i -= 1;
            while (i > 0 and output[i] != '"') i -= 1;
            if (i == 0) return;
            i -= 1;
            continue;
        }
        if (std.mem.eql(u8, output[i..][0..3], "fn ")) break;
        if (i == 0) return;
        i -= 1;
    }

    var paren_open = i + 3;
    while (paren_open < output.len and output[paren_open] != '(') paren_open += 1;
    if (paren_open >= output.len) return;

    var depth: u32 = 1;
    var paren_close = paren_open + 1;
    while (paren_close < output.len and depth > 0) : (paren_close += 1) {
        if (output[paren_close] == '(') depth += 1;
        if (output[paren_close] == ')') depth -= 1;
    }
    if (depth != 0) return;
    paren_close -= 1;

    const params = output[paren_open + 1 .. paren_close];
    if (std.mem.indexOf(u8, params, "allocator") != null) return;

    const has_params = std.mem.trim(u8, params, " \t\n\r").len > 0;
    const inject = if (has_params) ", allocator: std.mem.Allocator" else "allocator: std.mem.Allocator";
    try out.insertSlice(allocator, paren_close, inject);
}

const StripResult = struct {
    code: []u8,
    line_map: []u32,

    fn deinit(self: *StripResult, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.line_map);
    }
};

fn stripZsxImports(src: []const u8, allocator: std.mem.Allocator) !StripResult {
    var out = std.ArrayList(u8).empty;
    var line_map = std.ArrayList(u32).empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var orig_line: u32 = 1;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        const skip = shouldStripLine(t);
        if (!skip) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            try line_map.append(allocator, orig_line);
        }
        orig_line += 1;
    }
    return .{
        .code = try out.toOwnedSlice(allocator),
        .line_map = try line_map.toOwnedSlice(allocator),
    };
}

fn shouldStripLine(t: []const u8) bool {
    if (std.mem.eql(u8, t, "_ = allocator;")) return true;
    if (std.mem.startsWith(u8, t, "//!")) return true;
    if (isConstAssign(t, "Node")) return true;
    if (extractImportPackage(t)) |pkg| {
        if (std.mem.eql(u8, pkg.name, "std")) return true;
        if (std.mem.eql(u8, pkg.name, "web")) return true;
        if (std.mem.startsWith(u8, pkg.name, "web_runtime")) return true;
    }
    return false;
}

fn isConstAssign(t: []const u8, ident: []const u8) bool {
    var s = t;
    if (std.mem.startsWith(u8, s, "pub")) {
        s = s[3..];
        s = skipWs(s);
    }
    if (!std.mem.startsWith(u8, s, "const")) return false;
    s = s[5..];
    if (s.len == 0 or (s[0] != ' ' and s[0] != '\t')) return false;
    s = skipWs(s);
    if (!std.mem.startsWith(u8, s, ident)) return false;
    s = s[ident.len..];
    s = skipWs(s);
    return s.len > 0 and s[0] == '=';
}

const ImportInfo = struct {
    ident: []const u8,
    name: []const u8,
};

fn extractImportPackage(t: []const u8) ?ImportInfo {
    var s = t;

    if (std.mem.startsWith(u8, s, "pub")) {
        s = s[3..];
        s = skipWs(s);
    }

    if (!std.mem.startsWith(u8, s, "const")) return null;
    s = s[5..];
    if (s.len == 0 or (s[0] != ' ' and s[0] != '\t')) return null;
    s = skipWs(s);

    const ident_start = s;
    var ident_len: usize = 0;
    while (ident_len < s.len and (std.ascii.isAlphanumeric(s[ident_len]) or s[ident_len] == '_'))
        ident_len += 1;
    if (ident_len == 0) return null;
    const ident = ident_start[0..ident_len];
    s = s[ident_len..];
    s = skipWs(s);

    if (s.len == 0 or s[0] != '=') return null;
    s = s[1..];
    s = skipWs(s);

    if (!std.mem.startsWith(u8, s, "@import")) return null;
    s = s[7..];
    s = skipWs(s);

    if (s.len == 0 or s[0] != '(') return null;
    s = s[1..];
    s = skipWs(s);

    if (s.len == 0 or s[0] != '"') return null;
    s = s[1..];

    const pkg_start = s;
    var pkg_len: usize = 0;
    while (pkg_len < s.len and s[pkg_len] != '"') pkg_len += 1;
    if (pkg_len >= s.len) return null;
    const pkg = pkg_start[0..pkg_len];
    s = s[pkg_len + 1 ..];
    s = skipWs(s);

    if (s.len == 0 or s[0] != ')') return null;

    return .{ .ident = ident, .name = pkg };
}

fn skipWs(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

fn skipStringLiteral(src: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < src.len) {
        if (src[i] == '\\') {
            i += 2;
            continue;
        }
        if (src[i] == '"') return i + 1;
        i += 1;
    }
    return i;
}

fn skipLineComment(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and src[i] != '\n') i += 1;
    if (i < src.len) i += 1;
    return i;
}

fn skipLineString(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and src[i] != '\n') i += 1;
    if (i < src.len) i += 1;
    return i;
}

fn offsetToOrigLine(clean_src: []const u8, offset: usize, line_map: []const u32) u32 {
    var clean_line: usize = 0;
    const end = @min(offset, clean_src.len);
    for (clean_src[0..end]) |c| {
        if (c == '\n') clean_line += 1;
    }
    if (clean_line < line_map.len) return line_map[clean_line];
    if (line_map.len > 0) return line_map[line_map.len - 1];
    return 1;
}


const RouteAttrMatch = struct {
    attr_start: usize,
    content_start: usize,
    content_end: usize,
    end: usize,
};

fn tryMatchRouteAttr(src: []const u8, start: usize) ?RouteAttrMatch {
    if (start + 1 >= src.len) return null;
    if (src[start] != '@' or src[start + 1] != '(') return null;

    if (start > 0 and (std.ascii.isAlphanumeric(src[start - 1]) or src[start - 1] == '_'))
        return null;

    const content_start = start + 2;

    var depth: u32 = 1;
    var i = content_start;
    var in_string = false;
    while (i < src.len) : (i += 1) {
        if (in_string) {
            if (src[i] == '\\') {
                i += 1;
                continue;
            }
            if (src[i] == '"') in_string = false;
            continue;
        }
        switch (src[i]) {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) {
                    return .{
                        .attr_start = start,
                        .content_start = content_start,
                        .content_end = i,
                        .end = i + 1,
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

fn findNextFnName(src: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 3 < src.len) {
        if (src[i] == ' ' or src[i] == '\t' or src[i] == '\n' or src[i] == '\r') {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], "fn ")) {
            i += 3;
            while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
            const name_start = i;
            while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) i += 1;
            if (i > name_start) return src[name_start..i];
            return null;
        }
        break;
    }
    return null;
}

fn findLastStructClose(output: []const u8) ?usize {
    if (output.len < 2) return null;
    var i: usize = output.len - 1;
    while (i > 0 and (output[i] == ' ' or output[i] == '\t' or output[i] == '\n' or output[i] == '\r'))
        i -= 1;
    if (output[i] != ';') return null;
    if (i == 0) return null;
    if (output[i - 1] != '}') {
        var j = i - 1;
        while (j > 0 and (output[j] == ' ' or output[j] == '\t' or output[j] == '\n' or output[j] == '\r'))
            j -= 1;
        if (output[j] == '}') return j;
        return null;
    }
    return i - 1;
}

const RouteGenResult = struct {
    fields: []const u8,
    methods: []const u8,
};

fn emitRouteHandlerCode(allocator: std.mem.Allocator, routes: []const RouteAttr) !RouteGenResult {
    var has_handlers = false;
    for (routes) |route| {
        if (route.handler_type != null) {
            has_handlers = true;
            break;
        }
    }

    var fields = std.ArrayList(u8).empty;
    try fields.appendSlice(allocator,
        \\
        \\    allocator: std.mem.Allocator,
        \\    mediator: *web.Mediator,
        \\    handlers: Handlers = .{},
        \\
    );

    if (has_handlers) {
        try fields.appendSlice(allocator,
            \\    pub fn init(allocator: std.mem.Allocator, mediator: *web.Mediator, services: *Services) !@This() {
            \\        var rh: @This() = .{ .allocator = allocator, .mediator = mediator };
            \\
        );
        for (routes) |route| {
            if (route.handler_type != null) {
                try fields.print(
                    allocator,
                    "        try web.inject(Services, services, &rh.handlers.{s});\n",
                    .{route.fn_name},
                );
            }
        }
        try fields.appendSlice(allocator,
            \\        return rh;
            \\    }
            \\
        );

        try fields.appendSlice(allocator,
            \\    pub fn register(self: *@This()) !void {
            \\
        );
        for (routes) |route| {
            if (route.handler_type) |handler| {
                const method_str = route.method.toUpperStr();
                const req_type = if (route.body_type) |b| b else if (route.params_type) |p| p else null;
                if (req_type) |rt| {
                    try fields.print(
                        allocator,
                        "        try self.mediator.register(\"{s} {s}\", web.RequestHandler.from({s}, {s}, &self.handlers.{s}));\n",
                        .{ method_str, route.name, handler, rt, route.fn_name },
                    );
                }
            }
        }
        try fields.appendSlice(allocator,
            \\    }
            \\
        );
    } else {
        try fields.appendSlice(allocator,
            \\    pub fn init(allocator: std.mem.Allocator, mediator: *web.Mediator, _: anytype) !@This() {
            \\        return .{ .allocator = allocator, .mediator = mediator };
            \\    }
            \\    pub fn register(_: *@This()) !void {}
            \\
        );
    }

    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator,
        \\
        \\    /// Auto-generated. Parses raw request, dispatches to route function.
        \\    pub fn handle(self: *@This(), raw_request: []const u8) ![]const u8 {
        \\        const parsed = try web.parseRequest(self.allocator, raw_request, null, null);
        \\        const method = parsed.route.method;
        \\        const path = parsed.route.path;
        \\
    );

    for (routes) |route| {
        const method_str = route.method.toUpperStr();
        const params_str = if (route.params_type) |p| p else "null";
        const body_str = if (route.body_type) |b| b else "null";
        const has_path_params = std.mem.indexOf(u8, route.name, ":") != null;

        try out.print(
            allocator,
            "        if (std.mem.eql(u8, method, \"{s}\") and routeMatches(\"{s}\", path)) {{\n",
            .{ method_str, route.name },
        );

        if (route.body_type != null) {
            try out.print(
                allocator,
                "            var result = try web.parseRequest(self.allocator, raw_request, {s}, {s});\n",
                .{ params_str, body_str },
            );
            if (has_path_params and route.params_type != null) {
                try out.print(
                    allocator,
                    "            var params = result.params;\n" ++
                        "            web.extractPathParams({s}, \"{s}\", path, &params);\n",
                    .{ params_str, route.name },
                );
            }
            try out.print(
                allocator,
                "            return try self.{s}(&result.body);\n",
                .{route.fn_name},
            );
        } else if (route.params_type != null) {
            try out.print(
                allocator,
                "            const result = try web.parseRequest(self.allocator, raw_request, {s}, null);\n" ++
                    "            var params = result.params;\n",
                .{params_str},
            );
            if (has_path_params) {
                try out.print(
                    allocator,
                    "            web.extractPathParams({s}, \"{s}\", path, &params);\n",
                    .{ params_str, route.name },
                );
            }
            try out.print(
                allocator,
                "            return try self.{s}(&params);\n",
                .{route.fn_name},
            );
        } else {
            try out.print(
                allocator,
                "            return try self.{s}(null);\n",
                .{route.fn_name},
            );
        }

        try out.appendSlice(allocator, "        }\n");
    }

    try out.appendSlice(allocator,
        \\        return error.HandlerNotFound;
        \\    }
        \\
        \\    fn routeMatches(pattern: []const u8, path: []const u8) bool {
        \\        var pat_it = std.mem.splitScalar(u8, pattern, '/');
        \\        var path_it = std.mem.splitScalar(u8, path, '/');
        \\        while (true) {
        \\            const pat_seg = pat_it.next();
        \\            const path_seg = path_it.next();
        \\            if (pat_seg == null and path_seg == null) return true;
        \\            if (pat_seg == null or path_seg == null) return false;
        \\            if (pat_seg.?.len > 0 and pat_seg.?[0] == ':') continue;
        \\            if (!std.mem.eql(u8, pat_seg.?, path_seg.?)) return false;
        \\        }
        \\    }
        \\
    );

    return .{
        .fields = try fields.toOwnedSlice(allocator),
        .methods = try out.toOwnedSlice(allocator),
    };
}
