const std = @import("std");
const zsx = @import("zsx");
const Lexer = zsx.Lexer;
const TokenTag = zsx.TokenTag;
const ast = zsx.ast;

fn expectToken(lexer: *Lexer, expected_tag: TokenTag, expected_text: []const u8) !void {
    const tok = try lexer.next();
    try std.testing.expectEqual(expected_tag, tok.tag);
    try std.testing.expectEqualStrings(expected_text, tok.text);
}

fn expectTag(lexer: *Lexer, expected_tag: TokenTag) !void {
    const tok = try lexer.next();
    try std.testing.expectEqual(expected_tag, tok.tag);
}


test "tokenise open tag: <div>" {
    var lex = Lexer.init("<div>");
    try expectToken(&lex, .open_tag_start, "div");
}

test "tokenise close tag: </div>" {
    var lex = Lexer.init("</div>");
    try expectToken(&lex, .close_tag_start, "div");
}

test "tokenise self-closing tag: <br />" {
    var lex = Lexer.init("<br />");
    try expectToken(&lex, .open_tag_start, "br");
    const end = try lex.expectTagEnd();
    try std.testing.expectEqual(TokenTag.self_close_end, end);
}

test "tokenise open + tag_end via expectTagEnd" {
    var lex = Lexer.init("<div>");
    try expectToken(&lex, .open_tag_start, "div");
    const end = try lex.expectTagEnd();
    try std.testing.expectEqual(TokenTag.tag_end, end);
}


test "tokenise fragment open: <>" {
    var lex = Lexer.init("<>");
    try expectToken(&lex, .fragment_open, "<>");
}

test "tokenise fragment close: </>" {
    var lex = Lexer.init("</>");
    try expectToken(&lex, .fragment_close, "</>");
}

test "tokenise fragment pair: <>...</>" {
    var lex = Lexer.init("<>hello</>");
    try expectToken(&lex, .fragment_open, "<>");
    try expectToken(&lex, .text, "hello");
    try expectToken(&lex, .fragment_close, "</>");
}


test "tokenise string attribute: class=\"foo\"" {
    var lex = Lexer.init("<div class=\"foo\">");
    try expectToken(&lex, .open_tag_start, "div");
    const attrs = try lex.readAttrs(std.testing.allocator);
    defer std.testing.allocator.free(attrs);
    try std.testing.expectEqual(@as(usize, 1), attrs.len);
    try std.testing.expectEqualStrings("class", attrs[0].name);
    try std.testing.expectEqualStrings("foo", attrs[0].value.string);
}

test "tokenise expression attribute: id={expr}" {
    var lex = Lexer.init("<div id={myId}>");
    try expectToken(&lex, .open_tag_start, "div");
    const attrs = try lex.readAttrs(std.testing.allocator);
    defer std.testing.allocator.free(attrs);
    try std.testing.expectEqual(@as(usize, 1), attrs.len);
    try std.testing.expectEqualStrings("id", attrs[0].name);
    try std.testing.expectEqualStrings("myId", attrs[0].value.expression);
}

test "tokenise bare (boolean) attribute: disabled" {
    var lex = Lexer.init("<input disabled />");
    try expectToken(&lex, .open_tag_start, "input");
    const attrs = try lex.readAttrs(std.testing.allocator);
    defer std.testing.allocator.free(attrs);
    try std.testing.expectEqual(@as(usize, 1), attrs.len);
    try std.testing.expectEqualStrings("disabled", attrs[0].name);
    try std.testing.expectEqual(ast.AttrValue.bare, attrs[0].value);
}

test "tokenise spread attribute: {...props}" {
    var lex = Lexer.init("<div {...props} />");
    try expectToken(&lex, .open_tag_start, "div");
    const attrs = try lex.readAttrs(std.testing.allocator);
    defer std.testing.allocator.free(attrs);
    try std.testing.expectEqual(@as(usize, 1), attrs.len);
    try std.testing.expect(attrs[0].is_spread);
    try std.testing.expectEqualStrings("props", attrs[0].value.expression);
}

test "tokenise multiple attributes" {
    var lex = Lexer.init("<div class=\"foo\" id={bar} disabled />");
    try expectToken(&lex, .open_tag_start, "div");
    const attrs = try lex.readAttrs(std.testing.allocator);
    defer std.testing.allocator.free(attrs);
    try std.testing.expectEqual(@as(usize, 3), attrs.len);
    try std.testing.expectEqualStrings("class", attrs[0].name);
    try std.testing.expectEqualStrings("id", attrs[1].name);
    try std.testing.expectEqualStrings("disabled", attrs[2].name);
}

test "tokenise single-quoted attribute: class='bar'" {
    var lex = Lexer.init("<div class='bar'>");
    try expectToken(&lex, .open_tag_start, "div");
    const attrs = try lex.readAttrs(std.testing.allocator);
    defer std.testing.allocator.free(attrs);
    try std.testing.expectEqual(@as(usize, 1), attrs.len);
    try std.testing.expectEqualStrings("bar", attrs[0].value.string);
}


test "tokenise expression: {self.name}" {
    var lex = Lexer.init("{self.name}");
    try expectToken(&lex, .expression, "self.name");
}

test "tokenise expression: {a + b}" {
    var lex = Lexer.init("{a + b}");
    try expectToken(&lex, .expression, "a + b");
}


test "tokenise for_open: {for item in items}" {
    var lex = Lexer.init("{for item in items}");
    const tok = try lex.next();
    try std.testing.expectEqual(TokenTag.for_open, tok.tag);
    try std.testing.expectEqualStrings("{for item in items}", tok.text);
}

test "tokenise for_close: {/for}" {
    var lex = Lexer.init("{/for}");
    try expectToken(&lex, .for_close, "/for");
}

test "tokenise if_open: {if cond}" {
    var lex = Lexer.init("{if user.loggedIn}");
    const tok = try lex.next();
    try std.testing.expectEqual(TokenTag.if_open, tok.tag);
    try std.testing.expectEqualStrings("{if user.loggedIn}", tok.text);
}

test "tokenise if_close: {/if}" {
    var lex = Lexer.init("{/if}");
    try expectToken(&lex, .if_close, "/if");
}

test "tokenise else_tag: {else}" {
    var lex = Lexer.init("{else}");
    try expectToken(&lex, .else_tag, "else");
}

test "tokenise else with whitespace: { else }" {
    var lex = Lexer.init("{ else }");
    try expectToken(&lex, .else_tag, "else");
}


test "nested braces in expression: {fn() { return 1; }}" {
    var lex = Lexer.init("{fn() { return 1; }}");
    const tok = try lex.next();
    try std.testing.expectEqual(TokenTag.expression, tok.tag);
    try std.testing.expectEqualStrings("fn() { return 1; }", tok.text);
}

test "nested braces in attribute expression" {
    var lex = Lexer.init("<div on={fn() { doThing(); }}>");
    try expectToken(&lex, .open_tag_start, "div");
    const attrs = try lex.readAttrs(std.testing.allocator);
    defer std.testing.allocator.free(attrs);
    try std.testing.expectEqual(@as(usize, 1), attrs.len);
    try std.testing.expectEqualStrings("fn() { doThing(); }", attrs[0].value.expression);
}


test "unterminated string error" {
    var lex = Lexer.init("<div class=\"hello>");
    try expectToken(&lex, .open_tag_start, "div");
    const result = lex.readAttrs(std.testing.allocator);
    try std.testing.expectError(error.UnterminatedString, result);
}

test "unterminated expression error" {
    var lex = Lexer.init("{expr");
    const result = lex.next();
    try std.testing.expectError(error.UnterminatedExpr, result);
}


test "whitespace between tokens is skipped" {
    var lex = Lexer.init("   <div>   </div>   ");
    try expectToken(&lex, .open_tag_start, "div");
    const end = try lex.expectTagEnd();
    try std.testing.expectEqual(TokenTag.tag_end, end);
    try expectToken(&lex, .close_tag_start, "div");
    try expectTag(&lex, .eof);
}

test "pure whitespace between tags is skipped" {
    var lex = Lexer.init("<div>   \n\t   </div>");
    try expectToken(&lex, .open_tag_start, "div");
    _ = try lex.expectTagEnd();
    try expectToken(&lex, .close_tag_start, "div");
}


test "empty input returns eof" {
    var lex = Lexer.init("");
    try expectTag(&lex, .eof);
}

test "whitespace-only input returns eof" {
    var lex = Lexer.init("   \n\t  \r\n  ");
    try expectTag(&lex, .eof);
}

test "text between tags" {
    var lex = Lexer.init("hello world");
    const tok = try lex.next();
    try std.testing.expectEqual(TokenTag.text, tok.tag);
    try std.testing.expectEqualStrings("hello world", tok.text);
}

test "position tracking across newlines" {
    var lex = Lexer.init("\n\n<div>");
    const tok = try lex.next();
    try std.testing.expectEqual(@as(u32, 3), tok.pos.line);
    try std.testing.expectEqual(@as(u32, 1), tok.pos.col);
}

test "multiple tokens in sequence" {
    var lex = Lexer.init("<><div />{x}</>");
    try expectToken(&lex, .fragment_open, "<>");
    try expectToken(&lex, .open_tag_start, "div");
    const end = try lex.expectTagEnd();
    try std.testing.expectEqual(TokenTag.self_close_end, end);
    try expectToken(&lex, .expression, "x");
    try expectToken(&lex, .fragment_close, "</>");
    try expectTag(&lex, .eof);
}

test "for with extra whitespace: { for  item  in  items }" {
    var lex = Lexer.init("{ for  item  in  items }");
    const tok = try lex.next();
    try std.testing.expectEqual(TokenTag.for_open, tok.tag);
}

test "spread in child position: {...items}" {
    var lex = Lexer.init("{...items}");
    try expectToken(&lex, .spread, "items");
}

test "close tag with trailing whitespace: </div >" {
    var lex = Lexer.init("</div >");
    try expectToken(&lex, .close_tag_start, "div");
}

test "hyphenated tag name: <my-component>" {
    var lex = Lexer.init("<my-component>");
    try expectToken(&lex, .open_tag_start, "my-component");
}

test "data attribute: data-id=\"123\"" {
    var lex = Lexer.init("<div data-id=\"123\">");
    try expectToken(&lex, .open_tag_start, "div");
    const attrs = try lex.readAttrs(std.testing.allocator);
    defer std.testing.allocator.free(attrs);
    try std.testing.expectEqual(@as(usize, 1), attrs.len);
    try std.testing.expectEqualStrings("data-id", attrs[0].name);
    try std.testing.expectEqualStrings("123", attrs[0].value.string);
}

test "eof after next returns eof repeatedly" {
    var lex = Lexer.init("");
    try expectTag(&lex, .eof);
    try expectTag(&lex, .eof);
    try expectTag(&lex, .eof);
}
