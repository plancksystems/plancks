
const Ctx = @import("../../core/ctx.zig").Ctx;

const list = @import("handlers/list_handler.zig");
const create = @import("handlers/create_handler.zig");
const toggle = @import("handlers/toggle_handler.zig");
const delete_h = @import("handlers/delete_handler.zig");

pub fn register(app: anytype, ctx: *Ctx) !void {
    try app.get("/tasks", list.handle, ctx, .{});
    try app.post("/tasks", create.handle, ctx, .{});
    try app.put("/tasks/:id", toggle.handle, ctx, .{});
    try app.delete("/tasks/:id", delete_h.handle, ctx, .{});
}
