const std = @import("std");
const testing = std.testing;
const app_meta = @import("app_meta");

test "parseConfigYaml: extracts name and description from app: section" {
    const yaml =
        \\app:
        \\  name: eshop
        \\  description: "eShop microservices demo"
        \\  port: 3000
        \\
        \\workbench:
        \\  url: "http://127.0.0.1:2369"
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const meta = try app_meta.parseConfigYaml(arena.allocator(), yaml, "config.yaml");
    try testing.expectEqualStrings("eshop", meta.name);
    try testing.expectEqualStrings("eShop microservices demo", meta.description);
}

test "parseConfigYaml: missing app.name returns InvalidYaml" {
    const yaml =
        \\app:
        \\  description: "no name here"
        \\
        \\workbench:
        \\  url: x
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = app_meta.parseConfigYaml(arena.allocator(), yaml, "config.yaml");
    try testing.expectError(error.InvalidYaml, result);
}

test "parseConfigYaml: no app: section returns InvalidYaml" {
    const yaml =
        \\workbench:
        \\  url: x
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = app_meta.parseConfigYaml(arena.allocator(), yaml, "config.yaml");
    try testing.expectError(error.InvalidYaml, result);
}

test "parseConfigYaml: description optional, defaults to empty" {
    const yaml =
        \\app:
        \\  name: bare-app
        \\  port: 3000
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const meta = try app_meta.parseConfigYaml(arena.allocator(), yaml, "config.yaml");
    try testing.expectEqualStrings("bare-app", meta.name);
    try testing.expectEqualStrings("", meta.description);
}
