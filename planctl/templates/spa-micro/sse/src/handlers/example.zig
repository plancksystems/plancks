const std = @import("std");
const Allocator = std.mem.Allocator;
const schnell = @import("schnell");
const ssehub = @import("ssehub");

const hub_mod = @import("../hub.zig");

const log = std.log.scoped(.__PROJECT_NAME___sse);

fn parseLastEventId(header_value: ?[]const u8) u64 {
    const value = header_value orelse return 0;
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(u64, trimmed, 10) catch 0;
}

pub fn handle(ctx_ptr: ?*anyopaque, handler_allocator: Allocator, req: *const schnell.Request, writer: *std.Io.Writer) anyerror!void {
    const ctx: *hub_mod.HubCtx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));

    if (!ctx.bus.canAcceptSubscriber()) {
        log.warn("example: subscriber cap reached, rejecting", .{});
        return error.ServiceUnavailable;
    }

    const last_event_id = parseLastEventId(req.getHeader("Last-Event-ID"));

    log.info("example: subscribe last_event_id={d}", .{last_event_id});
    defer log.info("example: exit", .{});

    try ssehub.wire.writeHeaders(writer);
    try ssehub.wire.writeRetry(writer, ctx.bus.config.retry_ms);
    try writer.flush();

    const sub = try ssehub.Subscriber.init(handler_allocator, writer, ctx.io, ssehub.DEFAULT_QUEUE_SIZE);
    defer sub.deinit();

    try ctx.bus.subscribe("example", sub, .{ .last_event_id = last_event_id });
    defer ctx.bus.unsubscribe("example", sub);

    sub.runWriter();
}
