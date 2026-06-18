
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ssehub = @import("ssehub");

const render_example = @import("render_example.zig");

const log = std.log.scoped(.__PROJECT_NAME___sse);

pub const HubCtx = struct {
    allocator: Allocator,
    io: Io,
    bus: *ssehub.EventBus,

    pub fn init(allocator: Allocator, io: Io, bus: *ssehub.EventBus) HubCtx {
        return .{ .allocator = allocator, .io = io, .bus = bus };
    }

    pub fn deinit(self: *HubCtx) void {
        _ = self;
    }
};

pub fn processFrame(frame: ssehub.ChangeRecord, alloc: Allocator, ctx_ptr: ?*anyopaque) anyerror!void {
    const c: *HubCtx = @ptrCast(@alignCast(ctx_ptr orelse return));

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    log.info("hub: frame lsn={d} store={s} kind={s} value.len={d}", .{
        frame.lsn,
        frame.store_ns,
        @tagName(frame.kind),
        if (frame.value) |v| v.len else 0,
    });

    try render_example.publish(c, a, frame);
}
