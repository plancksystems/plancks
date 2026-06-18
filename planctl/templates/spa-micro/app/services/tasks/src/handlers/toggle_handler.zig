
const std = @import("std");
const web = @import("web");
const Request = web.Request;
const Response = web.Response;

const Ctx = @import("../ctx.zig").Ctx;
const ToggleTaskBody = @import("../models/task.zig").ToggleTaskBody;
const repo = @import("../repo.zig");

pub fn handle(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const Request, res: *Response) !void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));

    const id_str = req.getLocal("id") orelse return error.InvalidRequest;
    const id = std.fmt.parseInt(i64, id_str, 10) catch return error.InvalidRequest;

    const body = try req.getBody(allocator, ToggleTaskBody);
    const updated = try repo.TaskModel.updateOne(ctx.client, allocator, id, body);

    const reply = try std.json.Stringify.valueAlloc(allocator, updated, .{});
    try res.json(reply);
}
