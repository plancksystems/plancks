const std = @import("std");
const schnell = @import("schnell");
const Middleware = schnell.Middleware;
const Request = schnell.Request;
const Response = schnell.Response;

const log = std.log.scoped(.error_handler);

pub const ErrorHandlerMiddleware = struct {
    pub fn execute(self: *ErrorHandlerMiddleware, allocator: std.mem.Allocator, req: *const Request, res: *Response) !Middleware.Action {
        _ = self;
        _ = allocator;
        _ = req;
        _ = res;

        return .next;
    }

    pub fn middleware(self: *ErrorHandlerMiddleware) Middleware {
        return Middleware.from(ErrorHandlerMiddleware, self);
    }
};

pub fn errResponse(res: *Response, message: []const u8) !void {
    res.status = .internal_server_error;
    try res.setHeader("Content-Type", "application/json");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    try buf.appendSlice(std.heap.page_allocator, "{\"success\":false,\"error\":\"");
    for (message) |c| {
        switch (c) {
            '"' => try buf.appendSlice(std.heap.page_allocator, "\\\""),
            '\\' => try buf.appendSlice(std.heap.page_allocator, "\\\\"),
            '\n' => try buf.appendSlice(std.heap.page_allocator, "\\n"),
            '\r' => {},
            else => try buf.append(std.heap.page_allocator, c),
        }
    }
    try buf.appendSlice(std.heap.page_allocator, "\"}");
    try res.write(buf.items);
}
