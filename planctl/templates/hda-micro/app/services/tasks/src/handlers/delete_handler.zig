
const std = @import("std");
const web = @import("web");
const Request = web.Request;
const Response = web.Response;

const Ctx = @import("../ctx.zig").Ctx;
const TaskList = @import("../fragments/task_list.zig").TaskList;
const repo = @import("../repo.zig");

pub fn handle(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const Request, res: *Response) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));

    const id_str = req.getLocal("id") orelse return error.InvalidRequest;
    const id = std.fmt.parseInt(i64, id_str, 10) catch return error.InvalidRequest;

    try repo.TaskModel.deleteOne(ctx.client, allocator, id);

    const tasks = try repo.TaskModel.find(ctx.client, allocator, .{});
    defer allocator.free(tasks);

    var out: std.ArrayList(u8) = .empty;
    try TaskList.render(.{ .tasks = tasks }, &out, allocator);
    try res.html(out.items);
}
