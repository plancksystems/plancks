
const std = @import("std");
const planck = @import("planck");
const web = @import("web");

const Ctx = @import("ctx.zig").Ctx;
const routes = @import("routes.zig");

extern fn host_respond(ptr: [*]const u8, len: u32) void;

var app: web.WasmApp = undefined;
var client: planck.Client = undefined;
var ctx: Ctx = undefined;

export fn init(config_ptr: ?[*]const u8, config_len: u32) i32 {
    const allocator = std.heap.wasm_allocator;
    client = planck.Client.init(allocator, 64 * 1024) catch return -1;
    ctx = .{ .client = &client };

    const yaml_text = if (config_ptr) |ptr| ptr[0..config_len] else &.{};
    app = web.WasmApp.init(allocator, .{}, yaml_text) catch return -1;
    routes.register(&app, &ctx) catch return -1;

    app.onResponse(struct {
        fn hook(req: *const web.Request, res: *web.Response, resp_buf: []u8) void {
            _ = req;
            const bytes = res.toBytes(resp_buf) catch return;
            host_respond(bytes.ptr, @intCast(bytes.len));
        }
    }.hook);

    return 0;
}

export fn process(req_ptr: [*]const u8, req_len: u32) i32 {
    app.process(req_ptr, req_len) catch return -1;
    return 0;
}
