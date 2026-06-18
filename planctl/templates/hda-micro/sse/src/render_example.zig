
const std = @import("std");
const Allocator = std.mem.Allocator;
const bson = @import("bson");
const ssehub = @import("ssehub");

const Item = @import("models/item.zig").Item;
const ExampleCard = @import("fragments/example_card.zig").ExampleCard;
const hub_mod = @import("hub.zig");

const log = std.log.scoped(.__PROJECT_NAME___sse);

pub fn publish(c: *hub_mod.HubCtx, a: Allocator, frame: ssehub.ChangeRecord) !void {
    const body = frame.value orelse return;

    const item = bson.decode(a, Item, body) catch |err| {
        log.warn("render_example: bson decode failed: {s}", .{@errorName(err)});
        return;
    };

    var html: std.ArrayList(u8) = .empty;
    try ExampleCard.render(.{ .item = item }, &html, a);

    const patch_data = try std.fmt.allocPrint(a, "elements {s}", .{html.items});

    _ = c.bus.publish("example", .{
        .event = "datastar-patch-elements",
        .data = patch_data,
    }) catch |err| {
        log.warn("render_example: publish failed: {s}", .{@errorName(err)});
        return;
    };
}
