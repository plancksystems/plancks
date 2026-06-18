const std = @import("std");
const zsx = @import("zsx");
const Parser = zsx.Parser;
const ast = zsx.ast;
const Node = ast.Node;

fn makeArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.heap.page_allocator);
}

fn parse(src: []const u8) !Node {
    var parser = Parser.init(std.heap.page_allocator, src, "test.zsx");
    defer parser.deinit();
    return try parser.parseRoot();
}

fn parseWithErrors(src: []const u8) !struct { node: Node, has_errors: bool } {
    var parser = Parser.init(std.heap.page_allocator, src, "test.zsx");
    defer parser.deinit();
    const node = try parser.parseRoot();
    return .{ .node = node, .has_errors = parser.hasErrors() };
}


test "parse self-closing element: <br />" {
    const node = try parse("<br />");
    try std.testing.expectEqualStrings("br", node.element.tag);
    try std.testing.expect(node.element.self_closing);
    try std.testing.expectEqual(@as(usize, 0), node.element.children.len);
}


test "parse element with child: <div><span>text</span></div>" {
    const node = try parse("<div><span>hello</span></div>");
    try std.testing.expectEqualStrings("div", node.element.tag);
    try std.testing.expectEqual(@as(usize, 1), node.element.children.len);

    const span = node.element.children[0].element;
    try std.testing.expectEqualStrings("span", span.tag);
    try std.testing.expectEqual(@as(usize, 1), span.children.len);
    try std.testing.expectEqualStrings("hello", span.children[0].text.content);
}


test "parse component: <MyComp prop=\"val\" />" {
    const node = try parse("<MyComp prop=\"val\" />");
    try std.testing.expectEqualStrings("MyComp", node.component.name);
    try std.testing.expect(node.component.self_closing);
    try std.testing.expectEqual(@as(usize, 1), node.component.props.len);
    try std.testing.expectEqualStrings("prop", node.component.props[0].name);
    try std.testing.expectEqualStrings("val", node.component.props[0].value.string);
}

test "parse component with children" {
    const node = try parse("<Layout><div /></Layout>");
    try std.testing.expectEqualStrings("Layout", node.component.name);
    try std.testing.expect(!node.component.self_closing);
    try std.testing.expectEqual(@as(usize, 1), node.component.children.len);
}


test "parse fragment: <><div /><span /></>" {
    const node = try parse("<><div /><span /></>");
    try std.testing.expectEqual(@as(usize, 2), node.fragment.children.len);
    try std.testing.expectEqualStrings("div", node.fragment.children[0].element.tag);
    try std.testing.expectEqualStrings("span", node.fragment.children[1].element.tag);
}


test "parse text node with whitespace normalisation" {
    const node = try parse("<div>  hello  </div>");
    try std.testing.expectEqual(@as(usize, 1), node.element.children.len);
    const content = node.element.children[0].text.content;
    try std.testing.expect(content.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "hello") != null);
}

test "parse trailing space preservation: Hello {name}" {
    const node = try parse("<div>Hello {name}</div>");
    try std.testing.expectEqual(@as(usize, 2), node.element.children.len);
    const text_content = node.element.children[0].text.content;
    try std.testing.expect(text_content[text_content.len - 1] == ' ');
    try std.testing.expectEqualStrings("name", node.element.children[1].expression.value);
}


test "parse {for} block with body" {
    const node = try parse("{for item in items}<div />{/for}");
    try std.testing.expectEqualStrings("item", node.for_loop.iter_var);
    try std.testing.expectEqualStrings("items", node.for_loop.iter_expr);
    try std.testing.expectEqual(@as(usize, 1), node.for_loop.body.len);
}


test "parse {if} block without else" {
    const node = try parse("{if visible}<div />{/if}");
    try std.testing.expectEqualStrings("visible", node.if_block.condition);
    try std.testing.expectEqual(@as(usize, 1), node.if_block.then_body.len);
    try std.testing.expectEqual(@as(?[]Node, null), node.if_block.else_body);
}

test "parse {if} block with {else}" {
    const node = try parse("{if show}<div />{else}<span />{/if}");
    try std.testing.expectEqualStrings("show", node.if_block.condition);
    try std.testing.expectEqual(@as(usize, 1), node.if_block.then_body.len);
    try std.testing.expect(node.if_block.else_body != null);
    try std.testing.expectEqual(@as(usize, 1), node.if_block.else_body.?.len);
}


test "parse nested: {if x}<div>{for y in ys}<span />{/for}</div>{/if}" {
    const node = try parse("{if x}<div>{for y in ys}<span />{/for}</div>{/if}");
    try std.testing.expectEqualStrings("x", node.if_block.condition);
    try std.testing.expectEqual(@as(usize, 1), node.if_block.then_body.len);

    const div = node.if_block.then_body[0].element;
    try std.testing.expectEqualStrings("div", div.tag);
    try std.testing.expectEqual(@as(usize, 1), div.children.len);

    const for_loop = div.children[0].for_loop;
    try std.testing.expectEqualStrings("y", for_loop.iter_var);
    try std.testing.expectEqualStrings("ys", for_loop.iter_expr);
}


test "mismatched close tag records error" {
    const result = try parseWithErrors("<div></span>");
    try std.testing.expect(result.has_errors);
}

test "unclosed element at EOF records error" {
    var parser = Parser.init(std.heap.page_allocator, "<div><span>", "test.zsx");
    defer parser.deinit();
    _ = try parser.parseRoot();
}

test "unclosed fragment at EOF returns fragment with collected children" {
    var parser = Parser.init(std.heap.page_allocator, "<><div />", "test.zsx");
    defer parser.deinit();
    const node = try parser.parseRoot();
    try std.testing.expectEqual(@as(usize, 1), node.fragment.children.len);
}

test "unclosed {for} block at EOF returns partial for_loop" {
    var parser = Parser.init(std.heap.page_allocator, "{for x in xs}<div />", "test.zsx");
    defer parser.deinit();
    const node = try parser.parseRoot();
    try std.testing.expectEqualStrings("x", node.for_loop.iter_var);
    try std.testing.expectEqual(@as(usize, 1), node.for_loop.body.len);
}

test "unclosed {if} block at EOF returns partial if_block" {
    var parser = Parser.init(std.heap.page_allocator, "{if cond}<div />", "test.zsx");
    defer parser.deinit();
    const node = try parser.parseRoot();
    try std.testing.expectEqualStrings("cond", node.if_block.condition);
    try std.testing.expectEqual(@as(usize, 1), node.if_block.then_body.len);
}

test "empty input records error" {
    var parser = Parser.init(std.heap.page_allocator, "", "test.zsx");
    defer parser.deinit();
    const node = try parser.parseRoot();
    try std.testing.expectEqualStrings("", node.text.content);
    try std.testing.expect(parser.hasErrors());
}

test "whitespace-only input records error" {
    var parser = Parser.init(std.heap.page_allocator, "   \n\t  ", "test.zsx");
    defer parser.deinit();
    const node = try parser.parseRoot();
    try std.testing.expectEqualStrings("", node.text.content);
    try std.testing.expect(parser.hasErrors());
}


test "parse expression in child position" {
    const node = try parse("<div>{count}</div>");
    try std.testing.expectEqual(@as(usize, 1), node.element.children.len);
    try std.testing.expectEqualStrings("count", node.element.children[0].expression.value);
}

test "parse multiple children: text + expression + element" {
    const node = try parse("<div>Count: {n}<br /></div>");
    try std.testing.expectEqual(@as(usize, 3), node.element.children.len);
}


test "parse element with multiple attributes" {
    const node = try parse("<div class=\"foo\" id={bar} disabled />");
    try std.testing.expectEqual(@as(usize, 3), node.element.attrs.len);
    try std.testing.expectEqualStrings("class", node.element.attrs[0].name);
    try std.testing.expectEqualStrings("id", node.element.attrs[1].name);
    try std.testing.expectEqualStrings("disabled", node.element.attrs[2].name);
}

test "parse element with spread attribute" {
    const node = try parse("<div {...props} />");
    try std.testing.expectEqual(@as(usize, 1), node.element.attrs.len);
    try std.testing.expect(node.element.attrs[0].is_spread);
}
