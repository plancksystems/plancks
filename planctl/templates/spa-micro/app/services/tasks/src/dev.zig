const std = @import("std");
const builtin = @import("builtin");
const schnell = @import("schnell");
const planck = @import("planck");

const Ctx = @import("ctx.zig").Ctx;
const routes = @import("routes.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;
    defer if (builtin.mode == .Debug) {
        if (gpa.detectLeaks() > 0) std.process.exit(1);
    };

    var threaded: std.Io.Threaded = .init(allocator, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const io = threaded.io();

    const client = try planck.Client.init(allocator, io);
    var auth = try client.connect("127.0.0.1:24000;uid=admin;key=UGxhbmNrX0RlZmF1bHRfQWRtaW5fS2V5XzAwMTA=;tls=false");
    auth.deinit();

    var ctx = Ctx{ .client = client };

    var app = try schnell.App.init(allocator, .{
        .host = "127.0.0.1",
        .port = 4001,
    });
    defer app.deinit();

    var cors = schnell.CorsMiddleware.init(.{});
    try app.use(cors.middleware());

    try routes.register(&app, &ctx);

    std.debug.print("tasks service dev on http://127.0.0.1:4001\n", .{});
    try app.run(io);
}
