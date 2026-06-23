const std = @import("std");
const planck = @import("planck");
const schnell = @import("schnell");
const Query = planck.Query;
const pql = planck.pql;
const QueryRequest = @import("../model/requests/query.zig").QueryRequest;
const QueryResponse = @import("../model/responses/query.zig").QueryResponse;
const Ctx = @import("../ctx.zig").Ctx;

const interactive_query_timeout: planck.TimeoutConfig = .{
    .connect_timeout_ms = 5000,
    .read_timeout_ms = 30000,
    .write_timeout_ms = 10000,
    .operation_timeout_ms = 30000,
};

const log = std.log.scoped(.api_query);

pub fn handle(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));

    const inflight = ctx.inflight_queries.fetchAdd(1, .monotonic);
    defer _ = ctx.inflight_queries.fetchSub(1, .monotonic);
    if (inflight >= Ctx.MAX_INFLIGHT_QUERIES) {
        res.status = .service_unavailable;
        try res.json(try std.json.Stringify.valueAlloc(allocator, QueryResponse{
            .success = false,
            .@"error" = "Too many in-flight queries; try again shortly.",
        }, .{ .emit_null_optional_fields = false }));
        return;
    }

    const body = try req.getBody(allocator, QueryRequest);

    if (body.query.len == 0) {
        try res.json(try std.json.Stringify.valueAlloc(allocator, QueryResponse{ .success = false, .@"error" = "Query is required" }, .{ .emit_null_optional_fields = false }));
        return;
    }

    var resolved_name: ?[]const u8 = body.service;
    if (resolved_name == null) {
        if (body.db) |idx| {
            const i: usize = @intCast(idx);
            if (i < ctx.services.databases.len) {
                resolved_name = ctx.services.databases[i].name;
            }
        }
    }
    const service_name = resolved_name orelse {
        try res.json(try std.json.Stringify.valueAlloc(allocator, QueryResponse{ .success = false, .@"error" = "Service is required" }, .{ .emit_null_optional_fields = false }));
        return;
    };

    const conn = ctx.services.pool.acquire(service_name) catch {
        try res.json(try std.json.Stringify.valueAlloc(allocator, QueryResponse{ .success = false, .@"error" = "Not connected to service" }, .{ .emit_null_optional_fields = false }));
        return;
    };
    defer ctx.services.pool.release(service_name, false);

    const saved_timeout = conn.client.timeout_config;
    conn.client.setTimeoutConfig(interactive_query_timeout);
    defer conn.client.setTimeoutConfig(saved_timeout);

    var query_ast = pql.parse(allocator, body.query) catch |err| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Parse error ({s}). Use: store.filter(...).limit(n)", .{@errorName(err)}) catch "Parse error";
        try res.json(try std.json.Stringify.valueAlloc(allocator, QueryResponse{ .success = false, .@"error" = msg }, .{ .emit_null_optional_fields = false }));
        return;
    };
    defer query_ast.deinit();

    if (std.mem.eql(u8, service_name, "systemdb") and query_ast.mutation != null) {
        try res.json(try std.json.Stringify.valueAlloc(allocator, QueryResponse{
            .success = false,
            .@"error" = "systemdb is read-only — use Apps / Schedules / Deploy panels to modify state",
        }, .{ .emit_null_optional_fields = false }));
        return;
    }

    const store_name = query_ast.store orelse {
        try res.json(try std.json.Stringify.valueAlloc(allocator, QueryResponse{ .success = false, .@"error" = "No store specified. Use: store.filter(...)" }, .{ .emit_null_optional_fields = false }));
        return;
    };

    var query = Query.init(conn.client);
    defer query.deinit();

    _ = query.store(store_name);

    if (query_ast.doc_id) |doc_id| {
        _ = query.readByKey(doc_id);
    }

    for (query_ast.filters.items, 0..) |filter, i| {
        if (i > 0 and query_ast.filters.items[i - 1].logic == .@"or") {
            _ = query.@"or"(filter.field, filter.op, filter.value);
        } else {
            _ = query.where(filter.field, filter.op, filter.value);
        }
    }

    if (query_ast.limit_val) |lim| _ = query.limit(lim);
    if (query_ast.skip_val) |sk| _ = query.skip(sk);
    if (query_ast.after_val) |av| _ = query.after(av);

    if (query_ast.order_by) |ob| {
        for (ob.items) |spec| _ = query.orderBy(spec.field, spec.direction);
    }

    if (query_ast.projection) |proj| {
        if (proj.items.len > 0) _ = query.select(proj.items);
    }

    if (query_ast.group_by) |gb| {
        for (gb.items) |field| _ = query.groupBy(field);
    }

    if (query_ast.aggregations) |aggs| {
        for (aggs.items) |agg| {
            switch (agg.func) {
                .count => _ = query.count(agg.name),
                .sum => if (agg.field) |f| {
                    _ = query.sum(agg.name, f);
                },
                .avg => if (agg.field) |f| {
                    _ = query.avg(agg.name, f);
                },
                .min => if (agg.field) |f| {
                    _ = query.min(agg.name, f);
                },
                .max => if (agg.field) |f| {
                    _ = query.max(agg.name, f);
                },
            }
        }
    }

    if (query_ast.mutation) |mut| {
        switch (mut) {
            .insert => |json_payload| {
                const bson_payload = planck.bson.fromJson(query.allocator, json_payload) catch {
                    try res.json(try std.json.Stringify.valueAlloc(allocator, QueryResponse{ .success = false, .@"error" = "Failed to convert document to BSON" }, .{ .emit_null_optional_fields = false }));
                    return;
                };
                query.ast.mutation = .{ .insert = bson_payload };
                query_ast.allocator.free(json_payload);
            },
            .update => |json_payload| {
                const bson_payload = planck.bson.fromJson(query.allocator, json_payload) catch {
                    try res.json(try std.json.Stringify.valueAlloc(allocator, QueryResponse{ .success = false, .@"error" = "Failed to convert update to BSON" }, .{ .emit_null_optional_fields = false }));
                    return;
                };
                query.ast.mutation = .{ .update = bson_payload };
                query_ast.allocator.free(json_payload);
            },
            .delete => {
                query.ast.mutation = .delete;
            },
        }
        query_ast.mutation = null;
    }

    if (query_ast.query_type == .count) _ = query.countOnly();

    var result = query.run() catch {
        try res.json(try std.json.Stringify.valueAlloc(allocator, QueryResponse{ .success = false, .@"error" = "Query execution failed" }, .{ .emit_null_optional_fields = false }));
        return;
    };
    defer result.deinit();

    if (!result.success) {
        const err_msg = result.error_message orelse "Query failed";
        try res.json(try std.json.Stringify.valueAlloc(allocator, QueryResponse{ .success = false, .@"error" = err_msg }, .{ .emit_null_optional_fields = false }));
        return;
    }

    if (result.data) |data| {
        const json_data = planck.bson.toJsonArray(allocator, data) catch {
            try res.json(try std.json.Stringify.valueAlloc(allocator, QueryResponse{ .success = false, .@"error" = "Failed to convert results" }, .{ .emit_null_optional_fields = false }));
            return;
        };
        const body_str = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"data\":{s}}}", .{json_data});
        try res.json(body_str);
        return;
    }

    try res.json(try std.json.Stringify.valueAlloc(allocator, QueryResponse{ .success = true, .data = "[]" }, .{ .emit_null_optional_fields = false }));
}
