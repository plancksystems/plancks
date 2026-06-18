const std = @import("std");
const ast = @import("ast.zig");
const RouteAttr = ast.RouteAttr;
const HttpMethod = ast.HttpMethod;

pub fn parse(input: []const u8) !RouteAttr {
    var result = RouteAttr{
        .name = "",
        .method = .get,
    };
    var has_name = false;
    var has_method = false;

    var rest = input;
    while (rest.len > 0) {
        rest = skipWs(rest);
        if (rest.len == 0) break;

        const key = readIdent(rest);
        if (key.len == 0) return error.ExpectedKey;
        rest = rest[key.len..];
        rest = skipWs(rest);

        if (rest.len == 0 or rest[0] != '=') return error.ExpectedEquals;
        rest = rest[1..];
        rest = skipWs(rest);

        if (std.mem.eql(u8, key, "name")) {
            const val = try readStringValue(rest);
            result.name = val.str;
            rest = rest[val.consumed..];
            has_name = true;
        } else if (std.mem.eql(u8, key, "method")) {
            const val = readIdent(rest);
            if (val.len == 0) return error.ExpectedMethodValue;
            result.method = parseMethod(val) orelse return error.InvalidMethod;
            rest = rest[val.len..];
            has_method = true;
        } else if (std.mem.eql(u8, key, "params")) {
            const val = readIdent(rest);
            if (val.len == 0) return error.ExpectedTypeName;
            result.params_type = val;
            rest = rest[val.len..];
        } else if (std.mem.eql(u8, key, "body")) {
            const val = readIdent(rest);
            if (val.len == 0) return error.ExpectedTypeName;
            result.body_type = val;
            rest = rest[val.len..];
        } else if (std.mem.eql(u8, key, "handler")) {
            const val = readIdent(rest);
            if (val.len == 0) return error.ExpectedTypeName;
            result.handler_type = val;
            rest = rest[val.len..];
        } else {
            return error.UnknownAttribute;
        }

        rest = skipWs(rest);
        if (rest.len > 0 and rest[0] == ',') {
            rest = rest[1..];
        }
    }

    if (!has_name) return error.MissingName;
    if (!has_method) return error.MissingMethod;

    return result;
}

fn parseMethod(s: []const u8) ?HttpMethod {
    if (std.mem.eql(u8, s, "get")) return .get;
    if (std.mem.eql(u8, s, "post")) return .post;
    if (std.mem.eql(u8, s, "put")) return .put;
    if (std.mem.eql(u8, s, "delete")) return .delete;
    if (std.mem.eql(u8, s, "patch")) return .patch;
    if (std.mem.eql(u8, s, "GET")) return .get;
    if (std.mem.eql(u8, s, "POST")) return .post;
    if (std.mem.eql(u8, s, "PUT")) return .put;
    if (std.mem.eql(u8, s, "DELETE")) return .delete;
    if (std.mem.eql(u8, s, "PATCH")) return .patch;
    return null;
}

const StringValue = struct {
    str: []const u8,
    consumed: usize,
};

fn readStringValue(input: []const u8) !StringValue {
    if (input.len == 0 or input[0] != '"') return error.ExpectedStringLiteral;
    var i: usize = 1;
    while (i < input.len) {
        if (input[i] == '\\') {
            i += 2;
            continue;
        }
        if (input[i] == '"') {
            return .{ .str = input[1..i], .consumed = i + 1 };
        }
        i += 1;
    }
    return error.UnterminatedString;
}

fn readIdent(input: []const u8) []const u8 {
    var i: usize = 0;
    while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_'))
        i += 1;
    return input[0..i];
}

fn skipWs(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r'))
        i += 1;
    return s[i..];
}


test "parse full route attribute" {
    const attr = try parse("name=\"/items\", method=get, params=ItemParams, body=CreateItemBody");
    try std.testing.expectEqualStrings("/items", attr.name);
    try std.testing.expect(attr.method == .get);
    try std.testing.expectEqualStrings("ItemParams", attr.params_type.?);
    try std.testing.expectEqualStrings("CreateItemBody", attr.body_type.?);
}

test "parse route with only required fields" {
    const attr = try parse("name=\"/health\", method=get");
    try std.testing.expectEqualStrings("/health", attr.name);
    try std.testing.expect(attr.method == .get);
    try std.testing.expect(attr.params_type == null);
    try std.testing.expect(attr.body_type == null);
}

test "parse route with path params" {
    const attr = try parse("name=\"/items/:id\", method=delete, params=ItemParams");
    try std.testing.expectEqualStrings("/items/:id", attr.name);
    try std.testing.expect(attr.method == .delete);
    try std.testing.expectEqualStrings("ItemParams", attr.params_type.?);
    try std.testing.expect(attr.body_type == null);
}

test "parse POST with body only" {
    const attr = try parse("name=\"/items\", method=post, body=CreateItemBody");
    try std.testing.expectEqualStrings("/items", attr.name);
    try std.testing.expect(attr.method == .post);
    try std.testing.expect(attr.params_type == null);
    try std.testing.expectEqualStrings("CreateItemBody", attr.body_type.?);
}

test "parse with extra whitespace" {
    const attr = try parse("  name = \"/items\" ,  method = put ,  params = ItemParams  ");
    try std.testing.expectEqualStrings("/items", attr.name);
    try std.testing.expect(attr.method == .put);
    try std.testing.expectEqualStrings("ItemParams", attr.params_type.?);
}

test "missing name returns error" {
    const result = parse("method=get");
    try std.testing.expectError(error.MissingName, result);
}

test "missing method returns error" {
    const result = parse("name=\"/items\"");
    try std.testing.expectError(error.MissingMethod, result);
}

test "invalid method returns error" {
    const result = parse("name=\"/items\", method=banana");
    try std.testing.expectError(error.InvalidMethod, result);
}

test "unknown attribute returns error" {
    const result = parse("name=\"/items\", method=get, unknown=foo");
    try std.testing.expectError(error.UnknownAttribute, result);
}
