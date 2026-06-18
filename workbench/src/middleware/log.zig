const std = @import("std");
const schnell = @import("schnell");
const Middleware = schnell.Middleware;
const Request = schnell.Request;
const Response = schnell.Response;

const log = std.log.scoped(.http);

pub const LogMiddleware = struct {
    pub fn execute(self: *LogMiddleware, allocator: std.mem.Allocator, req: *const Request, res: *Response) !Middleware.Action {
        _ = self;
        _ = allocator;
        _ = res;

        log.info("{s} {s}", .{ req.method.toString(), req.path });

        return .next;
    }

    pub fn middleware(self: *LogMiddleware) Middleware {
        return Middleware.from(LogMiddleware, self);
    }
};
