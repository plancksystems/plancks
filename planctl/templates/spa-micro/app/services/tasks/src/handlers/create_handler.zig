
const std = @import("std");
const web = @import("web");
const Request = web.Request;
const Response = web.Response;

const Ctx = @import("../ctx.zig").Ctx;
const CreateTaskBody = @import("../models/task.zig").CreateTaskBody;
const repo = @import("../repo.zig");

pub fn handle(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const Request, res: *Response) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));

    const body = try req.getBody(allocator, CreateTaskBody);
    const created = try repo.TaskModel.create(ctx.client, allocator, body);

    const reply = try std.json.Stringify.valueAlloc(allocator, created, .{});
    try res.json(reply);
}
