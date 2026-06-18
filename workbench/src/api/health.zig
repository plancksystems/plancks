const std = @import("std");
const Allocator = std.mem.Allocator;
const schnell = @import("schnell");
const Ctx = @import("../ctx.zig").Ctx;
const json = @import("json.zig");

pub const HealthResponse = struct {
    ready: bool = false,
    systemdb: []const u8 = "disconnected",
    role: []const u8 = "",
};

pub fn handle(ctx_ptr: ?*anyopaque, allocator: Allocator, _: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));

    const ready = ctx.services.storage != null;
    const body = try json.serialize(allocator, HealthResponse{
        .ready = ready,
        .systemdb = if (ready) "connected" else "disconnected",
    });
    try res.json(body);
}
