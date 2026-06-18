
const std = @import("std");
const web = @import("web");
const Request = web.Request;
const Response = web.Response;

const Ctx = @import("../ctx.zig").Ctx;
const TaskList = @import("../fragments/task_list.zig").TaskList;
const repo = @import("../repo.zig");
const Task = @import("../models/task.zig").Task;

pub fn handle(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, _: *const Request, res: *Response) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));

    const tasks = repo.TaskModel.find(ctx.client, allocator, .{}) catch &[_]Task{};
    defer if (tasks.len > 0) allocator.free(tasks);

    var out: std.ArrayList(u8) = .empty;
    try TaskList.render(.{ .tasks = tasks }, &out, allocator);
    try res.html(out.items);
}
