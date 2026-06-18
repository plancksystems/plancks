const std = @import("std");
const schnell = @import("schnell");
const Middleware = schnell.Middleware;
const Request = schnell.Request;
const Response = schnell.Response;

pub const AuthMiddleware = struct {
    connected: *bool,

    pub fn execute(self: *AuthMiddleware, allocator: std.mem.Allocator, req: *const Request, res: *Response) !Middleware.Action {
        _ = allocator;

        if (isExempt(req.path)) return .next;

        if (!self.connected.*) {
            res.status = .unauthorized;
            try res.setHeader("Content-Type", "application/json");
            try res.write("{\"success\":false,\"error\":\"Not authenticated. Connect to system DB first.\"}");
            return .stop;
        }

        return .next;
    }

    fn isExempt(path: []const u8) bool {
        const exempt = [_][]const u8{
            "/api/system-db/status",
            "/api/system-db/connect",
            "/",
            "/index.html",
            "/index.js",
            "/index.css",
            "/ready",
        };
        for (&exempt) |p| {
            if (std.mem.eql(u8, path, p)) return true;
        }
        if (std.mem.endsWith(u8, path, ".css") or
            std.mem.endsWith(u8, path, ".js") or
            std.mem.endsWith(u8, path, ".ico") or
            std.mem.endsWith(u8, path, ".png") or
            std.mem.endsWith(u8, path, ".svg"))
        {
            return true;
        }
        return false;
    }

    pub fn middleware(self: *AuthMiddleware) Middleware {
        return Middleware.from(AuthMiddleware, self);
    }
};
