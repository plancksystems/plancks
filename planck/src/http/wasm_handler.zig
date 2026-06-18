const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const WasmRuntime = @import("../wasm/runtime.zig").WasmRuntime;
const HttpMethodTag = @import("../common/metrics.zig").HttpMethodTag;
const StopWatch = @import("utils").StopWatch;

pub fn handleRaw(allocator: Allocator, raw_request: []const u8, ctx: ?*anyopaque) ![]const u8 {
    const wasm_runtime: *WasmRuntime = @ptrCast(@alignCast(ctx orelse return error.MissingWasmContext));
    const io = wasm_runtime.io;
    const metrics = wasm_runtime.db_engine.engine_metrics;
    const method = parseHttpMethod(raw_request);

    if (metricsRoute(raw_request)) |kind| switch (kind) {
        .read => return try renderMetrics(allocator, &wasm_runtime.metrics),
        .reset => {
            wasm_runtime.metrics.reset();
            return try allocator.dupe(u8, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n");
        },
    };

    var wasm_sw = metrics.wasm.start(io);
    var http_sw = metrics.http.start(io, method);
    defer {
        metrics.wasm.stop(io, &wasm_sw);
        metrics.http.stop(io, &http_sw, method);
    }

    return wasm_runtime.handleRequestRaw(allocator, raw_request) catch |err| {
        const log = std.log.scoped(.wasm);
        log.err("WASM raw handler error: {s}", .{@errorName(err)});
        return err;
    };
}

const MetricsRoute = enum { read, reset };

fn metricsRoute(raw: []const u8) ?MetricsRoute {
    if (std.mem.startsWith(u8, raw, "GET /__wasm_metrics ") or
        std.mem.startsWith(u8, raw, "GET /__wasm_metrics\r")) return .read;
    if (std.mem.startsWith(u8, raw, "POST /__wasm_metrics/reset ") or
        std.mem.startsWith(u8, raw, "POST /__wasm_metrics/reset\r")) return .reset;
    return null;
}

fn renderMetrics(allocator: Allocator, m: anytype) ![]const u8 {
    var body_buf: [4096]u8 = undefined;
    const body = try m.writeJson(&body_buf);
    return try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
}

fn parseHttpMethod(raw: []const u8) HttpMethodTag {
    const space = std.mem.indexOfScalar(u8, raw, ' ') orelse return .GET;
    const method_str = raw[0..space];
    if (std.mem.eql(u8, method_str, "GET")) return .GET;
    if (std.mem.eql(u8, method_str, "POST")) return .POST;
    if (std.mem.eql(u8, method_str, "PUT")) return .PUT;
    if (std.mem.eql(u8, method_str, "DELETE")) return .DELETE;
    if (std.mem.eql(u8, method_str, "PATCH")) return .PATCH;
    if (std.mem.eql(u8, method_str, "HEAD")) return .HEAD;
    if (std.mem.eql(u8, method_str, "OPTIONS")) return .OPTIONS;
    return .GET;
}
