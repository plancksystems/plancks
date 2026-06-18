const std = @import("std");
const schnell = @import("schnell");
const SchemaRequest = @import("../model/requests/schema.zig").SchemaRequest;
const SchemaResponse = @import("../model/responses/schema.zig").SchemaResponse;
const services_mod = @import("../tasks/services.zig");
const DbEntry = services_mod.DbEntry;
const planck = @import("planck");
const proto = planck.proto;
const Ctx = @import("../ctx.zig").Ctx;
const json = @import("json.zig");

const log = std.log.scoped(.api_schema);

pub fn handle(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator, req: *const schnell.Request, res: *schnell.Response) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr orelse return error.NoContext));
    const body = try req.getBody(allocator, SchemaRequest);

    if (body.action.len == 0) {
        try res.json(try json.serialize(allocator, SchemaResponse{ .success = false, .@"error" = "Action is required" }));
        return;
    }
    if (body.ns.len == 0) {
        try res.json(try json.serialize(allocator, SchemaResponse{ .success = false, .@"error" = "Namespace is required" }));
        return;
    }

    const raw_name = body.service orelse {
        try res.json(try json.serialize(allocator, SchemaResponse{ .success = false, .@"error" = "Service is required" }));
        return;
    };

    const service_name = resolveWriteServiceName(raw_name, ctx.services.databases);

    if (std.mem.eql(u8, service_name, "systemdb")) {
        try res.json(try json.serialize(allocator, SchemaResponse{
            .success = false,
            .@"error" = "systemdb is read-only — schema changes are managed by the workbench bootstrap",
        }));
        return;
    }

    const conn = ctx.services.pool.acquire(service_name) catch {
        try res.json(try json.serialize(allocator, SchemaResponse{ .success = false, .@"error" = "Not connected to service" }));
        return;
    };
    var broken = false;
    defer ctx.services.pool.release(service_name, broken);

    if (std.mem.eql(u8, body.action, "create-store")) {
        conn.client.create(proto.Store{
            .id = 0,
            .store_id = 0,
            .ns = body.ns,
            .description = if (body.description.len > 0) body.description else null,
        }) catch |err| {
            broken = true;
            try res.json(try json.serialize(allocator, SchemaResponse{ .success = false, .@"error" = @errorName(err) }));
            return;
        };
    } else if (std.mem.eql(u8, body.action, "create-index")) {
        if (body.field.len == 0) {
            try res.json(try json.serialize(allocator, SchemaResponse{ .success = false, .@"error" = "Field name is required" }));
            return;
        }

        conn.client.create(proto.Index{
            .id = 0,
            .store_id = 0,
            .ns = body.ns,
            .field = body.field,
            .field_type = parseFieldType(body.field_type),
            .unique = std.mem.eql(u8, body.unique, "true"),
            .description = if (body.description.len > 0) body.description else null,
        }) catch |err| {
            broken = true;
            try res.json(try json.serialize(allocator, SchemaResponse{ .success = false, .@"error" = @errorName(err) }));
            return;
        };
    } else if (std.mem.eql(u8, body.action, "drop-store")) {
        conn.client.drop(.Store, body.ns) catch |err| {
            broken = true;
            try res.json(try json.serialize(allocator, SchemaResponse{ .success = false, .@"error" = @errorName(err) }));
            return;
        };
    } else if (std.mem.eql(u8, body.action, "drop-index")) {
        conn.client.drop(.Index, body.ns) catch |err| {
            broken = true;
            try res.json(try json.serialize(allocator, SchemaResponse{ .success = false, .@"error" = @errorName(err) }));
            return;
        };
    } else {
        try res.json(try json.serialize(allocator, SchemaResponse{ .success = false, .@"error" = "Unknown schema action" }));
        return;
    }

    try res.json(try json.serialize(allocator, SchemaResponse{ .success = true }));
}

fn parseFieldType(s: []const u8) proto.FieldType {
    if (std.mem.eql(u8, s, "U32")) return .U32;
    if (std.mem.eql(u8, s, "U64")) return .U64;
    if (std.mem.eql(u8, s, "I32")) return .I32;
    if (std.mem.eql(u8, s, "I64")) return .I64;
    if (std.mem.eql(u8, s, "F32")) return .F32;
    if (std.mem.eql(u8, s, "F64")) return .F64;
    if (std.mem.eql(u8, s, "Boolean")) return .Boolean;
    if (std.mem.eql(u8, s, "Integer")) return .I64;
    return .String;
}

fn resolveWriteServiceName(name: []const u8, databases: []const DbEntry) []const u8 {
    if (std.mem.endsWith(u8, name, ".db.query")) {
        const base = name[0 .. name.len - "query".len];
        for (databases) |entry| {
            if (std.mem.startsWith(u8, entry.name, base) and
                std.mem.endsWith(u8, entry.name, ".db.command"))
            {
                return entry.name;
            }
        }
    }
    return name;
}
