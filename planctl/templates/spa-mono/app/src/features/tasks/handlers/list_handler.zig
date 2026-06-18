
const std = @import("std");
const web = @import("web");
const Request = web.Request;
const Response = web.Response;

const Ctx = @import("../../../core/ctx.zig").Ctx;
const repo = @import("../repo.zig");
const Task = @import("../models/task.zig").Task;

pub fn handle(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, _: *const Request, res: *Response) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));

    const tasks = repo.TaskModel.find(ctx.client, allocator, .{}) catch &[_]Task{};
    defer if (tasks.len > 0) allocator.free(tasks);

    const body = try std.json.Stringify.valueAlloc(allocator, tasks, .{});
    try res.json(body);
}
